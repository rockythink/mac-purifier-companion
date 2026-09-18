import FanControlProtocol
import Foundation
import IOKit

// AppleSMC user-client ABI follows the public MIT-licensed SMC implementation from
// exelban/stats (SMC/smc.swift); its ABI declarations are adapted here while all keys stay private.
private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

private struct SMCValue {
    let type: UInt32
    let bytes: [UInt8]
}
struct SMCControlKeyDiagnostic: Encodable {
    let key: String
    let readable: Bool
    let type: String?
    let bytes: [UInt8]?
    let integerValue: Int64?
    let error: String?
}

final class AppleSMC {
    private static let selector: UInt32 = 2
    private static let readBytesCommand: UInt8 = 5
    private static let writeBytesCommand: UInt8 = 6
    private static let readKeyInfoCommand: UInt8 = 9
    private static let maximumFans = 16

    private var connection: io_connect_t = 0
    private var lowerCaseModeKeyAvailable: Bool?

    init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCError(description: "AppleSMC 服务不可用")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw SMCError(description: "未找到 AppleSMC 服务") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw SMCError(description: "无法打开 AppleSMC（\(result)）")
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func fans() throws -> [ControllableMacFan] {
        let countValue = try read("FNum")
        guard let rawCount = decodeInteger(countValue), rawCount >= 0 else {
            throw SMCError(description: "无法读取风扇数量")
        }
        let count = min(Int(rawCount), Self.maximumFans)
        return try (0..<count).map(readFan)
    }

    func fan(id: Int) throws -> ControllableMacFan {
        let all = try fans()
        guard all.indices.contains(id) else { throw SMCError(description: "风扇编号无效") }
        return all[id]
    }

    /// Read-only diagnostics for the fixed set of control keys needed to choose
    /// the Apple Silicon fan protocol. This deliberately accepts no caller key.
    func controlKeyDiagnostics() -> [SMCControlKeyDiagnostic] {
        ["F0md", "F0Md", "Ftst"].map { key in
            do {
                let value = try read(key)
                return SMCControlKeyDiagnostic(
                    key: key,
                    readable: true,
                    type: fourCCString(value.type),
                    bytes: value.bytes,
                    integerValue: decodeInteger(value),
                    error: nil
                )
            } catch {
                return SMCControlKeyDiagnostic(
                    key: key,
                    readable: false,
                    type: nil,
                    bytes: nil,
                    integerValue: nil,
                    error: error.localizedDescription
                )
            }
        }
    }

    func setManual(fanID: Int, rpm: Int) throws -> ControllableMacFan {
        let before = try fan(id: fanID)
        guard before.supportsManual, before.targetRPM?.isFinite == true else {
            throw SMCError(description: "此风扇没有可识别的手动控制协议")
        }
        guard rpm >= Int(ceil(before.minRPM)), rpm <= Int(floor(before.maxRPM)) else {
            throw SMCError(description: "目标转速超出安全范围")
        }
        let targetKey = fanKey(fanID, "Tg")
        try writeMode(fanModeKey(fanID), manual: true)
        // Issue the bounded target immediately after mode, as one transaction.
        // Do not leave a previous automatic reset target selected while waiting.
        try writeNumeric(targetKey, value: Double(rpm))
        guard try confirmWrite({
            guard try self.modeValue(fanID) == 1 else { return false }
            return abs(try self.numeric(targetKey) - Double(rpm)) <= 1
        }) else {
            throw SMCError(description: "SMC 未在确认期限内接受目标转速")
        }
        return try fan(id: fanID)
    }

    @discardableResult
    func restoreAutomatic(fanID: Int) throws -> ControllableMacFan {
        guard (0..<Self.maximumFans).contains(fanID) else { throw SMCError(description: "风扇编号无效") }
        let modeKey = fanModeKey(fanID)
        let targetKey = fanKey(fanID, "Tg")
        try writeMode(modeKey, manual: false)
        guard try confirmWrite({ try self.modeValue(fanID) == 0 }) else {
            throw SMCError(description: "SMC 未在确认期限内进入自动模式")
        }
        try writeNumeric(targetKey, value: 0)
        // Automatic control may replace the cleared target with its own value.
        guard try confirmWrite({ try self.modeValue(fanID) == 0 }) else {
            throw SMCError(description: "SMC 未确认自动模式保持生效")
        }
        let verified = try fan(id: fanID)
        return verified
    }

    private func confirmWrite(_ matches: () throws -> Bool) throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        // M4 returns the previous mode immediately after an accepted write. Even an
        // apparently automatic read may precede a queued manual transition.
        Thread.sleep(forTimeInterval: 0.5)
        while true {
            guard clock.now < deadline else { return false }
            if try matches() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func stillMatchesManual(fanID: Int, rpm: Int) throws -> Bool {
        let current = try fan(id: fanID)
        return try modeValue(fanID) == 1 && current.targetRPM.map { abs($0 - Double(rpm)) <= 1 } == true
    }

    func controlState(fanID: Int) throws -> (mode: Int64, targetRPM: Double?) {
        let current = try fan(id: fanID)
        return (try modeValue(fanID), current.targetRPM)
    }

    private func readFan(_ id: Int) throws -> ControllableMacFan {
        let actual = try numeric(fanKey(id, "Ac"))
        let minimum = try numeric(fanKey(id, "Mn"))
        let maximum = try numeric(fanKey(id, "Mx"))
        guard actual.isFinite, minimum.isFinite, maximum.isFinite,
              minimum >= 100, maximum > minimum, maximum <= 30_000 else {
            throw SMCError(description: "风扇 \(id) 返回了无效转速范围")
        }
        let mode = try? read(fanModeKey(id))
        let targetValue = try? read(fanKey(id, "Tg"))
        let target = targetValue.flatMap { value -> Double? in
            if value.type == fourCC("fpe2"), value.bytes.count >= 2 {
                return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4
            }
            if value.type == fourCC("flt "), value.bytes.count >= 4 {
                return Double(value.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            }
            return nil
        }
        let automatic = mode.flatMap(decodeInteger).flatMap { value -> Bool? in
            switch value {
            case 0: true
            case 1: false
            default: nil
            }
        }
        let modeIsWritable = mode.map {
            $0.bytes.count == 1 && fourCCString($0.type).hasPrefix("ui")
        } == true
        let targetIsWritable = targetValue.map {
            $0.type == fourCC("fpe2") || $0.type == fourCC("flt ")
        } == true
        // Capability means a bounded, typed protocol attempt is available. It
        // does not claim that this machine has already accepted a write.
        let supportsManual = automatic != nil && modeIsWritable && targetIsWritable && target?.isFinite == true
        let nameValue = try? read(fanKey(id, "ID"))
        let decodedName = nameValue.flatMap(decodeString)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = decodedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac 风扇 \(id + 1)"
        return ControllableMacFan(
            id: id,
            name: name,
            rpm: actual,
            minRPM: minimum,
            maxRPM: maximum,
            targetRPM: target,
            automatic: automatic,
            supportsManual: supportsManual
        )
    }

    private func fanKey(_ id: Int, _ suffix: String) -> String {
        precondition((0..<Self.maximumFans).contains(id))
        let digit = String(id, radix: 16, uppercase: true)
        return "F\(digit)\(suffix)"
    }

    private func fanModeKey(_ id: Int) -> String {
        precondition((0..<Self.maximumFans).contains(id))
#if arch(arm64)
        if lowerCaseModeKeyAvailable == nil {
            lowerCaseModeKeyAvailable = (try? read("F0md")) != nil
        }
        return fanKey(id, lowerCaseModeKeyAvailable == true ? "md" : "Md")
#else
        return fanKey(id, "Md")
#endif
    }

    private func modeValue(_ fanID: Int) throws -> Int64 {
        let value = try read(fanModeKey(fanID))
        guard let mode = decodeInteger(value) else {
            throw SMCError(description: "SMC 模式键类型不受支持")
        }
        return mode
    }

    private func numeric(_ key: String) throws -> Double {
        let value = try read(key)
        if value.type == fourCC("fpe2"), value.bytes.count >= 2 {
            return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4
        }
        if value.type == fourCC("flt "), value.bytes.count >= 4 {
            let float = value.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            return Double(float)
        }
        if let integer = decodeInteger(value) { return Double(integer) }
        throw SMCError(description: "SMC 键 \(key) 的数值类型不受支持")
    }

    private func decodeInteger(_ value: SMCValue) -> Int64? {
        guard !value.bytes.isEmpty, value.bytes.count <= 8 else { return nil }
        let type = fourCCString(value.type)
        guard type.hasPrefix("ui") || type.hasPrefix("si") else { return nil }
        var unsigned: UInt64 = 0
        for byte in value.bytes { unsigned = (unsigned << 8) | UInt64(byte) }
        if type.hasPrefix("si"), value.bytes.count < 8,
           (value.bytes[0] & 0x80) != 0 {
            let mask = UInt64.max << UInt64(value.bytes.count * 8)
            return Int64(bitPattern: unsigned | mask)
        }
        return Int64(unsigned)
    }

    private func decodeString(_ value: SMCValue) -> String? {
        let bytes = value.bytes.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func read(_ key: String) throws -> SMCValue {
        var input = SMCKeyData()
        input.key = try keyCode(key)
        input.data8 = Self.readKeyInfoCommand
        var info = try call(input)
        guard info.keyInfo.dataSize > 0, info.keyInfo.dataSize <= 32 else {
            throw SMCError(description: "SMC 键 \(key) 长度无效")
        }
        let dataSize = info.keyInfo.dataSize
        let dataType = info.keyInfo.dataType
        input.keyInfo.dataSize = dataSize
        input.data8 = Self.readBytesCommand
        info = try call(input)
        return SMCValue(type: dataType, bytes: bytes(from: info, count: Int(dataSize)))
    }

    private func writeNumeric(_ key: String, value: Double) throws {
        let existing = try read(key)
        let encoded: [UInt8]
        switch existing.type {
        case fourCC("fpe2"):
            let raw = UInt16((value * 4).rounded())
            encoded = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case fourCC("flt "):
            var float = Float(value)
            encoded = withUnsafeBytes(of: &float) { Array($0) }
        default:
            throw SMCError(description: "SMC 目标转速类型不受支持")
        }
        try write(key, expectedType: existing.type, bytes: encoded)
    }

    private func writeMode(_ key: String, manual: Bool) throws {
        let existing = try read(key)
        guard existing.bytes.count == 1, fourCCString(existing.type).hasPrefix("ui") else {
            throw SMCError(description: "SMC 模式键类型不受支持")
        }
        try write(key, expectedType: existing.type, bytes: [manual ? 1 : 0])
    }

    private func write(_ key: String, expectedType: UInt32, bytes: [UInt8]) throws {
        guard !bytes.isEmpty, bytes.count <= 32 else { throw SMCError(description: "SMC 写入长度无效") }
        var input = SMCKeyData()
        input.key = try keyCode(key)
        input.data8 = Self.writeBytesCommand
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.keyInfo.dataType = expectedType
        withUnsafeMutableBytes(of: &input.bytes) { destination in
            destination.copyBytes(from: bytes)
        }
        _ = try call(input)
    }

    private func call(_ input: SMCKeyData) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.selector,
                    inputPointer,
                    MemoryLayout<SMCKeyData>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS, output.result == 0 else {
            throw SMCError(description: "AppleSMC 操作失败（IO \(result)，SMC \(output.result)）")
        }
        return output
    }

    private func bytes(from value: SMCKeyData, count: Int) -> [UInt8] {
        withUnsafeBytes(of: value.bytes) { Array($0.prefix(count)) }
    }

    private func keyCode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { throw SMCError(description: "SMC 键格式无效") }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCCString(_ value: UInt32) -> String {
        String(bytes: [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? ""
    }
}
