#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// The parts of `UNNotificationSettings` the scheduler reads, copied out as system enums.
///
/// `UNNotificationSettings` is neither `Sendable` nor constructible outside the system, so it can
/// neither cross the seam nor be built by a test. This carries the status and the three switches
/// instead, and the mapping onto the package's own types stays in the scheduler.
struct CentreSettings: Sendable, Hashable {
    var authorizationStatus: UNAuthorizationStatus
    var alert: UNNotificationSetting
    var sound: UNNotificationSetting
    var badge: UNNotificationSetting
}

/// The `UNUserNotificationCenter` operations the scheduler needs.
///
/// Named for the role it plays, the notification centre, not for the fact that it is a seam.
/// It exists so the scheduler's real behaviour, the identifiers it puts on requests, the way
/// it maps a centre failure to a `NotificationSchedulingError`, and the way it maps a
/// `UNAuthorizationStatus` to a `NotificationAuthorization`, can be exercised without a device
/// or a permission prompt. `SystemNotificationCentre` is the production conformance; a test
/// substitutes its own.
protocol NotificationCentre: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// The status and the three switches, read together from one settings call.
    func notificationSettings() async -> CentreSettings
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    // `UNNotificationRequest` is not `Sendable`, so it crosses to a conformance that may be an
    // actor as `sending`: the scheduler builds a fresh request and hands off sole ownership.
    func add(_ request: sending UNNotificationRequest) async throws
    func removePending(withIdentifiers ids: [String]) async
    func removeDelivered(withIdentifiers ids: [String]) async
    func removeAllDelivered() async
    func removeAllPending() async
    func pendingIdentifiers() async -> [String]
    /// The pending notifications, reconstructed as the package's own value type. Returning
    /// `LocalNotification` rather than `UNNotificationRequest` keeps the seam `Sendable`: the
    /// request type is not, and the inverse mapping is the scheduler's, so a conformance runs it
    /// through `UserNotificationScheduler.notification(from:)`.
    func pendingNotifications() async -> [LocalNotification]
    /// The delivered notifications, for the same reason as `pendingNotifications()` returned as
    /// the package's own type: a conformance runs each `UNNotification` through
    /// `UserNotificationScheduler.delivered(from:)`. Order is not promised; the scheduler sorts.
    func deliveredNotifications() async -> [DeliveredNotification]
}

/// The production notification centre: a thin pass-through to `UNUserNotificationCenter`.
struct SystemNotificationCentre: NotificationCentre {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notificationSettings() async -> CentreSettings {
        let settings = await center.notificationSettings()
        return CentreSettings(
            authorizationStatus: settings.authorizationStatus,
            alert: settings.alertSetting,
            sound: settings.soundSetting,
            badge: settings.badgeSetting
        )
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: sending UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePending(withIdentifiers ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(withIdentifiers ids: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func removeAllDelivered() async {
        center.removeAllDeliveredNotifications()
    }

    func removeAllPending() async {
        center.removeAllPendingNotificationRequests()
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func pendingNotifications() async -> [LocalNotification] {
        await center.pendingNotificationRequests().map(UserNotificationScheduler.notification(from:))
    }

    func deliveredNotifications() async -> [DeliveredNotification] {
        await center.deliveredNotifications().map(UserNotificationScheduler.delivered(from:))
    }
}
#endif
