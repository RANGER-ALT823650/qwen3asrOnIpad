import AVFoundation
import Foundation

/// A deliberately small, foreground-only recorder for the model experiment.
///
/// The existing app recorder is coupled to the keyboard extension and App
/// Group state. Keeping this recorder local prevents the experiment target
/// from changing that production flow while still producing the 16 kHz mono
/// PCM that Qwen3-ASR expects.
@MainActor
final class LabAudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var recordingURL: URL?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start() async throws -> URL {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else {
            throw LabRecordingError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-asr-lab-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw LabRecordingError.couldNotStart
        }

        self.recorder = recorder
        recordingURL = url
        return url
    }

    func stop() throws -> URL {
        guard let recorder, let recordingURL else {
            throw LabRecordingError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        return recordingURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

enum LabRecordingError: LocalizedError {
    case microphonePermissionDenied
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "没有麦克风权限，请在系统设置中允许 Qwen3ASR Lab 使用麦克风。"
        case .couldNotStart:
            return "录音器没有成功启动。"
        case .notRecording:
            return "当前没有可停止的录音。"
        }
    }
}
