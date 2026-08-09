import SwiftUI
import Combine

public struct KeyboardView: View {
    private enum KeyboardLayout: Equatable {
        case letters
        case numbers
        case punctuation
        case symbols
    }

    public weak var controller: UIInputViewController?

    @State private var recordStatus: AppGroupBridge.RecordStatus = .idle
    @State private var isTranscribing = false
    @State private var statusText = "Qwen3-ASR 1.7B 已就绪，点击说话"
    @State private var recordingElapsed: TimeInterval = 0
    @State private var recordingAttemptID = UUID()
    @StateObject private var nineKeyInput = NineKeyInputModel()
    @State private var keyboardLayout: KeyboardLayout = .letters

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

            // 始终保留候选栏的空间；仅在九键组合输入时显示内容，避免首次输入时重排主键区。
            candidateBar
                .padding(.horizontal, 12)
                .opacity(nineKeyInput.isComposing ? 1 : 0)
                .allowsHitTesting(nineKeyInput.isComposing)
                .accessibilityHidden(!nineKeyInput.isComposing)

            // 主键盘布局：左侧语音工具栏 + 右侧固定 4 行 5 列 Grid。
            // 候选栏高度始终预留，因此首次输入不会挤压并下移键盘。
            HStack(spacing: 8) {
                // 左侧工具栏：语音按钮垂直居中，并与右侧主键区等高。
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

    // MARK: - Nine-key Composition

    private var candidateBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                // 输入码保持紧凑，候选词则在其余整段空间中居中。
                Text(nineKeyInput.digits)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: 52, alignment: .leading)

                if nineKeyInput.candidates.isEmpty {
                    Text("暂无候选")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(nineKeyInput.candidates) { candidate in
                                Button(candidate.text) {
                                    commit(candidate)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(standardKeyBackgroundColor)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        // 候选较少时也占满候选栏，令整组词始终居中；超过宽度时仍可横向滚动。
                        .frame(minWidth: max(0, geometry.size.width - 60), alignment: .center)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .frame(height: 34)
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

    // MARK: - Left Sidebar
    private var leftSidebar: some View {
        VStack(spacing: 10) {
            Spacer()

            voiceButton

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

            keypadGrid(rowHeight: rowHeight, spacing: spacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func keypadGrid(rowHeight: CGFloat, spacing: CGFloat) -> some View {
        switch keyboardLayout {
        case .letters:
            letterKeypadGrid(rowHeight: rowHeight, spacing: spacing)
        case .numbers:
            numberKeypadGrid(rowHeight: rowHeight, spacing: spacing)
        case .punctuation:
            punctuationKeypadGrid(rowHeight: rowHeight, spacing: spacing)
        case .symbols:
            otherSymbolKeypadGrid(rowHeight: rowHeight, spacing: spacing)
        }
    }

    private func letterKeypadGrid(rowHeight: CGFloat, spacing: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow {
                layoutKeyButton("123") { switchKeyboardLayout(to: .numbers) }
                layoutKeyButton(",.?!") { switchKeyboardLayout(to: .punctuation) }
                keyButton("ABC") { appendNineKeyDigit("2") }
                keyButton("DEF") { appendNineKeyDigit("3") }
                deleteKey
            }
            .frame(height: rowHeight)

            GridRow {
                layoutKeyButton("*@¥") { switchKeyboardLayout(to: .symbols) }
                    .frame(maxHeight: .infinity)

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        keyButton("GHI") { appendNineKeyDigit("4") }
                        keyButton("JKL") { appendNineKeyDigit("5") }
                        keyButton("MNO") { appendNineKeyDigit("6") }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: spacing) {
                        keyButton("PQRS") { appendNineKeyDigit("7") }
                        keyButton("TUV") { appendNineKeyDigit("8") }
                        keyButton("WXYZ") { appendNineKeyDigit("9") }
                    }
                    .frame(height: rowHeight)
                }
                .frame(height: rowHeight * 2 + spacing)
                .gridCellColumns(3)

                returnButton
                    .frame(maxHeight: .infinity)
            }
            .frame(height: rowHeight * 2 + spacing)

            GridRow {
                inputModeSwitchKey
                functionKeyButton(title: "选拼音") { commitFirstCandidate() }
                spaceBar
                    .gridCellColumns(2)
                functionKeyButton(iconSystemName: "mic") { handleVoiceTap() }
            }
            .frame(height: rowHeight)
        }
    }

    private func numberKeypadGrid(rowHeight: CGFloat, spacing: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow {
                pinyinLayoutReturnKey
                keyButton("1") { insertTextRespectingComposition("1") }
                keyButton("2") { insertTextRespectingComposition("2") }
                keyButton("3") { insertTextRespectingComposition("3") }
                deleteKey
            }
            .frame(height: rowHeight)

            GridRow {
                stackedKeyButtons("-", "。", spacing: spacing)
                    .frame(maxHeight: .infinity)

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        keyButton("4") { insertTextRespectingComposition("4") }
                        keyButton("5") { insertTextRespectingComposition("5") }
                        keyButton("6") { insertTextRespectingComposition("6") }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: spacing) {
                        keyButton("7") { insertTextRespectingComposition("7") }
                        keyButton("8") { insertTextRespectingComposition("8") }
                        keyButton("9") { insertTextRespectingComposition("9") }
                    }
                    .frame(height: rowHeight)
                }
                .frame(height: rowHeight * 2 + spacing)
                .gridCellColumns(3)

                returnButton
                    .frame(maxHeight: .infinity)
            }
            .frame(height: rowHeight * 2 + spacing)

            GridRow {
                // 所有布局的地球键都固定在左下角，避免切页后肌肉记忆失效。
                inputModeSwitchKey
                keyButton("0") { insertTextRespectingComposition("0") }
                keyButton("，") { insertTextRespectingComposition("，") }
                spaceBar
                    .gridCellColumns(2)
            }
            .frame(height: rowHeight)
        }
    }

    private func punctuationKeypadGrid(rowHeight: CGFloat, spacing: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow {
                pinyinLayoutReturnKey
                keyButton("，") { insertTextRespectingComposition("，") }
                keyButton("。") { insertTextRespectingComposition("。") }
                keyButton("？") { insertTextRespectingComposition("？") }
                deleteKey
            }
            .frame(height: rowHeight)

            GridRow {
                stackedKeyButtons("、", "；", spacing: spacing)
                    .frame(maxHeight: .infinity)

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        keyButton("：") { insertTextRespectingComposition("：") }
                        keyButton("（") { insertTextRespectingComposition("（") }
                        keyButton("）") { insertTextRespectingComposition("）") }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: spacing) {
                        keyButton("“") { insertTextRespectingComposition("“") }
                        keyButton("”") { insertTextRespectingComposition("”") }
                        keyButton("…") { insertTextRespectingComposition("…") }
                    }
                    .frame(height: rowHeight)
                }
                .frame(height: rowHeight * 2 + spacing)
                .gridCellColumns(3)

                returnButton
                    .frame(maxHeight: .infinity)
            }
            .frame(height: rowHeight * 2 + spacing)

            GridRow {
                // 标点页只允许返回拼音页；不提供与数字或其他符号页之间的跳转。
                inputModeSwitchKey
                keyButton("！") { insertTextRespectingComposition("！") }
                keyButton("-") { insertTextRespectingComposition("-") }
                spaceBar
                    .gridCellColumns(2)
            }
            .frame(height: rowHeight)
        }
    }

    private func otherSymbolKeypadGrid(rowHeight: CGFloat, spacing: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow {
                // 此页的返回键在左上角；地球键仍固定在左下角。
                pinyinLayoutReturnKey
                keyButton("#") { insertTextRespectingComposition("#") }
                keyButton("@") { insertTextRespectingComposition("@") }
                keyButton("¥") { insertTextRespectingComposition("¥") }
                deleteKey
            }
            .frame(height: rowHeight)

            GridRow {
                stackedKeyButtons("+", "=", spacing: spacing)
                    .frame(maxHeight: .infinity)

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        keyButton("*") { insertTextRespectingComposition("*") }
                        keyButton("_") { insertTextRespectingComposition("_") }
                        keyButton("&") { insertTextRespectingComposition("&") }
                    }
                    .frame(height: rowHeight)

                    HStack(spacing: spacing) {
                        keyButton("[") { insertTextRespectingComposition("[") }
                        keyButton("]") { insertTextRespectingComposition("]") }
                        keyButton("/") { insertTextRespectingComposition("/") }
                    }
                    .frame(height: rowHeight)
                }
                .frame(height: rowHeight * 2 + spacing)
                .gridCellColumns(3)

                returnButton
                    .frame(maxHeight: .infinity)
            }
            .frame(height: rowHeight * 2 + spacing)

            GridRow {
                inputModeSwitchKey
                keyButton("%") { insertTextRespectingComposition("%") }
                keyButton("-") { insertTextRespectingComposition("-") }
                spaceBar
                    .gridCellColumns(2)
            }
            .frame(height: rowHeight)
        }
    }

    private var returnButton: some View {
        Button(action: {
            if nineKeyInput.isComposing {
                commitFirstCandidate()
            } else {
                controller?.textDocumentProxy.insertText("\n")
            }
        }) {
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

    private var deleteKey: some View {
        functionKeyButton(iconSystemName: "delete.left") {
            if nineKeyInput.isComposing {
                nineKeyInput.deleteBackward()
            } else {
                controller?.textDocumentProxy.deleteBackward()
            }
        }
    }

    private var spaceBar: some View {
        Button(action: {
            if nineKeyInput.isComposing {
                commitFirstCandidate()
            } else {
                controller?.textDocumentProxy.insertText(" ")
            }
        }) {
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
    }

    private var inputModeSwitchKey: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(functionKeyBackgroundColor)
                .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
            InputModeSwitchButton(controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pinyinLayoutReturnKey: some View {
        Button(action: { switchKeyboardLayout(to: .letters) }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(functionKeyBackgroundColor)
                    .shadow(color: Color.black.opacity(0.25), radius: 0.5, x: 0, y: 1)
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("拼音")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("返回拼音键盘")
    }

    private func appendNineKeyDigit(_ digit: Character) {
        nineKeyInput.append(
            digit,
            contextBeforeInput: controller?.textDocumentProxy.documentContextBeforeInput
        )
    }

    /// Changing pages is also a composition boundary, matching the system
    /// keyboard's behavior and ensuring a half-entered nine-key word is never
    /// silently lost behind the numeric or symbol page.
    private func switchKeyboardLayout(to layout: KeyboardLayout) {
        guard keyboardLayout != layout else { return }
        if nineKeyInput.isComposing {
            if let composition = nineKeyInput.commitFirstCandidate() {
                controller?.textDocumentProxy.insertText(composition)
            } else {
                nineKeyInput.cancelComposition()
            }
        }
        keyboardLayout = layout
    }

    private func commit(_ candidate: NineKeyCandidate) {
        controller?.textDocumentProxy.insertText(nineKeyInput.commit(candidate))
    }

    private func commitFirstCandidate() {
        guard let text = nineKeyInput.commitFirstCandidate() else { return }
        controller?.textDocumentProxy.insertText(text)
    }

    private func insertTextRespectingComposition(_ text: String) {
        if let composition = nineKeyInput.commitFirstCandidate() {
            controller?.textDocumentProxy.insertText(composition)
        }
        controller?.textDocumentProxy.insertText(text)
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

    private func layoutKeyButton(_ title: String, action: @escaping () -> Void) -> some View {
        functionKeyButton(title: title, action: action)
    }

    private func stackedKeyButtons(
        _ upperTitle: String,
        _ lowerTitle: String,
        spacing: CGFloat
    ) -> some View {
        VStack(spacing: spacing) {
            keyButton(upperTitle) { insertTextRespectingComposition(upperTitle) }
                .frame(maxHeight: .infinity)
            keyButton(lowerTitle) { insertTextRespectingComposition(lowerTitle) }
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Bridges the system input-mode switcher into SwiftUI. Passing every touch
/// event to `handleInputModeList` preserves the system behavior: a tap advances
/// to the next enabled keyboard, while a long press or upward swipe presents
/// the system-managed list of enabled keyboards.
private struct InputModeSwitchButton: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "切换输入法"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleInputModeList(_:event:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.controller = controller
        button.tintColor = .label
    }

    final class Coordinator: NSObject {
        weak var controller: UIInputViewController?

        init(controller: UIInputViewController?) {
            self.controller = controller
        }

        @objc func handleInputModeList(_ sender: UIButton, event: UIEvent) {
            controller?.handleInputModeList(from: sender, with: event)
        }
    }
}
