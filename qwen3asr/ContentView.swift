import SwiftUI

struct ContentView: View {
    @StateObject private var recordController = AppRecordController.shared
    @StateObject private var audioRecorder = AudioRecorder.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    recordingStatusCard
                    headerCard
                    offlineModelCard
                    keyboardSetupGuideCard
                    usageNotesCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Qwen3-ASR 语音输入法")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var recordingStatusCard: some View {
        Group {
            if recordController.isRecording {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.headline)
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在录音…")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        Text("回到正在输入的 App，点击键盘上的语音按钮即可停止")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.red.opacity(0.08))
                .cornerRadius(12)
            } else if recordController.isTranscribing {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Qwen3-ASR 正在本机识别…")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        Text("请保持本页在前台；完成后会自动返回键盘")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(12)
            } else if audioRecorder.isMicrophoneWarm {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台语音服务已就绪")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        Text("麦克风保持开启；未点击键盘语音按钮时，输入帧会被直接丢弃，不写入文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.green.opacity(0.08))
                .cornerRadius(12)
            } else if !recordController.lastMessage.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recordController.lastMessage)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Button("打开设置开启麦克风") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
            }
        }
    }

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qwen3-ASR 1.7B 离线语音输入")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("录音和识别都在 iPhone 本机完成")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
    }

    private var offlineModelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .foregroundColor(.green)
                    .font(.headline)
                Text("本机离线模型")
                    .font(.headline)
                Spacer()
                Text("无需 Mac")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(12)
            }
            Text("已内置完整的 Qwen3-ASR 1.7B MLX 5-bit 模型，音频编码与文本解码复用同一份本地权重。识别过程不上传音频、不依赖局域网，也不需要启动 Mac 服务。")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Label("最长录音 \(Int(AppGroupBridge.maximumRecordingDuration)) 秒；CPU 安全加载，前台 Metal 推理", systemImage: "cpu")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
    }

    private var keyboardSetupGuideCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "keyboard")
                    .foregroundColor(.indigo)
                    .font(.headline)
                Text("iPhone 输入法设置")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) {
                guideStepRow(step: "1", title: "添加键盘", desc: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → qwen3asr 输入法")
                guideStepRow(step: "2", title: "开启完全访问", desc: "进入 qwen3asr 输入法，开启「允许完全访问」，让键盘能使用本机录音与离线转写组件。")
                guideStepRow(step: "3", title: "开始语音输入", desc: "在任意文本框切换到 qwen3asr 输入法，点击语音按钮即可原地录音；再次点击停止后会短暂打开本 App，识别完成后自动返回并插入文字。")
                guideStepRow(step: "4", title: "麦克风权限", desc: "第一次点击语音按钮时，请在弹出的对话框中选择「允许」。若之前拒绝了，可在本页下方或 iPhone 设置中重新开启。")
            }
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Label("打开 iPhone 设置", systemImage: "gearshape.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.indigo.opacity(0.12))
                    .foregroundColor(.indigo)
                    .cornerRadius(8)
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
    }

    private var usageNotesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("使用提示", systemImage: "info.circle")
                .font(.headline)
            Text("为了让键盘可连续开始下一轮，打开本 App 后麦克风会在后台保持开启，状态栏会显示橙色麦克风指示。只有当前 qwen3asr 键盘启动录音时才写入音频文件；待机采样会立即丢弃。持续后台运行会增加耗电，iOS 仍可能在资源紧张时结束 App。")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func guideStepRow(step: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.indigo))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
