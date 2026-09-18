import Charts
import SwiftUI

struct HistorySettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let controller: WorkerController
    @State private var selectedRange: HistoryRange = .sixHours
    @State private var showClearConfirmation = false
    @State private var showMacDetails = false
    @State private var showComparison = false
    @State private var showPurifierEvents = false

    private let chartColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = historyError {
                    ErrorState(message: error) { controller.requestHistory(hours: selectedRange.hours) }
                } else if controller.historyLoading, controller.history == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取本机趋势…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if let history = controller.history, !history.points.isEmpty {
                    macSection(history)
                    purifierSection(history)
                } else {
                    NeutralEmptyState(
                        symbol: "chart.xyaxis.line",
                        title: "还没有可绘制的趋势",
                        detail: "后台会把有效样本保存在这台 Mac 上。缺测处会保留断点，不会用相邻读数补齐。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
                historyFootnote
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("趋势")
        .toolbar {
            ToolbarItem {
                Button { controller.requestHistory(hours: selectedRange.hours) } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(controller.historyLoading)
            }
            ToolbarItem {
                Button("清除历史…", role: .destructive) { showClearConfirmation = true }
            }
        }
        .task(id: selectedRange) {
            while !Task.isCancelled {
                controller.requestHistory(hours: selectedRange.hours)
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .alert("清除全部本机趋势？", isPresented: $showClearConfirmation) {
            Button("清除全部历史", role: .destructive) { controller.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机保存的 30 天监测样本，无法撤销。不会更改米家账号、设备凭据、规则或当前控制状态。")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: controller.history?.requestId)
    }

    private var timeDomain: ClosedRange<Date> {
        let end = controller.history?.points.last?.timestamp ?? Date().timeIntervalSince1970
        let hours = controller.history?.hours ?? selectedRange.hours
        return Date(timeIntervalSince1970: end - hours * 3600)...Date(timeIntervalSince1970: end)
    }

    private var timeAxisFormat: Date.FormatStyle {
        selectedRange.hours > 24 ? .dateTime.month(.twoDigits).day(.twoDigits) : .dateTime.hour().minute()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("监测趋势")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("Mac 指标覆盖整台主机；净化器数据严格限定本次查询所选设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("时间范围", selection: $selectedRange) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            .accessibilityLabel("趋势时间范围")
        }
    }

    private func macSection(_ history: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "这台 Mac",
                subtitle: "主机范围 · 所有本机样本，不受净化器配对或选择变化影响",
                symbol: "desktopcomputer",
                color: .blue
            )
            LazyVGrid(columns: chartColumns, alignment: .leading, spacing: 12) {
                temperatureChart(history)
                activityChart(history)
                memoryChart(history)
                macFanChart(history)
            }
            DisclosureGroup(isExpanded: $showMacDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    stateHistory(history)
                    eventHistory(
                        history.events.filter { $0.deviceId == nil },
                        title: "Mac 事件",
                        emptyMessage: "所选范围没有主机事件。"
                    )
                }
                .padding(.top, 8)
            } label: {
                Label("主机状态与事件记录", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func purifierSection(_ history: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "空气净化器",
                subtitle: purifierSubtitle(history.selectedDeviceId),
                symbol: "air.purifier",
                color: .cyan
            )

            if let selectedDeviceId = history.selectedDeviceId, !selectedDeviceId.isEmpty {
                let points = history.points.filter { $0.deviceId == selectedDeviceId }
                let events = history.events.filter { $0.deviceId == selectedDeviceId }
                LazyVGrid(columns: chartColumns, alignment: .leading, spacing: 12) {
                    purifierRPMChart(points, events: events)
                    purifierLevelChart(points, events: events)
                }
                DisclosureGroup("净化器事件记录", isExpanded: $showPurifierEvents) {
                    eventHistory(events, title: "净化器事件", emptyMessage: "所选范围没有这台净化器的事件。")
                        .padding(.top, 8)
                }
                comparisonSection(history.comparison)
            } else {
                NeutralEmptyState(
                    symbol: "air.purifier",
                    title: "未选择净化器",
                    detail: "本次历史查询没有所选设备 ID，因此不会绘制其他历史设备的数据。"
                )
                .frame(maxWidth: .infinity, minHeight: 110)
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(0.65))
                .frame(width: 4, height: 34)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func temperatureChart(_ history: HistorySnapshot) -> some View {
        let samples = metricSamples(history.points, name: "CPU", value: { $0.cpu })
            + metricSamples(history.points, name: "GPU", value: { $0.gpu })
        return compactChart(title: "温度", subtitle: "CPU / GPU · °C") {
            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("时间", sample.date),
                        y: .value("温度", sample.value),
                        series: .value("连续区段", sample.series)
                    )
                    .foregroundStyle(by: .value("传感器", sample.name))
                    .interpolationMethod(.linear)
                }
                ForEach(history.events.filter { $0.deviceId == nil }) { event in
                    RuleMark(x: .value("Mac 事件", Date(timeIntervalSince1970: event.timestamp)))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(["CPU": Color.orange, "GPU": Color.purple])
            .chartLegend(position: .top, alignment: .leading)
            .chartXScale(domain: timeDomain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 100)
            .accessibilityLabel("Mac CPU 与 GPU 温度趋势及主机事件标记")
        }
    }

    private func activityChart(_ history: HistorySnapshot) -> some View {
        let samples = metricSamples(history.points, name: "CPU", value: { $0.cpuLoad })
            + metricSamples(history.points, name: "GPU", value: { $0.gpuLoad })
        return compactChart(title: "活跃度", subtitle: "CPU / GPU · %") {
            Chart(samples) { sample in
                LineMark(
                    x: .value("时间", sample.date),
                    y: .value("活跃度", sample.value),
                    series: .value("连续区段", sample.series)
                )
                .foregroundStyle(by: .value("处理器", sample.name))
                .interpolationMethod(.linear)
            }
            .chartForegroundStyleScale(["CPU": Color.blue, "GPU": Color.indigo])
            .chartYScale(domain: 0...100)
            .chartLegend(position: .top, alignment: .leading)
            .chartXScale(domain: timeDomain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) }
            .frame(height: 100)
            .accessibilityLabel("Mac CPU 与 GPU 活跃度趋势")
        }
    }

    private func memoryChart(_ history: HistorySnapshot) -> some View {
        let samples = metricSamples(history.points, name: "内存", value: { $0.memoryUsed })
            + metricSamples(history.points, name: "Swap", value: { $0.swapUsed })
        return compactChart(title: "内存", subtitle: "已用内存 / Swap") {
            Chart(samples) { sample in
                LineMark(
                    x: .value("时间", sample.date),
                    y: .value("字节", sample.value),
                    series: .value("连续区段", sample.series)
                )
                .foregroundStyle(by: .value("指标", sample.name))
                .interpolationMethod(.linear)
            }
            .chartForegroundStyleScale(["内存": Color.teal, "Swap": Color.mint])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(bytesText(bytes)) }
                    }
                }
            }
            .chartXScale(domain: timeDomain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
            .frame(height: 100)
            .accessibilityLabel("Mac 内存与 Swap 用量趋势")
        }
    }

    private func macFanChart(_ history: HistorySnapshot) -> some View {
        let samples = fanSamples(history.points)
        return compactChart(title: "风扇", subtitle: "Mac 系统只读 RPM") {
            ZStack {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("时间", sample.date),
                        y: .value("转速", sample.value),
                        series: .value("连续区段", sample.series)
                    )
                    .foregroundStyle(by: .value("风扇", sample.name))
                    .interpolationMethod(.linear)
                }
                .chartLegend(position: .top, alignment: .leading)
                .chartXScale(domain: timeDomain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
                .chartYAxis { AxisMarks(position: .leading) }
                if samples.isEmpty {
                    Text("系统未报告风扇读数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 100)
            .accessibilityLabel(samples.isEmpty ? "Mac 没有风扇读数" : "Mac 风扇转速趋势")
        }
    }

    private func purifierRPMChart(_ points: [HistoryPoint], events: [HistoryEvent]) -> some View {
        let samples = metricSamples(points, name: "实际 RPM", value: { $0.rpm })
        return compactChart(title: "实际转速", subtitle: "设备上报 RPM · 不作推算") {
            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("时间", sample.date),
                        y: .value("转速", sample.value),
                        series: .value("连续区段", sample.series)
                    )
                    .foregroundStyle(Color.cyan)
                    .symbol(.circle).symbolSize(6)
                    .interpolationMethod(.stepCenter)
                }
                ForEach(events) { event in
                    RuleMark(x: .value("净化器事件", Date(timeIntervalSince1970: event.timestamp)))
                        .foregroundStyle(Color.cyan.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: timeDomain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 100)
            .overlay {
                if samples.isEmpty { Text("此范围没有有效转速样本").font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityLabel("所选历史净化器实际转速趋势及净化器事件标记")
        }
    }

    private func purifierLevelChart(_ points: [HistoryPoint], events: [HistoryEvent]) -> some View {
        let samples = metricSamples(
            points,
            name: "最爱等级",
            value: { $0.level.map(Double.init) },
            include: { $0.deviceMode == "favorite" }
        )
        return compactChart(title: "最爱等级", subtitle: "仅 favorite 模式显示") {
            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("时间", sample.date),
                        y: .value("等级", sample.value),
                        series: .value("连续区段", sample.series)
                    )
                    .foregroundStyle(Color.cyan)
                    .symbol(.circle).symbolSize(6)
                    .interpolationMethod(.stepCenter)
                }
                ForEach(events) { event in
                    RuleMark(x: .value("净化器事件", Date(timeIntervalSince1970: event.timestamp)))
                        .foregroundStyle(Color.cyan.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: timeDomain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: timeAxisFormat, anchor: .topTrailing) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 100)
            .overlay {
                if samples.isEmpty { Text("此范围没有最爱模式样本").font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityLabel("所选历史净化器最爱模式实际等级趋势")
        }
    }

    private func compactChart<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateHistory(_ history: HistorySnapshot) -> some View {
        ContentSection(title: "系统状态记录", subtitle: "主机内存压力与系统热状态；未知值保持未知。") {
            let rows = Array(history.points.filter { $0.memoryPressure != nil || $0.thermalState != nil }.suffix(8).reversed())
            if rows.isEmpty {
                Text("所选范围没有系统状态样本。").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { point in
                    HStack {
                        Text(Date(timeIntervalSince1970: point.timestamp).formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                        Spacer()
                        Text("内存压力：\(pressureTitle(point.memoryPressure))")
                        Text("热状态：\(thermalTitle(point.thermalState))")
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func eventHistory(_ events: [HistoryEvent], title: String, emptyMessage: String) -> some View {
        ContentSection(title: title, subtitle: "竖线与列表只对应这一设备范围内后台记录的真实时间。") {
            if events.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            } else {
                ForEach(events.suffix(12).reversed()) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Date(timeIntervalSince1970: event.timestamp).formatted(date: .abbreviated, time: .standard))
                            .monospacedDigit()
                        Text(event.kind).font(.caption).foregroundStyle(.secondary)
                        Text(event.label)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func comparisonSection(_ comparison: CoolingComparison?) -> some View {
        DisclosureGroup(isExpanded: $showComparison) {
            VStack(alignment: .leading, spacing: 10) {
                if let comparison {
                    HStack(alignment: .top, spacing: 20) {
                        MetricView(title: "基线 CPU", value: String(format: "%.1f °C", comparison.baselineCPU), prominent: true)
                        MetricView(title: "联动期间 CPU", value: String(format: "%.1f °C", comparison.linkedCPU), prominent: true)
                        MetricView(title: "观察差值", value: deltaText(comparison.deltaCPU), prominent: true)
                    }
                    Divider()
                    Text(comparison.message).font(.callout)
                    Label("这是同期实测差异，不是净化器造成温度变化的结论。负载、环境和系统任务都可能影响结果。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    NeutralEmptyState(
                        symbol: "equal.circle",
                        title: "样本不足，不能作联动前后比较",
                        detail: "需要所选设备在同一连续会话内具备充分的配对、新鲜样本；不会用跨设备或缺测数据补齐。"
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            Label("联动观察", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.medium))
        }
    }

    private var historyFootnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let history = controller.history {
                Label("当前范围 \(history.totalSamples) 个主机样本 · 最长保留 \(history.retentionDays) 天", systemImage: "externaldrive")
                if let since = history.recordingSince {
                    Text("本机最早记录：\(Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .shortened))")
                }
            } else {
                Label("趋势尚未载入", systemImage: "externaldrive")
            }
            Text("Mac 趋势覆盖整台主机；净化器图表、事件与联动观察仅使用本次查询所选设备。历史不会保存账号会话、二维码或设备 token。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var historyError: String? {
        if let error = controller.history?.error, !error.isEmpty { return error }
        if let error = controller.status?.historyError, !error.isEmpty { return error }
        return nil
    }

    private func purifierSubtitle(_ deviceId: String?) -> String {
        guard let deviceId, !deviceId.isEmpty else {
            return "未选择设备 · 不显示其他历史设备数据"
        }
        return "所选历史设备 · ID 尾号 \(deviceId.suffix(6))"
    }

    private func metricSamples(
        _ points: [HistoryPoint],
        name: String,
        value: (HistoryPoint) -> Double?,
        include: (HistoryPoint) -> Bool = { _ in true }
    ) -> [MetricSample] {
        var result: [MetricSample] = []
        var gap = 0
        var previousSegment: String?
        result.reserveCapacity(points.count)
        for point in points {
            if point.segment != previousSegment {
                gap += 1
                previousSegment = point.segment
            }
            guard include(point), let reading = value(point) else {
                gap += 1
                continue
            }
            result.append(MetricSample(
                name: name,
                series: "\(name)-\(point.segment)-\(gap)",
                timestamp: point.timestamp,
                value: reading
            ))
        }
        return result
    }

    private func fanSamples(_ points: [HistoryPoint]) -> [MetricSample] {
        let names = Set(points.flatMap { $0.macFans.map(\.name) })
        return names.sorted().flatMap { name in
            var gap = 0
            var previousSegment: String?
            return points.compactMap { point -> MetricSample? in
                if point.segment != previousSegment {
                    gap += 1
                    previousSegment = point.segment
                }
                guard let fan = point.macFans.first(where: { $0.name == name }) else {
                    gap += 1
                    return nil
                }
                return MetricSample(
                    name: name,
                    series: "\(name)-\(point.segment)-\(gap)",
                    timestamp: point.timestamp,
                    value: fan.rpm
                )
            }
        }
    }

    private func deltaText(_ value: Double) -> String {
        if abs(value) < 0.05 { return "接近不变" }
        return String(format: value > 0 ? "低 %.1f °C" : "高 %.1f °C", abs(value))
    }
}

private enum HistoryRange: Double, CaseIterable, Identifiable {
    case oneHour = 1
    case sixHours = 6
    case oneDay = 24
    case sevenDays = 168
    case thirtyDays = 720

    var id: Double { rawValue }
    var hours: Double { rawValue }

    var title: String {
        switch self {
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .oneDay: "24h"
        case .sevenDays: "7d"
        case .thirtyDays: "30d"
        }
    }
}
