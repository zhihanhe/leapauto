import SwiftUI
import LeapCore

struct VehicleConnectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        DetailPage("车辆连接与能力") {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "连接状态")
                        .accessibilityIdentifier("connection.summary.title")
                    MetricRow(title: "数据来源", value: model.mode == .demo ? "离线演示" : "零跑中国区云端")
                        .accessibilityIdentifier("connection.source")
                    MetricRow(title: "所选车型", value: model.selectedVehicle?.modelName ?? "未知")
                    MetricRow(title: "车辆列表", value: model.selectedVehicle == nil ? "未选择车辆" : "已选择")
                    MetricRow(title: "车况响应", value: model.status == nil ? "尚未读取成功" : (model.mode == .demo ? "演示样例" : "已收到，需核对时效"))
                    MetricRow(title: "蓝牙钥匙", value: "尚未启用")
                    Text("云端车况可读不代表手机已连接车机。蓝牙仍缺少完整的原生密码后端、证书生命周期与实车验收。C10 不按车型名称直接判定支持或不支持。")
                        .font(.caption).foregroundStyle(.secondary)
                    TelemetryFreshnessView(status: model.status)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "服务端能力信息", caption: "来源：车辆列表 · 不作为控车授权")
                    if let timestamp = model.vehicleMetadataUpdatedAt {
                        Text("更新于：\(timestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.vehicleMetadataMessage {
                        Text(message)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("connection.metadata.message")
                    }
                    MetricRow(title: "年款 / 配置 / 车机固件", value: "已知接口尚未提供，保持未知")
                    if let vehicle = model.selectedVehicle {
                        ForEach(vehicle.capabilities.features) { feature in
                            MetricRow(title: feature.title, value: feature.statusTitle)
                        }
                    } else {
                        Text("尚未选择车辆。")
                    }
                    Text("功能被原界面隐藏，不等于车辆硬件不支持；服务端标记支持也不等于当前 iOS 已实现。缺失字段保持未知，不根据车型猜测。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "哨兵模式")
                    MetricRow(title: "当前状态", value: model.status?.sentryMode.map { $0 ? "开启" : "关闭" } ?? "未知")
                    Text("仅在车况明确上报哨兵状态、确认车辆已停稳且账号权限明确时可操作。共享账号不能开启；请求前会重新核对权限。硬件与服务端是否接受仍需实车验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("开启哨兵") { model.request(.sentryOn) }
                            .disabled(!model.canRequest(.sentryOn))
                            .accessibilityIdentifier("sentry.enable")
                        Button("关闭哨兵") { model.request(.sentryOff) }
                            .disabled(!model.canRequest(.sentryOff))
                            .accessibilityIdentifier("sentry.disable")
                    }
                    .buttonStyle(.bordered)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "蓝牙云端配置", caption: "来源：commonConfig · 只读同步")
                    if let configuration = model.connectionConfiguration {
                        MetricRow(title: "配置记录", value: configuration.hasBluetoothConfiguration ? "服务端已返回" : "服务端未提供，支持情况未知")
                        if let version = configuration.controllerVersion {
                            MetricRow(title: "控制器版本", value: version)
                        }
                        Text("查询时间：\(configuration.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("尚无当前车辆的配置结果。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let message = model.connectionConfigurationMessage {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("接入、切换车辆和刷新车况后自动只读同步，也可在此重试。不申请钥匙、不扫描蓝牙、不上传设置。控制器版本不等于车机固件版本。不会保存或显示蓝牙 MAC、证书及身份凭据。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("读取连接配置") { Task { await model.inspectConnectionConfiguration() } }
                        .buttonStyle(.bordered)
                        .disabled(model.mode != .connected || model.selectedVehicle == nil || model.isBusy || model.isCommandRunning || model.pendingCommand != nil)
                        .accessibilityIdentifier("connection.inspect")
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "本机视频诊断", caption: "独立离线测试")
                    Text("使用合成画面验证本机 H.264 编码与解码。不会录屏或连接车辆，结果不代表车机支持投屏。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("打开本机视频诊断") { LocalVideoCodecDiagnosticsView() }
                        .accessibilityIdentifier("connection.videoDiagnostics")
                }
            }
        }
        .accessibilityIdentifier("screen.connection")
    }
}
