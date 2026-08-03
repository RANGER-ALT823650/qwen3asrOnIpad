import Foundation
import whisper

enum WhisperTranscriptionError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case unsupportedAudio
    case noSpeech
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "未找到内置的 Whisper base 模型。"
        case .modelLoadFailed:
            return "Whisper 模型加载失败。"
        case .unsupportedAudio:
            return "录音不是 16 kHz、单声道、16 位 PCM WAV。"
        case .noSpeech:
            return "录音中没有检测到清晰语音，请检查麦克风输入后重试。"
        case .transcriptionFailed:
            return "Whisper 未能完成识别。"
        }
    }
}

/// Keeps all native whisper.cpp work off the keyboard UI thread and serializes
/// access to its C context, which is not safe to use concurrently.
actor WhisperTranscriber {
    static let shared = WhisperTranscriber()

    private static let modelName = "ggml-base-q5_1"

    static var isModelBundled: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "bin") != nil
    }

    func transcribe(audioFileURL: URL) throws -> String {
        let samples = try PCM16WAV.samples(from: audioFileURL)
        guard !samples.isEmpty else {
            throw WhisperTranscriptionError.unsupportedAudio
        }
        guard PCM16WAV.containsAudibleSignal(samples) else {
            throw WhisperTranscriptionError.noSpeech
        }

        guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "bin") else {
            throw WhisperTranscriptionError.modelMissing
        }

        var contextParameters = whisper_context_default_params()
#if targetEnvironment(simulator)
        contextParameters.use_gpu = false
#else
        // The bundled whisper.cpp XCFramework contains the Metal backend. Keeping
        // GPU inference enabled is critical for the base model in a keyboard.
        contextParameters.use_gpu = true
        contextParameters.flash_attn = true
#endif

        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParameters) else {
            throw WhisperTranscriptionError.modelLoadFailed
        }
        defer { whisper_free(context) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        // whisper.cpp accepts nullptr, an empty string, or "auto" for
        // language detection. Keep the pointer alive through whisper_full;
        // explicitly using "auto" is more reliable across the simulator and
        // device framework builds than combining a nil pointer with the
        // detect_language flag.
        let language = Array("auto".utf8CString)
        parameters.detect_language = false
        parameters.no_context = true
        parameters.single_segment = false
        parameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 2)))

        let result = language.withUnsafeBufferPointer { languageBuffer in
            parameters.language = languageBuffer.baseAddress
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard result == 0 else {
            throw WhisperTranscriptionError.transcriptionFailed
        }

        let text = (0..<whisper_full_n_segments(context))
            .compactMap { index -> String? in
                guard let segment = whisper_full_get_segment_text(context, index) else { return nil }
                return String(cString: segment)
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }
}

private enum PCM16WAV {
    /// Reject near-silent captures before loading the model. This commonly
    /// happens when Simulator's audio input is not connected to the Mac mic.
    static func containsAudibleSignal(_ samples: [Float]) -> Bool {
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

    static func samples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw WhisperTranscriptionError.unsupportedAudio
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
            guard contentEnd <= data.count else { throw WhisperTranscriptionError.unsupportedAudio }

            if chunkID == "fmt ", chunkSize >= 16 {
                format = littleEndianUInt16(in: data, at: contentStart)
                channels = littleEndianUInt16(in: data, at: contentStart + 2)
                sampleRate = littleEndianUInt32(in: data, at: contentStart + 4)
                bitsPerSample = littleEndianUInt16(in: data, at: contentStart + 14)
            } else if chunkID == "data" {
                // A Data slice keeps the original index range. The sample
                // loop below is intentionally zero-based, so materialize a
                // new Data value before indexing it; otherwise a valid WAV
                // with a non-44-byte chunk layout can trap in Data.subscript.
                // AVAudioRecorder may leave the chunk length at zero if iOS
                // suspends or kills the recording owner before it finalizes
                // the header. The PCM frames are still present after the
                // header, so recover them from the actual end of the file.
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
            throw WhisperTranscriptionError.unsupportedAudio
        }

        return stride(from: 0, to: audioBytes.count, by: 2).map { offset in
            let sample = Int16(bitPattern: littleEndianUInt16(in: audioBytes, at: offset))
            return Float(sample) / 32_768
        }
    }

    private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
