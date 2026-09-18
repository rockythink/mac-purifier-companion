import AppKit
import SwiftUI

struct HostOverviewSettingsView: View {
    let controller: WorkerController

    @State private var macIdentity = MacDeviceIdentity.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    pageHeader("本机状态", detail: "独立监测 · 无需连接米家")
                    Spacer(minLength: 16)
                    ManualControlButton(controller: controller)
                    Button("刷新") { controller.refresh() }
                        .disabled(!controller.isActionable)
                }

                deviceStage
                Text("暖色表示更高的温度或占用；风扇色深表示更高转速，不代表故障。")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("温度配色参考 40–100°C，负载和内存参考使用比例；不是控制阈值或系统内存压力。风扇颜色不代表散热效果。")

                if !controller.connected {
                    Label(controller.launching ? "正在连接后台…" : "后台未连接，所有实时读数已隐藏。",
                          systemImage: controller.launching ? "hourglass" : "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("系统状态与诊断") {
                    systemDetails
                        .padding(.top, 10)
                }

                DisclosureGroup("CPU 占用前三") {
                    processDetails
                        .padding(.top, 10)
                }

                Text("系统热状态不等于降频判断；进程占用与温度同时变化不代表因果关系。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("本机状态")
        .task {
            await macIdentity.load()
            while !Task.isCancelled {
                controller.requestProcesses()
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
            }
        }
    }

    private var deviceStage: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 10) {
                metric("Mac · CPU 温度", value: temperature(reading?.cpu), tint: intensityColor(reading?.cpu, minimum: 40, maximum: 100))
                metric("Mac · GPU 温度", value: temperature(reading?.gpu), tint: intensityColor(reading?.gpu, minimum: 40, maximum: 100))
                metric("Mac · 内存已用", value: bytesText(system?.memory?.usedBytes),
                       detail: system?.memory.map { "总量 " + bytesText($0.totalBytes) },
                       tint: intensityColor(system?.memory.flatMap { $0.totalBytes > 0 ? $0.usedBytes / $0.totalBytes * 100 : nil }))
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text(macIdentity.name).font(.headline)
                    Text(macIdentity.identifier + " · " + macIdentity.chip)
                        .font(.caption).foregroundStyle(.secondary)
                }
                DeviceStackArtwork(mac: macIdentity, purifierModel: controller.status?.device.model,
                                   imageURL: controller.status?.device.imageURL, height: 248)
                VStack(spacing: 4) {
                    Text(purifierName).font(.headline)
                    if let model = controller.status?.device.model, !model.isEmpty, model != purifierName {
                        Text(model).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(purifierConnectionText).font(.caption).foregroundStyle(purifierConnectionColor)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: 168)

            VStack(spacing: 10) {
                metric("Mac · CPU 负载", value: percent(reading?.cpuLoad), tint: intensityColor(reading?.cpuLoad))
                metric("Mac · GPU 负载", value: percent(system?.gpuLoad), tint: intensityColor(system?.gpuLoad))
                if let fans = system?.fans, !fans.isEmpty {
                    ForEach(fans) { fan in
                        metric("Mac · \(fan.name)", value: "\(Int(fan.rpm.rounded())) RPM", tint: fanColor(fan.rpm, maximum: fan.maxRPM))
                    }
                } else {
                    metric("Mac · 风扇", value: "—")
                }
                metric("净化器 · 风扇", value: purifierRPM.map { "\($0) RPM" } ?? "—", tint: fanColor(purifierRPM.map(Double.init)))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func metric(_ title: String, value: String, detail: String? = nil, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 61, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var systemDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 7) {
            GridRow {
                LabeledContent("系统热状态", value: thermalTitle(system?.thermalState))
                LabeledContent("内存压力", value: pressureTitle(system?.memoryPressure))
            }
            GridRow {
                LabeledContent("Swap", value: swapUsage(system?.memory))
                LabeledContent("采样时间", value: timestampText(system?.timestamp ?? reading?.timestamp))
            }
            if let fans = system?.fans, !fans.isEmpty {
                ForEach(fans) { fan in
                    GridRow {
                        LabeledContent("Mac · \(fan.name)", value: "\(Int(fan.rpm.rounded())) RPM")
                            .monospacedDigit()
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var processDetails: some View {
        if !controller.connected {
            Text("后台未连接，不显示旧的进程采样。")
                .foregroundStyle(.secondary)
        } else if let error = controller.processes?.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let processes = controller.processes?.processes, !processes.isEmpty {
            VStack(spacing: 7) {
                ForEach(Array(processes.prefix(3))) { process in
                    HStack {
                        Text(process.name)
                            .lineLimit(1)
                            .help("PID \(process.pid)")
                        Spacer()
                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .monospacedDigit()
                    }
                }
            }
        } else {
            Text(controller.processesLoading ? "正在采样…" : "暂无进程采样")
                .foregroundStyle(.secondary)
        }
    }

    private func intensityColor(_ value: Double?, minimum: Double = 0, maximum: Double = 100) -> Color {
        guard let value, value.isFinite, value >= 0 else { return .secondary }
        let fraction = min(max((value - minimum) / (maximum - minimum), 0), 1)
        return Color(hue: 0.38 * (1 - fraction), saturation: 0.76,
                     brightness: colorScheme == .dark ? 0.96 : 0.58)
    }

    private func fanColor(_ rpm: Double?, maximum: Double? = nil) -> Color {
        guard let rpm, rpm.isFinite, rpm >= 0 else { return .secondary }
        let fraction: Double
        if let maximum, maximum.isFinite, maximum > 0 {
            fraction = min(rpm / maximum, 1)
        } else {
            // An uncalibrated visual scale, not an invented hardware limit.
            fraction = rpm / (rpm + 1_500)
        }
        return Color(hue: 0.49 + 0.10 * fraction, saturation: 0.65 + 0.15 * fraction,
                     brightness: colorScheme == .dark ? 0.96 : 0.58)
    }

    private var reading: TemperatureStatus? {
        guard controller.connected, let value = controller.status?.temperature, !value.stale else { return nil }
        return value
    }

    private var system: SystemMetricsStatus? {
        guard controller.connected, let value = controller.status?.system, !value.stale else { return nil }
        return value
    }

    private var purifierName: String {
        guard let status = controller.status, status.account.paired else { return "净化器" }
        return status.device.productTitle
    }

    private var purifierConnectionText: String {
        guard let status = controller.status else { return "状态未知" }
        guard status.account.paired else { return "未配对" }
        guard controller.connected else { return "已配对 · 状态未知" }
        guard status.device.reachable else { return "已配对 · 离线" }
        switch status.device.power {
        case true: return "已配对 · 在线"
        case false: return "已配对 · 已关机"
        case nil: return "已配对 · 状态未知"
        }
    }

    private var purifierConnectionColor: Color {
        guard controller.connected, let status = controller.status, status.account.paired else { return .secondary }
        return status.device.reachable ? .secondary : .orange
    }

    private var purifierRPM: Int? {
        guard controller.connected,
              let status = controller.status,
              status.account.paired,
              status.device.reachable,
              status.device.power == true,
              !status.temperature.stale,
              let rpm = status.device.rpm
        else { return nil }
        return rpm
    }

}
