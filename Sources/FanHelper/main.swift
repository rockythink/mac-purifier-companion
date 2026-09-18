import Darwin
import FanControlProtocol
import Foundation
import Security
@preconcurrency import XPC

private let serviceName = "cc.ss-data.MacFanLink.FanHelper"
private let mainBundleIdentifier = "cc.ss-data.MacFanLink"

enum LeaseJournalPhase: String, Codable {
    case prepared
    case active
    case restoring
}

enum LeaseRecoveryAction: Equatable {
    case restoreAutomatic, releaseAutomatic, releaseExternal, hold
}

struct LeaseJournal: Codable, Equatable {
    let leaseID: UUID
    let fanID: Int
    let targetRPM: Int
    let originalTargetRPM: Double
    let phase: LeaseJournalPhase
    var restorationTargetRPM: Double? = nil

    private func ownsManualTarget(_ target: Double) -> Bool {
        guard target.isFinite else { return false }
        switch phase {
        case .prepared:
            return abs(target - Double(targetRPM)) <= 1 || abs(target - originalTargetRPM) <= 1
        case .active:
            return abs(target - Double(targetRPM)) <= 1
        case .restoring:
            return restorationTargetRPM.map { abs(target - $0) <= 1 } == true
        }
    }

    func recoveryAction(mode: Int64, targetRPM: Double?) -> LeaseRecoveryAction {
        if mode == 0 {
            // A prepared record may precede a queued mode write, so it still requires rollback.
            return phase == .active ? .releaseAutomatic : .restoreAutomatic
        }
        guard let targetRPM, targetRPM.isFinite else { return .hold }
        return mode == 1 && ownsManualTarget(targetRPM) ? .restoreAutomatic : .releaseExternal
    }
}

struct Lease {
    let id: UUID
    let fanID: Int
    let targetRPM: Int
    let originalTargetRPM: Double
    let uid: uid_t
    let ownerID: ObjectIdentifier
    var expiresAt: ContinuousClock.Instant
}

struct LeaseHardware {
    let setManual: (Int, Int) throws -> Void
    let controlState: (Int) throws -> (mode: Int64, targetRPM: Double?)
    let restoreAutomatic: (Int) throws -> Void
}
enum FanLeaseEngineError: LocalizedError {
    case preparation(String)
    case transition(String)

    var errorDescription: String? {
        switch self {
        case .preparation(let message), .transition(let message): message
        }
    }
}

enum FanLeaseEngine {
    static func take(
        _ lease: Lease,
        leases: inout [Int: Lease],
        journals: inout [Int: LeaseJournal],
        hardware: LeaseHardware,
        persist: (LeaseJournal) throws -> Void,
        removeJournal: (Int) -> Void,
        canContinue: () -> Bool
    ) throws {
        let prepared = LeaseJournal(
            leaseID: lease.id, fanID: lease.fanID, targetRPM: lease.targetRPM,
            originalTargetRPM: lease.originalTargetRPM, phase: .prepared
        )
        do {
            try persist(prepared)
        } catch {
            throw FanLeaseEngineError.preparation(error.localizedDescription)
        }
        journals[lease.fanID] = prepared
        leases[lease.fanID] = lease
        do {
            guard canContinue() else { throw SMCError(description: "写入前租约失效或热压力升高，取消手动控制") }
            try hardware.setManual(lease.fanID, lease.targetRPM)
            guard canContinue() else { throw SMCError(description: "确认期间租约失效或热压力升高，取消手动控制") }
            let active = LeaseJournal(
                leaseID: lease.id, fanID: lease.fanID, targetRPM: lease.targetRPM,
                originalTargetRPM: lease.originalTargetRPM, phase: .active
            )
            try persist(active)
            journals[lease.fanID] = active
        } catch {
            _ = release(
                fanID: lease.fanID, leases: &leases, journals: &journals,
                hardware: hardware, persist: persist, removeJournal: removeJournal
            )
            throw FanLeaseEngineError.transition(error.localizedDescription)
        }
    }

    @discardableResult
    static func release(
        fanID: Int,
        leases: inout [Int: Lease],
        journals: inout [Int: LeaseJournal],
        hardware: LeaseHardware,
        persist: (LeaseJournal) throws -> Void,
        removeJournal: (Int) -> Void
    ) -> Bool {
        guard let lease = leases[fanID], let journal = journals[fanID],
              journal.leaseID == lease.id else { return false }
        do {
            let state = try hardware.controlState(fanID)
            switch journal.recoveryAction(mode: state.mode, targetRPM: state.targetRPM) {
            case .releaseAutomatic:
                leases.removeValue(forKey: fanID)
                journals.removeValue(forKey: fanID)
                removeJournal(fanID)
                return true
            case .releaseExternal:
                leases.removeValue(forKey: fanID)
                journals.removeValue(forKey: fanID)
                removeJournal(fanID)
                return false
            case .hold:
                return false
            case .restoreAutomatic:
                if let target = state.targetRPM {
                    let restoring = LeaseJournal(
                        leaseID: lease.id, fanID: fanID, targetRPM: lease.targetRPM,
                        originalTargetRPM: lease.originalTargetRPM, phase: .restoring,
                        restorationTargetRPM: target
                    )
                    if (try? persist(restoring)) != nil { journals[fanID] = restoring }
                }
                try hardware.restoreAutomatic(fanID)
                leases.removeValue(forKey: fanID)
                journals.removeValue(forKey: fanID)
                removeJournal(fanID)
                return true
            }
        } catch {
            return false
        }
    }

    @discardableResult
    static func releaseAll(
        leases: inout [Int: Lease],
        journals: inout [Int: LeaseJournal],
        hardware: LeaseHardware,
        persist: (LeaseJournal) throws -> Void,
        removeJournal: (Int) -> Void
    ) -> Bool {
        var allRestored = true
        for fanID in Array(leases.keys) {
            if !release(
                fanID: fanID, leases: &leases, journals: &journals, hardware: hardware,
                persist: persist, removeJournal: removeJournal
            ) { allRestored = false }
        }
        return allRestored && leases.isEmpty
    }

    static func releaseExpired(
        at now: ContinuousClock.Instant,
        leases: inout [Int: Lease],
        journals: inout [Int: LeaseJournal],
        hardware: LeaseHardware,
        persist: (LeaseJournal) throws -> Void,
        removeJournal: (Int) -> Void
    ) -> Bool? {
        guard leases.values.contains(where: { $0.expiresAt <= now }) else { return nil }
        return releaseAll(
            leases: &leases, journals: &journals, hardware: hardware,
            persist: persist, removeJournal: removeJournal
        )
    }

    static func releaseConnection(
        ownerID: ObjectIdentifier,
        leases: inout [Int: Lease],
        journals: inout [Int: LeaseJournal],
        hardware: LeaseHardware,
        persist: (LeaseJournal) throws -> Void,
        removeJournal: (Int) -> Void
    ) -> Bool? {
        guard leases.values.contains(where: { $0.ownerID == ownerID }) else { return nil }
        return releaseAll(
            leases: &leases, journals: &journals, hardware: hardware,
            persist: persist, removeJournal: removeJournal
        )
    }
}

private struct PendingRecovery {
    var journal: LeaseJournal
    let url: URL
}

private final class FanHelperService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.ss-data.MacFanLink.FanHelper.serial")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let journalDirectory = URL(fileURLWithPath: "/var/db/cc.ss-data.MacFanLink", isDirectory: true)
    private let clock = ContinuousClock()
    private var leases: [Int: Lease] = [:]
    private var pendingRecovery: [Int: PendingRecovery] = [:]
    private var recoveryJournals: [Int: LeaseJournal] = [:]
    private var recoveryEvidenceInvalid = false
    private var smc: AppleSMC?
    private var timer: DispatchSourceTimer?
    private let clientRequirement: String

    init() throws {
        let team = try Self.ownTeamIdentifier()
        clientRequirement = "anchor apple generic and identifier \"\(mainBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        smc = try AppleSMC()
        recoverAfterRestart()
    }

    func run() -> Never {
        let listener = xpc_connection_create_mach_service(
            serviceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            self.accept(event)
        }
        xpc_connection_resume(listener)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLease() }
        timer.resume()
        self.timer = timer
        dispatchMain()
    }

    private func accept(_ connection: xpc_connection_t) {
        let result = clientRequirement.withCString {
            xpc_connection_set_peer_code_signing_requirement(connection, $0)
        }
        guard result == 0 else {
            xpc_connection_cancel(connection)
            return
        }
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { [weak self, weak connection] event in
            guard let self, let connection else { return }
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                self.handle(event, from: connection)
            } else if event === XPC_ERROR_CONNECTION_INVALID || event === XPC_ERROR_CONNECTION_INTERRUPTED {
                self.connectionEnded(connection)
            }
        }
        xpc_connection_resume(connection)
    }

    private func handle(_ message: xpc_object_t, from connection: xpc_connection_t) {
        guard authorizedUID(for: connection) != nil else {
            reply(.failure(.unauthorized, "仅当前登录用户可控制风扇", leases: leases), to: message, via: connection)
            return
        }
        var length = 0
        guard let raw = xpc_dictionary_get_data(message, FanControlWire.payloadKey, &length),
              length <= FanControlWire.maximumPayloadBytes else {
            reply(.failure(length > FanControlWire.maximumPayloadBytes ? .requestTooLarge : .malformedRequest, "请求格式无效", leases: leases), to: message, via: connection)
            return
        }
        do {
            let request = try decoder.decode(FanControlRequest.self, from: Data(bytes: raw, count: length))
            guard request.protocolVersion == FanControlWire.protocolVersion else {
                reply(.failure(.incompatibleProtocol, "应用与辅助程序版本不兼容", leases: leases), to: message, via: connection)
                return
            }
            reply(process(request, from: connection), to: message, via: connection)
        } catch {
            reply(.failure(.malformedRequest, "无法解析请求", leases: leases), to: message, via: connection)
        }
    }

    private func process(_ request: FanControlRequest, from connection: xpc_connection_t) -> FanControlResponse {
        guard let smc else { return .failure(.unavailable, "AppleSMC 不可用", leases: leases) }
        guard pendingRecovery.isEmpty, !recoveryEvidenceInvalid else {
            return .failure(.unavailable, "辅助程序正在恢复上次的风扇状态；恢复记录异常时会保留证据并停止写入", leases: leases)
        }
        let uid = xpc_connection_get_euid(connection)
        if releaseExpiredOwnedIfNeeded() != nil, !leases.isEmpty {
            return .failure(.verificationFailed, "租约已过期，但尚未确认所有风扇恢复自动模式", leases: leases)
        }
        do {
            switch request.operation {
            case .read:
                return .success(fans: try smc.fans(), leases: leases)
            case .status:
                for lease in Array(leases.values) {
                    if try !smc.stillMatchesManual(fanID: lease.fanID, rpm: lease.targetRPM) {
                        _ = restoreOwnedLeaseIfSafe(fanID: lease.fanID)
                    }
                }
                return .success(fans: try smc.fans(), leases: leases)
            case .setManual:
                guard !thermalPressureUnsafe else {
                    _ = restoreAllOwnedIfSafe()
                    return .failure(.thermalPressure, leases.isEmpty ? "系统温度压力过高，已释放手动控制" : "系统温度压力过高，尚未确认恢复自动模式", leases: leases)
                }
                guard let fanID = request.fanID, let rpm = request.rpm else {
                    return .failure(.malformedRequest, "缺少风扇或目标转速", leases: leases)
                }
                if let first = leases.values.first {
                    guard first.uid == uid, request.leaseID == first.id,
                          first.ownerID == ObjectIdentifier(connection) else {
                        return .failure(.leaseConflict, "已有风扇控制会话", leases: leases)
                    }
                }
                var fan = try smc.fan(id: fanID)
                guard fan.supportsManual else {
                    return .failure(.unsupported, "此风扇没有可识别的手动控制协议", leases: leases)
                }
                guard rpm >= Int(ceil(fan.minRPM)), rpm <= Int(floor(fan.maxRPM)) else {
                    return .failure(.invalidRPM, "目标转速须在 \(Int(ceil(fan.minRPM)))–\(Int(floor(fan.maxRPM))) RPM", leases: leases)
                }
                if leases[fanID] != nil {
                    guard restoreOwnedLeaseIfSafe(fanID: fanID), leases[fanID] == nil else {
                        return .failure(.writeFailed, "尚未确认释放此风扇控制", leases: leases)
                    }
                    fan = try smc.fan(id: fanID)
                }
                guard fan.automatic == true else {
                    return .failure(.leaseConflict, "所选风扇不在系统自动模式，未覆盖外部设置", leases: leases)
                }
                guard let originalTargetRPM = fan.targetRPM, originalTargetRPM.isFinite,
                      originalTargetRPM >= 0, originalTargetRPM <= fan.maxRPM else {
                    return .failure(.unsupported, "无法确认接管前的风扇目标", leases: leases)
                }

                let sessionID = leases.values.first?.id ?? request.leaseID ?? UUID()
                let expiry = clock.now.advanced(by: .seconds(30))
                let newLease = Lease(
                    id: sessionID, fanID: fanID, targetRPM: rpm,
                    originalTargetRPM: originalTargetRPM, uid: uid,
                    ownerID: ObjectIdentifier(connection), expiresAt: expiry
                )
                do {
                    try FanLeaseEngine.take(
                        newLease, leases: &leases, journals: &recoveryJournals,
                        hardware: leaseHardware(smc), persist: persistEngineJournal,
                        removeJournal: removeEngineJournal,
                        canContinue: { self.clock.now < expiry && !self.thermalPressureUnsafe }
                    )
                    for id in leases.keys { leases[id]?.expiresAt = expiry }
                } catch let error as FanLeaseEngineError {
                    switch error {
                    case .preparation:
                        return .failure(.internalFailure, "无法写入安全恢复记录；未更改风扇模式", leases: leases)
                    case .transition:
                        return .failure(.writeFailed, error.localizedDescription, leases: leases)
                    }
                }
                return .success(fans: try smc.fans(), leases: leases)
            case .renew:
                guard let first = leases.values.first, request.leaseID == first.id,
                      first.uid == uid, first.ownerID == ObjectIdentifier(connection),
                      leases.values.allSatisfy({ $0.expiresAt > clock.now }) else {
                    return .failure(.leaseExpired, "手动控制会话已失效", leases: leases)
                }
                guard !thermalPressureUnsafe else {
                    _ = restoreAllOwnedIfSafe()
                    return .failure(.thermalPressure, leases.isEmpty ? "系统温度压力过高，已释放手动控制" : "系统温度压力过高，尚未确认恢复自动模式", leases: leases)
                }
                var releasedExternal = false
                for lease in Array(leases.values) {
                    guard recoveryJournals[lease.fanID]?.phase == .active,
                          try smc.stillMatchesManual(fanID: lease.fanID, rpm: lease.targetRPM) else {
                        let restored = restoreOwnedLeaseIfSafe(fanID: lease.fanID)
                        guard leases[lease.fanID] == nil else {
                            return .failure(.verificationFailed, "尚未确认安全释放，保留恢复记录", leases: leases)
                        }
                        releasedExternal = releasedExternal || !restored
                        continue
                    }
                }
                guard !leases.isEmpty else {
                    return .success(fans: try smc.fans(), leases: leases, restored: releasedExternal ? false : true)
                }
                let expiry = clock.now.advanced(by: .seconds(30))
                for id in leases.keys { leases[id]?.expiresAt = expiry }
                return .success(fans: try smc.fans(), leases: leases)
            case .restoreAutomatic:
                if let first = leases.values.first {
                    guard first.uid == uid, request.leaseID == first.id,
                          first.ownerID == ObjectIdentifier(connection) else {
                        return .failure(.leaseConflict, "手动控制会话不属于此请求", leases: leases)
                    }
                }
                let restored: Bool
                if let fanID = request.fanID {
                    guard leases[fanID] != nil else {
                        let automatic = try smc.fan(id: fanID).automatic == true
                        return .success(fans: try smc.fans(), leases: leases, restored: automatic)
                    }
                    restored = restoreOwnedLeaseIfSafe(fanID: fanID)
                    guard leases[fanID] == nil else {
                        return .failure(.writeFailed, "尚未确认安全释放此风扇，保留恢复记录", leases: leases)
                    }
                } else {
                    restored = restoreAllOwnedIfSafe()
                    guard leases.isEmpty else {
                        return .failure(.writeFailed, "尚未确认安全释放所有风扇，保留恢复记录", leases: leases)
                    }
                }
                return .success(fans: try smc.fans(), leases: leases, restored: restored)
            }
        } catch {
            let code: FanControlErrorCode
            switch request.operation {
            case .setManual, .restoreAutomatic: code = .writeFailed
            case .renew: code = .verificationFailed
            case .read, .status: code = .readFailed
            }
            return .failure(code, error.localizedDescription, leases: leases)
        }
    }

    private var thermalPressureUnsafe: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func checkLease() {
        if !pendingRecovery.isEmpty { attemptPendingRecovery() }
        guard !leases.isEmpty else { return }
        if thermalPressureUnsafe {
            _ = restoreAllOwnedIfSafe()
            return
        }
        if releaseExpiredOwnedIfNeeded() != nil { return }
        for lease in Array(leases.values) {
            do {
                guard recoveryJournals[lease.fanID]?.phase == .active,
                      try smc?.stillMatchesManual(fanID: lease.fanID, rpm: lease.targetRPM) == true else {
                    _ = restoreOwnedLeaseIfSafe(fanID: lease.fanID)
                    continue
                }
            } catch {
                // Keep durable evidence and retry; never claim restoration after an I/O error.
            }
        }
    }

    private func connectionEnded(_ connection: xpc_connection_t) {
        guard let smc else { return }
        _ = FanLeaseEngine.releaseConnection(
            ownerID: ObjectIdentifier(connection), leases: &leases, journals: &recoveryJournals,
            hardware: leaseHardware(smc), persist: persistEngineJournal,
            removeJournal: removeEngineJournal
        )
    }

    private func leaseHardware(_ smc: AppleSMC) -> LeaseHardware {
        LeaseHardware(
            setManual: { fanID, rpm in _ = try smc.setManual(fanID: fanID, rpm: rpm) },
            controlState: { try smc.controlState(fanID: $0) },
            restoreAutomatic: { _ = try smc.restoreAutomatic(fanID: $0) }
        )
    }

    private func persistEngineJournal(_ journal: LeaseJournal) throws {
        try persist(journal, at: journalURL(fanID: journal.fanID))
    }

    private func removeEngineJournal(fanID: Int) {
        try? FileManager.default.removeItem(at: journalURL(fanID: fanID))
    }

    @discardableResult
    private func restoreAllOwnedIfSafe() -> Bool {
        guard let smc else { return false }
        let restored = FanLeaseEngine.releaseAll(
            leases: &leases, journals: &recoveryJournals, hardware: leaseHardware(smc),
            persist: persistEngineJournal, removeJournal: removeEngineJournal
        )
        return restored
    }

    @discardableResult
    private func restoreOwnedLeaseIfSafe(fanID: Int) -> Bool {
        guard let smc else { return false }
        let restored = FanLeaseEngine.release(
            fanID: fanID, leases: &leases, journals: &recoveryJournals,
            hardware: leaseHardware(smc), persist: persistEngineJournal,
            removeJournal: removeEngineJournal
        )
        return restored
    }

    private func releaseExpiredOwnedIfNeeded() -> Bool? {
        guard let smc else { return false }
        let restored = FanLeaseEngine.releaseExpired(
            at: clock.now, leases: &leases, journals: &recoveryJournals,
            hardware: leaseHardware(smc), persist: persistEngineJournal,
            removeJournal: removeEngineJournal
        )
        return restored
    }

    private func recoverAfterRestart() {
        let manager = FileManager.default
        var urls: [URL] = [journalDirectory.appendingPathComponent("owned-lease.json")]
        if let contents = try? manager.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil) {
            urls += contents.filter { $0.lastPathComponent.hasPrefix("owned-fan-") && $0.pathExtension == "json" }
        }
        for url in urls where manager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let journal = try? decoder.decode(LeaseJournal.self, from: data),
                  journal.phase != .restoring || journal.restorationTargetRPM?.isFinite == true,
                  pendingRecovery[journal.fanID] == nil else {
                recoveryEvidenceInvalid = true
                continue
            }
            pendingRecovery[journal.fanID] = PendingRecovery(journal: journal, url: url)
            recoveryJournals[journal.fanID] = journal
        }
        attemptPendingRecovery()
    }

    private func attemptPendingRecovery() {
        guard let smc else { return }
        for fanID in Array(pendingRecovery.keys) {
            guard var pending = pendingRecovery[fanID] else { continue }
            do {
                let state = try smc.controlState(fanID: fanID)
                switch pending.journal.recoveryAction(mode: state.mode, targetRPM: state.targetRPM) {
                case .hold:
                    continue
                case .restoreAutomatic:
                    if let target = state.targetRPM {
                        let restoring = LeaseJournal(
                            leaseID: pending.journal.leaseID, fanID: fanID,
                            targetRPM: pending.journal.targetRPM,
                            originalTargetRPM: pending.journal.originalTargetRPM,
                            phase: .restoring, restorationTargetRPM: target
                        )
                        if (try? persist(restoring, at: pending.url)) != nil {
                            pending.journal = restoring
                            pendingRecovery[fanID] = pending
                        }
                    }
                    _ = try smc.restoreAutomatic(fanID: fanID)
                case .releaseAutomatic, .releaseExternal:
                    break
                }
                pendingRecovery.removeValue(forKey: fanID)
                recoveryJournals.removeValue(forKey: fanID)
                try? FileManager.default.removeItem(at: pending.url)
            } catch {
                // Retry the exact owned state on the timer; never resume an old lease.
            }
        }
    }

    private func journalURL(fanID: Int) -> URL {
        journalDirectory.appendingPathComponent("owned-fan-\(fanID).json")
    }


    private func persist(_ journal: LeaseJournal, at destination: URL) throws {
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journalDirectory.path)
        let data = try encoder.encode(journal)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }


    private func authorizedUID(for connection: xpc_connection_t) -> uid_t? {
        let uid = xpc_connection_get_euid(connection)
        var info = stat()
        guard stat("/dev/console", &info) == 0, uid != 0, uid == info.st_uid else { return nil }
        return uid
    }

    private func reply(_ response: FanControlResponse, to message: xpc_object_t, via connection: xpc_connection_t) {
        guard let reply = xpc_dictionary_create_reply(message),
              let data = try? encoder.encode(response), data.count <= FanControlWire.maximumPayloadBytes else { return }
        data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(reply, FanControlWire.payloadKey, bytes.baseAddress, bytes.count)
        }
        xpc_connection_send_message(connection, reply)
    }

    private static func ownTeamIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw SMCError(description: "无法读取辅助程序签名")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw SMCError(description: "无法读取辅助程序静态签名")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            throw SMCError(description: "辅助程序必须使用开发者团队签名")
        }
        return team
    }
}

private extension FanControlResponse {
    static func failure(_ code: FanControlErrorCode, _ message: String, leases: [Int: Lease]) -> FanControlResponse {
        FanControlResponse(
            ok: false, failure: FanControlFailure(code: code, message: message),
            leaseID: leases.values.first?.id,
            leaseExpiresAt: leases.isEmpty ? nil : Date().addingTimeInterval(30),
            targets: Dictionary(uniqueKeysWithValues: leases.values.map { ($0.fanID, $0.targetRPM) })
        )
    }

    static func success(fans: [ControllableMacFan], leases: [Int: Lease], restored: Bool? = nil) -> FanControlResponse {
        FanControlResponse(
            ok: true, fans: fans, leaseID: leases.values.first?.id,
            leaseExpiresAt: leases.isEmpty ? nil : Date().addingTimeInterval(30),
            targets: Dictionary(uniqueKeysWithValues: leases.values.map { ($0.fanID, $0.targetRPM) }),
            automaticRestored: restored
        )
    }
}

private func runProbe() -> Never {
    struct Probe: Encodable {
        let fans: [ControllableMacFan]
        let controlKeys: [SMCControlKeyDiagnostic]
        let capabilities: [String: Bool]
        let error: String?
    }
    let output: Probe
    do {
        let smc = try AppleSMC()
        let fans = try smc.fans()
        output = Probe(fans: fans, controlKeys: smc.controlKeyDiagnostics(), capabilities: ["read": true, "manualWriteImplemented": true, "manualWriteVerified": false, "probeWrites": false], error: nil)
    } catch {
        output = Probe(fans: [], controlKeys: [], capabilities: ["read": false, "manualWriteImplemented": true, "manualWriteVerified": false, "probeWrites": false], error: error.localizedDescription)
    }
    let data = (try? JSONEncoder().encode(output)) ?? Data("{\"error\":\"encode failed\"}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(output.error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}

if CommandLine.arguments.dropFirst() == ["--probe"] { runProbe() }

do {
    try FanHelperService().run()
} catch {
    fputs("FanHelper：\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
