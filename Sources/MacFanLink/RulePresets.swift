import Foundation
import Observation

enum RuleTemplate: String, CaseIterable, Identifiable {
    case quiet
    case balanced
    case cooling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: "安静优先"
        case .balanced: "均衡"
        case .cooling: "散热优先"
        }
    }

    var summary: String {
        switch self {
        case .quiet: "较晚介入、较早退出。"
        case .balanced: "适度介入与回落。"
        case .cooling: "较早介入、较久保持。"
        }
    }

    func configuration(basedOn base: LinkConfig) -> LinkConfig {
        let values: (
            medium: Double,
            high: Double,
            down: Double,
            exit: Double,
            rise: Double,
            fall: Double,
            minAdjust: Double
        )

        switch self {
        case .quiet:
            values = (75, 90, 82, 68, 120, 120, 120)
        case .balanced:
            let defaults = LinkConfig.defaults
            values = (defaults.mediumThreshold, defaults.highThreshold, defaults.downThreshold,
                      defaults.exitThreshold, defaults.riseSeconds, defaults.fallSeconds, defaults.minAdjustSeconds)
        case .cooling:
            values = (65, 80, 73, 60, 30, 240, 60)
        }

        return LinkConfig(
            mediumThreshold: values.medium,
            highThreshold: values.high,
            downThreshold: values.down,
            exitThreshold: values.exit,
            riseSeconds: values.rise,
            fallSeconds: values.fall,
            minAdjustSeconds: values.minAdjust,
            sampleSeconds: base.sampleSeconds,
            staleSeconds: base.staleSeconds,
            mediumLevel: base.mediumLevel,
            highLevel: base.highLevel
        )
    }
}

struct RulePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var config: LinkConfig
}

enum RulePresetStoreError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case unknownPreset
    case invalidConfiguration(String)
    case corruptedStorage
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "预设名称不能为空。"
        case let .duplicateName(name):
            "已存在名为“\(name)”的预设。"
        case .unknownPreset:
            "找不到要修改的预设。"
        case let .invalidConfiguration(message):
            "无法保存预设：\(message)"
        case .corruptedStorage:
            "个人预设数据无法读取。为保护原数据，当前不能修改预设。"
        case let .persistenceFailed(message):
            "保存个人预设失败：\(message)"
        }
    }
}

@MainActor
@Observable
final class RulePresetStore {
    static let shared = RulePresetStore()
    static let storageKey = "rulePresetsV1"

    private(set) var presets: [RulePreset]
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storageIsCorrupted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        guard let stored = defaults.object(forKey: Self.storageKey) else {
            presets = []
            errorMessage = nil
            return
        }

        do {
            guard let data = stored as? Data else { throw RulePresetStoreError.corruptedStorage }
            presets = try JSONDecoder().decode([RulePreset].self, from: data)
            errorMessage = nil
        } catch {
            presets = []
            errorMessage = "个人预设数据无法读取，原数据已保留：\(error.localizedDescription)"
            storageIsCorrupted = true
        }
    }

    @discardableResult
    func save(name: String, config: LinkConfig, replacing id: UUID? = nil) throws -> UUID {
        try ensureStorageIsWritable()

        let replacementIndex: Int?
        if let id {
            guard let index = presets.firstIndex(where: { $0.id == id }) else {
                throw RulePresetStoreError.unknownPreset
            }
            replacementIndex = index
        } else {
            replacementIndex = nil
        }

        let trimmedName = try validatedName(name, excluding: id)
        let validatedConfig = try validate(config)
        var updated = presets

        if let id, let replacementIndex {
            updated[replacementIndex] = RulePreset(id: id, name: trimmedName, config: validatedConfig)
            try persist(updated)
            return id
        }

        let newID = UUID()
        updated.append(RulePreset(id: newID, name: trimmedName, config: validatedConfig))
        try persist(updated)
        return newID
    }

    func rename(id: UUID, to name: String) throws {
        try ensureStorageIsWritable()
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw RulePresetStoreError.unknownPreset
        }
        let trimmedName = try validatedName(name, excluding: id)

        var updated = presets
        updated[index].name = trimmedName
        try persist(updated)
    }

    func remove(id: UUID) throws {
        try ensureStorageIsWritable()
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw RulePresetStoreError.unknownPreset
        }

        var updated = presets
        updated.remove(at: index)
        try persist(updated)
    }

    private func ensureStorageIsWritable() throws {
        guard !storageIsCorrupted else {
            throw RulePresetStoreError.corruptedStorage
        }
    }

    private func validatedName(_ name: String, excluding id: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RulePresetStoreError.emptyName
        }
        guard !presets.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            throw RulePresetStoreError.duplicateName(trimmed)
        }
        return trimmed
    }

    private func validate(_ config: LinkConfig) throws -> LinkConfig {
        switch ConfigDraft(config).validated() {
        case let .success(validated):
            return validated
        case let .failure(error):
            throw RulePresetStoreError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func persist(_ updated: [RulePreset]) throws {
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.storageKey)
            presets = updated
            errorMessage = nil
        } catch {
            let message = error.localizedDescription
            errorMessage = "保存个人预设失败：\(message)"
            throw RulePresetStoreError.persistenceFailed(message)
        }
    }
}
