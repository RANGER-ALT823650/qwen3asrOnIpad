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
                        Text("在旁边日记 App 的键盘上再次点击语音按钮即可停止")
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
                        Text("保持本 App 与日记 App 分屏可见；文字会直接回传当前键盘")
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
                        Text("分屏语音服务已就绪")
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
                    Text("录音和识别都在 iPad 本机完成")
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
                Label("最长录音 \(Int(AppGroupBridge.maximumRecordingDuration)) 秒；iPad 分屏前台 MLX 推理", systemImage: "cpu")
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
                Text("iPad 输入法设置")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) {
                guideStepRow(step: "1", title: "添加键盘", desc: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → qwen3asr 输入法")
                guideStepRow(step: "2", title: "开启完全访问", desc: "进入 qwen3asr 输入法，开启「允许完全访问」，让键盘能使用本机录音与离线转写组件。")
                guideStepRow(step: "3", title: "保持分屏", desc: "将千问3 ASR与日记 App 同时放在 iPad 前台，并在日记文本框切换到本输入法。")
                guideStepRow(step: "4", title: "开始语音输入", desc: "点击语音按钮开始录音，再次点击后只通过 Darwin 通知让分屏中的本 App 停止、识别并回传文字。")
                guideStepRow(step: "5", title: "麦克风权限", desc: "第一次使用时请选择「允许」。若之前拒绝，可在本页下方或 iPad 设置中重新开启。")
            }
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Label("打开 iPad 设置", systemImage: "gearshape.fill")
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
            Text("请在使用期间保持千问3 ASR与日记 App 分屏可见。本 App 会保持麦克风输入图处于就绪状态，只有键盘明确启动录音时才写入文件；待机采样会立即丢弃。若模型 App 不再位于前台，本轮不会启动 MLX 推理。")
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
