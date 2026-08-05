import AudioCommon
import Foundation
import MLX
import MLXCommon
import Qwen3ASR

/// Offline Qwen3-ASR 1.7B runtime shared by the real keyboard host app and
/// the optional lab target.
///
/// The bundled 5-bit safetensors file already contains both the 1.7B audio
/// tower and text decoder. Keeping the complete pipeline on MLX avoids the
/// separate Core ML encoder entirely.
///
/// MLX 0.31's Metal backend currently aborts while materializing this model on
/// iOS 27 (the command-buffer error is misleadingly surfaced as an "ML
/// Program" failure). Load and materialize weights on CPU, then run the heavy
/// model pass on Metal only while the container app is frontmost. Earlier iOS
/// releases retain the direct compiled GPU path.
actor HybridQwen3ASREngine {
    static let shared = HybridQwen3ASREngine()

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    private static let modelID = "aufklarer/Qwen3-ASR-1.7B-MLX-5bit"
    private static let iOSCacheLimit = 384 * 1024 * 1024

    static var backendDescription: String {
        usesHybridSafetyMode ? "MLX/CPU 加载 + Metal 前台" : "MLX/Metal GPU"
    }

    private static var usesHybridSafetyMode: Bool {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    private static var preparationDevice: Device {
        usesHybridSafetyMode ? .cpu : .gpu
    }

    private static var inferenceDevice: Device { .gpu }

    /// MLXNN implements common activations such as SiLU/GELU with lazily
    /// compiled transforms. They are valid on Metal, but evaluating one on the
    /// iOS CPU backend is a fatal `Compiled::eval_cpu` assertion rather than a
    /// catchable Swift error. Disabling compilation before the model's first
    /// forward pass makes those wrappers return their ordinary eager graph.
    private static func configureExecutionRuntime() {
        guard usesHybridSafetyMode else { return }
        MLX.compile(enable: false)

        // Qwen's async decoder can outlive the Swift TaskLocal scope used by
        // `withDefaultDevice`. Pin MLX's process-wide fallback as well so an
        // escaped evaluation cannot silently return to Metal after the host
        // app moves behind the keyboard.
        Device.setDefault(device: Self.preparationDevice)
    }

    private static func configureInferenceRuntime() {
        guard usesHybridSafetyMode else { return }
        Device.setDefault(device: Self.inferenceDevice)
    }

    private var model: Qwen3ASRModel?
    private var tokenizer: Qwen3Tokenizer?
    private var preparationTask: Task<LoadedModel, Error>?

    var isReady: Bool {
        model != nil
    }

    func prepare(progress: ProgressHandler? = nil) async throws {
        guard model == nil else {
            progress?(1, "模型已就绪")
            return
        }

        #if targetEnvironment(simulator)
        throw HybridQwen3ASRError.physicalDeviceRequired
        #else
        let task: Task<LoadedModel, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            let modelDirectory = try BundledModelAssets.modelDirectory()
            progress?(0.03, "检查内置 MLX 5-bit 模型")

            task = Task {
                Self.configureExecutionRuntime()

                // Speech Swift's large-model cache policy is tuned for Macs
                // and may retain up to one quarter of physical RAM. A keyboard
                // host needs more headroom for UIKit, the audio session and
                // iOS background services, so bound only the disposable MLX
                // cache; model weights remain intact.
                MLX.Memory.cacheLimit = min(
                    MLX.Memory.cacheLimit,
                    Self.iOSCacheLimit
                )

                return try await Device.withDefaultDevice(Self.preparationDevice) {
                    let model = try await Qwen3ASRModel.fromPretrained(
                        modelId: Self.modelID,
                        cacheDir: modelDirectory,
                        offlineMode: true
                    ) { fraction, message in
                        progress?(0.05 + min(max(fraction, 0), 1) * 0.93, message)
                    }
                    let tokenizer = Qwen3Tokenizer()
                    try tokenizer.load(
                        from: modelDirectory.appendingPathComponent("vocab.json")
                    )
                    return LoadedModel(value: model, tokenizer: tokenizer)
                }
            }
            preparationTask = task
        }

        do {
            let loadedModel = try await task.value
            model = loadedModel.value
            tokenizer = loadedModel.tokenizer
            preparationTask = nil
            progress?(1, "MLX 5-bit 模型已就绪（\(Self.backendDescription)）")
        } catch {
            preparationTask = nil
            throw QwenPipelineStageError(
                stage: "模型加载",
                backend: Self.backendDescription,
                underlying: error
            )
        }
        #endif
    }

    func transcribe(
        recordingURL: URL,
        timeLimit: TimeInterval = 180
    ) async throws -> TranscriptionResult {
        if model == nil {
            try await prepare()
        }
        guard let model, let tokenizer else {
            throw HybridQwen3ASRError.modelNotReady
        }

        let samples: [Float]
        do {
            samples = try AudioFileLoader.load(
                url: recordingURL,
                targetSampleRate: 16_000
            )
        } catch {
            throw QwenPipelineStageError(
                stage: "录音文件读取",
                backend: Self.backendDescription,
                underlying: error
            )
        }
        guard samples.count >= 1_600 else {
            throw HybridQwen3ASRError.recordingTooShort
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        guard timeLimit > 0 else {
            throw HybridQwen3ASRError.inferenceTimedOut
        }
        let deadline = startedAt.advanced(
            by: .milliseconds(Int64(timeLimit * 1_000))
        )
        defer { MLX.Memory.clearCache() }

        // A fixed 448-token decode makes a very short utterance spend minutes
        // producing junk after silence when EOS is missed. Budget generously
        // by duration instead: 32 seconds still receives 440 tokens, while a
        // one-second dictation stops after at most 37 tokens.
        let audioDuration = Double(samples.count) / 16_000
        let maxTokens = min(
            448,
            max(24, Int(ceil(audioDuration * 13)) + 24)
        )

        Self.configureInferenceRuntime()
        let text = try Device.withDefaultDevice(Self.inferenceDevice) {
            try Self.transcribeFast(
                model: model,
                tokenizer: tokenizer,
                samples: samples,
                sampleRate: 16_000,
                maxTokens: maxTokens,
                deadline: deadline
            )
        }

        let elapsed = startedAt.duration(to: clock.now)
        return TranscriptionResult(
            text: text,
            audioDuration: audioDuration,
            inferenceDuration: elapsed.timeInterval
        )
    }

    /// A deadline-aware copy of Qwen3-ASR's optimized greedy path. Keeping
    /// argmax on Metal avoids transferring the full vocabulary logits to the
    /// CPU for every token. The deadline is checked between decoder steps so
    /// an in-flight Metal command may finish, but no later token is scheduled.
    private static func transcribeFast(
        model: Qwen3ASRModel,
        tokenizer: Qwen3Tokenizer,
        samples: [Float],
        sampleRate: Int,
        maxTokens: Int,
        deadline: ContinuousClock.Instant
    ) throws -> String {
        try checkDeadline(deadline)

        let melFeatures = model.featureExtractor.process(
            samples,
            sampleRate: sampleRate
        )
        let batchedFeatures = melFeatures.expandedDimensions(axis: 0)
        var audioEmbeds = model.audioEncoder(batchedFeatures)
        audioEmbeds = audioEmbeds.expandedDimensions(axis: 0)

        try checkDeadline(deadline)
        guard let textDecoder = model.textDecoder else {
            throw HybridQwen3ASRError.modelNotReady
        }

        let tokens = Qwen3ASRTokens.self
        let numberOfAudioTokens = audioEmbeds.dim(1)
        var inputIDs: [Int32] = [
            tokens.imStartTokenId,
            tokens.systemTokenId,
            tokens.newlineTokenId,
            tokens.imEndTokenId,
            tokens.newlineTokenId,
            tokens.imStartTokenId,
            tokens.userTokenId,
            tokens.newlineTokenId,
            tokens.audioStartTokenId,
        ].map(Int32.init)

        let audioStartIndex = inputIDs.count
        inputIDs.append(
            contentsOf: repeatElement(
                Int32(tokens.audioTokenId),
                count: numberOfAudioTokens
            )
        )
        let audioEndIndex = inputIDs.count
        inputIDs.append(contentsOf: [
            tokens.audioEndTokenId,
            tokens.imEndTokenId,
            tokens.newlineTokenId,
            tokens.imStartTokenId,
            tokens.assistantTokenId,
            tokens.newlineTokenId,
            tokens.asrTextTokenId,
        ].map(Int32.init))

        let inputIDTensor = MLXArray(inputIDs).expandedDimensions(axis: 0)
        var inputEmbeds = textDecoder.embedTokens(inputIDTensor)
        let audioEmbedsTyped = audioEmbeds.asType(inputEmbeds.dtype)
        let beforeAudio = inputEmbeds[0..., 0..<audioStartIndex, 0...]
        let afterAudio = inputEmbeds[0..., audioEndIndex..., 0...]
        inputEmbeds = concatenated(
            [beforeAudio, audioEmbedsTyped, afterAudio],
            axis: 1
        )

        try checkDeadline(deadline)
        let (hiddenStates, initialCache) = textDecoder(
            inputsEmbeds: inputEmbeds,
            cache: nil
        )
        let sequenceLength = hiddenStates.dim(1)
        let lastHidden = hiddenStates[
            0...,
            (sequenceLength - 1)..<sequenceLength,
            0...
        ]
        let initialLogits = textDecoder.embedTokens.asLinear(lastHidden)
        let generatedTokens = try generateGreedyTokens(
            textDecoder: textDecoder,
            initialLogits: initialLogits,
            cache: initialCache,
            maxTokens: maxTokens,
            deadline: deadline
        )

        let rawText = tokenizer.decode(
            tokens: generatedTokens.map(Int.init)
        )
        if let marker = rawText.range(of: "<asr_text>") {
            return String(rawText[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rawText
    }

    private static func generateGreedyTokens(
        textDecoder: QuantizedTextModel,
        initialLogits: MLXArray,
        cache initialCache: [(MLXArray, MLXArray)],
        maxTokens: Int,
        deadline: ContinuousClock.Instant
    ) throws -> [Int32] {
        guard maxTokens > 0 else { return [] }

        var generatedTokens: [Int32] = []
        var nextTokenArray = argMax(initialLogits, axis: -1)
            .squeezed()
            .asType(.int32)
        var cache = initialCache
        asyncEval(nextTokenArray, cache)

        let endToken = Int32(Qwen3ASRTokens.eosTokenId)
        for step in 0..<maxTokens {
            try checkDeadline(deadline)

            var followingTokenArray: MLXArray?
            var followingCache: [(MLXArray, MLXArray)]?
            if step + 1 < maxTokens {
                let nextEmbedding = textDecoder.embedTokens(
                    nextTokenArray
                        .expandedDimensions(axis: 0)
                        .expandedDimensions(axis: 0)
                )
                let (hidden, newCache) = textDecoder(
                    inputsEmbeds: nextEmbedding,
                    cache: cache
                )
                let logits = textDecoder.embedTokens.asLinear(
                    hidden[0..., (-1)..., .ellipsis]
                )
                let token = argMax(logits, axis: -1)
                    .squeezed()
                    .asType(.int32)
                asyncEval(token, newCache)
                followingTokenArray = token
                followingCache = newCache
            }

            let nextToken = nextTokenArray.item(Int32.self)
            generatedTokens.append(nextToken)
            if nextToken == endToken { break }

            guard let followingTokenArray, let followingCache else { break }
            nextTokenArray = followingTokenArray
            cache = followingCache
        }
        return generatedTokens
    }

    private static func checkDeadline(
        _ deadline: ContinuousClock.Instant
    ) throws {
        guard ContinuousClock().now < deadline else {
            throw HybridQwen3ASRError.inferenceTimedOut
        }
    }

}

private struct QwenPipelineStageError: LocalizedError, CustomNSError {
    let stage: String
    let backend: String
    let underlying: Error

    static var errorDomain: String { "project.qwen3asr.pipeline" }
    var errorCode: Int { 1 }

    var errorDescription: String? {
        "\(stage)失败（\(backend)）：\(underlying.localizedDescription)"
    }

    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: errorDescription ?? "Qwen3-ASR 执行失败",
            NSUnderlyingErrorKey: underlying,
        ]
    }
}

/// Qwen3ASRModel predates Swift's Sendable annotations. The instance is still
/// safe here because it never leaves HybridQwen3ASREngine's serial isolation.
private struct LoadedModel: @unchecked Sendable {
    let value: Qwen3ASRModel
    let tokenizer: Qwen3Tokenizer
}

struct TranscriptionResult: Sendable {
    let text: String
    let audioDuration: TimeInterval
    let inferenceDuration: TimeInterval

    var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return inferenceDuration / audioDuration
    }
}

private enum BundledModelAssets {
    static let folderName = "Qwen3-ASR-1.7B-MLX-5bit"
    static let requiredFiles = [
        "model.safetensors",
        "config.json",
        "vocab.json",
        "merges.txt",
        "tokenizer_config.json",
    ]

    static func modelDirectory(bundle: Bundle = .main) throws -> URL {
        let candidates = [
            bundle.url(forResource: folderName, withExtension: nil),
            bundle.resourceURL?.appendingPathComponent(folderName, isDirectory: true),
        ].compactMap { $0 }

        for candidate in candidates where requiredFiles.allSatisfy({ fileName in
            FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(fileName).path
            )
        }) {
            return candidate
        }
        throw HybridQwen3ASRError.missingModelAssets
    }
}

enum HybridQwen3ASRError: LocalizedError {
    case physicalDeviceRequired
    case missingModelAssets
    case modelNotReady
    case recordingTooShort
    case inferenceTimedOut

    var errorDescription: String? {
        switch self {
        case .physicalDeviceRequired:
            return "Qwen3-ASR 1.7B 需要在支持 Metal 的真机上运行；模拟器只用于编译和界面检查。"
        case .missingModelAssets:
            return "App 包内的 Qwen3-ASR 1.7B MLX 5-bit 模型不完整。"
        case .modelNotReady:
            return "模型仍在加载，请保持 qwen3asr 打开，稍后再试。"
        case .recordingTooShort:
            return "录音太短，请至少说 0.1 秒。"
        case .inferenceTimedOut:
            return "本轮识别超过 180 秒，已停止继续生成。"
        }
    }
}

enum TranscriptionQuality {
    nonisolated static func repetitionWarning(for text: String) -> String? {
        guard containsSuspiciousRepetition(text) else { return nil }
        return "⚠️ 检测到识别结果中存在连续重复；已按模型原文完整插入，请检查"
    }

    /// Detects the common runaway shape (a short phrase repeated at least three
    /// times, or a longer phrase repeated twice) without rewriting the result.
    nonisolated static func containsSuspiciousRepetition(_ text: String) -> Bool {
        let characters = Array(text.filter { !$0.isWhitespace })
        guard characters.count >= 6 else { return false }

        let maximumUnitLength = min(24, characters.count / 2)
        for unitLength in 1...maximumUnitLength {
            let minimumRepeats = unitLength >= 6 ? 2 : 3
            let minimumSpan = unitLength * minimumRepeats
            guard characters.count >= minimumSpan else { continue }

            for start in 0...(characters.count - minimumSpan) {
                let unitEnd = start + unitLength
                let unit = Array(characters[start..<unitEnd])
                guard unit.contains(where: containsNonPunctuation) else { continue }

                var repetitions = 1
                var cursor = unitEnd
                while cursor + unitLength <= characters.count,
                      Array(characters[cursor..<(cursor + unitLength)]) == unit {
                    repetitions += 1
                    cursor += unitLength
                }
                if repetitions >= minimumRepeats,
                   repetitions * unitLength >= 6 {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func containsNonPunctuation(
        _ character: Character
    ) -> Bool {
        character.unicodeScalars.contains { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
        }
    }
}

private extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
