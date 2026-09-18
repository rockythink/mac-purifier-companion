import AppKit
import FanControlProtocol
import Foundation
import Observation
import Security
import ServiceManagement
@preconcurrency import XPC

@MainActor
@Observable
final class MacFanController {
    static let shared = MacFanController()

    private(set) var fans: [ControllableMacFan] = []
    private(set) var helperInstalled = false
    private(set) var helperApprovalNeeded = false
    private(set) var helperUpdateNeeded = false
    private(set) var helperReady = false
    private(set) var connectionMessage = ""
    private(set) var actionMessage: String?
    private(set) var busy = false
    private(set) var active = false
    private(set) var targets: [Int: Int] = [:]

    private let service = SMAppService.daemon(plistName: "cc.ss-data.MacFanLink.FanHelper.plist")
    private var client: FanHelperClient?
    private var leaseID: UUID?
    private var renewalTask: Task<Void, Never>?
    private var terminationPrepared = false

    private init() { updateServiceStatus() }

    func refresh() async {
        guard !terminationPrepared, !busy else { return }
        updateServiceStatus()
        guard helperInstalled, !helperApprovalNeeded else {
            helperReady = false
            return
        }
        busy = true
        defer { busy = false }
        do {
            let response = try await request(FanControlRequest(operation: .status))
            apply(response)
            helperReady = true
            helperUpdateNeeded = false
            connectionMessage = active ? "Mac 风扇处于手动模式" : "辅助程序已就绪"
        } catch let issue as HelperUpdateRequired {
            applyLegacy(issue.response)
            helperReady = false
            helperUpdateNeeded = true
            connectionMessage = "风扇辅助程序版本过旧；请先更新辅助程序"
        } catch {
            helperReady = false
            connectionMessage = error.localizedDescription
        }
    }

    func installHelper() async {
        beginUserAction()
        guard !terminationPrepared, !busy else { return }
        guard isInstalledApplication else {
            actionMessage = "请先将 Mac 净化器伴侣移到“应用程序”文件夹，再安装风扇辅助程序。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try service.register()
            updateServiceStatus()
            if helperApprovalNeeded {
                connectionMessage = "请在“登录项与扩展”中允许 Mac 净化器伴侣的辅助程序。"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                connectionMessage = "辅助程序已就绪"
                actionMessage = "风扇辅助程序已安装"
            }
        } catch {
            updateServiceStatus()
            if helperApprovalNeeded {
                connectionMessage = "安装申请已提交，等待系统批准；批准后只核对连接，不会自动调速。"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                actionMessage = "安装辅助程序失败：\(error.localizedDescription)"
            }
        }
    }

    func updateHelper() async {
        beginUserAction()
        guard !terminationPrepared, !busy else { return }
        guard helperUpdateNeeded else {
            actionMessage = "当前辅助程序无需更新"
            return
        }
        guard isInstalledApplication else {
            actionMessage = "请先将 Mac 净化器伴侣移到“应用程序”文件夹，再更新风扇辅助程序。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            if let client {
                let legacy = try await client.restoreLegacyAutomatic(leaseID: leaseID)
                guard legacy.ok, legacy.leaseID == nil, legacy.automaticRestored != nil else {
                    throw ControllerError(legacy.failure?.message ?? "旧辅助程序未确认已释放风扇控制")
                }
            }
            clearLeaseState()
            try await service.unregister()
            client?.cancel()
            client = nil
            try service.register()
            helperUpdateNeeded = false
            helperReady = false
            updateServiceStatus()
            connectionMessage = helperApprovalNeeded ? "新版辅助程序等待系统批准" : "新版辅助程序已注册，请重新连接"
            actionMessage = "风扇辅助程序已更新"
        } catch {
            updateServiceStatus()
            actionMessage = "未更新辅助程序：\(error.localizedDescription)"
        }
    }

    func openApprovalSettings() {
        beginUserAction()
        SMAppService.openSystemSettingsLoginItems()
    }

    func uninstallHelper() async {
        beginUserAction()
        guard !terminationPrepared, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if helperUpdateNeeded, let client {
                let legacy = try await client.restoreLegacyAutomatic(leaseID: leaseID)
                guard legacy.ok, legacy.leaseID == nil, legacy.automaticRestored != nil else {
                    throw ControllerError(legacy.failure?.message ?? "旧辅助程序未确认已释放风扇控制")
                }
            } else {
                let response = try await request(FanControlRequest(operation: .restoreAutomatic, leaseID: leaseID))
                guard response.ok, response.automaticRestored != nil, response.leaseID == nil, response.targets.isEmpty else {
                    throw ControllerError(response.failure?.message ?? "无法确认已释放风扇控制")
                }
            }
            clearLeaseState()
            try await service.unregister()
            client?.cancel()
            client = nil
            helperReady = false
            helperUpdateNeeded = false
            fans = []
            updateServiceStatus()
            connectionMessage = ""
            actionMessage = "风扇辅助程序已卸载"
        } catch {
            actionMessage = "未卸载辅助程序：\(error.localizedDescription)"
        }
    }

    func setManual(fanID: Int, rpm: Int) async {
        beginUserAction()
        guard !helperUpdateNeeded else {
            actionMessage = "请先更新风扇辅助程序"
            return
        }
        guard !terminationPrepared else {
            actionMessage = "应用正在退出，不能开始新的风扇控制"
            return
        }
        guard !busy else {
            actionMessage = "另一项风扇操作正在进行"
            return
        }
        busy = true
        defer { busy = false }
        let previous = (leaseID, active, targets)
        let candidateLeaseID = leaseID ?? UUID()
        // A write may succeed even when its reply is lost. Preserve every potentially owned target first.
        leaseID = candidateLeaseID
        targets[fanID] = rpm
        active = true
        do {
            let response = try await request(FanControlRequest(operation: .setManual, fanID: fanID, rpm: rpm, leaseID: candidateLeaseID))
            guard response.leaseID == candidateLeaseID, response.targets[fanID] == rpm else {
                throw ControllerError("辅助程序未确认手动模式")
            }
            apply(response)
            helperReady = true
            actionMessage = "已设置风扇 \(fanID + 1) 目标 \(rpm) RPM；实际转速会逐步变化"
            startRenewingLease()
        } catch let issue as ControllerError {
            if issue.serverResponded {
                if let retainedLeaseID = issue.leaseID {
                    leaseID = retainedLeaseID
                    targets = issue.targets
                    active = !targets.isEmpty
                } else if [.writeFailed, .internalFailure, .hardwareChanged, .thermalPressure, .leaseExpired, .verificationFailed].contains(issue.code) {
                    clearLeaseState()
                } else {
                    (leaseID, active, targets) = previous
                }
                actionMessage = issue.localizedDescription
            } else {
                helperReady = false
                actionMessage = "手动控制结果未确认；退出前将继续尝试释放：\(issue.localizedDescription)"
            }
        } catch let issue as HelperUpdateRequired {
            applyLegacy(issue.response)
            helperReady = false
            helperUpdateNeeded = true
            actionMessage = "辅助程序版本过旧；请更新后再控制风扇"
        } catch {
            helperReady = false
            actionMessage = "手动控制结果未确认；退出前将继续尝试释放：\(error.localizedDescription)"
        }
    }

    func restoreAutomatic(fanID: Int? = nil) async {
        beginUserAction()
        guard !terminationPrepared, !busy else { return }
        guard !helperUpdateNeeded else {
            actionMessage = "请先更新辅助程序；更新流程会先安全释放旧控制"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let response = try await request(FanControlRequest(operation: .restoreAutomatic, fanID: fanID, leaseID: leaseID))
            guard response.ok, response.automaticRestored != nil else {
                throw ControllerError(response.failure?.message ?? "无法确认已释放风扇控制")
            }
            if let fanID {
                guard response.targets[fanID] == nil else { throw ControllerError("辅助程序仍持有此风扇") }
            } else {
                guard response.leaseID == nil, response.targets.isEmpty else { throw ControllerError("辅助程序仍持有风扇") }
            }
            let restored = response.automaticRestored == true
            apply(response)
            actionMessage = restored ? (fanID == nil ? "Mac 风扇已恢复系统自动模式" : "此风扇已恢复系统自动模式") : "已释放控制；风扇状态由其他软件管理"
        } catch {
            actionMessage = "无法确认恢复系统自动模式：\(error.localizedDescription)"
        }
    }

    func prepareForTermination() async -> Bool {
        terminationPrepared = true
        renewalTask?.cancel()
        renewalTask = nil
        guard !busy else {
            actionMessage = "风扇操作状态未知，暂不能安全退出"
            return false
        }
        guard active || leaseID != nil else { return true }
        busy = true
        defer { busy = false }
        do {
            if helperUpdateNeeded, let client {
                let legacy = try await client.restoreLegacyAutomatic(leaseID: leaseID)
                guard legacy.ok, legacy.leaseID == nil, legacy.automaticRestored != nil else {
                    throw ControllerError(legacy.failure?.message ?? "旧辅助程序未确认已释放风扇控制")
                }
            } else {
                let response = try await request(FanControlRequest(operation: .restoreAutomatic, leaseID: leaseID))
                guard response.ok, response.automaticRestored != nil, response.leaseID == nil, response.targets.isEmpty else {
                    throw ControllerError(response.failure?.message ?? "无法确认已释放风扇控制")
                }
                apply(response)
            }
            clearLeaseState()
            return true
        } catch {
            actionMessage = "退出前无法确认 Mac 风扇已恢复系统自动：\(error.localizedDescription)"
            return false
        }
    }

    func cancelTerminationPreparation() {
        terminationPrepared = false
        if active, !helperUpdateNeeded { startRenewingLease() }
    }

    private var isInstalledApplication: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return Bundle.main.bundleURL.pathExtension == "app" && (path == "/Applications/MacFanLink.app" || path.hasPrefix("/Applications/"))
    }

    private func updateServiceStatus() {
        switch service.status {
        case .enabled:
            helperInstalled = true
            helperApprovalNeeded = false
        case .requiresApproval:
            helperInstalled = true
            helperApprovalNeeded = true
        case .notRegistered, .notFound:
            helperInstalled = false
            helperApprovalNeeded = false
        @unknown default:
            helperInstalled = false
            helperApprovalNeeded = false
        }
        if !helperInstalled || helperApprovalNeeded {
            helperReady = false
            helperUpdateNeeded = false
            connectionMessage = helperApprovalNeeded ? "辅助程序等待系统批准" : "辅助程序尚未安装"
        }
    }

    private func beginUserAction() { actionMessage = nil }

    private func request(_ request: FanControlRequest) async throws -> FanControlResponse {
        if client == nil { client = try FanHelperClient() }
        guard let client else { throw ControllerError("无法连接风扇辅助程序") }
        let response: FanControlResponse
        do {
            response = try await client.send(request)
        } catch let issue as HelperUpdateRequired {
            applyLegacy(issue.response)
            helperReady = false
            helperUpdateNeeded = true
            throw issue
        }
        guard response.protocolVersion == FanControlWire.protocolVersion else { throw ControllerError("辅助程序协议版本不兼容") }
        guard response.ok else { throw ControllerError(response: response) }
        return response
    }

    private func apply(_ response: FanControlResponse) {
        fans = response.fans
        leaseID = response.leaseID
        targets = response.targets
        active = response.leaseID != nil || !response.targets.isEmpty
        if !active {
            renewalTask?.cancel()
            renewalTask = nil
        }
    }

    private func applyLegacy(_ response: LegacyFanControlResponse) {
        fans = response.fans
        leaseID = response.leaseID
        if let fanID = response.activeFanID, let rpm = response.targetRPM {
            targets = [fanID: rpm]
        } else {
            targets = [:]
        }
        active = response.leaseID != nil || !targets.isEmpty
    }

    private func clearLeaseState() {
        renewalTask?.cancel()
        renewalTask = nil
        leaseID = nil
        active = false
        targets = [:]
    }

    private func startRenewingLease() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, !self.terminationPrepared,
                      let leaseID = self.leaseID else { return }
                do {
                    let response = try await self.request(FanControlRequest(operation: .renew, leaseID: leaseID))
                    guard !Task.isCancelled, !self.terminationPrepared else { return }
                    if response.automaticRestored == false {
                        self.apply(response)
                        self.connectionMessage = "已释放被其他软件接管的风扇；其余风扇保持当前控制"
                        if !self.active { return }
                    } else {
                        self.apply(response)
                    }
                } catch {
                    guard !Task.isCancelled, !self.terminationPrepared else { return }
                    self.helperReady = false
                    self.connectionMessage = "无法确认风扇控制租约状态：\(error.localizedDescription)"
                    return
                }
            }
        }
    }
}

private struct ControllerError: LocalizedError {
    let text: String
    let code: FanControlErrorCode?
    let leaseID: UUID?
    let targets: [Int: Int]
    let serverResponded: Bool

    init(_ text: String) {
        self.text = text
        code = nil
        leaseID = nil
        targets = [:]
        serverResponded = false
    }

    init(response: FanControlResponse) {
        text = response.failure?.message ?? "辅助程序请求失败"
        code = response.failure?.code
        leaseID = response.leaseID
        targets = response.targets
        serverResponded = true
    }

    var errorDescription: String? { text }
}

private nonisolated struct LegacyFanControlResponse: Decodable, Sendable {
    let protocolVersion: Int?
    let ok: Bool
    let failure: FanControlFailure?
    let fans: [ControllableMacFan]
    let leaseID: UUID?
    let activeFanID: Int?
    let targetRPM: Int?
    let automaticRestored: Bool?
}

private nonisolated struct HelperUpdateRequired: LocalizedError, Sendable {
    let response: LegacyFanControlResponse
    var errorDescription: String? { "风扇辅助程序版本过旧，需要由用户更新" }
}

private nonisolated final class FanHelperClient: @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue = DispatchQueue(label: "cc.ss-data.MacFanLink.FanClient")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() throws {
        let team = try Self.ownTeamIdentifier()
        connection = xpc_connection_create_mach_service("cc.ss-data.MacFanLink.FanHelper", queue, 0)
        let requirement = "anchor apple generic and identifier \"cc.ss-data.MacFanLink.FanHelper\" and certificate leaf[subject.OU] = \"\(team)\""
        let result = requirement.withCString {
            xpc_connection_set_peer_code_signing_requirement(connection, $0)
        }
        guard result == 0 else { throw ControllerError("辅助程序签名要求无效") }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    deinit { xpc_connection_cancel(connection) }
    func cancel() { xpc_connection_cancel(connection) }

    func send(_ request: FanControlRequest) async throws -> FanControlResponse {
        let data = try await sendPayload(request)
        do {
            return try decoder.decode(FanControlResponse.self, from: data)
        } catch {
            if let legacy = try? decoder.decode(LegacyFanControlResponse.self, from: data),
               legacy.protocolVersion == nil {
                throw HelperUpdateRequired(response: legacy)
            }
            throw ControllerError("无法解析辅助程序响应")
        }
    }

    func restoreLegacyAutomatic(leaseID: UUID?) async throws -> LegacyFanControlResponse {
        let request = FanControlRequest(operation: .restoreAutomatic, leaseID: leaseID)
        let data = try await sendPayload(request)
        if let legacy = try? decoder.decode(LegacyFanControlResponse.self, from: data),
           legacy.protocolVersion == nil { return legacy }
        throw ControllerError("无法解析旧辅助程序的释放结果")
    }

    private func sendPayload(_ request: FanControlRequest) async throws -> Data {
        let data = try encoder.encode(request)
        guard data.count <= FanControlWire.maximumPayloadBytes else { throw ControllerError("风扇请求过大") }
        let message = xpc_dictionary_create(nil, nil, 0)
        data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, FanControlWire.payloadKey, bytes.baseAddress, bytes.count)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = DataReplyGate(continuation)
            xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    gate.fail(ControllerError("辅助程序连接中断"))
                    return
                }
                var length = 0
                guard let raw = xpc_dictionary_get_data(reply, FanControlWire.payloadKey, &length),
                      length <= FanControlWire.maximumPayloadBytes else {
                    gate.fail(ControllerError("辅助程序响应无效"))
                    return
                }
                gate.succeed(Data(bytes: raw, count: length))
            }
            queue.asyncAfter(deadline: .now() + 10) {
                gate.fail(ControllerError("辅助程序响应超时"))
            }
        }
    }

    private static func ownTeamIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ControllerError("无法读取应用签名") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw ControllerError("无法读取应用静态签名") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            throw ControllerError("应用必须使用开发者团队签名")
        }
        return team
    }
}

private nonisolated final class DataReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func succeed(_ value: Data) { finish(.success(value)) }
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
