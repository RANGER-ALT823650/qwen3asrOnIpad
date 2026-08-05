import SwiftUI
import Combine

public struct KeyboardView: View {
    public weak var controller: UIInputViewController?

    @State private var recordStatus: AppGroupBridge.RecordStatus = .idle
    @State private var isTranscribing = false
    @State private var statusText = "Qwen3-ASR 1.7B 已就绪，点击说话"
    @State private var recordingElapsed: TimeInterval = 0
    @State private var recordingAttemptID = UUID()
    @State private var didRequestForegroundTranscription = false

    private let statusPoller = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    public init(controller: UIInputViewController? = nil) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Qwen3-ASR 1.7B 本机离线")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .cornerRadius(10)

                Spacer()

                Button(action: { controller?.textDocumentProxy.deleteBackward() }) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .padding(6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            VStack(spacing: 4) {
                if recordStatus == .recording {
                    HStack(spacing: 8) {
                        Text("录音中")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                        ProgressView(
                            value: recordingElapsed,
                            total: AppGroupBridge.maximumRecordingDuration
                        )
                        .tint(.red)
                        Text(recordingProgressText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("录音进度")
                    .accessibilityValue(recordingProgressText)
                } else if isTranscribing {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.8)
                            Text("Qwen3-ASR 正在本机识别…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: recordStatus == .error) {
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundColor(statusForegroundColor)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)

            HStack(spacing: 12) {
                // Do not read `needsInputModeSwitchKey` while SwiftUI is
                // building the view. On recent Simulator runtimes the
                // keyboard host connection may not exist yet, and that
                // getter can terminate the extension during first activation.
                Button(action: { controller?.advanceToNextInputMode() }) {
                    Image(systemName: "globe")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 50)
                        .background(Color(UIColor.tertiarySystemFill))
                        .cornerRadius(8)
                        .foregroundColor(.primary)
                }
                .accessibilityLabel("切换输入法")

                voiceButton.frame(maxWidth: .infinity)

                VStack(spacing: 6) {
                    Button(action: { controller?.textDocumentProxy.deleteBackward() }) {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 18))
                            .frame(width: 46, height: 22)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(6)
                            .foregroundColor(.primary)
                    }
                    Button(action: { controller?.textDocumentProxy.insertText("\n") }) {
                        Image(systemName: "return")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 46, height: 22)
                            .background(Color.blue)
                            .cornerRadius(6)
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(UIColor.secondarySystemGroupedBackground).ignoresSafeArea())
        .onAppear {
            AppGroupBridge.markKeyboardActive()
            observeSharedRecordStatus()
            refreshSharedRecordStatus()
        }
        .onReceive(statusPoller) { _ in
            // Darwin notifications are edge-triggered and can be missed while
            // iOS tears down or recreates the keyboard extension. Polling the
            // tiny shared state prevents a new keyboard process from showing
            // an obsolete state forever.
            if AppGroupBridge.keyboardActiveAge > 0.8 {
                AppGroupBridge.markKeyboardActive()
            }
            refreshSharedRecordStatus()
        }
    }

    // MARK: - Voice button

    private var voiceButton: some View {
        Button(action: handleVoiceTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(buttonColor)
                    .frame(height: 50)
                    .shadow(color: buttonColor.opacity(0.3), radius: 4, x: 0, y: 2)
                HStack(spacing: 8) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 20, weight: .bold))
                    Text(buttonTitle)
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.white)
            }
        }
        .disabled(isTranscribing)
        .accessibilityIdentifier("voiceInputButton")
        .accessibilityLabel(buttonTitle)
    }

    private var buttonColor: Color {
        switch recordStatus {
        case .recording: return .red
        case .requested: return .gray
        case .stopped, .transcribing, .completed: return .blue
        default: return .blue
        }
    }

    private var statusForegroundColor: Color {
        if statusText.hasPrefix("⚠️") {
            return .orange
        }
        switch recordStatus {
        case .error, .micDenied:
            return .red
        default:
            return .secondary
        }
    }

    private var buttonTitle: String {
        switch recordStatus {
        case .recording: return "点击 停止录音"
        case .requested: return "正在启动…"
        case .stopped, .transcribing: return "识别中…"
        default: return "点击 语音输入"
        }
    }

    private var buttonIcon: String {
        switch recordStatus {
        case .recording: return "stop.circle.fill"
        case .requested: return "hourglass"
        default: return "mic.circle.fill"
        }
    }

    // MARK: - Flow control

    private func handleVoiceTap() {
        switch recordStatus {
        case .idle, .micDenied, .error:
            startVoiceFlow()
        case .recording:
            stopVoiceFlow()
        default:
            break
        }
    }

    /// iOS does not permit a third-party keyboard extension to capture audio,
    /// even after the user grants microphone permission. The container app owns
    /// the audio session and reports progress through the shared App Group.
    private func startVoiceFlow() {
        guard controller?.hasFullAccess == true else {
            statusText = "请先在设置中为本键盘开启“允许完全访问”"
            return
        }

        recordStatus = .requested
        statusText = "正在启动录音…"
        AppGroupBridge.beginRequest()

        // If the container app still has a live process, this starts recording
        // without bringing it to the foreground.
        DarwinNotifications.post(DarwinNotifications.startRecording)

        guard let recordURL = URL(string: "qwen3asr://record") else {
            recordStatus = .error
            statusText = "无法创建录音请求，请重试"
            return
        }

        let attemptID = UUID()
        recordingAttemptID = attemptID

        // A keyboard extension is not allowed to use NSExtensionContext.open.
        // For the sideloaded build, invoke the containing UIApplication through
        // the responder chain only when its existing process did not respond.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard recordingAttemptID == attemptID,
                  AppGroupBridge.status == .requested else { return }

            controller?.openContainingApp(at: recordURL) { didOpen in
                guard recordingAttemptID == attemptID,
                      AppGroupBridge.status == .requested else { return }

                if didOpen {
                    statusText = "正在打开 qwen3asr 开始录音…"
                } else {
                    // Keep the shared request pending so manually opening the
                    // app can still take it over during the timeout window.
                    recordStatus = .requested
                    statusText = "App 已被系统结束，请打开 qwen3asr 恢复后台服务"
                    AppGroupBridge.setStatus(.requested, message: statusText)
                }
            }
        }

        // Do not leave the keyboard indefinitely disabled if the app was
        // removed, killed during launch, or otherwise failed to handle the URL.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard recordingAttemptID == attemptID,
                  AppGroupBridge.status == .requested else { return }
            recordStatus = .error
            statusText = "后台服务未运行，请打开 qwen3asr 后返回键盘"
            AppGroupBridge.setStatus(.error, message: statusText)
        }
    }

    /// Tap 2: ask the container app to stop recording and transcribe the WAV.
    private func stopVoiceFlow() {
        guard recordStatus == .recording else {
            print("KeyboardView: stopVoiceFlow 被调用但状态不是 recording: \(recordStatus)")
            return
        }

        recordStatus = .transcribing
        isTranscribing = true
        statusText = "正在打开 qwen3asr 前台识别…"
        DarwinNotifications.post(DarwinNotifications.stopRecording)
        openContainerForForegroundTranscription()
    }

    /// iOS terminates a non-frontmost app when the 1.7B model sustains enough
    /// CPU work, while MLX Metal is unavailable in the background. Foreground
    /// the container for the model pass, then let it suspend back here after it
    /// publishes either text or a concrete error through the App Group.
    private func openContainerForForegroundTranscription() {
        guard !didRequestForegroundTranscription else { return }
        didRequestForegroundTranscription = true

        guard let stopURL = URL(string: "qwen3asr://stop") else {
            didRequestForegroundTranscription = false
            statusText = "无法创建识别请求，请手动打开 qwen3asr"
            return
        }

        controller?.openContainingApp(at: stopURL) { didOpen in
            if !didOpen {
                didRequestForegroundTranscription = false
                statusText = "系统未允许打开 qwen3asr，请手动打开 App 完成识别"
            }
        }
    }

    private func observeSharedRecordStatus() {
        DarwinNotifications.observe(DarwinNotifications.statusChanged) {
            refreshSharedRecordStatus()
        }
    }

    private func refreshSharedRecordStatus() {
        switch AppGroupBridge.status {
        case .idle:
            guard !isTranscribing else { return }
            didRequestForegroundTranscription = false
            recordingElapsed = 0
            recordStatus = .idle
            statusText = AppGroupBridge.lastMessage
                ?? "Qwen3-ASR 1.7B 已就绪，点击说话"
        case .requested:
            recordingElapsed = 0
            guard AppGroupBridge.statusAge < 12 else {
                isTranscribing = false
                recordStatus = .error
                statusText = "后台服务未运行，请打开 qwen3asr 后返回键盘"
                AppGroupBridge.setStatus(.error, message: statusText)
                return
            }
            recordStatus = .requested
            statusText = AppGroupBridge.lastMessage ?? "正在启动录音…"
        case .recording:
            didRequestForegroundTranscription = false
            recordStatus = .recording
            isTranscribing = false
            recordingElapsed = min(
                AppGroupBridge.statusAge,
                AppGroupBridge.maximumRecordingDuration
            )
            statusText = "🎙️ 正在录音… 最长 \(Int(AppGroupBridge.maximumRecordingDuration)) 秒，点击停止"
        case .stopped, .transcribing:
            recordingElapsed = 0
            recordStatus = .transcribing
            isTranscribing = true
            statusText = AppGroupBridge.lastMessage ?? "Qwen3-ASR 正在本机识别…"
            openContainerForForegroundTranscription()
        case .completed:
            recordingElapsed = 0
            isTranscribing = false
            didRequestForegroundTranscription = false
            recordStatus = .idle
            let text = AppGroupBridge.transcriptionText ?? ""
            let warning = AppGroupBridge.lastMessage
            if text.isEmpty {
                statusText = "未识别到文字，请重试"
            } else {
                controller?.textDocumentProxy.insertText(text)
                statusText = warning ?? "已转写: \(text)"
            }
            // A repetition warning is informational: insert the complete text
            // unchanged, then keep the warning visible until the next request.
            AppGroupBridge.setStatus(.idle, message: warning)
        case .micDenied:
            recordingElapsed = 0
            isTranscribing = false
            didRequestForegroundTranscription = false
            recordStatus = .micDenied
            statusText = AppGroupBridge.lastMessage ?? "麦克风权限被拒绝，请在设置中允许 qwen3asr 访问麦克风"
        case .error:
            recordingElapsed = 0
            isTranscribing = false
            didRequestForegroundTranscription = false
            recordStatus = .error
            statusText = AppGroupBridge.lastMessage ?? "录音或识别失败，请重试"
        }
    }

    private var recordingProgressText: String {
        let elapsed = min(recordingElapsed, AppGroupBridge.maximumRecordingDuration)
        return String(
            format: "%.1f / %.0f 秒",
            elapsed,
            AppGroupBridge.maximumRecordingDuration
        )
    }
}
