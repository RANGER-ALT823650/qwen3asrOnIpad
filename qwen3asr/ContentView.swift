import SwiftUI

struct ContentView: View {
    @StateObject private var recordController = AppRecordController.shared

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
            .navigationTitle("Whisper 语音输入法")
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
                    Text("Whisper base 离线语音输入")
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
            Text("已内置 Whisper base 多语言 Q5_1 量化模型。识别过程不上传音频、不依赖局域网，也不需要启动 Mac 服务。")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Label("运行时使用 whisper.cpp 的 Metal 后端加速", systemImage: "cpu")
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
                guideStepRow(step: "2", title: "开启完全访问", desc: "进入 qwen3asr 输入法，开启「允许完全访问」，以便键盘唤起本 App 录音。")
                guideStepRow(step: "3", title: "开始语音输入", desc: "在任意文本框切换到 qwen3asr 输入法，点击语音按钮。App 会短暂打开并开始录音，随后自动回到键盘；再次点击按钮停止并转写。")
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
            Text("离线模型首次识别需要加载片刻；录音结束后请等待转写完成。较长录音会消耗更多时间与电量。")
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
