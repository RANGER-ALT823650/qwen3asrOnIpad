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
/// 1. The keyboard posts a Darwin notification while this app remains beside
///    the diary app in iPad split screen.
/// 2. We record into the App Group container without changing either app's
///    foreground placement.
/// 3. A second Darwin notification stops recording; this still-visible app runs
///    Qwen inference and publishes text back to the existing diary keyboard.
///    The record URL is only a cold-start fallback when no process responds.
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
    @Published private(set) var isTranscribing = false
    private var isStoppingRecording = false
    private var activeRequestID: String?
    /// Unique to this concrete app process. Persisted transcriptions owned by
    /// another launch are remnants of a force-quit or jetsam termination.
    private let launchID = UUID().uuidString
    private let logger = Logger(subsystem: "project.qwen3asr", category: "recording")

    private init() {
        observeDarwinCommands()
        observeAudioSessionInterruptions()
        observeAppActivation()
        recoverStaleRecordState()
        resumeRequestedRecordingIfNeeded()

        // Keep the recording handshake light. The 2.3 GB model is materialized
        // only after the user stops, while both split-screen apps stay in place.
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
        case .transcribing:
            // A freshly initialized singleton means a new app process. Never
            // replay a heavy inference that belonged to the process iOS or the
            // user already terminated; remove its WAV and return to idle.
            discardInterruptedTranscription()
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
              AppGroupBridge.statusAge < 30,
              let requestID = AppGroupBridge.currentRequestID else { return }

        logger.info("Taking over pending keyboard request during app launch")
        _ = AppGroupBridge.acknowledgeRecordingRequest(requestID)
        DarwinNotifications.post(DarwinNotifications.statusChanged)
        openedViaRecordURL = true
        Task { @MainActor in
            AppRecordController.shared.startRecordingFlow()
        }
    }

    func handle(url: URL) {
        guard url.scheme == "qwen3asr" else { return }

        switch url.host {
        case "record":
            logger.info("Received record URL handoff")
            openedViaRecordURL = true
            if let requestID = AppGroupBridge.currentRequestID {
                _ = AppGroupBridge.acknowledgeRecordingRequest(requestID)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
            }
            startRecordingFlow()
        default:
            break
        }
    }

    /// The containing app calls this once after its launch-time microphone
    /// permission flow. Keeping a discard-only input unit warm makes repeated
    /// split-screen dictation rounds start without rebuilding the audio graph.
    func preparePersistentRuntime(permissionGranted: Bool) {
        guard permissionGranted else { return }

        if AudioRecorder.shared.startPersistentInput() {
            logger.info("Persistent microphone input is active")
            lastMessage = ""
        } else {
            let detail = AudioRecorder.shared.lastError ?? "常驻麦克风启动失败"
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
        guard let requestID = AppGroupBridge.currentRequestID else {
            let detail = "录音请求状态已失效，请返回键盘重新开始"
            lastMessage = detail
            AppGroupBridge.setStatus(.error, message: detail)
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }
        guard granted else {
            logger.error("Microphone permission denied")
            isRecording = false
            lastMessage = "麦克风权限被拒绝，请在设置中允许"
            AppGroupBridge.setStatus(.micDenied, message: "麦克风权限被拒绝，请在 iPad 设置中允许千问3 ASR访问麦克风")
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }
        if !AudioRecorder.shared.isPersistentInputRunning {
            guard isAppVisibleInForeground else {
                let detail = "模型 App 当前不在前台，请先将千问3 ASR与日记 App 分屏显示"
                isRecording = false
                lastMessage = detail
                AppGroupBridge.setStatus(.error, message: detail)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                return
            }
            guard AudioRecorder.shared.startPersistentInput() else {
                let detail = AudioRecorder.shared.lastError ?? "常驻麦克风启动失败"
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
        activeRequestID = requestID
        lastMessage = ""
        AppGroupBridge.setStatus(.recording)
        DarwinNotifications.post(DarwinNotifications.statusChanged)
        logger.info("Recording started and status published")
        keyboardPresenceGraceUntil = openedViaRecordURL
            ? Date().addingTimeInterval(6)
            : nil
        openedViaRecordURL = false
        scheduleAutoStop()
        scheduleKeyboardPresenceCheck()
    }

    /// Stops the recorder. When `publishWAV` is true, the host app performs
    /// transcription with its resident model and publishes the text.
    private func stopRecordingFlow(publishWAV: Bool, errorMessage: String? = nil) {
        guard AudioRecorder.shared.isRecording, !isStoppingRecording else { return }
        let stoppedRequestID = activeRequestID
        activeRequestID = nil
        isStoppingRecording = true
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        keyboardPresenceTimer?.invalidate()
        keyboardPresenceTimer = nil
        keyboardPresenceGraceUntil = nil

        print("AppRecordController: 停止录音流程开始, publishWAV=\(publishWAV)")

        AudioRecorder.shared.stopRecording { url in
            Task { @MainActor in
                print("AppRecordController: 录音已停止, url=\(String(describing: url))")
                AppRecordController.shared.isStoppingRecording = false
                AppRecordController.shared.isRecording = false

                if publishWAV {
                    if let url {
                        guard let requestID = stoppedRequestID,
                              AppGroupBridge.currentRequestID == requestID else {
                            let detail = "录音请求状态已失效，请重新录音"
                            try? FileManager.default.removeItem(at: url)
                            AppRecordController.shared.lastMessage = detail
                            AppGroupBridge.setStatus(.error, message: detail)
                            DarwinNotifications.post(DarwinNotifications.statusChanged)
                            return
                        }
                        print("AppRecordController: 进入宿主 App 转写: \(url.path)")
                        guard AppGroupBridge.markTranscribing(
                            requestID: requestID,
                            launchID: AppRecordController.shared.launchID,
                            message: "正在分屏前台识别…",
                            wavPath: url.path
                        ) else {
                            try? FileManager.default.removeItem(at: url)
                            return
                        }
                        DarwinNotifications.post(DarwinNotifications.statusChanged)
                        AppRecordController.shared.transcribe(url: url, requestID: requestID)
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

    private func transcribe(url: URL, requestID: String) {
        // The diary scene may own keyboard focus while this split-screen scene
        // is foreground-inactive. It is still on screen and may run the MLX pass.
        guard isAppVisibleInForeground else {
            logger.info("Deferring Qwen3-ASR inference until the container is visible")
            AppGroupBridge.setStatus(
                .transcribing,
                message: "等待千问3 ASR回到 iPad 分屏前台…",
                wavPath: url.path
            )
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }
        guard !isTranscribing else { return }
        guard AppGroupBridge.ownsTranscription(
            requestID: requestID,
            launchID: launchID
        ) else { return }
        isTranscribing = true

        guard AppGroupBridge.markTranscribing(
            requestID: requestID,
            launchID: launchID,
            message: "正在识别（\(HybridQwen3ASREngine.backendDescription)）…",
            wavPath: url.path
        ) else { return }
        DarwinNotifications.post(DarwinNotifications.statusChanged)

        // Persistent input already keeps the host eligible during short scene
        // transitions. If it is unavailable, request only a bounded grace
        // period; the MLX pass itself still requires the app to stay frontmost.
        if !AudioRecorder.shared.isPersistentInputRunning,
           transcriptionBackgroundTask == .invalid {
            transcriptionBackgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "qwen3asr-qwen-transcription"
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
                let result = try await HybridQwen3ASREngine.shared.transcribe(
                    recordingURL: url,
                    timeLimit: AppGroupBridge.maximumTranscriptionDuration
                )
                guard AppGroupBridge.ownsTranscription(
                    requestID: requestID,
                    launchID: AppRecordController.shared.launchID
                ) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let text = result.text
                print("AppRecordController: 宿主 App 转写完成，文本长度: \(text.count)")
                guard AppGroupBridge.setTranscription(text, for: requestID) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let warning = TranscriptionQuality.repetitionWarning(for: text)
                AppGroupBridge.setStatus(.completed, message: warning)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                try? FileManager.default.removeItem(at: url)
            } catch {
                guard AppGroupBridge.ownsTranscription(
                    requestID: requestID,
                    launchID: AppRecordController.shared.launchID
                ) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let diagnostic = Self.diagnosticDescription(for: error)
                print("AppRecordController: 宿主 App 转写失败: \(diagnostic)")
                AppRecordController.shared.logger.error(
                    "Qwen3-ASR transcription failed: \(diagnostic, privacy: .public)"
                )
                let visibleMessage: String
                if case HybridQwen3ASRError.inferenceTimedOut = error {
                    visibleMessage = "识别超过 \(Int(AppGroupBridge.maximumTranscriptionDuration)) 秒，已终止并丢弃本轮录音"
                    try? FileManager.default.removeItem(at: url)
                } else {
                    visibleMessage = "识别出错（\(HybridQwen3ASREngine.backendDescription)）\n\(diagnostic)"
                }
                AppRecordController.shared.lastMessage = visibleMessage
                AppGroupBridge.setStatus(.error, message: visibleMessage)
                DarwinNotifications.post(DarwinNotifications.statusChanged)
                // Non-timeout failures keep their WAV only for diagnostics;
                // there is no automatic or user-visible retry path.
            }
        }
    }

    /// Preserve the underlying NSError chain in device logs. Apple's top-level
    /// Core ML and Metal messages are often generic; the nested domain/code is
    /// what distinguishes resource pressure from malformed model inputs.
    private static func diagnosticDescription(for error: Error) -> String {
        var messages: [String] = []
        var current: NSError? = error as NSError
        var depth = 0

        while let item = current, depth < 6 {
            messages.append(
                "\(item.domain)(\(item.code)): \(item.localizedDescription)"
            )
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return messages.joined(separator: " -> ")
    }

    /// Continue only work claimed by this same live process, for example when a
    /// 32-second auto-stop finishes just before the keyboard foregrounds us.
    /// A new process has a different launch ID and discards the WAV instead.
    private func resumeOwnedTranscriptionIfNeeded() {
        guard isAppVisibleInForeground,
              AppGroupBridge.status == .transcribing,
              AppGroupBridge.currentTranscriptionLaunchID == launchID,
              let requestID = AppGroupBridge.currentRequestID,
              let path = AppGroupBridge.pendingWavPath else { return }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppGroupBridge.setStatus(.error, message: "待识别录音文件已丢失，请重新录音")
            DarwinNotifications.post(DarwinNotifications.statusChanged)
            return
        }

        print("AppRecordController: 继续当前进程等待前台的宿主 App 转写")
        transcribe(url: url, requestID: requestID)
    }

    private func discardInterruptedTranscription() {
        if let path = AppGroupBridge.pendingWavPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        isTranscribing = false
        let detail = "上次识别因 App 被结束而中断，旧录音已删除"
        lastMessage = detail
        AppGroupBridge.setStatus(.idle, message: detail)
        DarwinNotifications.post(DarwinNotifications.statusChanged)
    }

    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTask)
        transcriptionBackgroundTask = .invalid
    }

    /// When keyboard focus belongs to the diary app, this split-screen scene can
    /// be foreground-inactive even though it remains fully visible.
    private var isAppVisibleInForeground: Bool {
        let scenes = UIApplication.shared.connectedScenes
        if scenes.isEmpty {
            return UIApplication.shared.applicationState != .background
        }
        return scenes.contains {
            $0.activationState == .foregroundActive
                || $0.activationState == .foregroundInactive
        }
    }

    /// Keeps each keyboard dictation round within the model's supported window.
    /// Reaching the limit is a normal stop and still transcribes the captured
    /// audio, matching an explicit tap on the keyboard's stop button.
    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: AppGroupBridge.maximumRecordingDuration,
            repeats: false
        ) { _ in
            Task { @MainActor in
                AppRecordController.shared.stopRecordingFlow(
                    publishWAV: true
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

    // MARK: - Cross-process commands

    private func observeDarwinCommands() {
        DarwinNotifications.observe(DarwinNotifications.startRecording) {
            Task { @MainActor in
                guard let requestID = AppGroupBridge.currentRequestID,
                      AppGroupBridge.acknowledgeRecordingRequest(requestID) else { return }
                DarwinNotifications.post(DarwinNotifications.statusChanged)
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
                AppRecordController.shared.resumeOwnedTranscriptionIfNeeded()
                AppRecordController.shared.resumeRequestedRecordingIfNeeded()
            }
        }
    }
}
