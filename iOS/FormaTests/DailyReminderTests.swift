import XCTest
import UserNotifications
@testable import Forma

@MainActor
private final class ReminderCenterStub: DailyReminderCenter {
    var status: UNAuthorizationStatus = .authorized
    var permissionCalls = 0
    var addCalls = 0
    var pending: [String: DailyReminder] = [:]
    var delivered = Set<String>()
    var holdPermission = false
    var holdAdd = false
    var failAdd = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var addContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        permissionCalls += 1
        if holdPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        status = .authorized
        return true
    }

    func add(_ reminder: DailyReminder) async throws {
        addCalls += 1
        if holdAdd {
            holdAdd = false
            await withCheckedContinuation { addContinuation = $0 }
        }
        if failAdd { throw URLError(.unknown) }
        pending[DailyReminder.identifier] = reminder
    }

    func remove() {
        pending.removeValue(forKey: DailyReminder.identifier)
        delivered.remove(DailyReminder.identifier)
    }

    func allowPermission() {
        status = .authorized
        permissionContinuation?.resume(returning: true)
        permissionContinuation = nil
    }

    func completeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

final class DailyReminderTests: XCTestCase {
    @MainActor
    func testDefaultIsOffAndRefreshingDoesNotAskPermission() async {
        let defaults = temporaryDefaults()
        let center = ReminderCenterStub()
        center.status = .notDetermined
        let service = DailyReminderService(defaults: defaults, center: center)
        await service.refresh()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.hour, 20)
        XCTAssertEqual(service.minute, 0)
        XCTAssertEqual(center.permissionCalls, 0)
        XCTAssertEqual(center.addCalls, 0)
    }

    @MainActor
    func testEnablingRequestsPermissionAndTimeChangesReplaceOneRequest() async {
        let defaults = temporaryDefaults()
        let center = ReminderCenterStub()
        center.status = .notDetermined
        let service = DailyReminderService(defaults: defaults, center: center)
        await service.setEnabled(true)
        await service.setTime(hour: 7, minute: 15)
        await service.setTime(hour: 21, minute: 30)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(center.permissionCalls, 1)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending[DailyReminder.identifier]?.hour, 21)
        XCTAssertEqual(center.pending[DailyReminder.identifier]?.minute, 30)
        XCTAssertTrue(defaults.bool(forKey: "dailyReminderEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "dailyReminderHour"), 21)
        XCTAssertEqual(defaults.integer(forKey: "dailyReminderMinute"), 30)
    }

    @MainActor
    func testRevokedPermissionDisablesReminderWithoutAnotherPrompt() async {
        let defaults = temporaryDefaults()
        let center = ReminderCenterStub()
        let service = DailyReminderService(defaults: defaults, center: center)
        await service.setEnabled(true)
        center.status = .denied
        await service.refresh()
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.isPermissionDenied)
        XCTAssertFalse(defaults.bool(forKey: "dailyReminderEnabled"))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.permissionCalls, 0)
        XCTAssertNotNil(service.errorMessage)
    }

    @MainActor
    func testDisablingRemovesOnlyOwnedPendingAndDeliveredNotifications() async {
        let center = ReminderCenterStub()
        let unrelated = DailyReminder(hour: 1, minute: 0, title: "other", body: "other")
        center.pending["unrelated"] = unrelated
        center.delivered = [DailyReminder.identifier, "unrelated"]
        let service = DailyReminderService(defaults: temporaryDefaults(), center: center)
        await service.setEnabled(true)
        await service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(Set(center.pending.keys), ["unrelated"])
        XCTAssertEqual(center.delivered, ["unrelated"])
    }

    @MainActor
    func testDisablingWhilePermissionIsPendingCannotScheduleLater() async {
        let center = ReminderCenterStub()
        center.status = .notDetermined
        center.holdPermission = true
        let service = DailyReminderService(defaults: temporaryDefaults(), center: center)
        let enabling = Task { await service.setEnabled(true) }
        await waitUntil { center.permissionContinuation != nil }
        let disabling = Task { await service.setEnabled(false) }
        await waitUntil { !service.isEnabled }
        center.allowPermission()
        await enabling.value
        await disabling.value
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(center.addCalls, 0)
        XCTAssertTrue(center.pending.isEmpty)
    }

    @MainActor
    func testDisablingWhileAnAddIsPendingRemovesTheLateRequest() async {
        let center = ReminderCenterStub()
        center.holdAdd = true
        let service = DailyReminderService(defaults: temporaryDefaults(), center: center)
        let enabling = Task { await service.setEnabled(true) }
        await waitUntil { center.addContinuation != nil }
        let disabling = Task { await service.setEnabled(false) }
        await waitUntil { !service.isEnabled }
        center.completeAdd()
        await enabling.value
        await disabling.value
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(center.pending.isEmpty)
    }

    @MainActor
    func testLatestTimeWinsWhenThePreviousAddFinishesLate() async {
        let center = ReminderCenterStub()
        center.holdAdd = true
        let service = DailyReminderService(defaults: temporaryDefaults(), center: center)
        let enabling = Task { await service.setEnabled(true) }
        await waitUntil { center.addContinuation != nil }
        let changing = Task { await service.setTime(hour: 8, minute: 45) }
        await waitUntil { service.hour == 8 }
        center.completeAdd()
        await enabling.value
        await changing.value
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending[DailyReminder.identifier]?.hour, 8)
        XCTAssertEqual(center.pending[DailyReminder.identifier]?.minute, 45)
    }

    @MainActor
    func testSchedulingFailureDoesNotLeaveTheToggleEnabled() async {
        let defaults = temporaryDefaults()
        let center = ReminderCenterStub()
        center.failAdd = true
        let service = DailyReminderService(defaults: defaults, center: center)
        await service.setEnabled(true)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "dailyReminderEnabled"))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertNotNil(service.errorMessage)
    }

    func testRequestRepeatsDailyAtLocalTimeWithoutSoundOrFixedTimezone() throws {
        let reminder = DailyReminder(hour: 20, minute: 15, title: "pushx", body: "A little movement")
        let request = reminder.request
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, DailyReminder.identifier)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 20)
        XCTAssertEqual(trigger.dateComponents.minute, 15)
        XCTAssertNil(trigger.dateComponents.year)
        XCTAssertNil(trigger.dateComponents.month)
        XCTAssertNil(trigger.dateComponents.day)
        XCTAssertNil(trigger.dateComponents.timeZone)
        XCTAssertNil(trigger.dateComponents.calendar)
        XCTAssertNil(request.content.sound)
        XCTAssertNil(request.content.badge)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous reminder operation did not start", file: file, line: line)
    }

    private func temporaryDefaults() -> UserDefaults {
        let name = "pushx.reminder.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
