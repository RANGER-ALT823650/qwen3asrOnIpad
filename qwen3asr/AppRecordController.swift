import Foundation
import AVFoundation
import Combine
import SwiftUI

/// Owned by the container app.
///
/// The keyboard extension cannot reliably start AVAudioRecorder inside its
/// sandbox, so recording happens here instead:
///
/// 1. The keyboard taps the voice button and opens `qwen3asr://record`.
/// 2. We request microphone access, start recording into the App Group
///    container, then background the app so the user lands back on the
///    keyboard (which shows the live recording state).
/// 3. When the keyboard taps stop it posts a Darwin notification; we stop,
///    publish the WAV path through the App Group, and the keyboard runs the
///    local Whisper transcription and inserts the text.
@MainActor
final class AppRecordController: ObservableObject {
    static let shared = AppRecordController()

    @Published var isRecording = false
    @Published var lastMessage = ""

    private var openedViaRecordURL = false
    private var autoStopTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        observeDarwinCommands()
        observeAudioSessionInterruptions()
    }

    // MARK: - URL entry point

    func handle(url: URL) {
        guard url.scheme == "qwen3asr", url.host == "record" else { return }
        openedViaRecordURL = true
        startRecordingFlow()
    }

    // MARK: - Recording flow

    private func startRecordingFlow() {
        AudioRecorder.shared.requestPermission { granted in
            Task { @MainActor in
                AppRecordController.shared.continueRecordingFlow(permissionGranted: granted)
            }
        }
    }

    private func continueRecordingFlow(permissionGranted granted: Bool) {
        guard !AudioRecorder.shared.isRecording else { return }
        guard granted else {
            isRecording = false
            lastMessage = "麦克风权限被拒绝，请在设置中允许"
            AppGroupBridge.setStatus(.micDenied, message: "麦克风权限被拒绝，请在 iPhone 设置中允许 qwen3asr 访问麦克风")
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }
        guard AudioRecorder.shared.startRecording() != nil else {
            let detail = AudioRecorder.shared.lastError ?? "录音启动失败"
            isRecording = false
            lastMessage = detail
            AppGroupBridge.setStatus(.error, message: detail)
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }

        isRecording = true
        lastMessage = ""
        AppGroupBridge.setStatus(.recording)
        DarwinNotifications.post(DarwinNotifications.statusChanged)
        scheduleAutoStop()
        scheduleAutoBackground()
    }

    /// Stops the recorder. When `publishWAV` is true the WAV path is published
    /// to the App Group so the keyboard can transcribe it.
    private func stopRecordingFlow(publishWAV: Bool) {
        guard AudioRecorder.shared.isRecording else { return }
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        AudioRecorder.shared.stopRecording { url in
            Task { @MainActor in
                if publishWAV, let url {
                    AppGroupBridge.setStatus(.stopped, wavPath: url.path)
                } else {
                    AppGroupBridge.setStatus(.idle)
                    if let url { try? FileManager.default.removeItem(at: url) }
                }
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                AppRecordController.shared.isRecording = false
            }
        }
    }

    /// Safety net: never let a recording run forever if the keyboard flow dies.
    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            Task { @MainActor in
                let controller = AppRecordController.shared
                controller.stopRecordingFlow(publishWAV: false)
                controller.lastMessage = "录音超时，已自动停止"
                AppGroupBridge.setStatus(.error, message: "录音超时，已自动停止")
                DarwinNotifications.post(DarwinNotifications.statusChanged)
            }
        }
    }

    /// Backgrounds the app shortly after recording starts so the user lands
    /// back on the host app with the keyboard visible. Uses the well-known
    /// "suspend" selector; if it does not fire, the user can switch back
    /// manually and the keyboard still follows the shared status.
    private func scheduleAutoBackground() {
        guard openedViaRecordURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            }
        }
    }

    // MARK: - Cross-process commands

    private func observeDarwinCommands() {
        DarwinNotifications.observe(DarwinNotifications.startRecording) {
            Task { @MainActor in
                AppRecordController.shared.startRecordingFlow()
            }
        }
        DarwinNotifications.observe(DarwinNotifications.stopRecording) {
            Task { @MainActor in
                AppRecordController.shared.stopRecordingFlow(publishWAV: true)
            }
        }
        DarwinNotifications.observe(DarwinNotifications.cancelRecording) {
            Task { @MainActor in
                AppRecordController.shared.stopRecordingFlow(publishWAV: false)
            }
        }
    }

    private func observeAudioSessionInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended,
                  AudioRecorder.shared.isRecording else { return }
            // Call/Siri interrupted the session; drop the recording rather
            // than publishing broken audio.
            let interrupted = true
            Task { @MainActor in
                if interrupted {
                    AppRecordController.shared.stopRecordingFlow(publishWAV: false)
                }
            }
        }
    }
}
