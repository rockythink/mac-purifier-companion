import AppKit
import Charts
import SwiftUI

enum MenuBarAppearance: String, CaseIterable, Identifiable {
    case singleIcon
    case dualIcon
    case iconsAndTemperature
    case iconsAndPurifierRPM

    static let storageKey = "menuBarAppearanceV2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleIcon: "单图标"
        case .dualIcon: "双图标"
        case .iconsAndTemperature: "图标与温度"
        case .iconsAndPurifierRPM: "图标与净化器转速"
        }
    }
}

struct MenuBarAppearancePicker: View {
    @AppStorage(MenuBarAppearance.storageKey) private var appearanceRawValue = MenuBarAppearance.iconsAndTemperature.rawValue

    var body: some View {
        Picker("菜单栏显示", selection: $appearanceRawValue) {
            ForEach(MenuBarAppearance.allCases) { appearance in
                Text(appearance.title).tag(appearance.rawValue)
            }
        }
        .help("可显示 CPU 温度或净化器实测转速；读数不可用时显示 —。")
    }
}

private struct StatusIndicator {
    let symbol: String
    let color: Color
    let description: String
}

private struct MenuIconKey: Equatable {
    let appearance: MenuBarAppearance
    let hostSymbol: String
    let hostColor: Color
    let purifierSymbol: String
    let purifierColor: Color
    let badge: Bool
    let scheme: ColorScheme
    let scale: CGFloat
}

@MainActor
private final class MenuIconCache {
    private var key: MenuIconKey?
    private var image: NSImage?

    func image(for next: MenuIconKey, render: () -> NSImage) -> NSImage {
        if key == next, let image { return image }
        let rendered = render()
        image = rendered
        key = next
        return rendered
    }
}

struct MenuBarStatusLabel: View {
    @Environment(\.openSettings) private var openSettings
    @State private var didOpenRequestedSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var iconCache = MenuIconCache()
    @AppStorage(MenuBarAppearance.storageKey) private var appearanceRawValue = MenuBarAppearance.iconsAndTemperature.rawValue
    let controller: WorkerController

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: combinedIcon).renderingMode(.original)

            if let readoutText {
                Text(readoutText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
        .task {
            guard !didOpenRequestedSettings, CommandLine.arguments.contains("--show-settings") else { return }
            didOpenRequestedSettings = true
            openSettingsWindow(page: controller.requestedSettingsPage)
        }
    }

    private var combinedIcon: NSImage {
        let host = hostIndicator
        let purifier = purifierIndicator
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = MenuIconKey(appearance: appearance, hostSymbol: host.symbol, hostColor: host.color,
                              purifierSymbol: purifier.symbol, purifierColor: purifier.color,
                              badge: purifierNeedsBadge, scheme: colorScheme, scale: scale)
        return iconCache.image(for: key) {
            // MenuBarExtra extracts a single image from its label. Rasterize the
            // icon group together so both indicators survive that extraction.
            let renderer = ImageRenderer(content: HStack(spacing: 5) {
                hostImage
                if appearance != .singleIcon { statusImage(purifier) }
            }
            .font(.system(size: 14))
            .padding(3)
            .environment(\.colorScheme, colorScheme))
            renderer.scale = scale
            let image = renderer.nsImage ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "图标渲染不可用")!
            image.isTemplate = false
            return image
        }
    }

    private var hostImage: some View {
        statusImage(hostIndicator)
            .overlay(alignment: .bottomTrailing) {
                if appearance == .singleIcon, purifierNeedsBadge {
                    Image(systemName: purifierIndicator.symbol)
                        .renderingMode(.original)
                        .font(.system(size: 7, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(purifierIndicator.color)
                        .padding(1)
                        .background(.background, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
    }

    private func statusImage(_ indicator: StatusIndicator) -> some View {
        Image(systemName: indicator.symbol)
            .renderingMode(.original)
            .symbolRenderingMode(.palette)
            .foregroundStyle(indicator.color)
            .help(indicator.description)
    }

    private var appearance: MenuBarAppearance {
        MenuBarAppearance(rawValue: appearanceRawValue) ?? .iconsAndTemperature
    }

    private var purifierNeedsBadge: Bool {
        guard controller.connected, let status = controller.status, status.account.paired else { return false }
        if !status.device.reachable || !status.device.supported || status.commandState == "failed" { return true }
        return status.device.power != false && status.owner && status.mode != "dryRun"
    }

    private var hostIndicator: StatusIndicator {
        guard controller.connected, let status = controller.status else {
            return StatusIndicator(symbol: "macbook", color: .secondary, description: controller.launching ? "Mac：正在连接后台" : "Mac：后台未连接")
        }
        guard !status.system.stale, !status.temperature.stale else {
            return StatusIndicator(symbol: "exclamationmark.triangle.fill", color: .orange, description: "Mac：监测指标已过期")
        }
        let thermal = status.system.thermalState?.lowercased()
        let pressure = status.system.memoryPressure?.lowercased()
        if thermal == "critical" || pressure == "critical" {
            return StatusIndicator(symbol: thermal == "critical" ? "thermometer.high" : "memorychip.fill", color: .red, description: "Mac：\(thermalTitle(status.system.thermalState))，内存压力\(pressureTitle(status.system.memoryPressure))")
        }
        if thermal == "serious" || pressure == "warning" || pressure == "warn" {
            return StatusIndicator(symbol: thermal == "serious" ? "thermometer.high" : "memorychip.fill", color: .orange, description: "Mac：\(thermalTitle(status.system.thermalState))，内存压力\(pressureTitle(status.system.memoryPressure))")
        }
        if thermal == "fair" {
            return StatusIndicator(symbol: "thermometer.medium", color: .yellow, description: "Mac：热状态偏高，内存压力\(pressureTitle(status.system.memoryPressure))")
        }
        if thermal == "nominal", pressure == "normal" {
            return StatusIndicator(symbol: "macbook", color: .green, description: "Mac：热状态正常，内存压力正常")
        }
        return StatusIndicator(symbol: "macbook", color: .secondary, description: "Mac：热状态\(thermalTitle(status.system.thermalState))，内存压力\(pressureTitle(status.system.memoryPressure))")
    }

    private var purifierIndicator: StatusIndicator {
        guard controller.connected, let status = controller.status else {
            return StatusIndicator(symbol: "air.purifier", color: .secondary, description: "净化器：等待后台连接")
        }
        guard status.account.paired else {
            return StatusIndicator(symbol: "air.purifier", color: .secondary, description: "净化器：未配对")
        }
        guard status.device.reachable else {
            return StatusIndicator(symbol: "exclamationmark.triangle.fill", color: .orange, description: "净化器：离线")
        }
        if !status.device.supported || status.commandState == "failed" {
            return StatusIndicator(symbol: "exclamationmark.triangle.fill", color: .orange, description: !status.device.supported ? "净化器：设备不受支持" : "净化器：最近操作失败")
        }
        guard status.device.power == true else {
            return StatusIndicator(symbol: "air.purifier", color: status.device.power == false ? .secondary : .orange,
                                   description: status.device.power == false ? "净化器：已关闭" : "净化器：电源状态未知")
        }
        if status.owner, status.mode != "dryRun" {
            return StatusIndicator(symbol: "air.purifier.fill", color: .blue, description: "净化器：本应用正在接管")
        }
        return StatusIndicator(symbol: "air.purifier", color: .secondary, description: status.mode == "dryRun" ? "净化器：仅演练，未写设备" : "净化器：等待规则介入")
    }

    private var readoutText: String? {
        switch appearance {
        case .iconsAndTemperature: temperatureText
        case .iconsAndPurifierRPM: purifierRPMText
        case .singleIcon, .dualIcon: nil
        }
    }

    private var purifierRPMText: String {
        guard controller.connected, let status = controller.status, status.account.paired,
              status.device.reachable, status.device.power == true,
              !status.temperature.stale, let rpm = status.device.rpm else { return "—" }
        return "\(rpm) RPM"
    }

    private var temperatureText: String {
        guard controller.connected, let temperature = controller.status?.temperature,
              !temperature.stale, let cpu = temperature.cpu else { return "—" }
        return "\(Int(cpu.rounded()))°"
    }

    private var accessibilityText: String {
        "\(hostIndicator.description)；\(purifierIndicator.description)；CPU 温度 \(temperatureText)；净化器转速 \(purifierRPMText)"
    }

    private func openSettingsWindow(page: SettingsPage) {
        controller.requestedSettingsPage = page
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuPopoverView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var showingErrorDetails = false
    @State private var detailedErrorMessage = ""
    @State private var macIdentity = MacDeviceIdentity.shared
    @State private var menuVisible = false
    let controller: WorkerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigationHeader
            Divider()
            overview
            Divider()
            MenuRecentCharts(
                history: controller.connected ? controller.menuHistory : nil,
                loading: controller.connected && controller.menuHistoryLoading,
                paired: controller.connected && controller.status?.account.paired == true,
                connected: controller.connected
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider()
            processSection
            if let message = controller.errorMessage, !message.isEmpty {
                Divider()
                errorRow(message)
            }
            Divider()
            footer
        }
        .frame(width: 600, alignment: .top)
        .background(MenuWindowVisibility(isVisible: $menuVisible))
        .alert("操作失败", isPresented: $showingErrorDetails) {
            Button("关闭", role: .cancel) {}
        } message: {
            Text(detailedErrorMessage)
        }
        .task {
            await macIdentity.load()
        }
        .task(id: menuVisible) {
            guard menuVisible else { return }
            controller.start()
            while !Task.isCancelled {
                controller.requestProcesses()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .task(id: menuVisible) {
            guard menuVisible else { return }
            while !Task.isCancelled {
                controller.requestMenuHistory()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }

    /// MenuBarExtra retains its content after closing, so task lifetime alone is not visibility.
    private struct MenuWindowVisibility: NSViewRepresentable {
        @Binding var isVisible: Bool

        func makeNSView(context: Context) -> VisibilityAnchor {
            let view = VisibilityAnchor()
            view.onVisibilityChange = { isVisible = $0 }
            return view
        }

        func updateNSView(_ view: VisibilityAnchor, context: Context) {
            view.onVisibilityChange = { isVisible = $0 }
        }

        static func dismantleNSView(_ view: VisibilityAnchor, coordinator: ()) {
            view.stopObserving()
        }

        final class VisibilityAnchor: NSView {
            var onVisibilityChange: ((Bool) -> Void)?
            private var pendingUpdate: Task<Void, Never>?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self)
                if let window {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(visibilityChanged(_:)),
                        name: NSWindow.didChangeOcclusionStateNotification, object: window
                    )
                }
                visibilityChanged()
            }

            @objc private func visibilityChanged(_ notification: Notification? = nil) {
                pendingUpdate?.cancel()
                // Defer attachment notifications out of SwiftUI layout; read the latest window state.
                pendingUpdate = Task { @MainActor [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    let visible = self.window?.isVisible == true
                        && self.window?.occlusionState.contains(.visible) == true
                    self.onVisibilityChange?(visible)
                    self.pendingUpdate = nil
                }
            }

            func stopObserving() {
                NotificationCenter.default.removeObserver(self)
                pendingUpdate?.cancel()
                pendingUpdate = nil
                onVisibilityChange = nil
            }
        }
    }

    private var navigationHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac 净化器伴侣").font(.system(size: 15, weight: .semibold))
                Text("\(hostStateTitle) · \(deviceSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { controller.connected ? controller.refresh() : controller.start() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(controller.launching || (controller.connected && !controller.isActionable))
            .help(controller.connected ? "刷新状态" : "重新连接后台")
            Button("规则…") { openSettings(page: .rules) }.buttonStyle(.borderless)
            Button("历史…") { openSettings(page: .history) }.buttonStyle(.borderless)
            Button("设置…") { openSettings(page: .overview) }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                deviceIdentity
                    .frame(width: 198, alignment: .leading)
                primaryReadings
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                CompactControlBar(controller: controller, prominent: true)
                Spacer(minLength: 0)
                ManualControlButton(controller: controller)
            }

            secondaryReadings
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var deviceIdentity: some View {
        HStack(alignment: .top, spacing: 10) {
            DeviceStackArtwork(mac: macIdentity, purifierModel: pairedDevice?.model,
                               imageURL: pairedDevice?.imageURL, height: 134)
            VStack(alignment: .leading, spacing: 4) {
                Text(macIdentity.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                Text(macIdentity.identifier + " · " + macIdentity.chip)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(purifierName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(purifierModel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(purifierAvailability)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: 134, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var primaryReadings: some View {
        if let status = freshStatus {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    popupMetric("CPU 温度", temperature(status.temperature.stale ? nil : status.temperature.cpu), prominent: true)
                    popupMetric("GPU 温度", temperature(status.temperature.stale ? nil : status.temperature.gpu), prominent: true)
                }
                GridRow {
                    popupMetric("CPU 活跃", percent(status.temperature.stale ? nil : status.temperature.cpuLoad), prominent: true)
                    popupMetric("GPU 活跃", percent(status.system.stale ? nil : status.system.gpuLoad), prominent: true)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(hostUnavailableText).lineLimit(2)
                    Button("查看详情…") { openSettings(page: .overview) }.buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 134, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var secondaryReadings: some View {
        if let status = freshStatus {
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow {
                    popupMetric("内存", memorySummary(status.system.stale ? nil : status.system.memory))
                    popupMetric("Swap", status.system.stale ? "—" : swapUsage(status.system.memory))
                    popupMetric("内存压力", status.system.stale ? "—" : pressureTitle(status.system.memoryPressure))
                    popupMetric("热状态", status.system.stale ? "—" : thermalTitle(status.system.thermalState))
                }
            }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU 最高进程").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if controller.connected && controller.processesLoading { ProgressView().controlSize(.mini) }
            }
            if !controller.connected {
                Text("后台未连接，未显示旧进程")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error = controller.processes?.error, !error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("详情…") { openSettings(page: .overview) }.buttonStyle(.borderless)
                }
                .font(.caption)
            } else if let processes = controller.processes?.processes.prefix(3), !processes.isEmpty {
                ForEach(Array(processes)) { process in
                    HStack(spacing: 6) {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Text("PID \(process.pid)").foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f%%", process.cpuPercent)).monospacedDigit()
                    }
                    .font(.system(size: 13))
                }
            } else {
                Text(controller.processesLoading ? "正在读取进程…" : "暂无进程采样")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 8)
            Button("详情…") {
                detailedErrorMessage = message
                showingErrorDetails = true
            }
            .buttonStyle(.borderless)
            Button { controller.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("关闭错误提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 42)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            MenuBarAppearancePicker().labelsHidden().frame(width: 168)
            if controller.connected && controller.status?.account.paired == true {
                Button("设备…") { openSettings(page: .device) }.buttonStyle(.borderless)
            } else {
                Button("连接设备…") { openSettings(page: .account) }.buttonStyle(.borderless)
            }
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var freshStatus: WorkerStatus? {
        guard controller.connected, let status = controller.status,
              !status.system.stale || !status.temperature.stale else { return nil }
        return status
    }

    private var hostStateTitle: String {
        guard controller.connected else { return controller.launching ? "正在连接后台…" : "后台未连接" }
        if controller.status?.system.stale == false { return "Mac 热状态：\(thermalTitle(controller.status?.system.thermalState))" }
        if controller.status?.temperature.stale == false { return "Mac 温度采样正常" }
        return "Mac 指标已过期"
    }

    private var hostUnavailableText: String {
        controller.connected ? "本机指标暂不可用或已过期" : "后台未连接，未显示旧读数"
    }

    private var pairedDevice: DeviceStatus? {
        guard controller.connected, let status = controller.status, status.account.paired else { return nil }
        return status.device
    }

    private var purifierName: String {
        guard let device = pairedDevice else { return "未配对净化器" }
        return device.productTitle
    }

    private var purifierModel: String {
        guard let device = pairedDevice else { return "前往设置连接设备" }
        return device.model.isEmpty ? "型号未知" : device.model
    }

    private var purifierAvailability: String {
        guard controller.connected else { return "后台未连接" }
        guard let device = pairedDevice else { return "未连接设备" }
        return device.reachable ? "设备在线" : "设备离线"
    }
    private var deviceSummary: String {
        guard controller.connected, let status = controller.status else { return "净化器等待连接" }
        guard status.account.paired else { return "净化器未配对" }
        guard status.device.reachable else { return "净化器离线" }
        if status.mode == "manual" { return "净化器手动控制中" }
        if status.owner, status.mode != "dryRun" { return "净化器正在接管" }
        return controller.modeTitle
    }

    private func openSettings(page: SettingsPage) {
        controller.requestedSettingsPage = page
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func popupMetric(_ title: String, _ value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: prominent ? 23 : 16, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuRecentCharts: View {
    let history: HistorySnapshot?
    let loading: Bool
    let paired: Bool
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近 1 小时").font(.system(size: 12, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
            if connected, let history, !history.points.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 6) {
                    spark(title: "CPU / GPU 温度", latest: latestTemperatures(history.points), unit: "°C", samples: samples(history.points, name: "CPU", keyPath: \.cpu) + samples(history.points, name: "GPU", keyPath: \.gpu), colors: ["CPU": .orange, "GPU": .purple])
                    spark(title: "CPU / GPU 活跃度", latest: latestActivity(history.points), unit: "%", samples: samples(history.points, name: "CPU", keyPath: \.cpuLoad) + samples(history.points, name: "GPU", keyPath: \.gpuLoad), colors: ["CPU": .blue, "GPU": .indigo], domain: 0...100)
                    spark(title: "内存 / Swap", latest: latestMemory(history.points), unit: "GB", samples: samples(history.points, name: "内存", keyPath: \.memoryUsed, divisor: 1_073_741_824) + samples(history.points, name: "Swap", keyPath: \.swapUsed, divisor: 1_073_741_824), colors: ["内存": .teal, "Swap": .mint])
                    spark(title: paired ? "Mac 风扇 / 净化器" : "Mac 风扇", latest: latestFans(history.points), unit: "RPM", samples: fanSamples(history.points), colors: fanColors(history.points))
                }
            } else {
                ContentUnavailableView(
                    connected ? (loading ? "正在读取趋势" : "暂无趋势样本") : "后台未连接",
                    systemImage: connected ? "chart.xyaxis.line" : "bolt.horizontal.circle"
                )
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 188, alignment: .top)
    }

    private func spark(title: String, latest: String, unit: String, samples: [MetricSample], colors: [String: Color], domain: ClosedRange<Double>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(latest).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Chart(samples) { sample in
                LineMark(
                    x: .value("时间", sample.date),
                    y: .value(unit, sample.value),
                    series: .value("连续区段", sample.series)
                )
                .foregroundStyle(by: .value("指标", sample.name))
                .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
            .chartForegroundStyleScale(domain: colors.keys.sorted(), range: colors.keys.sorted().compactMap { colors[$0] })
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: domain ?? automaticDomain(samples))
            .frame(height: 30)
            .accessibilityLabel("\(title)，最近一小时，最新值 \(latest)")
        }
        .padding(6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private func samples(_ points: [HistoryPoint], name: String, keyPath: KeyPath<HistoryPoint, Double?>, divisor: Double = 1) -> [MetricSample] {
        var output: [MetricSample] = []
        var gap = 0
        var previousSegment: String?
        for point in points {
            if point.segment != previousSegment { previousSegment = point.segment; gap += 1 }
            guard let value = point[keyPath: keyPath] else { gap += 1; continue }
            output.append(MetricSample(name: name, series: "\(name)-\(point.segment)-\(gap)", timestamp: point.timestamp, value: value / divisor))
        }
        return output
    }

    private func fanSamples(_ points: [HistoryPoint]) -> [MetricSample] {
        let names = Set(points.flatMap { $0.macFans.map(\.name) })
        var output = names.sorted().flatMap { name -> [MetricSample] in
            var gap = 0
            var segment: String?
            return points.compactMap { point in
                if point.segment != segment { segment = point.segment; gap += 1 }
                guard let fan = point.macFans.first(where: { $0.name == name }) else { gap += 1; return nil }
                return MetricSample(name: name, series: "\(name)-\(point.segment)-\(gap)", timestamp: point.timestamp, value: fan.rpm)
            }
        }
        if paired { output += samples(points, name: "净化器", keyPath: \.rpm) }
        return output
    }

    private func fanColors(_ points: [HistoryPoint]) -> [String: Color] {
        var colors: [String: Color] = [:]
        for (index, name) in Set(points.flatMap { $0.macFans.map(\.name) }).sorted().enumerated() {
            colors[name] = index.isMultiple(of: 2) ? .green : .cyan
        }
        if paired { colors["净化器"] = .orange }
        return colors
    }

    private func automaticDomain(_ samples: [MetricSample]) -> ClosedRange<Double> {
        guard let low = samples.map(\.value).min(), let high = samples.map(\.value).max() else { return 0...1 }
        let padding = max((high - low) * 0.12, max(abs(high), 1) * 0.02)
        return max(0, low - padding)...max(high + padding, low + 1)
    }

    private func latestTemperatures(_ points: [HistoryPoint]) -> String {
        "CPU \(temperature(points.lazy.compactMap(\.cpu).last)) · GPU \(temperature(points.lazy.compactMap(\.gpu).last))"
    }

    private func latestActivity(_ points: [HistoryPoint]) -> String {
        "CPU \(percent(points.lazy.compactMap(\.cpuLoad).last)) · GPU \(percent(points.lazy.compactMap(\.gpuLoad).last))"
    }

    private func latestMemory(_ points: [HistoryPoint]) -> String {
        "内存 \(bytesText(points.lazy.compactMap(\.memoryUsed).last)) · Swap \(bytesText(points.lazy.compactMap(\.swapUsed).last))"
    }

    private func latestFans(_ points: [HistoryPoint]) -> String {
        let mac = points.lazy.reversed().first(where: { !$0.macFans.isEmpty })?.macFans.first.map { "Mac \(Int($0.rpm.rounded()))" } ?? "Mac —"
        guard paired else { return "\(mac) RPM" }
        let purifier = points.lazy.compactMap(\.rpm).last.map { String(Int($0.rounded())) } ?? "—"
        return "\(mac) · 净化器 \(purifier) RPM"
    }
}
