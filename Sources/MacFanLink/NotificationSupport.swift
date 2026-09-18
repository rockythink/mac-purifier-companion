import AppKit
import Foundation
import UserNotifications

nonisolated enum MonitorAlertCondition: String, CaseIterable, Sendable {
    case thermal
    case sensorUnavailable
    case deviceOffline
    case memoryPressure

    var title: String {
        switch self {
        case .thermal: "Mac 散热状态持续异常"
        case .sensorUnavailable: "温度传感器持续不可用"
        case .deviceOffline: "已配对净化器持续离线"
        case .memoryPressure: "内存压力持续处于严重状态"
        }
    }

    var body: String {
        switch self {
        case .thermal: "系统散热状态已持续达到严重或危急级别，请检查当前负载与通风。"
        case .sensorUnavailable: "应用已持续无法取得温度样本，联动可能无法依据温度工作。"
        case .deviceOffline: "已配对的净化器持续不可达，请检查设备电源与本地网络。"
        case .memoryPressure: "系统内存压力已持续处于严重级别，请检查占用较高的应用。"
        }
    }
}

nonisolated struct MonitorAlertSample: Sendable {
    var thermalState: String?
    var memoryPressure: String?
    var temperatureAvailable: Bool
    var devicePaired: Bool
    var deviceReachable: Bool
    var heatDataConnected: Bool
    var systemDataFresh: Bool
}

nonisolated struct SustainedAlertPolicy: Sendable {
    private struct ConditionState: Sendable {
        var startedAt: TimeInterval?
        var lastObservedAt: TimeInterval?
        var notifiedInEpisode = false
        var lastNotificationAt: TimeInterval?
    }

    private var states = Dictionary(uniqueKeysWithValues: MonitorAlertCondition.allCases.map { ($0, ConditionState()) })

    private let maximumGap: TimeInterval
    private let cooldown: TimeInterval

    init(maximumGap: TimeInterval = 30, cooldown: TimeInterval = 600) {
        self.maximumGap = maximumGap
        self.cooldown = cooldown
    }

    mutating func evaluate(_ sample: MonitorAlertSample, at now: TimeInterval) -> [MonitorAlertCondition] {
        var fired: [MonitorAlertCondition] = []
        update(.thermal, abnormal: sample.heatDataConnected && sample.systemDataFresh && ["serious", "critical"].contains(sample.thermalState), duration: 60, at: now, fired: &fired)
        update(.sensorUnavailable, abnormal: !sample.temperatureAvailable, duration: 180, at: now, fired: &fired)
        update(.deviceOffline, abnormal: sample.devicePaired && !sample.deviceReachable, duration: 60, at: now, fired: &fired)
        update(.memoryPressure, abnormal: sample.systemDataFresh && sample.memoryPressure == "critical", duration: 60, at: now, fired: &fired)
        return fired
    }

    mutating func reset() {
        states = Dictionary(uniqueKeysWithValues: MonitorAlertCondition.allCases.map { ($0, ConditionState()) })
    }

    private mutating func update(
        _ condition: MonitorAlertCondition,
        abnormal: Bool,
        duration: TimeInterval,
        at now: TimeInterval,
        fired: inout [MonitorAlertCondition]
    ) {
        guard var state = states[condition] else { return }
        defer { states[condition] = state }

        guard abnormal else {
            state.startedAt = nil
            state.lastObservedAt = now
            state.notifiedInEpisode = false
            return
        }

        if let last = state.lastObservedAt, now < last || now - last > maximumGap {
            state.startedAt = now
            state.notifiedInEpisode = false
        } else if state.startedAt == nil {
            state.startedAt = now
        }
        state.lastObservedAt = now

        guard !state.notifiedInEpisode,
              let startedAt = state.startedAt,
              now - startedAt >= duration,
              state.lastNotificationAt.map({ now - $0 >= cooldown }) ?? true
        else { return }

        state.notifiedInEpisode = true
        state.lastNotificationAt = now
        fired.append(condition)
    }
}

@MainActor
final class NotificationSupport: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationSupport()

    private enum DefaultsKey {
        static let enabled = "monitoringNotificationsEnabled"
    }

    private let center = UNUserNotificationCenter.current()
    private(set) var enabled: Bool
    private(set) var statusMessage = "通知默认关闭。启用后，仅在异常持续一段时间时提醒。"
    private var policy = SustainedAlertPolicy()
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Mac 净化器伴侣"

    private override init() {
        enabled = UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        applyAuthorization(settings.authorizationStatus)
    }

    func setEnabled(_ requested: Bool) async {
        guard requested else {
            enabled = false
            UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
            policy.reset()
            statusMessage = "通知已关闭；尚未结束的异常提醒已重置。"
            return
        }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                if granted {
                    persistEnabled()
                } else {
                    deny()
                }
            } catch {
                enabled = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
                statusMessage = "无法请求通知权限，请在“系统设置 > 通知 > \(appName)”中检查权限。"
            }
        case .authorized, .provisional:
            persistEnabled()
        case .denied:
            deny()
        @unknown default:
            deny()
        }
    }

    func consume(_ sample: MonitorAlertSample, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        for condition in policy.evaluate(sample, at: now) {
            deliver(condition)
        }
    }

    func resetEpisodes() {
        policy.reset()
    }

    func sendTestNotification() async {
        guard enabled else {
            statusMessage = "请先启用通知，再发送测试提醒。"
            return
        }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            deny()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(appName) 通知测试"
        content.body = "通知已启用。只有持续异常才会触发正式提醒。"
        do {
            try await center.add(UNNotificationRequest(identifier: "monitor-test-\(UUID().uuidString)", content: content, trigger: nil))
            statusMessage = "测试提醒已提交给系统；实际显示取决于通知横幅和专注模式设置。"
        } catch {
            statusMessage = "测试提醒未能提交，请在系统设置中检查通知权限。"
        }
    }

    private func applyAuthorization(_ authorization: UNAuthorizationStatus) {
        switch authorization {
        case .authorized, .provisional:
            if enabled { statusMessage = "通知已启用，仅提醒持续异常。" }
            else { statusMessage = "系统已允许通知；应用内通知仍保持关闭。" }
        case .denied:
            if enabled {
                enabled = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
                policy.reset()
            }
            statusMessage = "通知权限已拒绝，请在“系统设置 > 通知 > \(appName)”中开启。"
        case .notDetermined:
            if enabled {
                enabled = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
                policy.reset()
            }
            statusMessage = "通知默认关闭；启用时才会请求系统权限。"
        @unknown default:
            deny()
        }
    }

    private func persistEnabled() {
        enabled = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.enabled)
        statusMessage = "通知已启用，仅提醒持续异常。"
    }

    private func deny() {
        enabled = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
        policy.reset()
        statusMessage = "通知权限已拒绝，请在“系统设置 > 通知 > \(appName)”中开启。"
    }

    private func deliver(_ condition: MonitorAlertCondition) {
        deliver(title: condition.title, body: condition.body, identifier: "monitor-\(condition.rawValue)-\(UUID().uuidString)")
    }

    private func deliver(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.statusMessage = "通知未能送达，请在系统设置中检查通知权限。"
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
