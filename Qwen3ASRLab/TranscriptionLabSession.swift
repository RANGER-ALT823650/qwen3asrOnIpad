import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionLabSession {
    enum Phase: Equatable {
        case loading(progress: Double, message: String)
        case ready
        case recording(startedAt: Date)
        case transcribing
        case failed(message: String)
    }

    var phase: Phase
    var transcript = ""
    var metrics: String?

    private let recorder: LabAudioRecorder
    private let engine: HybridQwen3ASREngine

    init(phase: Phase = .loading(progress: 0, message: "准备离线模型")) {
        self.phase = phase
        recorder = LabAudioRecorder()
        engine = HybridQwen3ASREngine()
    }

    static var preview: TranscriptionLabSession {
        let session = TranscriptionLabSession(phase: .ready)
        session.transcript = "这里会显示用户停止录音后的离线转写结果。"
        session.metrics = "音频 4.8 秒 · 推理 0.9 秒 · RTF 0.188"
        return session
    }

    var canRecord: Bool {
        phase == .ready
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func prepareModel() async {
        if await engine.isReady {
            phase = .ready
            return
        }

        phase = .loading(progress: 0, message: "检查内置模型")
        do {
            let session = self
            try await engine.prepare { progress, message in
                Task { @MainActor in
                    session.phase = .loading(progress: progress, message: message)
                }
            }
            phase = .ready
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopAndTranscribe()
        } else {
            await startRecording()
        }
    }

    func retryLoading() {
        Task {
            await prepareModel()
        }
    }

    private func startRecording() async {
        guard canRecord else { return }
        do {
            _ = try await recorder.start()
            transcript = ""
            metrics = nil
            phase = .recording(startedAt: Date())
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private func stopAndTranscribe() async {
        let recordingURL: URL
        do {
            recordingURL = try recorder.stop()
        } catch {
            phase = .failed(message: error.localizedDescription)
            return
        }

        phase = .transcribing
        defer {
            try? FileManager.default.removeItem(at: recordingURL)
        }

        do {
            let result = try await engine.transcribe(recordingURL: recordingURL)
            transcript = result.text.isEmpty ? "（没有识别到文字）" : result.text
            metrics = String(
                format: "音频 %.1f 秒 · 推理 %.2f 秒 · RTF %.3f",
                result.audioDuration,
                result.inferenceDuration,
                result.realTimeFactor
            )
            phase = .ready
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}
