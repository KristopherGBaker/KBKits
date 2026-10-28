#if canImport(UserNotifications)
import Foundation
import UserNotifications

@testable import KBNotificationKit

/// A substitute notification centre, standing in for `UNUserNotificationCenter` so the real
/// `UserNotificationScheduler` adapter can be driven without a device or a permission prompt.
/// It records the identifiers and intervals it is handed, answers a configured authorization
/// status and set of switches, can be told to reject an `add` so the error mapping is reachable,
/// and can fire a pending request so the delivered readback is reachable too. A file of its own
/// because every adapter suite drives it.
actor RecordingCentre: NotificationCentre {
    var status: UNAuthorizationStatus
    var addError: (any Error)?
    private(set) var alertSwitch: UNNotificationSetting = .enabled
    private(set) var soundSwitch: UNNotificationSetting = .enabled
    private(set) var badgeSwitch: UNNotificationSetting = .enabled
    /// How many times `notificationSettings()` was read, so a test can tell one read from several.
    private(set) var settingsReads = 0
    private(set) var authorizationRequests = 0
    private(set) var requestedOptions: [UNAuthorizationOptions] = []
    private(set) var addedIdentifiers: [String] = []
    private(set) var addedIntervals: [TimeInterval] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []
    private(set) var removeAllCount = 0
    private(set) var removeAllDeliveredCount = 0
    // Keyed by identifier so that adding the same id replaces the pending request, matching the
    // real centre. Non-Sendable requests never leave the actor: the readbacks below return only
    // Sendable projections (`LocalNotification`, `DateComponents`, the interruption-level enum).
    private var requests: [String: UNNotificationRequest] = [:]
    // Fired requests with the system date each arrived at, deliberately left in the order
    // `deliver(id:at:)` was called, so the order a test sees is the adapter's own sort.
    private var delivered: [(request: UNNotificationRequest, date: Date)] = []

    init(status: UNAuthorizationStatus = .authorized, addError: (any Error)? = nil) {
        self.status = status
        self.addError = addError
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func notificationSettings() async -> CentreSettings {
        settingsReads += 1
        return CentreSettings(authorizationStatus: status, alert: alertSwitch, sound: soundSwitch, badge: badgeSwitch)
    }

    /// Sets the status and the three switches `notificationSettings()` answers with.
    func configure(
        status: UNAuthorizationStatus,
        alert: UNNotificationSetting,
        sound: UNNotificationSetting,
        badge: UNNotificationSetting
    ) {
        self.status = status
        alertSwitch = alert
        soundSwitch = sound
        badgeSwitch = badge
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests += 1
        requestedOptions.append(options)
        return status == .authorized || status == .provisional
    }

    func add(_ request: sending UNNotificationRequest) async throws {
        if let addError { throw addError }
        addedIdentifiers.append(request.identifier)
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
            addedIntervals.append(trigger.timeInterval)
        }
        requests[request.identifier] = request
    }

    /// Fires the pending request `id` at `date`, moving it from pending to delivered the way the
    /// system does. The request keeps the user info the adapter put on it, stamp included.
    func deliver(id: String, at date: Date) {
        guard let request = requests.removeValue(forKey: id) else { return }
        delivered.removeAll { $0.request.identifier == id }
        delivered.append((request, date))
    }

    func removePending(withIdentifiers ids: [String]) async {
        removedPending.append(contentsOf: ids)
        for id in ids { requests[id] = nil }
    }

    func removeDelivered(withIdentifiers ids: [String]) async {
        removedDelivered.append(contentsOf: ids)
        delivered.removeAll { ids.contains($0.request.identifier) }
    }

    func removeAllDelivered() async {
        removeAllDeliveredCount += 1
        delivered.removeAll()
    }

    func removeAllPending() async {
        removeAllCount += 1
        requests.removeAll()
    }

    func pendingIdentifiers() async -> [String] { requests.keys.sorted() }

    func pendingNotifications() async -> [LocalNotification] {
        requests.values.map(UserNotificationScheduler.notification(from:))
    }

    func deliveredNotifications() async -> [DeliveredNotification] {
        delivered.map { UserNotificationScheduler.delivered(request: $0.request, deliveredAt: $0.date) }
    }

    /// The user info actually put on a pending request's content, before any readback strips it,
    /// so a test can show the reserved stamp was there to be stripped.
    func systemUserInfoKeys(forId id: String) -> Set<String> {
        Set(requests[id]?.content.userInfo.keys.compactMap { $0 as? String } ?? [])
    }

    /// The system interruption level actually set on the content of a pending request, so a test
    /// can assert the mapping reached `UNMutableNotificationContent`, not just the readback.
    func interruptionLevel(forId id: String) -> UNNotificationInterruptionLevel? {
        requests[id]?.content.interruptionLevel
    }

    /// Whether the pending request for `id` carries a calendar trigger.
    func hasCalendarTrigger(forId id: String) -> Bool {
        requests[id]?.trigger is UNCalendarNotificationTrigger
    }

    /// Whether the pending request for `id` carries an interval trigger.
    func hasIntervalTrigger(forId id: String) -> Bool {
        requests[id]?.trigger is UNTimeIntervalNotificationTrigger
    }

    /// The date components matched by the pending request's calendar trigger, if it has one.
    func calendarComponents(forId id: String) -> DateComponents? {
        (requests[id]?.trigger as? UNCalendarNotificationTrigger)?.dateComponents
    }
}
#endif
