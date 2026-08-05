import SwiftUI
import Combine

public struct KeyboardView: View {
    public weak var controller: UIInputViewController?

    @State private var recordStatus: AppGroupBridge.RecordStatus = .idle
    @State private var isTranscribing = false
    @State private var statusText = "Qwen3-ASR 1.7B 已就绪，点击说话"
    @State private var recordingElapsed: TimeInterval = 0
    @State private var recordingAttemptID = UUID()

    private let statusPoller = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    public init(controller: UIInputViewController? = nil) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 6) {
            // 顶部状态提示栏
            topStatusBar
                .padding(.horizontal, 12)
                .padding(.top, 4)

            // 主键盘布局：左侧2按钮居中工具栏 + 右侧 4行5列 严丝合缝 Grid
            HStack(spacing: 8) {
                // 左侧工具栏：仅包含 2 个按钮，整体高度对齐右侧，垂直居中
                leftSidebar
                    .frame(width: 155)

                // 右侧键盘区域：使用 SwiftUI Grid 强行锁定 5 列垂直划齐
                rightKeypadGrid
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(keyboardBackgroundColor.ignoresSafeArea())
        .onAppear {
            AppGroupBridge.markKeyboardActive()
            observeSharedRecordStatus()
            refreshSharedRecordStatus()
        }
        .onReceive(statusPoller) { _ in
            if AppGroupBridge.keyboardActiveAge > 0.8 {
                AppGroupBridge.markKeyboardActive()
            }
            refreshSharedRecordStatus()
        }
    }

    // MARK: - Top Status Bar
    private var topStatusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Qwen3-ASR 1.7B")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)

            if recordStatus == .recording {
                HStack(spacing: 6) {
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
            } else if isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }
            } else {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(statusForegroundColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Button(action: { controller?.dismissKeyboard() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(4)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Left Sidebar (2 Buttons Vertically Centered)
    private var leftSidebar: some View {
        VStack(spacing: 10) {
            Spacer()

            // 1. 点击语音输入按钮
            voiceButton

            // 2. 切换键盘按钮
            Button(action: { controller?.advanceToNextInputMode() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(functionKeyBackgroundColor)
                        .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                    Image(systemName: "globe")
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                }
                .frame(height: 48)
            }
            .accessibilityLabel("切换输入法")

            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Voice Button
    private var voiceButton: some View {
        Button(action: handleVoiceTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(buttonColor)
                    .shadow(color: buttonColor.opacity(0.25), radius: 2, x: 0, y: 1)
                HStack(spacing: 6) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 16, weight: .bold))
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
            }
            .frame(height: 48)
        }
        .disabled(isTranscribing)
        .accessibilityIdentifier("voiceInputButton")
        .accessibilityLabel(buttonTitle)
    }

    // MARK: - Right Keypad Grid (SwiftUI Native Grid)
    private var rightKeypadGrid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let rowHeight = max(0, (geometry.size.height - spacing * 3) / 4)

            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                // Row 1: 123 | ,.?! | ABC | DEF | Delete
                GridRow {
                    keyButton("123") { controller?.textDocumentProxy.insertText("1") }
                    keyButton(",.?!") { controller?.textDocumentProxy.insertText("，") }
                    keyButton("ABC") { controller?.textDocumentProxy.insertText("a") }
                    keyButton("DEF") { controller?.textDocumentProxy.insertText("d") }

                    functionKeyButton(iconSystemName: "delete.left") {
                        controller?.textDocumentProxy.deleteBackward()
                    }
                }
                .frame(height: rowHeight)

                // Rows 2 & 3 Combined: #@¥ (Col 1, Spans 2 Rows) | Middle 3x2 Block (Cols 2-4) | Return (Col 5, Spans 2 Rows)
                GridRow {
                    // Col 1: #@¥
                    keyButton("#@¥") { controller?.textDocumentProxy.insertText("#") }
                        .frame(maxHeight: .infinity)

                    // Cols 2, 3, 4: Middle 2-row letter keypad block
                    VStack(spacing: spacing) {
                        // Upper row: GHI | JKL | MNO
                        HStack(spacing: spacing) {
                            keyButton("GHI") { controller?.textDocumentProxy.insertText("g") }
                            keyButton("JKL") { controller?.textDocumentProxy.insertText("j") }
                            keyButton("MNO") { controller?.textDocumentProxy.insertText("m") }
                        }
                        .frame(height: rowHeight)

                        // Lower row: PQRS | TUV | WXYZ
                        HStack(spacing: spacing) {
                            keyButton("PQRS") { controller?.textDocumentProxy.insertText("p") }
                            keyButton("TUV") { controller?.textDocumentProxy.insertText("t") }
                            keyButton("WXYZ") { controller?.textDocumentProxy.insertText("w") }
                        }
                        .frame(height: rowHeight)
                    }
                    .frame(height: rowHeight * 2 + spacing)
                    .gridCellColumns(3)

                    // Col 5: Return Button
                    returnButton
                        .frame(maxHeight: .infinity)
                }
                .frame(height: rowHeight * 2 + spacing)

                // Row 4: 😀 | 选拼音 | 空格 (Span 2 cols) | Secondary Mic
                GridRow {
                    functionKeyButton(title: "😀") { controller?.textDocumentProxy.insertText("😀") }
                    functionKeyButton(title: "选拼音") { controller?.textDocumentProxy.insertText("拼音") }

                    // Space bar spanning 2 columns
                    Button(action: { controller?.textDocumentProxy.insertText(" ") }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(standardKeyBackgroundColor)
                                .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                            Text("空 格")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .gridCellColumns(2)

                    functionKeyButton(iconSystemName: "mic") {
                        handleVoiceTap()
                    }
                }
                .frame(height: rowHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var returnButton: some View {
        Button(action: { controller?.textDocumentProxy.insertText("\n") }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(functionKeyBackgroundColor)
                    .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                Image(systemName: "return")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(standardKeyBackgroundColor)
                    .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func functionKeyButton(title: String? = nil, iconSystemName: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(functionKeyBackgroundColor)
                    .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                if let iconSystemName = iconSystemName {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                } else if let title = title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var keyboardBackgroundColor: Color {
        Color(UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 43/255.0, green: 43/255.0, blue: 44/255.0, alpha: 1.0)
            } else {
                return UIColor(red: 209/255.0, green: 213/255.0, blue: 219/255.0, alpha: 1.0)
            }
        })
    }

    private var standardKeyBackgroundColor: Color {
        Color(UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 88/255.0, green: 88/255.0, blue: 92/255.0, alpha: 1.0)
            } else {
                return UIColor.white
            }
        })
    }

    private var functionKeyBackgroundColor: Color {
        Color(UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 54/255.0, green: 54/255.0, blue: 56/255.0, alpha: 1.0)
            } else {
                return UIColor(red: 172/255.0, green: 177/255.0, blue: 185/255.0, alpha: 1.0)
            }
        })
    }

    private var buttonColor: Color {
        switch recordStatus {
        case .recording: return .red
        case .requested: return .gray
        case .stopped, .transcribing, .completed: return Color(red: 0.15, green: 0.52, blue: 0.98)
        default: return Color(red: 0.15, green: 0.52, blue: 0.98)
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
        case .recording: return "点击 停止"
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

    // MARK: - Flow Control

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

    private func startVoiceFlow() {
        guard controller?.hasFullAccess == true else {
            statusText = "请先在设置中为本键盘开启“允许完全访问”"
            return
        }

        recordStatus = .requested
        statusText = "正在启动录音…"
        let requestID = AppGroupBridge.beginRequest()

        guard let recordURL = URL(string: "qwen3asr://record") else {
            recordStatus = .error
            statusText = "无法创建录音请求，请重试"
            return
        }

        let attemptID = UUID()
        recordingAttemptID = attemptID

        DarwinNotifications.post(DarwinNotifications.startRecording)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard recordingAttemptID == attemptID,
                  AppGroupBridge.status == .requested,
                  !AppGroupBridge.hasAcknowledgedRecordingRequest(requestID) else { return }
            DarwinNotifications.post(DarwinNotifications.startRecording)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard recordingAttemptID == attemptID,
                  AppGroupBridge.status == .requested,
                  !AppGroupBridge.hasAcknowledgedRecordingRequest(requestID) else { return }

            controller?.openContainingApp(at: recordURL) { didOpen in
                guard recordingAttemptID == attemptID,
                      AppGroupBridge.status == .requested else { return }

                if didOpen {
                    statusText = "模型 App 未响应，正在打开千问3 ASR…"
                } else {
                    recordStatus = .requested
                    statusText = "模型 App 未响应，请打开千问3 ASR后重试"
                    AppGroupBridge.setStatus(.requested, message: statusText)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard recordingAttemptID == attemptID,
                  AppGroupBridge.status == .requested else { return }
            recordStatus = .error
            statusText = "模型 App 未响应，请将千问3 ASR与日记 App 分屏显示"
            AppGroupBridge.setStatus(.error, message: statusText)
        }
    }

    private func stopVoiceFlow() {
        guard recordStatus == .recording else {
            print("KeyboardView: stopVoiceFlow 被调用但状态不是 recording: \(recordStatus)")
            return
        }

        recordStatus = .transcribing
        isTranscribing = true
        statusText = "Qwen3-ASR 正在分屏前台识别…"
        DarwinNotifications.post(DarwinNotifications.stopRecording)
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
            recordingElapsed = 0
            recordStatus = .idle
            statusText = AppGroupBridge.lastMessage
                ?? "Qwen3-ASR 1.7B 已就绪，点击说话"
        case .requested:
            recordingElapsed = 0
            guard AppGroupBridge.statusAge < 12 else {
                isTranscribing = false
                recordStatus = .error
                statusText = "模型 App 未响应，请将千问3 ASR与日记 App 分屏显示"
                AppGroupBridge.setStatus(.error, message: statusText)
                return
            }
            recordStatus = .requested
            statusText = AppGroupBridge.lastMessage ?? "正在启动录音…"
        case .recording:
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
            statusText = AppGroupBridge.lastMessage
                ?? "Qwen3-ASR 正在分屏前台识别…"
        case .completed:
            recordingElapsed = 0
            isTranscribing = false
            recordStatus = .completed
            let text = AppGroupBridge.transcriptionText ?? ""
            let warning = AppGroupBridge.lastMessage
            if text.isEmpty {
                statusText = "未识别到文字，请重试"
                AppGroupBridge.setStatus(.idle)
                recordStatus = .idle
                return
            }

            guard (controller as? KeyboardViewController)?.isKeyboardVisible == true else {
                statusText = "识别完成，返回日记输入页面后将自动填入"
                return
            }

            controller?.textDocumentProxy.insertText(text)
            statusText = warning ?? "已转写: \(text)"
            AppGroupBridge.setStatus(.idle, message: warning)
            recordStatus = .idle
        case .micDenied:
            recordingElapsed = 0
            isTranscribing = false
            recordStatus = .micDenied
            statusText = AppGroupBridge.lastMessage ?? "麦克风权限被拒绝，请在设置中允许 qwen3asr 访问麦克风"
        case .error:
            recordingElapsed = 0
            isTranscribing = false
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

#if DEBUG
struct KeyboardView_Previews: PreviewProvider {
    static var previews: some View {
        KeyboardView()
            .frame(width: 1024, height: 300)
            .previewLayout(.fixed(width: 1024, height: 300))
            .previewDisplayName("iPad Keyboard")
    }
}
#endif
