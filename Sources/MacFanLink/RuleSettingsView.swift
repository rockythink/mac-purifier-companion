import SwiftUI

struct RuleSettingsView: View {
    let controller: WorkerController
    @State private var presetStore = RulePresetStore.shared
    @State private var draft = ConfigDraft()
    @State private var dirty = false
    @State private var message: String?
    @State private var submittedConfig: LinkConfig?
    @State private var pendingTestLevels: [Int]?
    @State private var showTestConfirmation = false
    @State private var selectedTemplate: RuleTemplate?
    @State private var selectedPresetID: UUID?
    @State private var presetMessage: String?
    @State private var presetError: String?
    @State private var presetName = ""
    @State private var showSavePreset = false
    @State private var showRenamePreset = false
    @State private var showDeletePreset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                pageHeader("联动规则", detail: "精确设置 CPU 温度与净化器最爱等级；编辑草稿不会操作设备。")
                actionBar
                currentStatus

                strategySection

                ContentSection(title: "温度 → 最爱等级", subtitle: "四个阈值构成两档升温与回落回差") {
                    VStack(spacing: 0) {
                        tableHeader
                        Divider()
                        escalationRow(
                            title: "升至中档",
                            comparison: "≥",
                            threshold: \.mediumThreshold,
                            thresholdValue: draft.mediumThresholdValue,
                            level: \.mediumLevel,
                            levelValue: draft.mediumLevelValue,
                            duration: previewConfig.map { "\(exactNumber($0.riseSeconds)) 秒" } ?? "—"
                        )
                        Divider()
                        escalationRow(
                            title: "升至高档",
                            comparison: "≥",
                            threshold: \.highThreshold,
                            thresholdValue: draft.highThresholdValue,
                            level: \.highLevel,
                            levelValue: draft.highLevelValue,
                            duration: previewConfig.map { "\(exactNumber($0.riseSeconds)) 秒" } ?? "—"
                        )
                        Divider()
                        returnRow(
                            title: "降回中档",
                            comparison: "≤",
                            threshold: \.downThreshold,
                            duration: previewConfig.map { "\(exactNumber($0.fallSeconds)) 秒" } ?? "—",
                            destination: levelDescription(draft.mediumLevelValue)
                        )
                        Divider()
                        returnRow(
                            title: "退出接管",
                            comparison: "≤",
                            threshold: \.exitThreshold,
                            duration: previewConfig.map { "\(exactNumber($0.fallSeconds)) 秒" } ?? "—",
                            destination: "恢复原状态"
                        )
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isSaving)

                    Text(draft.timingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    timingFields
                    Text("阈值关系：退出 < 中档 ≤ 降回中档 < 高档。两档等级都必须为 0–17 的整数，且中档低于高档。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ContentSection(title: "规则预览") {
                    if let config = previewConfig {
                        RuleStairPreview(config: config)
                    } else {
                        Label(validationMessage ?? "请修正输入后查看预览。", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Text("最爱等级是设备的离散档位，不对应固定 RPM。上方状态栏仅显示设备当前实测 RPM；它只读，且不会由等级推算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("规则")
        .task { resetDraft() }
        .onChange(of: controller.status?.config) { _, config in
            guard !dirty, submittedConfig == nil, let config else { return }
            draft.apply(config)
        }
        .onChange(of: controller.feedback) { _, _ in consumeSaveFeedback() }
        .alert("试听中档与高档？", isPresented: $showTestConfirmation) {
            Button("开始试听", role: .destructive) {
                if let pendingTestLevels { controller.testStrategy(pendingTestLevels) }
                pendingTestLevels = nil
            }
            Button("取消", role: .cancel) { pendingTestLevels = nil }
        } message: {
            Text(testConfirmationMessage)
        }
        .alert("另存为个人预设", isPresented: $showSavePreset) {
            TextField("预设名称", text: $presetName)
            Button("保存") { saveAsPreset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存当前草稿的完整规则。不会应用到正在运行的联动。")
        }
        .alert("重命名个人预设", isPresented: $showRenamePreset) {
            TextField("预设名称", text: $presetName)
            Button("重命名") { renameSelectedPreset() }
            Button("取消", role: .cancel) {}
        }
        .alert("删除个人预设？", isPresented: $showDeletePreset) {
            Button("删除", role: .destructive) { deleteSelectedPreset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("“\(selectedPreset?.name ?? "此预设")”将从这台 Mac 永久删除。当前草稿不会改变。")
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(controller.pendingOperation == "configure" ? "正在应用…" : "应用到联动") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                    .keyboardShortcut("s", modifiers: .command)
                Button("还原") { resetDraft() }
                    .disabled(!dirty || isSaving)
                Button("试听两档…") { prepareTest() }
                    .disabled(!canTest)
                Spacer(minLength: 8)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("停止") { controller.stop() }
                    .disabled(!controller.canStop)
            }
            if applyBlockedByLink {
                Label("联动正在启用、接管或处理操作；请先暂停或停止联动再应用。草稿和个人预设仍可编辑。", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var currentStatus: some View {
        HStack(spacing: 14) {
            Label(cpuText, systemImage: "cpu")
            Label(currentLevelText, systemImage: "wind")
            if controller.status?.device.reachable == true, let rpm = controller.status?.device.rpm {
                Divider().frame(height: 14)
                Label("实测 \(rpm) RPM（只读）", systemImage: "fan")
                    .help("设备当前报告的实测转速，只读")
            }
            Spacer()
            Text(controller.modeTitle)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 2)
    }

    private var strategySection: some View {
        ContentSection(title: "策略与个人预设", subtitle: "载入只会替换编辑草稿，不会启用联动或操作设备") {
            HStack(spacing: 8) {
                ForEach(RuleTemplate.allCases) { template in
                    Button {
                        load(template)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selectedTemplate == template ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedTemplate == template ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.title).font(.callout.weight(.medium))
                                Text(template.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    if presetStore.presets.isEmpty {
                        Text("尚无个人预设")
                    } else {
                        ForEach(presetStore.presets) { preset in
                            Button {
                                load(preset)
                            } label: {
                                if selectedPresetID == preset.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label(selectedPreset?.name ?? "载入个人预设", systemImage: "person.crop.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(presetStore.presets.isEmpty || isSaving)

                Button("另存为预设…") {
                    presetName = ""
                    presetError = nil
                    showSavePreset = true
                }
                .disabled(draftConfig == nil)
            }

            HStack(spacing: 8) {
                Button("更新所选预设") { updateSelectedPreset() }
                    .disabled(selectedPreset == nil || draftConfig == nil)
                Button("重命名…") {
                    guard let selectedPreset else { return }
                    presetName = selectedPreset.name
                    presetError = nil
                    showRenamePreset = true
                }
                .disabled(selectedPreset == nil)
                Button("删除…", role: .destructive) { showDeletePreset = true }
                    .disabled(selectedPreset == nil)
                Spacer()
                if selectedPresetIsModified {
                    Text("已修改，尚未更新预设")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = presetStore.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let presetError {
                Label(presetError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let presetMessage {
                Text(presetMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var timingFields: some View {
        HStack(spacing: 16) {
            timingField("升档确认", keyPath: \.riseSeconds)
            timingField("降档确认", keyPath: \.fallSeconds)
            timingField("最短调节间隔", keyPath: \.minAdjustSeconds)
            Spacer(minLength: 0)
        }
        .disabled(isSaving)
    }

    private func timingField(_ title: String, keyPath: WritableKeyPath<ConfigDraft, String>) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            numericField(keyPath, suffix: "秒", width: 54, accessibilityLabel: "\(title)秒数")
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("动作").frame(width: 82, alignment: .leading)
            Text("CPU 阈值").frame(width: 232, alignment: .leading)
            Text("持续").frame(width: 58, alignment: .leading)
            Text("目标最爱等级").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func escalationRow(
        title: String,
        comparison: String,
        threshold: WritableKeyPath<ConfigDraft, String>,
        thresholdValue: Double?,
        level: WritableKeyPath<ConfigDraft, String>,
        levelValue: Int?,
        duration: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 82, alignment: .leading)
            HStack(spacing: 6) {
                Text(comparison).foregroundStyle(.secondary)
                if let thresholdValue {
                    Slider(value: thresholdSliderBinding(threshold, current: thresholdValue), in: temperatureRange(around: thresholdValue), step: 0.5)
                        .accessibilityLabel("\(title)温度")
                } else {
                    invalidTrack("输入温度")
                }
                numericField(threshold, suffix: "°C", width: 58, accessibilityLabel: "\(title)温度数值")
            }
            .frame(width: 232)
            Text(duration).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let levelValue, (0...17).contains(levelValue) {
                    Slider(value: levelSliderBinding(level, current: levelValue), in: 0...17, step: 1)
                        .accessibilityLabel("\(title)最爱等级")
                } else {
                    invalidTrack("输入等级")
                }
                numericField(level, suffix: nil, width: 38, accessibilityLabel: "\(title)等级数值")
            }
            .frame(maxWidth: .infinity)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func returnRow(
        title: String,
        comparison: String,
        threshold: WritableKeyPath<ConfigDraft, String>,
        duration: String,
        destination: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 82, alignment: .leading)
            HStack(spacing: 6) {
                Text(comparison).foregroundStyle(.secondary)
                Spacer()
                numericField(threshold, suffix: "°C", width: 58, accessibilityLabel: "\(title)温度数值")
            }
            .frame(width: 232)
            Text(duration).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            Label(destination, systemImage: "arrow.turn.down.left")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func numericField(
        _ keyPath: WritableKeyPath<ConfigDraft, String>,
        suffix: String?,
        width: CGFloat,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: 3) {
            TextField("—", text: textBinding(keyPath))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityLabel(accessibilityLabel)
                .frame(width: width)
            if let suffix { Text(suffix).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func invalidTrack(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
    }

    private var draftConfig: LinkConfig? {
        if case let .success(config) = draft.validated() { return config }
        return nil
    }

    private var previewConfig: LinkConfig? {
        submittedConfig ?? draftConfig
    }

    private var validationMessage: String? {
        if case let .failure(error) = draft.validated() { return error.localizedDescription }
        return nil
    }

    private var isSaving: Bool {
        submittedConfig != nil
    }

    private var selectedPreset: RulePreset? {
        guard let selectedPresetID else { return nil }
        return presetStore.presets.first { $0.id == selectedPresetID }
    }

    private var selectedPresetIsModified: Bool {
        guard let selectedPreset else { return false }
        return draftConfig != selectedPreset.config
    }

    private var applyBlockedByLink: Bool {
        guard let status = controller.status else { return controller.pendingOperation != nil }
        return status.mode == "enabled" || status.owner || status.busy || controller.pendingOperation != nil
    }

    private var canApply: Bool {
        dirty && draftConfig != nil && controller.isActionable && !applyBlockedByLink
    }

    private var canTest: Bool {
        controller.pendingOperation == nil && controller.isActionable && controller.status?.mode != "enabled"
            && controller.status?.device.reachable == true && controller.status?.device.power == true
            && testLevels != nil
    }

    private var testLevels: [Int]? {
        guard let config = draftConfig,
              let medium = config.mediumLevel,
              let high = config.highLevel else { return nil }
        return [medium, high]
    }

    private var testConfirmationMessage: String {
        let levels = pendingTestLevels ?? []
        let description = levels.count == 2 ? "等级 \(levels[0]) 和 \(levels[1])" : "当前两档"
        return "净化器将依次切到\(description)，每档约 10 秒。每档只在控制权未被人工改变时恢复；失败、人工改动或停止会取消余下试听。这会真实写入设备。"
    }

    private var cpuText: String {
        guard let temperature = controller.status?.temperature, let cpu = temperature.cpu else { return "CPU —" }
        return "CPU \(displayNumber(cpu)) °C\(temperature.stale ? "（已过期）" : "")"
    }

    private var currentLevelText: String {
        guard let device = controller.status?.device else { return "设备模式 —" }
        if device.mode == "favorite", let level = device.level { return "最爱等级 \(level)" }
        return "设备模式 \(deviceModeTitle(device.mode))"
    }

    private func textBinding(_ keyPath: WritableKeyPath<ConfigDraft, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                guard submittedConfig == nil, draft[keyPath: keyPath] != value else { return }
                draft[keyPath: keyPath] = value
                changed()
            }
        )
    }

    private func thresholdSliderBinding(
        _ keyPath: WritableKeyPath<ConfigDraft, String>,
        current: Double
    ) -> Binding<Double> {
        Binding(
            get: { Double(draft[keyPath: keyPath]) ?? current },
            set: { value in
                guard submittedConfig == nil else { return }
                draft[keyPath: keyPath] = exactNumber(value)
                changed()
            }
        )
    }

    private func levelSliderBinding(
        _ keyPath: WritableKeyPath<ConfigDraft, String>,
        current: Int
    ) -> Binding<Double> {
        Binding(
            get: { Double(Int(draft[keyPath: keyPath]) ?? current) },
            set: { value in
                guard submittedConfig == nil else { return }
                draft[keyPath: keyPath] = String(Int(value.rounded()))
                changed()
            }
        )
    }

    private func temperatureRange(around value: Double) -> ClosedRange<Double> {
        min(0, floor(value / 10) * 10)...max(120, ceil(value / 10) * 10)
    }

    private func levelDescription(_ level: Int?) -> String {
        level.map { "等级 \($0)" } ?? "中档未设置"
    }

    private func changed() {
        if case let .success(value) = draft.validated(), value == controller.status?.config {
            dirty = false
            message = nil
        } else {
            dirty = true
            message = validationMessage ?? "尚未应用；设备未改变。"
        }
    }

    private func resetDraft() {
        guard submittedConfig == nil else { return }
        draft.apply(controller.status?.config ?? .defaults)
        dirty = false
        selectedTemplate = nil
        selectedPresetID = nil
        message = nil
    }

    private func save() {
        guard canApply else {
            if applyBlockedByLink {
                message = "请先暂停或停止联动再应用。"
            }
            return
        }
        guard case let .success(value) = draft.validated() else {
            message = validationMessage
            return
        }
        submittedConfig = value
        message = "正在等待后台确认应用…"
        controller.configure(value)
    }

    private func load(_ template: RuleTemplate) {
        guard submittedConfig == nil else { return }
        let mediumLevel = draft.mediumLevel
        let highLevel = draft.highLevel
        draft.apply(template.configuration(basedOn: controller.status?.config ?? .defaults))
        draft.mediumLevel = mediumLevel
        draft.highLevel = highLevel
        selectedTemplate = template
        selectedPresetID = nil
        presetError = nil
        presetMessage = "已载入“\(template.title)”模板；尚未应用到联动。"
        changed()
    }

    private func load(_ preset: RulePreset) {
        guard submittedConfig == nil else { return }
        draft.apply(preset.config)
        selectedTemplate = nil
        selectedPresetID = preset.id
        presetError = nil
        presetMessage = "已载入“\(preset.name)”；尚未应用到联动。"
        changed()
    }

    private func saveAsPreset() {
        guard let config = draftConfig else {
            presetError = validationMessage ?? "请先修正规则。"
            return
        }
        do {
            selectedPresetID = try presetStore.save(name: presetName, config: config, replacing: nil)
            selectedTemplate = nil
            presetError = nil
            presetMessage = "已保存个人预设“\(presetName.trimmingCharacters(in: .whitespacesAndNewlines))”。联动未改变。"
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func updateSelectedPreset() {
        guard let id = selectedPresetID, let config = draftConfig else { return }
        do {
            selectedPresetID = try presetStore.save(name: selectedPreset?.name ?? "", config: config, replacing: id)
            presetError = nil
            presetMessage = "已更新个人预设；联动未改变。"
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func renameSelectedPreset() {
        guard let id = selectedPresetID else { return }
        do {
            try presetStore.rename(id: id, to: presetName)
            presetError = nil
            presetMessage = "个人预设已重命名。"
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func deleteSelectedPreset() {
        guard let id = selectedPresetID else { return }
        do {
            try presetStore.remove(id: id)
            selectedPresetID = nil
            presetError = nil
            presetMessage = "个人预设已删除；当前草稿未改变。"
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func prepareTest() {
        guard let testLevels else { return }
        pendingTestLevels = testLevels
        showTestConfirmation = true
    }

    private func consumeSaveFeedback() {
        guard let feedback = controller.feedback,
              feedback.op == "configure",
              let submittedConfig else { return }
        switch feedback.phase {
        case .pending:
            message = feedback.detail
        case .succeeded:
            draft.apply(submittedConfig)
            dirty = false
            self.submittedConfig = nil
            message = feedback.detail
        case .failed:
            self.submittedConfig = nil
            message = feedback.detail
        }
    }

    private func exactNumber(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }

    private func displayNumber(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
    }

    private func deviceModeTitle(_ mode: String?) -> String {
        switch mode {
        case "favorite": "最爱"
        case "auto": "自动"
        case "silent": "睡眠"
        case nil: "—"
        default: mode ?? "—"
        }
    }
}

private struct RuleStairPreview: View {
    let config: LinkConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("升温路径（从未接管开始，持续 \(number(config.riseSeconds)) 秒）")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                band(
                    "待机",
                    detail: "低于 \(number(config.mediumThreshold)) °C",
                    color: .secondary
                )
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                band(
                    "中档 \(level(config.mediumLevel))",
                    detail: "≥ \(number(config.mediumThreshold)) °C",
                    color: .blue
                )
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                band(
                    "高档 \(level(config.highLevel))",
                    detail: "≥ \(number(config.highThreshold)) °C",
                    color: .orange
                )
            }
            HStack(spacing: 16) {
                Label("≤ \(number(config.downThreshold)) °C 持续 \(number(config.fallSeconds)) 秒：高档 → 中档", systemImage: "arrow.down.right")
                Label("≤ \(number(config.exitThreshold)) °C 持续 \(number(config.fallSeconds)) 秒：退出接管", systemImage: "arrow.uturn.backward")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func band(_ title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }

    private func level(_ value: Int?) -> String {
        value.map { "· 等级 \($0)" } ?? "· 未设置"
    }

    private func number(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }
}
