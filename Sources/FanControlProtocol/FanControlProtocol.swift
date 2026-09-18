import Foundation

public struct ControllableMacFan: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let rpm: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?
    public let automatic: Bool?
    public let supportsManual: Bool

    public init(
        id: Int,
        name: String,
        rpm: Double,
        minRPM: Double,
        maxRPM: Double,
        targetRPM: Double?,
        automatic: Bool?,
        supportsManual: Bool
    ) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.automatic = automatic
        self.supportsManual = supportsManual
    }
}

public enum FanControlOperation: String, Codable, Sendable {
    case read
    case status
    case setManual
    case renew
    case restoreAutomatic
}

public struct FanControlRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let operation: FanControlOperation
    public let fanID: Int?
    public let rpm: Int?
    public let leaseID: UUID?

    public init(
        operation: FanControlOperation,
        fanID: Int? = nil,
        rpm: Int? = nil,
        leaseID: UUID? = nil
    ) {
        protocolVersion = FanControlWire.protocolVersion
        self.operation = operation
        self.fanID = fanID
        self.rpm = rpm
        self.leaseID = leaseID
    }
}

public enum FanControlErrorCode: String, Codable, Sendable {
    case malformedRequest
    case requestTooLarge
    case unauthorized
    case unavailable
    case incompatibleProtocol
    case invalidFan
    case invalidRPM
    case unsupported
    case thermalPressure
    case leaseConflict
    case leaseExpired
    case hardwareChanged
    case readFailed
    case writeFailed
    case verificationFailed
    case internalFailure
}

public struct FanControlFailure: Codable, Equatable, Sendable {
    public let code: FanControlErrorCode
    public let message: String

    public init(code: FanControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct FanControlResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let ok: Bool
    public let failure: FanControlFailure?
    public let fans: [ControllableMacFan]
    public let leaseID: UUID?
    public let leaseExpiresAt: Date?
    public let targets: [Int: Int]
    public let automaticRestored: Bool?

    public init(
        ok: Bool,
        failure: FanControlFailure? = nil,
        fans: [ControllableMacFan] = [],
        leaseID: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        targets: [Int: Int] = [:],
        automaticRestored: Bool? = nil
    ) {
        protocolVersion = FanControlWire.protocolVersion
        self.ok = ok
        self.failure = failure
        self.fans = fans
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
        self.targets = targets
        self.automaticRestored = automaticRestored
    }
}

public enum FanControlWire {
    public static let protocolVersion = 2
    public static let maximumPayloadBytes = 16 * 1024
    public static let payloadKey = "payload"
}
