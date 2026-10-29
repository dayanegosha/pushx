import Combine
import Foundation
import UserNotifications

struct DailyReminder: Equatable {
    static let identifier = "pushx.daily-reminder"
    let hour: Int
    let minute: Int
    let title: String
    let body: String

    var request: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        return UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
    }
}

@MainActor
protocol DailyReminderCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ reminder: DailyReminder) async throws
    func remove()
}

@MainActor
private final class SystemDailyReminderCenter: DailyReminderCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func add(_ reminder: DailyReminder) async throws {
        try await center.add(reminder.request)
    }

    func remove() {
        center.removePendingNotificationRequests(withIdentifiers: [DailyReminder.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [DailyReminder.identifier])
    }
}

@MainActor
final class DailyReminderService: ObservableObject {
    static let shared = DailyReminderService()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hour: Int
    @Published private(set) var minute: Int
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isBusy = false
    @Published private var errorKey: String?
    var errorMessage: String? { errorKey.map(L.text) }
    var isPermissionDenied: Bool { authorization == .denied }

    private let defaults: UserDefaults
    private let center: DailyReminderCenter
    private var revision = 0
    private var allowPermissionPrompt = false
    private var reconciliation: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, center: DailyReminderCenter? = nil) {
        self.defaults = defaults
        self.center = center ?? SystemDailyReminderCenter()
        isEnabled = defaults.bool(forKey: "dailyReminderEnabled")
        hour = min(23, max(0, defaults.object(forKey: "dailyReminderHour") as? Int ?? 20))
        minute = min(59, max(0, defaults.integer(forKey: "dailyReminderMinute")))
    }

    func setEnabled(_ enabled: Bool) async {
        revision += 1
        isEnabled = enabled
        defaults.set(enabled, forKey: "dailyReminderEnabled")
        allowPermissionPrompt = enabled
        errorKey = nil
        if !enabled { center.remove() }
        await reconcile()
    }

    func setTime(hour: Int, minute: Int) async {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        defaults.set(self.hour, forKey: "dailyReminderHour")
        defaults.set(self.minute, forKey: "dailyReminderMinute")
        revision += 1
        await reconcile()
    }

    func refresh() async {
        revision += 1
        await reconcile()
    }

    private func reconcile() async {
        if let reconciliation { await reconciliation.value; return }
        let task = Task { await runReconciliation() }
        reconciliation = task
        await task.value
    }

    private func runReconciliation() async {
        isBusy = true
        defer { isBusy = false; reconciliation = nil }
        while true {
            let token = revision
            let status = await center.authorizationStatus()
            guard token == revision else { continue }
            authorization = status
            if !isEnabled {
                allowPermissionPrompt = false
                center.remove()
            } else {
                if status == .notDetermined && allowPermissionPrompt {
                    allowPermissionPrompt = false
                    do { _ = try await center.requestAuthorization() }
                    catch {
                        guard token == revision else { continue }
                        disableAfterFailure(key: "reminder_error")
                        return
                    }
                    guard token == revision else { continue }
                    authorization = await center.authorizationStatus()
                    guard token == revision else { continue }
                }
                guard Self.canDeliver(authorization) else {
                    disableAfterFailure(key: authorization == .denied ? "reminder_denied" : "reminder_permission_needed")
                    return
                }
                do {
                    try await center.add(DailyReminder(hour: hour, minute: minute, title: L.text("reminder_notification_title"), body: L.text("reminder_notification_body")))
                    guard token == revision else { center.remove(); continue }
                    errorKey = nil
                } catch {
                    guard token == revision else { center.remove(); continue }
                    disableAfterFailure(key: "reminder_error")
                    return
                }
            }
            if token == revision { return }
        }
    }

    private func disableAfterFailure(key: String) {
        isEnabled = false
        allowPermissionPrompt = false
        defaults.set(false, forKey: "dailyReminderEnabled")
        center.remove()
        errorKey = key
    }

    private static func canDeliver(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}
