import Foundation
@preconcurrency import AVFoundation
import OSLog
import whisper

/// Persistent Whisper service owned by the container app.
///
/// The keyboard extension is short-lived and can be torn down between input
/// method changes. Keeping the native context here means one app process owns
/// the model for all recording rounds. The context is released only when this
/// process is destroyed by iOS or the service itself is destroyed.
actor AppWhisperTranscriber {
    static let shared = AppWhisperTranscriber()

    private static let modelName = "ggml-base-q5_1"
    private let logger = Logger(subsystem: "project.qwen3asr", category: "whisper")
    private var context: OpaquePointer?
    private var contextUsesGPU = false

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    /// Loads the model once. Calling this again after a successful load is a
    /// cheap cache hit and never creates a second native context.
    func preload() throws {
        guard context == nil else {
            logger.debug("Whisper model already resident; reusing native context")
            return
        }

        guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "bin") else {
            logger.error("Whisper model is missing from the container app bundle")
            throw AppWhisperTranscriptionError.modelMissing
        }

        let startedAt = Date()
#if targetEnvironment(simulator)
        guard let cpuContext = makeContext(modelURL: modelURL, useGPU: false) else {
            logger.error("Whisper model failed to load on CPU")
            throw AppWhisperTranscriptionError.modelLoadFailed
        }
        context = cpuContext
        contextUsesGPU = false
#else
        if let gpuContext = makeContext(modelURL: modelURL, useGPU: true) {
            context = gpuContext
            contextUsesGPU = true
        } else {
            logger.warning("Whisper GPU context failed to load; falling back to CPU")
            guard let cpuContext = makeContext(modelURL: modelURL, useGPU: false) else {
                logger.error("Whisper model failed to load on CPU")
                throw AppWhisperTranscriptionError.modelLoadFailed
            }
            context = cpuContext
            contextUsesGPU = false
        }
#endif

        logger.info("Whisper model loaded into resident \(self.contextUsesGPU ? "GPU" : "CPU") context in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
    }

    func transcribe(audioFileURL: URL) throws -> String {
        try preload()

        let samples = try AudioSamples.samples(from: audioFileURL)
        guard !samples.isEmpty else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }
        guard PCM16WAV.containsAudibleSignal(samples) else {
            throw AppWhisperTranscriptionError.noSpeech
        }

        guard var activeContext = context else {
            throw AppWhisperTranscriptionError.modelLoadFailed
        }

        let startedAt = Date()
        var result = runTranscription(context: activeContext, samples: samples)

        // The Simulator always exercises the CPU backend, while a physical
        // device normally uses Metal. If Metal accepts model initialization but
        // fails during inference (observed on iOS 27 beta), rebuild a fresh CPU
        // context and retry this same recording once. A new context is required
        // because backend selection is fixed at whisper_init time.
        if result != 0, contextUsesGPU {
            logger.error("Whisper GPU transcription failed with code \(result); retrying on CPU")
            whisper_free(activeContext)
            context = nil
            contextUsesGPU = false

            guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "bin"),
                  let cpuContext = makeContext(modelURL: modelURL, useGPU: false) else {
                logger.error("Whisper CPU fallback context failed to load")
                throw AppWhisperTranscriptionError.modelLoadFailed
            }

            context = cpuContext
            activeContext = cpuContext
            result = runTranscription(context: activeContext, samples: samples)
        }

        guard result == 0 else {
            logger.error("Whisper transcription failed with code \(result)")
            throw AppWhisperTranscriptionError.transcriptionFailed(result)
        }

        let text = (0..<whisper_full_n_segments(activeContext))
            .compactMap { index -> String? in
                guard let segment = whisper_full_get_segment_text(activeContext, index) else { return nil }
                return String(cString: segment)
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("Whisper transcription finished on \(self.contextUsesGPU ? "GPU" : "CPU") in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s, characters=\(text.count)")
        return text
    }

    private func makeContext(modelURL: URL, useGPU: Bool) -> OpaquePointer? {
        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = useGPU
        contextParameters.flash_attn = useGPU
        return whisper_init_from_file_with_params(modelURL.path, contextParameters)
    }

    private func runTranscription(context: OpaquePointer, samples: [Float]) -> Int32 {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        let language = Array("auto".utf8CString)
        parameters.detect_language = false
        parameters.no_context = true
        parameters.single_segment = false
        parameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 2)))

        return language.withUnsafeBufferPointer { languageBuffer in
            parameters.language = languageBuffer.baseAddress
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }
    }
}

private enum AppWhisperTranscriptionError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case unsupportedAudio
    case noSpeech
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "未找到内置的 Whisper base 模型。"
        case .modelLoadFailed:
            return "Whisper 模型加载失败。"
        case .unsupportedAudio:
            return "录音文件无法转换为 Whisper 所需的 16 kHz 单声道音频。"
        case .noSpeech:
            return "录音中没有检测到清晰语音，请检查麦克风输入后重试。"
        case .transcriptionFailed(let code):
            return "Whisper 未能完成识别（错误码 \(code)）。"
        }
    }
}

private enum AudioSamples {
    nonisolated static func samples(from url: URL) throws -> [Float] {
        if url.pathExtension.lowercased() == "wav" {
            return try PCM16WAV.samples(from: url)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        let sourceFormat = file.processingFormat
        guard file.length > 0,
              file.length <= Int64(UInt32.max),
              sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        do {
            try file.read(into: sourceBuffer, frameCount: sourceFrameCount)
        } catch {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * ratio) + 32
        )
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error,
              conversionError == nil,
              targetBuffer.frameLength > 0,
              let channel = targetBuffer.floatChannelData?[0] else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        return Array(UnsafeBufferPointer(
            start: channel,
            count: Int(targetBuffer.frameLength)
        ))
    }
}

private enum PCM16WAV {
    /// A valid WAV may still contain only the Simulator's low-level input
    /// noise. Report that condition directly instead of spending time in the
    /// model and returning an unexplained empty string.
    nonisolated static func containsAudibleSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }

        var peak: Float = 0
        var sumOfSquares = 0.0
        for sample in samples {
            peak = max(peak, abs(sample))
            sumOfSquares += Double(sample * sample)
        }
        let rootMeanSquare = sqrt(sumOfSquares / Double(samples.count))
        return peak >= 0.01 || rootMeanSquare >= 0.002
    }

    nonisolated static func samples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        var offset = 12
        var format: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var audioBytes: Data?

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(littleEndianUInt32(in: data, at: offset + 4))
            let contentStart = offset + 8
            let contentEnd = contentStart + chunkSize
            guard contentEnd <= data.count else { throw AppWhisperTranscriptionError.unsupportedAudio }

            if chunkID == "fmt ", chunkSize >= 16 {
                format = littleEndianUInt16(in: data, at: contentStart)
                channels = littleEndianUInt16(in: data, at: contentStart + 2)
                sampleRate = littleEndianUInt32(in: data, at: contentStart + 4)
                bitsPerSample = littleEndianUInt16(in: data, at: contentStart + 14)
            } else if chunkID == "data" {
                // When the app is suspended or killed mid-recording,
                // AVAudioRecorder can leave the data size at zero even though
                // valid PCM frames follow. Recover those frames using the
                // actual file length; copying also resets the Data indices to
                // zero and avoids the historical slice-subscript crash.
                let audioEnd = chunkSize == 0 ? data.count : contentEnd
                audioBytes = Data(data[contentStart..<audioEnd])
                break
            }

            offset = contentEnd + (chunkSize % 2)
        }

        guard format == 1,
              channels == 1,
              sampleRate == 16_000,
              bitsPerSample == 16,
              let audioBytes,
              audioBytes.count.isMultiple(of: 2) else {
            throw AppWhisperTranscriptionError.unsupportedAudio
        }

        return stride(from: 0, to: audioBytes.count, by: 2).map { offset in
            let sample = Int16(bitPattern: littleEndianUInt16(in: audioBytes, at: offset))
            return Float(sample) / 32_768
        }
    }

    private nonisolated static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private nonisolated static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
