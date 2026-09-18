import Foundation

enum SettingsPage: String, Hashable {
    case overview
    case device
    case rules
    case account
    case runtime
    case history
    case manual
}

enum DraftValidationError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

struct LinkConfig: Codable, Equatable, Sendable {
    var mediumThreshold: Double
    var highThreshold: Double
    var downThreshold: Double
    var exitThreshold: Double
    var riseSeconds: Double
    var fallSeconds: Double
    var minAdjustSeconds: Double
    var sampleSeconds: Double
    var staleSeconds: Double
    var mediumLevel: Int?
    var highLevel: Int?

    static let defaults = LinkConfig(
        mediumThreshold: 70,
        highThreshold: 85,
        downThreshold: 78,
        exitThreshold: 63,
        riseSeconds: 60,
        fallSeconds: 180,
        minAdjustSeconds: 60,
        sampleSeconds: 20,
        staleSeconds: 180,
        mediumLevel: nil,
        highLevel: nil
    )
}

struct TemperatureStatus: Codable, Equatable, Sendable {
    var cpu: Double?
    var gpu: Double?
    var timestamp: Double?
    var stale: Bool
    var cpuLoad: Double?
}

struct DeviceStatus: Codable, Equatable, Sendable {
    var reachable: Bool
    var power: Bool?
    var mode: String?
    var level: Int?
    var rpm: Int?
    var model: String
    var firmware: String
    var ip: String
    var name: String
    var imageURL: String?
    var productName: String?
    var supported: Bool
    var supportDescription: String

    var productTitle: String { productName ?? (model.isEmpty ? "型号未知" : model) }
}

struct PairingDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var model: String
    var ip: String
    var supported: Bool
    var reason: String
    var imageURL: String?
}

struct AccountStatus: Codable, Equatable, Sendable {
    var paired: Bool
    var label: String
    var region: String
    var phase: String
    var message: String
    var qrImagePath: String?
    var expiresAt: Double?
    var devices: [PairingDevice]
}

struct WorkerStatus: Codable, Equatable, Sendable {
    var kind: String
    var mode: String
    var phase: String
    var reason: String
    var temperature: TemperatureStatus
    var device: DeviceStatus
    var account: AccountStatus
    var owner: Bool
    var busy: Bool
    var canEnable: Bool
    var verifiedLevels: [Int]
    var commandState: String
    var commandDetail: String
    var eventLog: [String]
    var config: LinkConfig
    var dwell: [DwellStatus]
    var historyError: String?
    var system: SystemMetricsStatus
}

struct WorkerError: Codable, Sendable {
    var kind: String
    var message: String
}

struct WorkerCommand: Encodable, Sendable {
    let id = UUID().uuidString
    var op: String
    var config: LinkConfig?
    var region: String?
    var deviceId: String?
    var levels: [Int]?
    var hours: Double?
    var level: Int?

    init(
        op: String,
        config: LinkConfig? = nil,
        region: String? = nil,
        deviceId: String? = nil,
        levels: [Int]? = nil,
        hours: Double? = nil,
        level: Int? = nil
    ) {
        self.op = op
        self.config = config
        self.region = region
        self.deviceId = deviceId
        self.levels = levels
        self.hours = hours
        self.level = level
    }
}

struct DwellStatus: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var elapsed: Double
    var required: Double
    var id: String { name }
}

enum ActionFeedbackPhase: String, Equatable {
    case pending, succeeded, failed
}

struct ActionFeedback: Equatable, Identifiable {
    let id: String
    let op: String
    var phase: ActionFeedbackPhase
    var title: String
    var detail: String
}

struct WorkerCommandResult: Decodable {
    var kind: String
    var id: String
    var op: String
    var success: Bool
    var message: String
    var status: WorkerStatus
}

struct HistoryPoint: Decodable, Equatable, Identifiable {
    var timestamp: Double
    var cpu: Double?
    var gpu: Double?
    var cpuLoad: Double?
    var rpm: Double?
    var level: Int?
    var deviceMode: String?
    var mode: String
    var owner: Bool
    var segment: String
    var gpuLoad: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var swapUsed: Double?
    var memoryPressure: String?
    var thermalState: String?
    var macFans: [MacFanReading]
    var deviceId: String?
    var id: String { "\(segment):\(timestamp)" }
}

struct CoolingComparison: Decodable, Equatable {
    var baselineCPU: Double
    var linkedCPU: Double
    var deltaCPU: Double
    var baselineLoad: Double?
    var linkedLoad: Double?
    var baselineCount: Int
    var linkedCount: Int
    var start: Double
    var end: Double
    var message: String
}

struct HistorySnapshot: Decodable, Equatable {
    var kind: String
    var requestId: String
    var hours: Double
    var retentionDays: Int
    var totalSamples: Int
    var recordingSince: Double?
    var points: [HistoryPoint]
    var comparison: CoolingComparison?
    var error: String?
    var events: [HistoryEvent] = []
    var selectedDeviceId: String? = nil
}

struct MacFanReading: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var rpm: Double
    var maxRPM: Double?
    var id: String { name }
}

struct MemoryMetrics: Codable, Equatable, Sendable {
    var totalBytes: Double
    var usedBytes: Double
    var swapTotalBytes: Double
    var swapUsedBytes: Double
}

struct SystemMetricsStatus: Codable, Equatable, Sendable {
    var timestamp: Double?
    var stale: Bool
    var gpuLoad: Double?
    var memory: MemoryMetrics?
    var memoryPressure: String?
    var thermalState: String?
    var fans: [MacFanReading]
}

struct HistoryEvent: Decodable, Equatable, Identifiable {
    var id: String
    var timestamp: Double
    var kind: String
    var label: String
    var deviceId: String?
}

struct ProcessReading: Decodable, Equatable, Identifiable, Sendable {
    var pid: Int
    var name: String
    var cpuPercent: Double
    var id: Int { pid }
}

struct ProcessSnapshot: Decodable, Equatable {
    var kind: String
    var requestId: String
    var timestamp: Double?
    var processes: [ProcessReading]
    var error: String?
}

struct ConfigDraft: Equatable {
    var mediumThreshold: String
    var highThreshold: String
    var downThreshold: String
    var exitThreshold: String
    var mediumLevel: String
    var highLevel: String
    var riseSeconds: String
    var fallSeconds: String
    var minAdjustSeconds: String

    private var sampleSeconds: Double
    private var staleSeconds: Double

    init(_ config: LinkConfig = .defaults) {
        mediumThreshold = Self.text(config.mediumThreshold)
        highThreshold = Self.text(config.highThreshold)
        downThreshold = Self.text(config.downThreshold)
        exitThreshold = Self.text(config.exitThreshold)
        mediumLevel = config.mediumLevel.map(String.init) ?? ""
        highLevel = config.highLevel.map(String.init) ?? ""
        riseSeconds = Self.text(config.riseSeconds)
        fallSeconds = Self.text(config.fallSeconds)
        minAdjustSeconds = Self.text(config.minAdjustSeconds)
        sampleSeconds = config.sampleSeconds
        staleSeconds = config.staleSeconds
    }

    mutating func apply(_ config: LinkConfig) {
        self = ConfigDraft(config)
    }

    var mediumThresholdValue: Double? { Self.finiteDouble(mediumThreshold) }
    var highThresholdValue: Double? { Self.finiteDouble(highThreshold) }
    var downThresholdValue: Double? { Self.finiteDouble(downThreshold) }
    var exitThresholdValue: Double? { Self.finiteDouble(exitThreshold) }
    var mediumLevelValue: Int? { Self.integer(mediumLevel) }
    var highLevelValue: Int? { Self.integer(highLevel) }

    var timingSummary: String {
        "升档 \(Self.formattedNumber(riseSeconds)) 秒 · 回落 \(Self.formattedNumber(fallSeconds)) 秒 · 最短调档 \(Self.formattedNumber(minAdjustSeconds)) 秒 · 采样 \(Self.text(sampleSeconds)) 秒 · 过期 \(Self.text(staleSeconds)) 秒"
    }

    func validated() -> Result<LinkConfig, DraftValidationError> {
        guard let medium = mediumThresholdValue,
              let high = highThresholdValue,
              let down = downThresholdValue,
              let exit = exitThresholdValue else {
            return .failure(.message("四个温度阈值都必须是有限数值。"))
        }
        guard exit < medium, medium <= down, down < high else {
            return .failure(.message("温度必须满足：退出 < 中档 ≤ 降回中档 < 高档。"))
        }
        guard let rise = Self.finiteDouble(riseSeconds),
              let fall = Self.finiteDouble(fallSeconds),
              let minAdjust = Self.finiteDouble(minAdjustSeconds),
              sampleSeconds.isFinite, staleSeconds.isFinite else {
            return .failure(.message("计时设置必须是有限数值。"))
        }
        guard rise > 0, fall > 0, sampleSeconds > 0, staleSeconds > 0,
              minAdjust >= 0 else {
            return .failure(.message("升档、回落、采样和过期时间必须大于 0；最短调档时间不能小于 0。"))
        }
        guard sampleSeconds < staleSeconds else {
            return .failure(.message("数据过期时间必须大于采样间隔。"))
        }

        let mediumLevelResult = Self.level(mediumLevel, name: "中档")
        let highLevelResult = Self.level(highLevel, name: "高档")
        guard case let .success(parsedMediumLevel) = mediumLevelResult else {
            if case let .failure(error) = mediumLevelResult { return .failure(error) }
            preconditionFailure("Result case changed while validating the draft")
        }
        guard case let .success(parsedHighLevel) = highLevelResult else {
            if case let .failure(error) = highLevelResult { return .failure(error) }
            preconditionFailure("Result case changed while validating the draft")
        }
        if parsedMediumLevel >= parsedHighLevel {
            return .failure(.message("中档最爱等级必须低于高档。"))
        }

        return .success(LinkConfig(
            mediumThreshold: medium,
            highThreshold: high,
            downThreshold: down,
            exitThreshold: exit,
            riseSeconds: rise,
            fallSeconds: fall,
            minAdjustSeconds: minAdjust,
            sampleSeconds: sampleSeconds,
            staleSeconds: staleSeconds,
            mediumLevel: parsedMediumLevel,
            highLevel: parsedHighLevel
        ))
    }

    private static func level(_ text: String, name: String) -> Result<Int, DraftValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (0...17).contains(value) else {
            return .failure(.message("\(name)最爱等级必须是 0–17 的整数。"))
        }
        return .success(value)
    }

    private static func finiteDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private static func integer(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private static func formattedNumber(_ value: String) -> String {
        finiteDouble(value).map(text) ?? value
    }

    private static func text(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }
}
