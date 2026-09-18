import SwiftUI

struct PurifierManualControlView: View {
    let controller: WorkerController

    @State private var draftLevel = 0.0
    @State private var draggingSlider = false
    @State private var dragChanged = false

    var body: some View {
        ContentSection(
            title: controller.status?.account.paired == true ? controller.status?.device.productTitle ?? "净化器风量" : "净化器风量",
            subtitle: "手动可选 0–17 整数档位；实际 RPM 来自设备回读，不是设定值"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                modeControls

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    MetricView(title: "设备实际转速", value: actualRPM, prominent: true)
                    MetricView(title: "当前状态", value: stateTitle)
                }

                manualSpeedControl

                if shouldOfferRestore {
                    Divider()
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("结束手动控制").font(.subheadline.weight(.medium))
                            Text("按条件恢复进入手动前的设备模式和档位，不会开启已关机的设备。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(restoreButtonTitle) { controller.releaseManualPurifier() }
                            .disabled(!canRestore)
                    }
                }

                if let message = unavailableMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = operationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .onAppear { synchronizeDraftFromStatus() }
        .onChange(of: controller.status?.device.level) { _, _ in synchronizeDraftFromStatus() }
        .onChange(of: controller.status?.mode) { _, _ in synchronizeDraftFromStatus() }
    }

    private var modeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("控制方式").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                modeButton(
                    title: "自动联动",
                    detail: "按已保存的 CPU 温度规则控制",
                    symbol: "arrow.triangle.branch",
                    selected: activeMode == .automatic,
                    enabled: canSelectAutomatic
                ) {
                    guard activeMode != .automatic else { return }
                    controller.enable()
                }

                modeButton(
                    title: "手动风速",
                    detail: "固定到下方所选档位",
                    symbol: "slider.horizontal.3",
                    selected: activeMode == .manual,
                    enabled: canWrite
                ) {
                    guard activeMode != .manual else { return }
                    controller.setManualPurifier(level: selectedLevel)
                }
            }
        }
    }

    private var manualSpeedControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("手动档位").font(.subheadline.weight(.medium))
                Spacer()
                Text("最爱 \(selectedLevel) 档")
                    .font(.headline)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { draftLevel },
                    set: { draftLevel = $0; if draggingSlider { dragChanged = true } }
                ),
                in: 0...17,
                step: 1
            ) { editing in
                if editing {
                    draggingSlider = true
                    dragChanged = false
                } else {
                    draggingSlider = false
                    applyDragIfNeeded()
                }
            }
            .disabled(!canWrite)
            .accessibilityLabel("净化器手动档位")
            .accessibilityValue("最爱 \(selectedLevel) 档")

            HStack {
                Text("低档 0")
                Spacer()
                Text("高档 17")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            Text("0 是最低最爱档位，不代表关机；设备实际转速以回读为准。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(activeMode == .manual
                     ? "拖动只修改预览；松手后应用一次。键盘调整后请点“应用档位”。"
                     : "先选择档位，再点“手动风速”显式进入手动控制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if activeMode == .manual {
                    Button("应用档位") { applyDraft() }
                        .disabled(!canWrite || !hasUnappliedDraft)
                }
            }
        }
    }

    private func modeButton(
        title: String,
        detail: String,
        symbol: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || controller.pendingOperation != nil)
    }

    private enum ActiveMode {
        case automatic
        case manual
    }

    private var activeMode: ActiveMode? {
        guard controller.connected,
              controller.errorMessage == nil,
              controller.status?.device.reachable == true,
              controller.status?.device.power == true,
              controller.status?.temperature.stale == false,
              controller.status?.commandState != "unknown"
        else { return nil }

        switch controller.status?.mode {
        case "enabled": return .automatic
        case "manual": return .manual
        default: return nil
        }
    }

    private var selectedLevel: Int {
        min(max(Int(draftLevel.rounded()), 0), 17)
    }

    private var actualRPM: String {
        guard controller.connected,
              let status = controller.status,
              status.device.reachable,
              status.device.power == true,
              !status.temperature.stale,
              status.commandState != "unknown",
              let rpm = status.device.rpm
        else { return "—" }
        return "\(rpm) RPM"
    }

    private var canWrite: Bool {
        guard let status = controller.status else { return false }
        return controller.isActionable
            && status.account.paired
            && status.device.reachable
            && status.device.power == true
            && !status.temperature.stale
            && status.commandState != "unknown"
    }

    private var canRestore: Bool {
        guard let status = controller.status else { return false }
        return controller.isActionable
            && status.account.paired
            && status.device.reachable
            && status.device.power == true
            && !status.temperature.stale
            && (status.mode == "manual" || status.commandState == "unknown")
    }

    private var hasUnappliedDraft: Bool {
        selectedLevel != controller.status?.device.level
    }

    private var canSelectAutomatic: Bool {
        guard canWrite, let status = controller.status else { return false }
        if status.mode != "manual" { return status.canEnable || status.mode == "enabled" }
        guard let medium = status.config.mediumLevel,
              let high = status.config.highLevel, medium < high else { return false }
        return status.verifiedLevels.contains(medium) && status.verifiedLevels.contains(high)
    }

    private var shouldOfferRestore: Bool {
        controller.status?.mode == "manual" || controller.status?.commandState == "unknown"
    }

    private var restoreButtonTitle: String {
        controller.status?.commandState == "unknown" ? "尝试恢复原状态" : "恢复原状态"
    }

    private var stateTitle: String {
        guard controller.connected else { return controller.launching ? "正在连接" : "后台离线" }
        guard let status = controller.status else { return "正在读取" }
        guard status.device.reachable else { return "设备离线" }
        guard status.device.power == true else { return status.device.power == false ? "设备已关机" : "电源未知" }
        guard !status.temperature.stale else { return "采样已过期" }
        guard status.commandState != "unknown" else { return "状态待确认" }
        switch status.mode {
        case "enabled": return "自动联动"
        case "manual": return "手动风速"
        case "paused": return status.reason.contains("人工修改") ? "外部修改后暂停" : "已暂停"
        case "dryRun": return "仅演练"
        case "stopped": return "已停止"
        default: return "状态未知"
        }
    }

    private var unavailableMessage: String? {
        guard let status = controller.status else { return "正在等待后台状态。" }
        if !status.account.paired { return "请先配对净化器。" }
        if !status.device.reachable { return "净化器离线，已停用所有写入操作。" }
        if status.device.power != true { return "净化器已关机或电源状态未知；本页面不会替你开机。" }
        if status.temperature.stale { return "状态采样已过期，已停用所有写入操作。" }
        if status.commandState == "unknown" { return "上次设备写入结果未能确认；可尝试恢复原状态。" }
        return nil
    }

    private var operationError: String? {
        if let feedback = controller.feedback, feedback.phase == .failed {
            return feedback.detail.isEmpty ? feedback.title : "\(feedback.title)：\(feedback.detail)"
        }
        return controller.errorMessage
    }

    private func synchronizeDraftFromStatus() {
        guard !draggingSlider,
              let current = controller.status?.device.level,
              0...17 ~= current
        else { return }
        draftLevel = Double(current)
    }

    private func applyDragIfNeeded() {
        defer { dragChanged = false }
        guard dragChanged else { return }
        applyDraft()
    }

    private func applyDraft() {
        guard activeMode == .manual,
              canWrite,
              selectedLevel != controller.status?.device.level
        else { return }
        controller.setManualPurifier(level: selectedLevel)
    }
}
