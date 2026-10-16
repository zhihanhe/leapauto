import SwiftUI
import LeapCore

/// Deliberately independent of AppModel, authenticated sessions and vehicle state.
struct LocalVideoCodecDiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LocalVideoCodecDiagnosticsModel()
    @State private var highResolution = false

    var body: some View {
        DetailPage("本机视频诊断") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "合成画面 · 本机 H.264", caption: "不代表已支持车机投屏")
                    Text("只生成彩条和计数，依次编码、解码并校验像素。不会录制屏幕、采集声音、联网、落盘或连接车辆。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("默认最多 300 帧。停止、离开页面或 App 不再活跃时结束；不会自动恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("图像尺寸", selection: $highResolution) {
                        Text("640 × 360").tag(false)
                        Text("1280 × 720").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("video.resolution")
                    Text("切换尺寸会清除本轮统计，并重建编解码器。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.isRunning ? "重新开始" : "开始本机诊断") { start() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("video.start")
                        Button("停止") { model.stop() }
                            .buttonStyle(.bordered)
                            .disabled(!model.isRunning)
                            .accessibilityIdentifier("video.stop")
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(phaseTitle).font(.headline).accessibilityIdentifier("video.phase")
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1)
                            .resizable().scaledToFit()
                            .accessibilityLabel("真实 H.264 解码后的合成彩条")
                            .accessibilityIdentifier("video.decodedPreview")
                    } else {
                        ContentUnavailableView("尚无解码预览", systemImage: "film",
                            description: Text("点击开始后，显示本机实际解码的合成画面。"))
                    }
                    if let message = model.snapshot.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(LeapStyle.danger)
                            .accessibilityIdentifier("video.error")
                    }
                    MetricRow(title: "已提交 / 已编码 / 已解码", value: "\(model.snapshot.submittedFrames) / \(model.snapshot.encodedFrames) / \(model.snapshot.decodedFrames)")
                        .accessibilityIdentifier("video.frames")
                    MetricRow(title: "丢帧（背压 / 编解码 / 取消）", value: "\(model.snapshot.backpressureDrops) / \(model.snapshot.codecDrops) / \(model.snapshot.cancelledFrames)")
                    MetricRow(title: "错误帧 / 在途帧 / 峰值", value: "\(model.snapshot.failedFrames) / \(model.snapshot.inFlightFrames) / \(model.snapshot.peakInFlightFrames)")
                    MetricRow(title: "H.264 字节数", value: model.snapshot.encodedBytes.formatted())
                    MetricRow(title: "平均 / 最大耗时", value: String(format: "%.1f / %.1f ms", model.snapshot.meanLatencyMilliseconds, model.snapshot.maximumLatencyMilliseconds))
                    Text("耗时从提交前到解码像素校验完成，不包含网络或车机延迟。")
                        .font(.caption).foregroundStyle(.secondary)
                    MetricRow(title: "编码器 / 解码器", value: "\(implementation(model.encoderUsesHardware)) / \(implementation(model.decoderUsesHardware))")
                    Text("由当前系统选择软硬件实现；模拟器结果不能证明真机硬件能力。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading(title: "屏幕共享仍待接入")
                    Text("当前未接 ReplayKit，也未验证车机接收、发现、握手或传输协议。本机编解码成功仅证明这一段视频链路可运行。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("screen.videoDiagnostics")
        .onChange(of: highResolution) { _, _ in if model.isRunning { start() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.stop() }
    }

    private func start() { model.start(configuration: highResolution ? .hd : .standard) }
    private func implementation(_ hardware: Bool?) -> String {
        guard let hardware else { return "未知" }
        return hardware ? "硬件" : "软件"
    }
    private var phaseTitle: String {
        if model.isStopping { return "正在停止并释放本轮资源" }
        switch model.snapshot.phase {
        case .idle: return "尚未运行"
        case .running: return "正在本机编码、解码"
        case .completed: return "本轮完成（仅本机诊断）"
        case .stopped: return "已停止"
        case .failed: return "诊断失败"
        }
    }
}
