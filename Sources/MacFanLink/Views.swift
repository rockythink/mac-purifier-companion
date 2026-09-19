import AppKit
import SwiftUI

struct SettingsView: View {
    let controller: WorkerController

    var body: some View {
        @Bindable var controller = controller
        let navigation = NavigationSplitView {
            List(selection: $controller.requestedSettingsPage) {
                Section("监测") {
                    Label("本机状态", systemImage: "waveform.path.ecg.rectangle").tag(SettingsPage.overview)
                    Label("趋势", systemImage: "chart.xyaxis.line").tag(SettingsPage.history)
                }
                Section("控制") {
                    Label("手动控制", systemImage: "fan").tag(SettingsPage.manual)
                    Label("联动设备", systemImage: "air.purifier").tag(SettingsPage.device)
                    Label("联动规则", systemImage: "slider.horizontal.3").tag(SettingsPage.rules)
                }
                Section("设置") {
                    Label("米家账号", systemImage: "person.crop.circle").tag(SettingsPage.account)
                    Label("运行与通知", systemImage: "gearshape.2").tag(SettingsPage.runtime)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let feedback = controller.feedback {
                    ActionFeedbackView(feedback: feedback, dismiss: controller.dismissFeedback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10).padding(.horizontal, 24)
                }
                page(controller.requestedSettingsPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 680)
        .background(CompactSettingsToolbar())
        .task { controller.start() }
        if #available(macOS 15, *) {
            navigation.toolbar(removing: .title)
        } else {
            navigation
        }
    }

    @ViewBuilder
    private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .overview: HostOverviewSettingsView(controller: controller)
        case .history: HistorySettingsView(controller: controller)
        case .manual: ManualControlSettingsView(controller: controller)
        case .device: DeviceSettingsView(controller: controller)
        case .rules: RuleSettingsView(controller: controller)
        case .account: AccountSettingsView(controller: controller)
        case .runtime: RuntimeSettingsView(controller: controller)
        }
    }
}

/// Settings scenes can retain an expanded AppKit toolbar despite the SwiftUI scene style.
private struct CompactSettingsToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarAnchor { ToolbarAnchor() }
    func updateNSView(_ view: ToolbarAnchor, context: Context) { view.configureWindow() }

    final class ToolbarAnchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.toolbar?.displayMode = .iconOnly
        }
    }
}

private struct DeviceSettingsView: View {
    let controller: WorkerController
    @State private var eventsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CompactControlBar(controller: controller)
                ManualControlButton(controller: controller)
                Button("规则…") { controller.requestedSettingsPage = .rules }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DeviceHero(controller: controller)
                    if let status = controller.status {
                        HStack {
                            Label(phaseTitle(status.phase), systemImage: "arrow.triangle.branch")
                            Spacer()
                            Text(status.owner ? "本应用已接管" : "未接管").foregroundStyle(status.owner ? Color.blue : Color.secondary)
                            Text("采样 \(timestampText(status.temperature.timestamp))").foregroundStyle(.secondary)
                        }.font(.callout)
                        Text(status.reason).font(.callout).foregroundStyle(.secondary)
                        if !status.dwell.isEmpty { DwellStrip(dwell: status.dwell) }
                        ContentSection(title: "已保存的温度 → 风量规则", subtitle: "CPU 平均温度；达到持续时间才执行，不是瞬时调速") {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                GridRow {
                                    Text("升温 ≥ \(status.config.mediumThreshold.formatted()) °C")
                                    Text("持续 \(status.config.riseSeconds.formatted()) 秒")
                                    Text("→ 中档 \(status.config.mediumLevel.map(String.init) ?? "未设置")").fontWeight(.medium)
                                }
                                GridRow {
                                    Text("升温 ≥ \(status.config.highThreshold.formatted()) °C")
                                    Text("持续 \(status.config.riseSeconds.formatted()) 秒")
                                    Text("→ 高档 \(status.config.highLevel.map(String.init) ?? "未设置")").fontWeight(.medium)
                                }
                                GridRow {
                                    Text("降温 ≤ \(status.config.downThreshold.formatted()) °C")
                                    Text("持续 \(status.config.fallSeconds.formatted()) 秒")
                                    Text("→ 降回中档")
                                }
                                GridRow {
                                    Text("降温 ≤ \(status.config.exitThreshold.formatted()) °C")
                                    Text("持续 \(status.config.fallSeconds.formatted()) 秒")
                                    Text("→ 恢复原状态")
                                }
                            }.font(.callout).monospacedDigit()
                        }
                        DisclosureGroup("最近事件（\(status.eventLog.count)）", isExpanded: $eventsExpanded) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(status.eventLog.suffix(8).enumerated()), id: \.offset) { _, event in
                                    Text(event).font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    } else {
                        Text("等待后台状态").foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: 920, alignment: .leading)
            }
        }
        .navigationTitle("联动设备")
    }
}

private struct DeviceHero: View {
    let controller: WorkerController

    var body: some View {
        HStack(spacing: 16) {
            ProductImage(urlString: controller.status?.device.imageURL, size: 72, presentation: .hero)
                .frame(width: 84, height: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text(deviceName).font(.title2.weight(.semibold)).lineLimit(1)
                OwnershipBadge(status: controller.status)
                Text(deviceMode).font(.callout)
                HStack(spacing: 12) {
                    Label(powerText, systemImage: "power")
                    Label(controller.status?.device.reachable == true ? "在线" : "离线", systemImage: "wifi")
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text("净化器实际 RPM").font(.caption).foregroundStyle(.secondary)
                Text(controller.status?.device.reachable == true ? controller.status?.device.rpm.map(String.init) ?? "—" : "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("CPU \(temperature(controller.status?.temperature.stale == false ? controller.status?.temperature.cpu : nil))")
                    .font(.callout).monospacedDigit()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var deviceName: String {
        guard let device = controller.status?.device else { return "未连接净化器" }
        return device.productTitle
    }
    private var powerText: String {
        controller.status?.device.power == true ? "已开机" : (controller.status?.device.power == false ? "已关机" : "电源未知")
    }
    private var deviceMode: String {
        guard let device = controller.status?.device, device.reachable else { return "设备状态不可用" }
        switch device.mode {
        case "favorite": return device.level.map { "最爱等级 \($0) · RPM 仅为实时读数" } ?? "最爱模式"
        case "auto": return "设备自动模式 · 未固定转速"
        case "silent": return "睡眠模式"
        case let mode?: return mode
        default: return "模式未知"
        }
    }
}

struct CompactControlBar: View {
    let controller: WorkerController
    var prominent = false

    var body: some View {
        HStack(spacing: 10) {
            Button { primaryAction() } label: {
                Text(primaryTitle)
                    .frame(minWidth: prominent ? 170 : nil, minHeight: prominent ? 28 : nil)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(prominent ? .large : .regular)
                .font(prominent ? .headline : .body)
                .help("自动监控按已保存规则调节净化器；暂停后仍保留本机只读采样。")
                .disabled(!canUsePrimary)
                .keyboardShortcut(.return, modifiers: [])

            Button("仅演练") { controller.setDryRun() }
                .disabled(!controller.isActionable || controller.pendingOperation != nil || controller.status?.mode == "manual")
                .help(controller.status?.mode == "manual" ? "请先结束净化器手动控制" : "只计算规则，不向净化器写入命令")

            if !prominent { Spacer(minLength: 8) }

            if controller.pendingOperation != nil {
                ProgressView().controlSize(.small).accessibilityLabel("操作处理中")
            }

            Button("停止") { controller.stop() }
                .disabled(!controller.canStop || controller.status?.mode == "manual")
                .keyboardShortcut(".", modifiers: .command)
                .help(controller.status?.mode == "manual" ? "请在高级手动控制中恢复原状态" : "繁忙或状态未知时仍可请求安全停止")
        }
        .padding(.horizontal, prominent ? 10 : 14)
        .padding(.vertical, prominent ? 6 : 10)
        .adaptiveGlass(cornerRadius: 14, interactive: true)
    }

    private var primaryTitle: String {
        if let pending = controller.pendingOperation {
            switch pending {
            case "enable": return "正在启用…"
            case "pause": return "正在暂停…"
            default: return "正在处理…"
            }
        }
        switch controller.status?.mode {
        case "enabled": return prominent ? "暂停自动监控" : (controller.status?.owner == true ? "暂停接管" : "暂停监测")
        case "manual": return "净化器手动控制中"
        case "paused": return prominent ? "恢复自动监控" : "恢复联动"
        default: return prominent ? "开启自动监控" : "启用联动"
        }
    }

    private var canUsePrimary: Bool {
        guard controller.pendingOperation == nil, controller.isActionable else { return false }
        if controller.status?.mode == "manual" { return false }
        if controller.status?.mode == "enabled" { return true }
        return controller.status?.canEnable ?? false
    }

    private func primaryAction() {
        guard controller.status?.mode != "manual" else { return }
        if controller.status?.mode == "enabled" { controller.pause() }
        else { controller.enable() }
    }
}

private struct DwellStrip: View {
    let dwell: [DwellStatus]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(dwell, id: \.name) { condition in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(dwellTitle(condition.name)).font(.caption).fontWeight(.medium)
                        Spacer(minLength: 10)
                        Text("\(Int(condition.elapsed.rounded(.down))) / \(Int(condition.required.rounded())) 秒")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    ProgressView(value: min(condition.elapsed, condition.required), total: max(condition.required, 1))
                        .accessibilityLabel(dwellTitle(condition.name))
                        .accessibilityValue("已真实观测 \(Int(condition.elapsed.rounded(.down))) 秒，共需 \(Int(condition.required.rounded())) 秒")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct MetricSample: Identifiable {
    let name: String
    let series: String
    let timestamp: Double
    let value: Double
    var id: String { "\(series)-\(timestamp)" }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
}

private struct AccountSettingsView: View {
    let controller: WorkerController
    @State private var region = "cn"
    @State private var showLogoutConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeader("米家与设备", detail: "授权、选择设备，并核对真实在线状态。")

                if let device = controller.status?.device, controller.status?.account.paired == true {
                    DeviceCard(device: device, modeTitle: controller.modeTitle)
                }

                ContentSection(title: "米家账号") {
                    if let account = controller.status?.account, account.paired {
                        LabeledContent("当前账号", value: account.label.isEmpty ? "已授权" : account.label)
                        LabeledContent("地区", value: regionName(account.region))
                        HStack {
                            Button("重新选择设备") { controller.beginPairing(region: account.region) }
                                .disabled(!controller.isActionable || controller.pendingOperation != nil)
                            Button("退出并切换账号…", role: .destructive) { showLogoutConfirmation = true }
                                .disabled(!controller.isActionable || controller.pendingOperation != nil)
                            Spacer()
                        }
                    } else {
                        Picker("米家地区", selection: $region) {
                            Text("中国大陆").tag("cn")
                            Text("欧洲").tag("de")
                            Text("美国").tag("us")
                            Text("新加坡").tag("sg")
                            Text("印度").tag("in")
                            Text("俄罗斯").tag("ru")
                        }
                        .frame(maxWidth: 300)
                        Button("扫码登录米家") { controller.beginPairing(region: region) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!controller.isActionable || pairingInProgress || controller.pendingOperation != nil)
                    }
                }

                pairingContent

                if let error = controller.errorMessage {
                    ErrorNotice(message: error, dismiss: controller.clearError)
                    Button("重试") { controller.beginPairing(region: region) }
                        .disabled(!controller.isActionable || controller.pendingOperation != nil)
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("米家与设备")
        .task {
            if let existing = controller.status?.account.region, !existing.isEmpty { region = existing }
        }
        .alert("退出当前米家授权？", isPresented: $showLogoutConfirmation) {
            Button("仅移除本机授权", role: .destructive) { controller.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会移除这台 Mac 上保存的米家授权与设备凭据，不会从米家云解绑或删除设备。若后台无法安全恢复净化器状态，退出会被拒绝，现有设备资料也不会被遗忘。")
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        let account = controller.status?.account
        switch account?.phase {
        case "requesting", "loadingDevices", "connecting":
            ContentSection(title: pairingTitle) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(account?.message ?? "请稍候…").foregroundStyle(.secondary)
                }
                Button("取消") { controller.cancelPairing() }
            }
        case "waitingForScan":
            ContentSection(title: "使用米家扫码") {
                HStack(alignment: .top, spacing: 24) {
                    Group {
                        if let path = account?.qrImagePath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        } else {
                            Image(systemName: "qrcode").font(.system(size: 80)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 210, height: 210)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("米家登录二维码")

                    VStack(alignment: .leading, spacing: 12) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(expiryText(at: context.date)).font(.headline).monospacedDigit()
                        }
                        Text(account?.message ?? "请用米家 App 扫码并在手机上确认。")
                            .foregroundStyle(.secondary)
                        Button("取消扫码") { controller.cancelPairing() }
                    }
                }
            }
        case "choosingDevice":
            ContentSection(title: "选择一台净化器") {
                ForEach(account?.devices ?? []) { device in
                    PairingDeviceRow(device: device) { controller.selectDevice(deviceId: device.id) }
                    Divider()
                }
            }
        case "error":
            ContentSection(title: "登录未完成") {
                Label(account?.message ?? "发生错误。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("重试") { controller.beginPairing(region: region) }.buttonStyle(.borderedProminent)
                    Button("取消") { controller.cancelPairing() }
                }
            }
        default:
            EmptyView()
        }
    }

    private var pairingInProgress: Bool {
        ["requesting", "waitingForScan", "loadingDevices", "choosingDevice", "connecting"].contains(controller.status?.account.phase ?? "")
    }

    private var pairingTitle: String {
        controller.status?.account.phase == "connecting" ? "正在连接设备" : "正在读取米家账号"
    }

    private func expiryText(at date: Date) -> String {
        guard let expiry = controller.status?.account.expiresAt else { return "二维码会自动过期" }
        let remaining = max(0, Int(expiry - date.timeIntervalSince1970))
        return remaining > 0 ? "二维码将在 \(remaining) 秒后过期" : "二维码已过期，请重试"
    }

    private func regionName(_ code: String) -> String {
        ["cn": "中国大陆", "de": "欧洲", "us": "美国", "sg": "新加坡", "in": "印度", "ru": "俄罗斯"][code] ?? code
    }
}

private struct PairingDeviceRow: View {
    let device: PairingDevice
    let select: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ProductImage(urlString: device.imageURL, size: 70, presentation: .thumbnail)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name.isEmpty ? device.model : device.name).font(.headline)
                Text("\(device.model) · \(device.ip)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(device.reason).font(.caption).foregroundStyle(device.supported ? Color.secondary : Color.orange)
            }
            Spacer()
            Button("选择") { select() }.disabled(!device.supported)
                .accessibilityLabel("选择 \(device.name.isEmpty ? device.model : device.name)")
        }
        .padding(.vertical, 6)
    }
}

private struct RuntimeSettingsView: View {
    let controller: WorkerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader("运行与通知", detail: "管理菜单栏显示、后台启动与持续状态提醒。")
                ContentSection(title: "菜单栏显示") {
                    MenuBarAppearancePicker()
                    Text("Mac：绿色正常、橙色警告、红色严重；净化器：蓝色介入、灰色待命、橙色异常。颜色同时配合图标和状态文字。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ContentSection(title: "后台运行") {
                    LabeledContent("连接", value: controller.connected ? "已连接" : "未连接")
                    Toggle("登录后自动启动本应用", isOn: Binding(get: { controller.loginEnabled }, set: { controller.setLoginEnabled($0) }))
                        .help("只注册或移除本应用自身的登录项")
                    if let message = controller.loginMessage { Text(message).font(.caption).foregroundStyle(.red) }
                }

                ContentSection(title: "持续状态通知", subtitle: "默认关闭。仅在你主动开启后，针对持续满足条件的状态发送提醒。") {
                    Toggle("允许持续状态提醒", isOn: Binding(get: { controller.notificationsEnabled }, set: { controller.setNotificationsEnabled($0) }))
                        .disabled(controller.notificationBusy)
                    HStack {
                        Label(controller.notificationStatus, systemImage: "bell.badge")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if controller.notificationBusy { ProgressView().controlSize(.small) }
                        Button("发送测试通知") { controller.sendTestNotification() }
                            .disabled(controller.notificationBusy || !controller.notificationsEnabled)
                    }
                    Text("提醒不包含进程参数、文件路径、账号凭据或设备 token；关闭后不会继续发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ContentSection(title: "数据与安全") {
                    LabeledContent("本机来源", value: "macmon 与 macOS 系统指标")
                    LabeledContent("设备控制", value: "本地网络 · miIO 直连")
                    LabeledContent("历史保留", value: "本机 30 天")
                    LabeledContent("设备型号", value: controller.status?.account.paired == true ? controller.status?.device.model ?? "—" : "未配对")
                    Text("凭据只由后台从 macOS 钥匙串读取；界面、历史与日志不会保存或显示 token、授权地址、二维码正文或账号会话。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                ContentSection(title: "安全边界") {
                    Text("应用不会自动开启净化器。停止、退出和试听结束均为条件恢复：发现人工改动时不会覆盖；无法确认安全恢复时会取消退出。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("运行与通知")
        .task { controller.refreshNotificationAuthorization() }
    }
}

struct DeviceCard: View {
    let device: DeviceStatus?
    let modeTitle: String
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 12 : 22) {
            ProductImage(urlString: device?.imageURL, size: compact ? 62 : 112, presentation: compact ? .thumbnail : .hero)
            VStack(alignment: .leading, spacing: 6) {
                Text(deviceName).font(compact ? .headline : .title2).fontWeight(.semibold)
                Text(device?.model.isEmpty == false ? device!.model : "尚未选择设备")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 12) {
                    Label(powerText, systemImage: device?.power == true ? "power.circle.fill" : "power.circle")
                    Label(device?.reachable == true ? "在线" : "离线", systemImage: device?.reachable == true ? "wifi" : "wifi.slash")
                    if let rpm = device?.rpm { Label("\(rpm) RPM", systemImage: "fan").monospacedDigit() }
                }
                .font(.caption)
                Text("\(deviceMode) · \(modeTitle)").font(.callout)
                if let description = device?.supportDescription, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(device?.supported == true ? Color.secondary : Color.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 4 : 8)
        .accessibilityElement(children: .combine)
    }

    private var deviceName: String {
        guard let device else { return "未连接净化器" }
        return device.productTitle
    }

    private var powerText: String {
        device?.power == true ? "已开机" : (device?.power == false ? "已关机" : "电源未知")
    }

    private var deviceMode: String {
        switch device?.mode {
        case "favorite": return device?.level.map { "最爱等级 \($0)" } ?? "最爱模式"
        case "auto": return "自动模式"
        case "silent": return "睡眠模式"
        case "paused": return "已暂停"
        case let value?: return value
        default: return "模式未知"
        }
    }
}

enum ProductImagePresentation { case hero, thumbnail }

struct ProductImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let urlString: String?
    let size: CGFloat
    let presentation: ProductImagePresentation

    var body: some View {
        // Hero slots represent "your purifier": before pairing, show the generic
        // product photo instead of the schematic symbol. Thumbnails keep the
        // symbol so an unknown model never borrows another model's photo.
        let effectiveURL = urlString ?? (presentation == .hero ? ProductPhotoStore.fallbackPurifierURL : nil)
        Group {
            if let effectiveURL, let url = URL(string: effectiveURL) {
                AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.24))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit().transition(.opacity)
                    case .failure:
                        fallback
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .padding(presentation == .hero ? size * 0.03 : 0)
        .background {
            if presentation == .thumbnail {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: presentation == .hero ? 22 : 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: "air.purifier")
            .resizable()
            .scaledToFit()
            .padding(size * 0.22)
            .foregroundStyle(.secondary)
    }
}
private struct OwnershipBadge: View {
    let status: WorkerStatus?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
            .accessibilityLabel(accessibilityTitle)
    }

    private var title: String {
        if status?.owner == true { return "正在接管 · \(phaseTitle(status?.phase))" }
        if status?.mode == "enabled" { return "联动已启用 · 监测中" }
        if status?.mode == "dryRun" { return "仅演练 · 不写设备" }
        if status?.mode == "paused" { return "联动已暂停" }
        return "未接管设备"
    }

    private var accessibilityTitle: String {
        status?.owner == true ? "本应用当前拥有控制权，\(phaseTitle(status?.phase))" : title
    }

    private var symbol: String {
        status?.owner == true ? "fan.fill" : (status?.mode == "enabled" ? "eye.fill" : "pause.circle")
    }

    private var color: Color {
        status?.owner == true ? .green : (status?.mode == "enabled" ? .blue : .secondary)
    }
}

private struct ActionFeedbackView: View {
    let feedback: ActionFeedback
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if feedback.phase == .pending { ProgressView().controlSize(.small) }
                else { Image(systemName: feedback.phase == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") }
            }
            .foregroundStyle(feedback.phase == .failed ? Color.red : feedback.phase == .succeeded ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title).font(.callout.weight(.semibold))
                Text(feedback.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if feedback.phase != .pending {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭操作结果")
            }
        }
        .padding(11)
        .adaptiveGlass(cornerRadius: 12, interactive: false)
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorNotice: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("关闭错误提示")
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ContentSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct MetricView: View {
    let title: String
    let value: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(prominent ? .system(size: 24, weight: .semibold, design: .rounded) : .body)
                .monospacedDigit()
                .contentTransition(prominent ? .numericText() : .identity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NeutralEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
            Text("无法读取本机趋势").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button("重试", action: retry)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }
}

private struct AdaptiveGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(contrast == .increased ? 0.26 : 0.1), lineWidth: 1)
                }
        }
    }
}

private extension View {
    func adaptiveGlass(cornerRadius: CGFloat, interactive: Bool) -> some View {
        modifier(AdaptiveGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}

@ViewBuilder
func pageHeader(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.title2.weight(.semibold))
        Text(detail).font(.callout).foregroundStyle(.secondary)
    }
}

private func phaseTitle(_ phase: String?) -> String {
    switch phase {
    case "manual": "手动净化器"
    case "medium": "中档接管"
    case "high": "高档接管"
    default: "等待条件"
    }
}

private func dwellTitle(_ name: String) -> String {
    switch name {
    case "high": "升至高档"
    case "medium": "进入中档"
    case "down": "降回中档"
    case "exit": "退出接管"
    default: name
    }
}
func temperature(_ value: Double?) -> String {
    value.map { String(format: "%.1f °C", $0) } ?? "—"
}

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "—"
}

func bytesText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .memory)
}

func memorySummary(_ memory: MemoryMetrics?) -> String {
    guard let memory, memory.totalBytes > 0 else { return "—" }
    return "\(percent(memory.usedBytes / memory.totalBytes * 100)) · \(bytesText(memory.usedBytes))"
}


func swapUsage(_ memory: MemoryMetrics?) -> String {
    guard let memory else { return "—" }
    return "\(bytesText(memory.swapUsedBytes)) / \(bytesText(memory.swapTotalBytes))"
}

func timestampText(_ timestamp: Double?) -> String {
    guard let timestamp else { return "—" }
    return Date(timeIntervalSince1970: timestamp).formatted(date: .omitted, time: .standard)
}

func pressureTitle(_ pressure: String?) -> String {
    switch pressure {
    case "normal": "正常"
    case "warning": "警告"
    case "critical": "严重"
    default: "未知"
    }
}

func thermalTitle(_ state: String?) -> String {
    switch state {
    case "nominal": "正常"
    case "fair": "偏热"
    case "serious": "较高"
    case "critical": "严重"
    default: "未知"
    }
}

