import Foundation
import AVFoundation
import Combine
import SwiftUI
import OSLog

/// Owned by the container app.
///
/// The keyboard extension cannot reliably own microphone input inside its
/// sandbox, so recording happens here instead:
///
/// 1. The keyboard taps the voice button and opens `qwen3asr://record`.
/// 2. We request microphone access, start recording into the App Group
///    container, then background the app so the user lands back on the
///    keyboard (which shows the live recording state).
/// 3. When the keyboard taps stop it posts a Darwin notification; we stop,
///    transcribe in the container app with its resident Whisper context, and
///    publish only the result through the App Group.
@MainActor
final class AppRecordController: ObservableObject {
    static let shared = AppRecordController()

    @Published var isRecording = false
    @Published var lastMessage = ""

    private var openedViaRecordURL = false
    private var autoStopTimer: Timer?
    private var keyboardPresenceTimer: Timer?
    private var keyboardPresenceGraceUntil: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var transcriptionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isStartingRecording = false
    private var isTranscribing = false
    private let logger = Logger(subsystem: "project.qwen3asr", category: "recording")

    private init() {
        observeDarwinCommands()
        observeAudioSessionInterruptions()
        observeAppActivation()
        recoverStaleRecordState()
        resumePendingTranscriptionIfNeeded()
        resumeRequestedRecordingIfNeeded()

        // Start loading as soon as the app process exists. The actor keeps the
        // native context alive for all later recording rounds.
        Task(priority: .utility) {
            do {
                try await AppWhisperTranscriber.shared.preload()
            } catch {
                print("AppRecordController: Whisper 预加载失败: \(error.localizedDescription)")
            }

        }
    }

    // MARK: - URL entry point

    private func recoverStaleRecordState() {
        switch AppGroupBridge.status {
        case .recording:
            // A new controller cannot inherit an audio engine from a
            // process that iOS already killed.
            AppGroupBridge.setStatus(.idle)
            DarwinNotifications.post(DarwinNotifications.statusChanged)
        case .requested where Date().timeIntervalSince1970 - AppGroupBridge.updatedAt > 30:
            AppGroupBridge.setStatus(.idle)
            DarwinNotifications.post(DarwinNotifications.statusChanged)
        default:
            break
        }
    }

    /// The private URL bridge used by a sideloaded keyboard may launch the app
    /// without delivering the URL to the SwiftUI scene on some iOS releases.
    /// The shared request is therefore the source of truth during cold launch.
    /// It also makes manually opening the app complete the pending action.
    private func resumeRequestedRecordingIfNeeded() {
        guard AppGroupBridge.status == .requested,
              AppGroupBridge.statusAge < 30 else { return }

        logger.info("Taking over pending keyboard request during app launch")
        openedViaRecordURL = true
        Task { @MainActor in
            AppRecordController.shared.startRecordingFlow()
        }
    }

    func handle(url: URL) {
        guard url.scheme == "qwen3asr", url.host == "record" else { return }
        logger.info("Received record URL handoff")
        openedViaRecordURL = true
        startRecordingFlow()
    }

    /// The containing app calls this once after its launch-time microphone
    /// permission flow. Keeping a discard-only input unit active prevents iOS
    /// from suspending the process between keyboard dictation rounds.
    func preparePersistentRuntime(permissionGranted: Bool) {
        guard permissionGranted else { return }

        if AudioRecorder.shared.startPersistentInput() {
            logger.info("Persistent background microphone input is active")
            lastMessage = ""
        } else {
            let detail = AudioRecorder.shared.lastError ?? "后台麦克风启动失败"
            logger.error("Persistent input failed: \(detail, privacy: .public)")
            lastMessage = detail
        }
    }

    // MARK: - Recording flow

    private func startRecordingFlow() {
        guard !AudioRecorder.shared.isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        logger.info("Starting recording flow")

        AudioRecorder.shared.requestPermission { granted in
            Task { @MainActor in
                let controller = AppRecordController.shared
                controller.isStartingRecording = false
                controller.continueRecordingFlow(permissionGranted: granted)
            }
        }
    }

    private func continueRecordingFlow(permissionGranted granted: Bool) {
        guard !AudioRecorder.shared.isRecording else { return }
        guard granted else {
            logger.error("Microphone permission denied")
            isRecording = false
            lastMessage = "麦克风权限被拒绝，请在设置中允许"
            AppGroupBridge.setStatus(.micDenied, message: "麦克风权限被拒绝，请在 iPhone 设置中允许 qwen3asr 访问麦克风")
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }
        if !AudioRecorder.shared.isPersistentInputRunning {
            guard UIApplication.shared.applicationState == .active else {
                let detail = "后台麦克风服务已停止，请打开 qwen3asr 恢复后再录音"
                isRecording = false
                lastMessage = detail
                AppGroupBridge.setStatus(.error, message: detail)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                return
            }
            guard AudioRecorder.shared.startPersistentInput() else {
                let detail = AudioRecorder.shared.lastError ?? "后台麦克风启动失败"
                isRecording = false
                lastMessage = detail
                AppGroupBridge.setStatus(.error, message: detail)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                return
            }
        }
        guard AudioRecorder.shared.startRecording() != nil else {
            let detail = AudioRecorder.shared.lastError ?? "录音启动失败"
            logger.error("Recording failed to start: \(detail, privacy: .public)")
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
        logger.info("Recording started and status published")
        keyboardPresenceGraceUntil = openedViaRecordURL
            ? Date().addingTimeInterval(6)
            : nil
        scheduleAutoStop()
        scheduleKeyboardPresenceCheck()
        scheduleAutoBackground()
    }

    /// Stops the recorder. When `publishWAV` is true, the host app performs
    /// transcription with its resident model and publishes the text.
    private func stopRecordingFlow(publishWAV: Bool, errorMessage: String? = nil) {
        guard AudioRecorder.shared.isRecording else { return }
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        keyboardPresenceTimer?.invalidate()
        keyboardPresenceTimer = nil
        keyboardPresenceGraceUntil = nil

        print("AppRecordController: 停止录音流程开始, publishWAV=\(publishWAV)")

        AudioRecorder.shared.stopRecording { url in
            Task { @MainActor in
                print("AppRecordController: 录音已停止, url=\(String(describing: url))")
                AppRecordController.shared.isRecording = false

                if publishWAV {
                    if let url {
                        print("AppRecordController: 进入宿主 App 转写: \(url.path)")
                        AppGroupBridge.setStatus(.transcribing, wavPath: url.path)
                        DarwinNotifications.post(DarwinNotifications.statusChanged)
                        AppRecordController.shared.transcribe(url: url)
                    } else {
                        let detail = AudioRecorder.shared.lastError ?? "录音文件没有生成，请重新录音"
                        AppRecordController.shared.lastMessage = detail
                        AppGroupBridge.setStatus(.error, message: detail)
                        DarwinNotifications.post(DarwinNotifications.statusChanged)
                    }
                } else {
                    if let errorMessage {
                        AppRecordController.shared.lastMessage = errorMessage
                        AppGroupBridge.setStatus(.error, message: errorMessage)
                    } else {
                        AppGroupBridge.setStatus(.idle)
                    }
                    DarwinNotifications.post(DarwinNotifications.statusChanged)
                    if let url {
                        print("AppRecordController: 删除未发布的录音文件")
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                print("AppRecordController: 录音流程完成")
            }
        }
    }

    private func transcribe(url: URL) {
        guard !isTranscribing else { return }
        isTranscribing = true

        if transcriptionBackgroundTask == .invalid {
            transcriptionBackgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "qwen3asr-whisper-transcription"
            ) { [weak self] in
                guard let self else { return }
                self.logger.error("Background transcription time expired")
                if AppGroupBridge.status == .transcribing {
                    AppGroupBridge.setStatus(.error, message: "后台识别超时，请打开 qwen3asr 后重新录音")
                    DarwinNotifications.post(DarwinNotifications.statusChanged)
                }
                self.endTranscriptionBackgroundTask()
            }
        }

        Task { @MainActor in
            defer {
                AppRecordController.shared.isTranscribing = false
                AppRecordController.shared.endTranscriptionBackgroundTask()
            }

            do {
                let text = try await AppWhisperTranscriber.shared.transcribe(audioFileURL: url)
                print("AppRecordController: 宿主 App 转写完成，文本长度: \(text.count)")
                AppGroupBridge.setTranscription(text)
                AppGroupBridge.setStatus(.completed)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                try? FileManager.default.removeItem(at: url)
            } catch {
                print("AppRecordController: 宿主 App 转写失败: \(error.localizedDescription)")
                AppGroupBridge.setStatus(.error, message: "识别出错: \(error.localizedDescription)")
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                // Keep a failed WAV in the App Group. It allows a later app
                // launch or a device-log investigation to distinguish audio
                // capture problems from Whisper backend failures.
            }
        }
    }

    /// If iOS killed the app after the recorder published `.transcribing`,
    /// resume that work on the next app launch instead of leaving the keyboard
    /// in a permanent loading state.
    private func resumePendingTranscriptionIfNeeded() {
        guard AppGroupBridge.status == .transcribing,
              let path = AppGroupBridge.pendingWavPath else { return }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppGroupBridge.setStatus(.error, message: "待识别录音文件已丢失，请重新录音")
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }

        print("AppRecordController: 恢复被系统中断的宿主 App 转写")
        transcribe(url: url)
    }

    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTask)
        transcriptionBackgroundTask = .invalid
    }

    /// Safety net: never let a recording run forever if the keyboard flow dies.
    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            Task { @MainActor in
                AppRecordController.shared.stopRecordingFlow(
                    publishWAV: false,
                    errorMessage: "录音超时，已自动停止"
                )
            }
        }
    }

    /// The microphone input unit stays active globally, but a WAV may be
    /// written only while this keyboard remains the current input view.
    private func scheduleKeyboardPresenceCheck() {
        keyboardPresenceTimer?.invalidate()
        keyboardPresenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard AudioRecorder.shared.isRecording else { return }
                if let graceUntil = AppRecordController.shared.keyboardPresenceGraceUntil,
                   Date() < graceUntil {
                    return
                }
                guard AppGroupBridge.keyboardActiveAge > 4 else { return }

                AppRecordController.shared.stopRecordingFlow(
                    publishWAV: false,
                    errorMessage: "键盘已关闭或切换，录音已取消"
                )
            }
        }
    }

    /// Return to the keyboard after the container app has taken ownership of
    /// the microphone. The persistent input unit keeps the app eligible for
    /// background audio execution and leaves the resident model available for
    /// the next recording round.
    ///
    /// This selector is intentionally limited to the sideloaded keyboard hand
    /// off flow. It is not used for ordinary app launches.
    private func scheduleAutoBackground() {
        guard openedViaRecordURL else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self,
                  self.isRecording,
                  AppGroupBridge.status == .recording,
                  UIApplication.shared.applicationState == .active else { return }

            // There is no public API for an app to return the foreground to a
            // keyboard extension. This is the same system suspend action used
            // by the original sideload workflow; the model is not freed.
            let suspendSelector = NSSelectorFromString("suspend")
            guard UIApplication.shared.responds(to: suspendSelector) else {
                self.logger.error("UIApplication no longer exposes the sideload suspend selector")
                return
            }
            UIApplication.shared.perform(suspendSelector)
            self.openedViaRecordURL = false
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
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            Task { @MainActor in
                switch type {
                case .began where AudioRecorder.shared.isRecording:
                    // A call or Siri interrupted the round; discard it rather
                    // than publishing a WAV with a silent or missing segment.
                    AppRecordController.shared.stopRecordingFlow(
                        publishWAV: false,
                        errorMessage: "录音被系统音频打断，请重新录音"
                    )
                case .ended:
                    AudioRecorder.shared.resumePersistentInputIfNeeded()
                default:
                    break
                }
            }
        }
    }

    /// A manual foreground launch is the supported recovery path when iOS
    /// rejects the keyboard's private URL bridge. Re-check shared work even if
    /// the app process was already resident and its initializer will not run.
    private func observeAppActivation() {
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AudioRecorder.shared.resumePersistentInputIfNeeded()
                AppRecordController.shared.resumePendingTranscriptionIfNeeded()
                AppRecordController.shared.resumeRequestedRecordingIfNeeded()
            }
        }
    }
}
