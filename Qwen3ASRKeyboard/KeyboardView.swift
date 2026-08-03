import SwiftUI

public struct KeyboardView: View {
    public weak var controller: UIInputViewController?

    @State private var recordStatus: AppGroupBridge.RecordStatus = .idle
    @State private var isTranscribing = false
    @State private var statusText = "Whisper base 已就绪，点击说话"
    @State private var isModelAvailable = WhisperTranscriber.isModelBundled
    @State private var pollTimer: Timer?

    public init(controller: UIInputViewController? = nil) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isModelAvailable ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(isModelAvailable ? "Whisper base 本机离线" : "离线模型缺失")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isModelAvailable ? .green : .red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((isModelAvailable ? Color.green : Color.red).opacity(0.12))
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
                if isTranscribing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.8)
                        Text("Whisper 正在本机识别...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.blue)
                    }
                } else {
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 24)

            HStack(spacing: 12) {
                if let controller, controller.needsInputModeSwitchKey {
                    Button(action: { controller.advanceToNextInputMode() }) {
                        Image(systemName: "globe")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 50)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(8)
                            .foregroundColor(.primary)
                    }
                }

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
        .background(Color(UIColor.secondarySystemGroupedBackground).ignoresSafeArea())
        .onAppear {
            isModelAvailable = WhisperTranscriber.isModelBundled
            statusText = isModelAvailable ? "Whisper base 已就绪，点击说话" : "未找到内置模型，请重新安装 App"
            DarwinNotifications.observe(DarwinNotifications.statusChanged) {
                refreshStatus()
            }
            startPolling()
            recoverColdStart()
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
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
        .disabled(isTranscribing || !isModelAvailable)
    }

    private var buttonColor: Color {
        switch recordStatus {
        case .recording: return .red
        case .requested: return .gray
        case .stopped: return .blue
        default: return .blue
        }
    }

    private var buttonTitle: String {
        switch recordStatus {
        case .recording: return "点击 停止录音"
        case .requested: return "正在启动…"
        case .stopped: return "识别中…"
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

    /// Tap 1: ask the (possibly backgrounded) app to start recording; if the
    /// app is not alive, fall back to opening `qwen3asr://record`.
    private func startVoiceFlow() {
        guard isModelAvailable else {
            statusText = "未找到内置模型，请重新安装 App"
            return
        }
        guard controller?.hasFullAccess == true else {
            statusText = "请先在设置中为本键盘开启“允许完全访问”"
            return
        }

        AppGroupBridge.setStatus(.requested)
        recordStatus = .requested
        statusText = "正在启动录音…"
        DarwinNotifications.post(DarwinNotifications.startRecording)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
            guard AppGroupBridge.status == .requested else { return }
            let url = URL(string: "qwen3asr://record")!
            controller?.extensionContext?.open(url)
        }

        // Fallback hint: if the app still has not answered shortly after the
        // URL open attempt, tell the user what to do instead of hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if AppGroupBridge.status == .requested {
                statusText = "无法自动唤起 App，请先手动打开一次 qwen3asr App"
            }
        }
    }

    /// Tap 2: ask the app to stop recording; it publishes the WAV path and we
    /// transcribe locally once the shared status flips to `.stopped`.
    private func stopVoiceFlow() {
        isTranscribing = true
        statusText = "正在等待录音保存…"
        DarwinNotifications.post(DarwinNotifications.stopRecording)
    }

    // MARK: - Shared status sync

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak controller] _ in
            guard controller != nil else { return }
            refreshStatus()
        }
    }

    private func refreshStatus() {
        let status = AppGroupBridge.status
        guard status != recordStatus else {
            // While transcribing, surface a hint if the app never answered.
            if isTranscribing, recordStatus == .recording,
               Date().timeIntervalSince1970 - AppGroupBridge.updatedAt > 8 {
                statusText = "App 未响应，请重新打开 App 后再试"
            }
            return
        }

        recordStatus = status
        switch status {
        case .requested:
            statusText = "正在启动录音…"
        case .recording:
            statusText = "🎙️ 正在录音… 点击停止"
        case .stopped:
            if !isTranscribing, let path = AppGroupBridge.pendingWavPath {
                beginTranscription(wavPath: path)
            }
        case .micDenied:
            statusText = AppGroupBridge.lastMessage ?? "麦克风权限被拒绝"
        case .error:
            statusText = AppGroupBridge.lastMessage ?? "录音出错"
        case .idle:
            statusText = isModelAvailable ? "Whisper base 已就绪，点击说话" : "未找到内置模型，请重新安装 App"
        }
    }

    /// If the keyboard process was killed while the app recorded, recover the
    /// pending WAV the next time the keyboard appears.
    private func recoverColdStart() {
        let status = AppGroupBridge.status
        switch status {
        case .stopped:
            if let path = AppGroupBridge.pendingWavPath,
               Date().timeIntervalSince1970 - AppGroupBridge.updatedAt < 600 {
                beginTranscription(wavPath: path)
            }
        case .requested:
            // Stale request from a keyboard that died mid-launch.
            if Date().timeIntervalSince1970 - AppGroupBridge.updatedAt > 30 {
                AppGroupBridge.setStatus(.idle)
            }
        case .recording:
            statusText = "🎙️ 正在录音… 点击停止"
            recordStatus = .recording
        default:
            break
        }
    }

    // MARK: - Transcription

    private func beginTranscription(wavPath: String) {
        isTranscribing = true
        statusText = "Whisper 正在本机识别..."
        Task {
            do {
                let text = try await WhisperTranscriber.shared.transcribe(
                    audioFileURL: URL(fileURLWithPath: wavPath)
                )
                await MainActor.run {
                    finishTranscription(text: text, wavPath: wavPath)
                }
            } catch {
                await MainActor.run {
                    isTranscribing = false
                    recordStatus = .idle
                    AppGroupBridge.setStatus(.idle)
                    AppGroupBridge.clearPending()
                    statusText = "识别出错: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishTranscription(text: String, wavPath: String) {
        isTranscribing = false
        recordStatus = .idle
        AppGroupBridge.clearPending()
        AppGroupBridge.setStatus(.idle)
        try? FileManager.default.removeItem(atPath: wavPath)

        if text.isEmpty {
            statusText = "未识别到文字，请重试"
        } else {
            controller?.textDocumentProxy.insertText(text)
            statusText = "已转写: \(text)"
        }
    }
}
