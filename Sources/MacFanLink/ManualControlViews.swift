import AppKit
import FanControlProtocol
import SwiftUI

struct ManualControlButton: View {
    @Environment(\.openSettings) private var openSettings
    let controller: WorkerController

    var body: some View {
        Button("手动控制…") {
            controller.requestedSettingsPage = .manual
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .help("打开手动控制页；进入页面不会接管任何风扇")
    }
}

struct ManualControlSettingsView: View {
    let controller: WorkerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("手动控制", detail: "Mac 自动交给系统；净化器自动使用已有温度联动规则。")
                MacManualFanControl()
                PurifierManualControlView(controller: controller)
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("手动控制")
    }
}

private struct MacManualFanControl: View {
    @State private var controller = MacFanController.shared
    @State private var editingFanIDs: Set<Int> = []
    @State private var confirmingHelperRemoval = false

    var body: some View {
        ContentSection(title: "Mac 内部风扇", subtitle: "系统自动＝本应用不接管转速，不运行 Mac 风扇自动规则。") {
            VStack(alignment: .leading, spacing: 12) {
                helperContent
                if controller.helperReady {
                    if controller.fans.isEmpty {
                        Text("没有检测到可控制的风扇。无风扇机型无需调速；无法读取时不会虚构风扇。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("检测到 \(controller.fans.count) 个风扇，每个可独立切换与调整。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(controller.fans) { fan in
                            MacFanControlRow(fan: fan, controller: controller) { editing in
                                if editing { editingFanIDs.insert(fan.id) }
                                else { editingFanIDs.remove(fan.id) }
                            }
                        }
                    }
                }

                if controller.active {
                    Button("全部交还系统自动") {
                        Task { await controller.restoreAutomatic() }
                    }
                    .disabled(controller.busy)
                }

                if let message = controller.actionMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !controller.connectionMessage.isEmpty {
                    Text(controller.connectionMessage).font(.caption).foregroundStyle(.secondary)
                }

                DisclosureGroup("权限与失效保护") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("手动转速使用 30 秒租约，应用负责续期。应用断开、租约到期或严重热压力时，助手会尝试交还系统；不更改或绕过 SIP。离开页面不会结束已确认的手动控制。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if controller.helperInstalled {
                            Button("卸载风扇助手…", role: .destructive) { confirmingHelperRemoval = true }
                                .disabled(controller.busy)
                        }
                    }.padding(.top, 6)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if editingFanIDs.isEmpty { await controller.refresh() }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .alert("卸载风扇助手？", isPresented: $confirmingHelperRemoval) {
            Button("取消", role: .cancel) {}
            Button("确认卸载", role: .destructive) {
                Task { await controller.uninstallHelper() }
            }
        } message: {
            Text("先确认全部由本应用接管的风扇已释放，再移除助手；无法确认时不会卸载。本机监测和净化器联动不受影响。")
        }
    }

    @ViewBuilder
    private var helperContent: some View {
        if controller.helperUpdateNeeded {
            Label("风扇助手需要更新后才能使用独立多风扇控制。", systemImage: "arrow.down.circle")
                .font(.callout)
            Button("更新风扇助手…") { Task { await controller.updateHelper() } }
                .disabled(controller.busy)
        } else if !controller.helperInstalled {
            Text("手动控制需要管理员批准的风扇助手；未安装时仍由系统自动管理。")
                .font(.callout).foregroundStyle(.secondary)
            Button("安装风扇助手…") { Task { await controller.installHelper() } }
                .disabled(controller.busy)
        } else if controller.helperApprovalNeeded {
            Label("等待你在系统设置中批准风扇助手。", systemImage: "exclamationmark.shield")
                .font(.callout)
            Button("打开系统设置…") { controller.openApprovalSettings() }
                .disabled(controller.busy)
        } else if !controller.helperReady {
            Label("助手尚未就绪，不能确认或修改风扇控制。", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct MacFanControlRow: View {
    private enum Mode: Hashable { case automatic, manual, unavailable }

    let fan: ControllableMacFan
    let controller: MacFanController
    let editingChanged: (Bool) -> Void
    @State private var draftRPM = 0.0
    @State private var draftIsDirty = false
    @State private var editing = false
    @State private var confirmingManual = false

    private var mode: Mode {
        if let target = controller.targets[fan.id] {
            guard fan.automatic == false, let readback = fan.targetRPM,
                  readback.isFinite, abs(readback - Double(target)) <= 1 else { return .unavailable }
            return .manual
        }
        return fan.automatic == true ? .automatic : .unavailable
    }

    private var range: ClosedRange<Double>? {
        guard fan.minRPM.isFinite, fan.maxRPM.isFinite, fan.minRPM >= 0,
              fan.maxRPM > fan.minRPM, fan.maxRPM <= 100_000,
              fan.minRPM.rounded(.up) <= fan.maxRPM.rounded(.down) else { return nil }
        return fan.minRPM...fan.maxRPM
    }

    private var writesUnavailable: Bool { controller.busy || !controller.helperReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(fan.name, systemImage: "fan")
                    .font(.headline)
                Spacer()
                Text("实际 " + rpmText(fan.rpm))
                    .font(.callout).monospacedDigit()
            }
            Picker("\(fan.name) 控制模式", selection: Binding(get: { mode }, set: selectMode)) {
                Text("系统自动").tag(Mode.automatic)
                Text("手动转速").tag(Mode.manual).disabled(!fan.supportsManual || range == nil)
                if mode == .unavailable {
                    Text(controller.targets[fan.id] != nil ? "等待回读确认" : (fan.automatic == false ? "其他软件控制" : "状态未知"))
                        .tag(Mode.unavailable).disabled(true)
                }
            }
            .pickerStyle(.segmented)
            .disabled(writesUnavailable)

            if let range, fan.supportsManual {
                HStack {
                    Text("目标转速").foregroundStyle(.secondary)
                    Spacer()
                    Text(mode == .manual ? rpmText(clampedDraft(in: range)) : "由 macOS 决定")
                        .monospacedDigit()
                }
                .font(.callout)
                Slider(value: Binding(
                    get: { clampedDraft(in: range) },
                    set: { draftRPM = $0; draftIsDirty = true }
                ), in: range, step: 100, onEditingChanged: sliderEditingChanged)
                .accessibilityLabel("\(fan.name) 目标转速")
                .disabled(writesUnavailable || mode != .manual)
                HStack {
                    Text(rpmText(range.lowerBound))
                    Spacer()
                    Text(rpmText(range.upperBound))
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if mode == .manual {
                    Text("拖动后松手应用，仅调整此风扇。实际转速会逐步接近目标。")
                        .font(.caption).foregroundStyle(.secondary)
                    if draftIsDirty && !editing {
                        Button("应用转速") { applyDraft() }
                            .disabled(writesUnavailable)
                    }
                }
            } else {
                Text("此风扇未提供可靠的手动调速范围，保留只读监测。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { synchronizeDraft() }
        .onChange(of: fan) { _, _ in synchronizeDraft() }
        .onChange(of: controller.targets[fan.id]) { _, _ in
            if !editing { draftIsDirty = false; synchronizeDraft() }
        }
        .onDisappear { editingChanged(false) }
        .alert("开始手动控制 \(fan.name)？", isPresented: $confirmingManual) {
            Button("取消", role: .cancel) {}
            Button("开启手动") { applyDraft() }
        } message: {
            Text("仅接管此风扇，初始目标为 \(rpmText(draftRPM))。其他风扇保持现有控制。选择“系统自动”会交还系统调度，不启用任何本应用的 Mac 调速规则。")
        }
    }

    private func selectMode(_ selected: Mode) {
        guard selected != mode, !writesUnavailable else { return }
        switch selected {
        case .automatic:
            Task { await controller.restoreAutomatic(fanID: fan.id) }
        case .manual:
            guard fan.supportsManual, range != nil else { return }
            synchronizeDraft()
            confirmingManual = true
        case .unavailable:
            break
        }
    }

    private func sliderEditingChanged(_ value: Bool) {
        editing = value
        editingChanged(value)
        if !value, draftIsDirty, mode == .manual { applyDraft() }
    }

    private func applyDraft() {
        guard let range, fan.supportsManual, !writesUnavailable else { return }
        let target = min(Int(range.upperBound.rounded(.down)),
                         max(Int(range.lowerBound.rounded(.up)), Int(clampedDraft(in: range).rounded())))
        Task {
            await controller.setManual(fanID: fan.id, rpm: target)
            if controller.targets[fan.id] == target { draftIsDirty = false }
        }
    }

    private func synchronizeDraft() {
        guard !editing, !draftIsDirty, let range else { return }
        let source = controller.targets[fan.id].map(Double.init) ?? fan.rpm
        guard source.isFinite else { return }
        draftRPM = min(max(source, range.lowerBound), range.upperBound)
    }

    private func clampedDraft(in range: ClosedRange<Double>) -> Double {
        min(max(draftRPM, range.lowerBound), range.upperBound)
    }

    private func rpmText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + " RPM"
    }
}
