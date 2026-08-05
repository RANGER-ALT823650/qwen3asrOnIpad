import SwiftUI

@MainActor
struct Qwen3ASRLabView: View {
    @State private var session: TranscriptionLabSession

    init() {
        _session = State(initialValue: TranscriptionLabSession())
    }

    init(session: TranscriptionLabSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    architectureCard
                    statusCard
                    transcriptCard
                    recordControl
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Qwen3-ASR Lab")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await session.prepareModel()
        }
    }

    private var architectureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1.7B MLX 本地推理", systemImage: "waveform.badge.mic")
                .font(.headline)

            modelRow(
                title: "音频编码器",
                value: "MLX 1.7B",
                detail: "Metal GPU",
                color: .blue
            )
            modelRow(
                title: "文本解码器",
                value: "MLX 5-bit",
                detail: "Metal GPU",
                color: .blue
            )

            Text("模型权重随实验 App 打包；录音与转写都在设备本地完成。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var statusCard: some View {
        switch session.phase {
        case .loading(let progress, let message):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView()
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                }
                ProgressView(value: progress)
                    .tint(.blue)
                Text("首次装载 1.7B 权重需要一些时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .cardStyle()

        case .ready:
            Label("模型已就绪，可以开始录音", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

        case .recording(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                let seconds = max(0, context.date.timeIntervalSince(startedAt))
                HStack {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在录音")
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: "已录音 %.1f 秒", seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .cardStyle()
            }

        case .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在离线转写")
                        .font(.subheadline.weight(.semibold))
                    Text("GPU 编码音频并生成文本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .cardStyle()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("无法继续", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("重试加载") {
                    session.retryLoading()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("转写结果", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                if let metrics = session.metrics {
                    Text(metrics)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(session.transcript.isEmpty ? "停止录音后，识别文字会显示在这里。" : session.transcript)
                .font(.body)
                .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .cardStyle()
    }

    private var recordControl: some View {
        Button {
            Task {
                await session.toggleRecording()
            }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(session.isRecording ? Color.red : Color.blue)
                        .frame(width: 82, height: 82)
                    Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(session.isRecording ? "停止并转写" : "开始录音")
                    .font(.headline)
            }
        }
        .buttonStyle(.plain)
        .disabled(!session.canRecord && !session.isRecording)
        .opacity((session.canRecord || session.isRecording) ? 1 : 0.45)
        .accessibilityIdentifier("recordButton")
        .accessibilityLabel(session.isRecording ? "停止录音并转写" : "开始录音")
    }

    private func modelRow(
        title: String,
        value: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 5, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    Qwen3ASRLabView(session: .preview)
}
