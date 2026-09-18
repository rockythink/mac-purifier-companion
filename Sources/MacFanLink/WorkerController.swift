import AppKit
import Foundation
import Observation
import ServiceManagement


@MainActor
@Observable
final class WorkerController {
    static let shared = WorkerController()

    private(set) var status: WorkerStatus?
    private(set) var connected = false
    private(set) var launching = false
    private(set) var errorMessage: String?
    private(set) var loginEnabled = false
    private(set) var loginMessage: String?
    private(set) var feedback: ActionFeedback?
    private(set) var history: HistorySnapshot?
    private(set) var historyLoading = false
    private(set) var menuHistory: HistorySnapshot?
    private(set) var menuHistoryLoading = false
    private(set) var processes: ProcessSnapshot?
    private(set) var processesLoading = false
    private(set) var notificationsEnabled = false
    private(set) var notificationStatus = "通知默认关闭。启用后，仅在异常持续一段时间时提醒。"
    private(set) var notificationBusy = false
    var requestedSettingsPage: SettingsPage = .overview

    private var process: Process?
    private var input: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var shutdownTimeoutTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var repliedToTermination = false
    private var macTerminationPrepared = false
    private var lastWorkerExitCode: Int32?
    private var feedbackTimeoutTask: Task<Void, Never>?
    private var historyTimeoutTask: Task<Void, Never>?
    private var historyRequestId: String?
    private var historyHours: Double = 24
    private var menuHistoryTimeoutTask: Task<Void, Never>?
    private var menuHistoryRequestId: String?
    private var lastMenuHistoryRequestAt: TimeInterval?
    private var processesTimeoutTask: Task<Void, Never>?
    private var processesRequestId: String?
    private var alertCheckTask: Task<Void, Never>?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        refreshLoginStatus()
        notificationsEnabled = NotificationSupport.shared.enabled
        notificationStatus = NotificationSupport.shared.statusMessage
        alertCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.refreshStalenessAndAlerts()
            }
        }
        refreshNotificationAuthorization()
    }

    var pendingOperation: String? { feedback?.phase == .pending ? feedback?.op : nil }

    var isActionable: Bool {
        connected && !launching && !(status?.busy ?? true) && !shutdownRequested && pendingOperation == nil
    }

    var modeTitle: String {
        guard connected else { return launching ? "正在连接后台…" : "后台未连接" }
        switch status?.mode {
        case "enabled": return "联动已启用"
        case "manual": return "净化器手动控制"
        case "dryRun": return "仅演练 · 不写设备"
        case "paused": return "已暂停"
        case "stopped": return "已停止"
        default: return "正在读取状态"
        }
    }

    var canStop: Bool {
        connected && !launching && !shutdownRequested && status != nil
            && pendingOperation != "stop" && pendingOperation != "shutdown"
            && (pendingOperation != nil || status?.busy == true || status?.mode != "stopped" || status?.commandState == "unknown")
    }

    func start() {
        guard process == nil, !launching else { return }
        launching = true
        errorMessage = nil

        do {
            let launch = try launchConfiguration()
            let process = Process()
            let stdout = Pipe()
            let stdin = Pipe()
            let stderr = Pipe()

            process.executableURL = launch.python
            process.arguments = ["-B", "-E", "-s", launch.worker.path]
            process.currentDirectoryURL = launch.resources
            var environment = ProcessInfo.processInfo.environment
            environment["MACFANLINK_RESOURCE_DIR"] = launch.resources.path
            environment["MACFANLINK_MACMON"] = launch.macmon.path
            process.environment = environment
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] terminatedProcess in
                let exitCode = terminatedProcess.terminationStatus
                Task { @MainActor in self?.workerExited(exitCode: exitCode) }
            }

            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            connected = true
            launching = false
            readOutput(stdout.fileHandleForReading)
            drainSanitizedError(stderr.fileHandleForReading)
            send(WorkerCommand(op: "refresh"), presentFeedback: false)
        } catch {
            launching = false
            connected = false
            errorMessage = launchErrorDescription(error)
        }
    }

    func configure(_ config: LinkConfig) { send(WorkerCommand(op: "configure", config: config)) }
    func setDryRun() { send(WorkerCommand(op: "dryRun")) }
    func enable() { send(WorkerCommand(op: "enable")) }
    func pause() { send(WorkerCommand(op: "pause")) }
    func stop() { send(WorkerCommand(op: "stop")) }
    func refresh() { send(WorkerCommand(op: "refresh")) }
    func setManualPurifier(level: Int) { send(WorkerCommand(op: "manualPurifier", level: level)) }
    func releaseManualPurifier() { send(WorkerCommand(op: "releaseManualPurifier")) }
    func clearHistory() { send(WorkerCommand(op: "clearHistory")) }
    func dismissFeedback() { if pendingOperation == nil { feedback = nil } }

    func requestHistory(hours: Double) {
        guard [1.0, 6, 24, 168, 720].contains(hours), !shutdownRequested else { return }
        guard !historyLoading || hours != historyHours else { return }
        historyTimeoutTask?.cancel()
        let command = WorkerCommand(op: "history", hours: hours)
        historyHours = hours
        historyRequestId = command.id
        historyLoading = true
        guard send(command, presentFeedback: false) else {
            failHistory("后台未连接，无法读取观测记录。已有记录未删除。")
            return
        }
        historyTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.historyRequestId == command.id else { return }
            self.failHistory("读取记录尚未完成，请稍后重试。已有记录未删除。")
        }
    }
    func requestMenuHistory() {
        guard !menuHistoryLoading, !shutdownRequested else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastMenuHistoryRequestAt, now - lastMenuHistoryRequestAt < 10 { return }
        menuHistoryTimeoutTask?.cancel()
        let command = WorkerCommand(op: "history", hours: 1)
        menuHistoryRequestId = command.id
        lastMenuHistoryRequestAt = now
        menuHistoryLoading = true
        guard send(command, presentFeedback: false) else {
            failMenuHistory("后台未连接，无法读取最近一小时记录。")
            return
        }
        menuHistoryTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.menuHistoryRequestId == command.id else { return }
            self.failMenuHistory("读取最近一小时记录尚未完成，请稍后重试。")
        }
    }
    func requestProcesses() {
        guard !processesLoading, !shutdownRequested else { return }
        processesTimeoutTask?.cancel()
        let command = WorkerCommand(op: "processes")
        processesRequestId = command.id
        processesLoading = true
        guard send(command, presentFeedback: false) else {
            failProcesses("后台未连接，无法读取进程占用。")
            return
        }
        processesTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.processesRequestId == command.id else { return }
            self.failProcesses("读取进程占用尚未完成，请稍后重试。")
        }
    }

    func refreshNotificationAuthorization() {
        guard !notificationBusy else { return }
        notificationBusy = true
        Task { @MainActor [weak self] in
            await NotificationSupport.shared.refreshAuthorization()
            self?.syncNotificationState()
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard !notificationBusy else { return }
        notificationBusy = true
        Task { @MainActor [weak self] in
            await NotificationSupport.shared.setEnabled(enabled)
            self?.syncNotificationState()
        }
    }

    func sendTestNotification() {
        guard !notificationBusy else { return }
        notificationBusy = true
        Task { @MainActor [weak self] in
            await NotificationSupport.shared.sendTestNotification()
            self?.syncNotificationState()
        }
    }

    func testStrategy(_ levels: [Int]) {
        let unique = levels.reduce(into: [Int]()) { result, level in
            guard (0...17).contains(level), !result.contains(level), result.count < 2 else { return }
            result.append(level)
        }
        guard !unique.isEmpty else {
            errorMessage = "没有可试听的有效等级。"
            return
        }
        send(WorkerCommand(op: "testStrategy", levels: unique))
    }

    func beginPairing(region: String) {
        requestedSettingsPage = .account
        send(WorkerCommand(op: "beginPairing", region: region))
    }

    func cancelPairing() { send(WorkerCommand(op: "cancelPairing")) }
    func selectDevice(deviceId: String) { send(WorkerCommand(op: "selectDevice", deviceId: deviceId)) }
    func logout() { send(WorkerCommand(op: "logout")) }
    func clearError() { errorMessage = nil }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginMessage = "登录启动设置失败（\(String(describing: type(of: error)))）。"
        }
    }

    func requestApplicationTermination() -> NSApplication.TerminateReply {
        guard !shutdownRequested else { return .terminateLater }
        shutdownRequested = true
        repliedToTermination = false
        macTerminationPrepared = false
        shutdownTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await MacFanController.shared.prepareForTermination()
            guard self.shutdownRequested else {
                MacFanController.shared.cancelTerminationPreparation()
                return
            }
            guard restored else {
                self.cancelApplicationTermination("Mac 内置风扇尚未确认恢复系统自动，已取消退出。请重试恢复。")
                return
            }
            self.macTerminationPrepared = true
            guard self.process != nil else {
                if self.lastWorkerExitCode != 0, self.status?.owner == true || self.status?.commandState == "unknown" {
                    self.cancelApplicationTermination("后台已断开，净化器恢复尚未确认。请重新连接后台并停止控制。")
                } else {
                    self.finishApplicationTermination()
                }
                return
            }
            guard self.send(WorkerCommand(op: "shutdown"), allowDuringShutdown: true) else {
                self.cancelApplicationTermination("无法向后台发送安全退出命令，已取消退出。")
                return
            }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard self.shutdownRequested else { return }
            self.cancelApplicationTermination("后台未能确认安全恢复，已取消退出。请保持应用运行并重试停止。")
        }
        return .terminateLater
    }

    private func cancelApplicationTermination(_ message: String) {
        errorMessage = message
        shutdownRequested = false
        macTerminationPrepared = false
        repliedToTermination = true
        shutdownTimeoutTask?.cancel()
        shutdownTimeoutTask = nil
        MacFanController.shared.cancelTerminationPreparation()
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    @discardableResult
    private func send(_ command: WorkerCommand, allowDuringShutdown: Bool = false, presentFeedback: Bool = true) -> Bool {
        if presentFeedback, pendingOperation != nil, !["stop", "pause", "cancelPairing", "shutdown"].contains(command.op) { return false }
        if presentFeedback {
            feedbackTimeoutTask?.cancel()
            errorMessage = nil
            feedback = ActionFeedback(id: command.id, op: command.op, phase: .pending, title: pendingTitle(command.op), detail: "正在等待后台确认；不会重复发送。")
        }
        guard connected, let input, allowDuringShutdown || !shutdownRequested else {
            if !shutdownRequested {
                errorMessage = "后台未连接，操作未发送。"
                if presentFeedback { failFeedback(errorMessage!) }
            }
            return false
        }
        do {
            var data = try encoder.encode(command)
            data.append(0x0A)
            try input.write(contentsOf: data)
            if presentFeedback {
                feedbackTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.feedback?.id == command.id, self.pendingOperation != nil else { return }
                    self.failFeedback("后台尚未确认结果，不能断定操作未执行。请刷新状态，必要时停止联动；不会自动重试。")
                }
            }
            return true
        } catch {
            connected = false
            errorMessage = "无法向后台发送命令（\(String(describing: type(of: error)))）。"
            if presentFeedback { failFeedback(errorMessage!) }
            return false
        }
    }

    private func pendingTitle(_ op: String) -> String {
        switch op {
        case "enable": "正在启用联动…"
        case "pause": "正在暂停并核对恢复…"
        case "stop", "shutdown": "正在停止并核对恢复…"
        case "manualPurifier": "正在切换手动档位并核对回读…"
        case "releaseManualPurifier": "正在结束手动并恢复原状态…"
        case "configure": "正在保存规则…"
        case "dryRun": "正在进入演练…"
        case "testStrategy": "正在准备试听…"
        case "refresh": "正在刷新设备状态…"
        case "beginPairing": "正在准备米家登录…"
        case "cancelPairing": "正在取消登录…"
        case "selectDevice": "正在提交设备选择…"
        case "logout": "正在移除本机授权…"
        case "clearHistory": "正在清除本机记录…"
        default: "正在处理…"
        }
    }

    private func failFeedback(_ message: String) {
        guard feedback != nil else { return }
        feedback?.phase = .failed
        feedback?.title = "操作结果未确认"
        feedback?.detail = message
    }

    private func failHistory(_ message: String) {
        historyTimeoutTask?.cancel()
        historyLoading = false
        history = HistorySnapshot(kind: "history", requestId: historyRequestId ?? "", hours: historyHours, retentionDays: 30, totalSamples: history?.totalSamples ?? 0, recordingSince: history?.recordingSince, points: history?.hours == historyHours ? history?.points ?? [] : [], comparison: nil, error: message)
        historyRequestId = nil
    }

    private func failMenuHistory(_ message: String) {
        menuHistoryTimeoutTask?.cancel()
        menuHistoryLoading = false
        menuHistory = HistorySnapshot(kind: "history", requestId: menuHistoryRequestId ?? "", hours: 1, retentionDays: 30, totalSamples: menuHistory?.totalSamples ?? 0, recordingSince: menuHistory?.recordingSince, points: menuHistory?.points ?? [], comparison: nil, error: message)
        menuHistoryRequestId = nil
    }
    private func failProcesses(_ message: String) {
        processesTimeoutTask?.cancel()
        processesLoading = false
        processes = ProcessSnapshot(
            kind: "processes",
            requestId: processesRequestId ?? "",
            timestamp: processes?.timestamp,
            processes: processes?.processes ?? [],
            error: message
        )
        processesRequestId = nil
    }

    private func syncNotificationState() {
        notificationsEnabled = NotificationSupport.shared.enabled
        notificationStatus = NotificationSupport.shared.statusMessage
        notificationBusy = false
    }

    private func applyStatus(_ newStatus: WorkerStatus) {
        status = newStatus
        connected = true
        evaluateAlerts(using: newStatus)
    }

    private func refreshStalenessAndAlerts() {
        guard var current = status else { return }
        let now = Date().timeIntervalSince1970
        if current.temperature.timestamp.map({ now - $0 > current.config.staleSeconds }) ?? true {
            current.temperature.stale = true
        }
        if current.system.timestamp.map({ now - $0 > 10 }) ?? true {
            current.system.stale = true
        }
        status = current
        evaluateAlerts(using: current)
    }

    private func evaluateAlerts(using current: WorkerStatus) {
        let temperatureAvailable = connected && !current.temperature.stale && current.temperature.timestamp != nil
            && (current.temperature.cpu != nil || current.temperature.gpu != nil)
        NotificationSupport.shared.consume(MonitorAlertSample(
            thermalState: current.system.thermalState,
            memoryPressure: current.system.memoryPressure,
            temperatureAvailable: temperatureAvailable,
            devicePaired: current.account.paired,
            deviceReachable: current.device.reachable,
            heatDataConnected: connected,
            systemDataFresh: connected && !current.system.stale
        ))
    }

    private func receiveResult(_ result: WorkerCommandResult) {
        applyStatus(result.status)
        guard result.id == feedback?.id, result.op == feedback?.op else { return }
        feedbackTimeoutTask?.cancel()
        var outcome = ActionFeedback(id: result.id, op: result.op, phase: result.success ? .succeeded : .failed, title: result.success ? "操作已确认" : "操作未完成", detail: result.message)
        if result.success {
            switch result.op {
            case "enable":
                outcome.title = "联动已启用 · 正在监测"
                outcome.detail = "启用不等于立即调档。达到温度阈值并持续足够时间后才会接管；当前净化器保持原状态。"
            case "manualPurifier": outcome.title = "手动档位已确认"
            case "releaseManualPurifier": outcome.title = "手动已结束 · 原状态已恢复"
            case "configure": outcome.title = "规则已保存"
            case "pause": outcome.title = "联动已暂停"
            case "stop": outcome.title = "联动已停止"
            case "dryRun": outcome.title = "演练已开始 · 不写设备"
            case "testStrategy": outcome.title = "试听已开始，尚未完成"
            case "refresh": outcome.title = !result.status.account.paired ? "主机状态已更新" : (result.status.device.reachable ? "设备状态已更新" : "设备暂不可达")
            case "beginPairing": outcome.title = "登录流程已开始"
            case "cancelPairing": outcome.title = "已取消本次登录"
            case "selectDevice": outcome.title = "已提交选择 · 正在核验设备"
            case "logout": outcome.title = "本机授权已移除"
            case "clearHistory":
                outcome.title = "本机观测记录已清除"
                outcome.detail = "从下一个有效样本重新记录；米家授权与联动规则未改动。"
                let reloadHistory = history != nil || historyLoading
                let reloadMenuHistory = menuHistory != nil || menuHistoryLoading
                historyTimeoutTask?.cancel()
                menuHistoryTimeoutTask?.cancel()
                historyRequestId = nil
                menuHistoryRequestId = nil
                historyLoading = false
                menuHistoryLoading = false
                history = nil
                menuHistory = nil
                lastMenuHistoryRequestAt = nil
                if reloadHistory { requestHistory(hours: historyHours) }
                if reloadMenuHistory { requestMenuHistory() }
            default: break
            }
            if ["stop", "pause", "dryRun", "testStrategy"].contains(result.op), ["unknown", "failed"].contains(result.status.commandState) {
                outcome.phase = .failed
                outcome.title = "设备操作尚未确认"
                outcome.detail = result.status.commandDetail
            } else if result.op == "refresh", result.status.account.paired, !result.status.device.reachable {
                outcome.phase = .failed
                outcome.detail = "当前无法读取设备；显示的上次资料不代表实时状态。请检查本地网络与设备电源。"
            }
        }
        feedback = outcome
    }

    private func readOutput(_ output: FileHandle) {
        let lines = lineStream(from: output)
        outputTask = Task { @MainActor [weak self] in
            for await line in lines {
                guard let self else { return }
                receive(line)
            }
        }
    }

    private func drainSanitizedError(_ errorOutput: FileHandle) {
        let lines = lineStream(from: errorOutput)
        errorTask = Task { @MainActor in
            for await _ in lines {
                // Discarded: upstream exceptions may contain credentials or authorization URLs.
            }
        }
    }

    private func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        let framer = NDJSONLineFramer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    for line in framer.finish() { continuation.yield(line) }
                    continuation.finish()
                    return
                }
                for line in framer.append(data) { continuation.yield(line) }
            }
        }
    }

    private func receive(_ line: String) {
        guard process != nil, !Task.isCancelled, let data = line.data(using: .utf8) else { return }
        var receivedKind: String?
        do {
            let envelope = try decoder.decode(KindEnvelope.self, from: data)
            receivedKind = envelope.kind
            switch envelope.kind {
            case "status":
                applyStatus(try decoder.decode(WorkerStatus.self, from: data))
            case "commandResult":
                receiveResult(try decoder.decode(WorkerCommandResult.self, from: data))
            case "history":
                let snapshot = try decoder.decode(HistorySnapshot.self, from: data)
                if snapshot.requestId == historyRequestId {
                    historyTimeoutTask?.cancel()
                    history = snapshot
                    historyLoading = false
                    historyRequestId = nil
                } else if snapshot.requestId == menuHistoryRequestId {
                    menuHistoryTimeoutTask?.cancel()
                    menuHistory = snapshot
                    menuHistoryLoading = false
                    menuHistoryRequestId = nil
                }
            case "processes":
                let snapshot = try decoder.decode(ProcessSnapshot.self, from: data)
                guard snapshot.requestId == processesRequestId else { return }
                processesTimeoutTask?.cancel()
                if let message = snapshot.error {
                    processes = ProcessSnapshot(kind: snapshot.kind, requestId: snapshot.requestId, timestamp: processes?.timestamp, processes: processes?.processes ?? [], error: message)
                } else {
                    processes = snapshot
                }
                processesLoading = false
                processesRequestId = nil
            case "error":
                let message = try decoder.decode(WorkerError.self, from: data).message
                errorMessage = message
                if historyLoading { failHistory(message) }
                if menuHistoryLoading { failMenuHistory(message) }
                if processesLoading { failProcesses(message) }
            default:
                errorMessage = "后台返回了未知消息类型。"
            }
        } catch {
            let message = "后台返回了无法解析的 \(receivedKind ?? "消息")（\(String(describing: type(of: error)))）。"
            errorMessage = message
            if receivedKind == "history", historyLoading { failHistory(message) }
            if receivedKind == "history", menuHistoryLoading { failMenuHistory(message) }
            if receivedKind == "processes", processesLoading { failProcesses(message) }
        }
    }

    private func workerExited(exitCode: Int32) {
        let expected = shutdownRequested
        lastWorkerExitCode = exitCode
        connected = false
        process = nil
        input = nil
        outputTask?.cancel()
        errorTask?.cancel()
        outputTask = nil
        errorTask = nil
        feedbackTimeoutTask?.cancel()
        historyTimeoutTask?.cancel()
        menuHistoryTimeoutTask?.cancel()
        processesTimeoutTask?.cancel()
        if historyLoading { failHistory("后台已退出，当前无法读取观测记录。") }
        if menuHistoryLoading { failMenuHistory("后台已退出，当前无法读取最近一小时记录。") }
        if processesLoading { failProcesses("后台已退出，当前无法读取进程占用。") }
        if pendingOperation != nil { failFeedback("后台已退出，无法确认操作结果。请重新连接后核对设备状态。") }
        if var retained = status {
            retained.temperature.stale = true
            retained.system.stale = true
            status = retained
            if !expected { evaluateAlerts(using: retained) }
        }

        if expected {
            if exitCode != 0 {
                cancelApplicationTermination("后台异常退出（代码 \(exitCode)），不能确认净化器已恢复，已取消退出。")
            } else if macTerminationPrepared {
                finishApplicationTermination()
            }
        } else {
            errorMessage = "后台进程已退出（代码 \(exitCode)）。控制已停用；上次设备资料仍保留显示。"
        }
    }

    private func finishApplicationTermination() {
        guard !repliedToTermination else { return }
        repliedToTermination = true
        shutdownTimeoutTask?.cancel()
        shutdownTimeoutTask = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func launchConfiguration() throws -> (resources: URL, python: URL, worker: URL, macmon: URL) {
        let environment = ProcessInfo.processInfo.environment
        let resources: URL
        if let override = environment["MACFANLINK_RESOURCE_DIR"], !override.isEmpty {
            resources = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else if let bundled = Bundle.main.resourceURL,
                  FileManager.default.isReadableFile(atPath: bundled.appendingPathComponent("scripts/worker.py").path) {
            resources = bundled.standardizedFileURL
        } else {
            resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .standardizedFileURL
        }

        let python = resources.appendingPathComponent("runtime/bin/python3.12")
        let worker = resources.appendingPathComponent("scripts/worker.py")
        let macmon = resources.appendingPathComponent("bin/macmon")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw LaunchProblem.pythonUnavailable }
        guard FileManager.default.isReadableFile(atPath: worker.path) else { throw LaunchProblem.workerUnavailable }
        guard FileManager.default.isExecutableFile(atPath: macmon.path) else { throw LaunchProblem.macmonUnavailable }
        return (resources, python, worker, macmon)
    }

    private func launchErrorDescription(_ error: Error) -> String {
        if let problem = error as? LaunchProblem { return problem.description }
        return "后台启动失败（\(String(describing: type(of: error)))）。"
    }
}

private nonisolated final class NDJSONLineFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maximumBufferedBytes = 1_048_576

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maximumBufferedBytes, !buffer.contains(0x0A) {
            buffer.removeAll(keepingCapacity: true)
            return []
        }
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
            buffer.removeSubrange(...newline)
        }
        return lines
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return [line]
    }
}

private struct KindEnvelope: Decodable {
    var kind: String
}

private enum LaunchProblem: Error {
    case pythonUnavailable
    case workerUnavailable
    case macmonUnavailable

    var description: String {
        switch self {
        case .pythonUnavailable: "应用包内的 Python 3.12 运行时不存在或不可执行。"
        case .workerUnavailable: "应用包内的 scripts/worker.py 不存在或不可读。"
        case .macmonUnavailable: "应用包内的 macmon 不存在或不可执行。"
        }
    }
}
