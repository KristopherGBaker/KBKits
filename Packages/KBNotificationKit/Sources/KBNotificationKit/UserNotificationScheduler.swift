#if canImport(UserNotifications)
import Foundation
import UserNotifications

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
}

/// The production notification centre: a thin pass-through to `UNUserNotificationCenter`.
struct SystemNotificationCentre: NotificationCentre {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
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
}

/// The real thing.
public struct UserNotificationScheduler: NotificationScheduler {
    private let centre: any NotificationCentre

    public init() {
        self.centre = SystemNotificationCentre()
    }

    /// Injects a substitute centre. Internal, for tests: the production path uses `init()`.
    init(centre: any NotificationCentre) {
        self.centre = centre
    }

    public func authorization() async -> NotificationAuthorization {
        Self.authorization(from: await centre.authorizationStatus())
    }

    /// Maps the system's status onto ours. `ephemeral`, the App Clip grant, is treated as
    /// authorized because it delivers.
    static func authorization(from status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized: .authorized
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .ephemeral: .authorized
        @unknown default: .notDetermined
        }
    }

    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        await requestAuthorization(options: defaultAuthorizationOptions)
    }

    @discardableResult
    public func requestAuthorization(options: Set<NotificationAuthorizationOption>) async -> NotificationAuthorization {
        do {
            _ = try await centre.requestAuthorization(options: Self.systemOptions(from: options))
        } catch {
            return .denied
        }
        return await authorization()
    }

    /// Maps the package's authorisation categories onto the system's option set. The default set
    /// stays alert and sound; `.badge` is added only when a caller asks for it.
    static func systemOptions(from options: Set<NotificationAuthorizationOption>) -> UNAuthorizationOptions {
        var result: UNAuthorizationOptions = []
        if options.contains(.alert) { result.insert(.alert) }
        if options.contains(.sound) { result.insert(.sound) }
        if options.contains(.badge) { result.insert(.badge) }
        return result
    }

    /// Maps the package's interruption level onto the system's. Discriminating: each case maps to
    /// its own `UNNotificationInterruptionLevel`, so a time-sensitive request is not silently
    /// downgraded to active.
    static func systemInterruptionLevel(
        from level: NotificationInterruptionLevel
    ) -> UNNotificationInterruptionLevel {
        switch level {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        case .critical: .critical
        }
    }

    /// The inverse of `systemInterruptionLevel(from:)`, for reading a pending request back.
    static func interruptionLevel(
        from level: UNNotificationInterruptionLevel
    ) -> NotificationInterruptionLevel {
        switch level {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        case .critical: .critical
        @unknown default: .active
        }
    }

    /// The date components a wall-clock trigger is matched on: enough to pin a single moment to
    /// the second, so it survives a DST change or a time-zone move.
    private static let calendarComponents: Set<Calendar.Component> =
        [.year, .month, .day, .hour, .minute, .second]

    public func schedule(_ notification: LocalNotification) async throws {
        // An end that has already passed is not an error, it is a notification that should simply
        // not fire. This holds for both anchor kinds: a wall-clock moment in the past has no
        // future occurrence any more than a non-positive interval does.
        guard notification.deliverAt > Date() else {
            await cancel(id: notification.id)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.playsSound { content.sound = .default }
        if let badge = notification.badge { content.badge = NSNumber(value: badge) }
        if let thread = notification.threadIdentifier { content.threadIdentifier = thread }
        content.userInfo = Self.systemUserInfo(for: notification)
        content.interruptionLevel = Self.systemInterruptionLevel(from: notification.interruptionLevel)

        let trigger = Self.trigger(for: notification)

        // Adding a request with an existing identifier replaces it, so callers with one logical
        // timer never have to cancel before scheduling. A failure here is reported rather than
        // swallowed: the caller has to be able to learn the notification is not pending.
        do {
            try await centre.add(
                UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
            )
        } catch {
            throw NotificationSchedulingError.centreRejected(
                id: notification.id,
                reason: error.localizedDescription
            )
        }
    }

    /// The key an interval-anchored request carries its delivery moment under. Namespaced to keep
    /// it out of a caller's way, and stripped again when the request is read back.
    ///
    /// Namespacing makes a collision unlikely, not impossible, and the round-trip guarantee is not
    /// allowed an asterisk: a caller that puts its own value under this exact key gets that value
    /// back unchanged, because the stamp carries it (see `stamp(deliverAt:shadowing:)`).
    private static let deliverAtKey = "com.kristophergbaker.KBNotificationKit.deliverAt"

    /// The user info actually put on the content. An interval-anchored request also carries the
    /// delivery moment the caller asked for, written as a string so the dictionary stays a
    /// `[String: String]`.
    ///
    /// A `UNTimeIntervalNotificationTrigger` remembers only the original duration, which says
    /// nothing about when the request was added, so a readback has no way to recover the moment
    /// from the trigger alone. A wall-clock request needs no stamp: its trigger already names an
    /// absolute moment, so its user info is the caller's untouched.
    private static func systemUserInfo(for notification: LocalNotification) -> [String: String] {
        guard notification.deliveryAnchor == .interval else { return notification.userInfo }
        var info = notification.userInfo
        info[deliverAtKey] = stamp(
            deliverAt: notification.deliverAt,
            shadowing: notification.userInfo[deliverAtKey]
        )
        return info
    }

    /// The stamp written under `deliverAtKey`: a JSON array holding the delivery moment and, when
    /// the caller had its own value under that key, that value too.
    ///
    /// A caller's value travels INSIDE the stamp rather than under a second reserved key, because a
    /// second key would only move the collision one key along and invite the same bug again. One
    /// key is written, one key is read, and the caller's data is what comes back out.
    private static func stamp(deliverAt: Date, shadowing callerValue: String?) -> String {
        var fields = [String(deliverAt.timeIntervalSinceReferenceDate)]
        if let callerValue { fields.append(callerValue) }
        guard let data = try? JSONEncoder().encode(fields),
              let encoded = String(data: data, encoding: .utf8) else {
            // Unreachable for an array of strings, but a failure here must not lose the moment.
            return String(deliverAt.timeIntervalSinceReferenceDate)
        }
        return encoded
    }

    /// Takes the stamp out of a readback's user info, returning the moment it recorded and putting
    /// any shadowed caller value back under the reserved key.
    ///
    /// A bare number is accepted as well as the JSON form, because a request written by an older
    /// build carries the moment on its own. Anything else is treated as no stamp at all: the key is
    /// still removed, so nothing this adapter wrote for itself reaches a caller as one of its own.
    private static func takeStamp(from userInfo: inout [String: String]) -> Date? {
        guard let raw = userInfo.removeValue(forKey: deliverAtKey) else { return nil }
        guard let data = raw.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String].self, from: data),
              let moment = fields.first.flatMap(Double.init) else {
            return Double(raw).map(Date.init(timeIntervalSinceReferenceDate:))
        }
        if fields.count > 1 { userInfo[deliverAtKey] = fields[1] }
        return Date(timeIntervalSinceReferenceDate: moment)
    }

    /// Builds the trigger for a notification's anchor kind. An interval anchor captures the
    /// duration from now; a wall-clock anchor captures the date components of the moment, so it
    /// fires at that clock time rather than that many seconds from acceptance.
    private static func trigger(for notification: LocalNotification) -> sending UNNotificationTrigger {
        switch notification.deliveryAnchor {
        case .interval:
            UNTimeIntervalNotificationTrigger(
                timeInterval: notification.deliverAt.timeIntervalSinceNow,
                repeats: false
            )
        case .wallClock:
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(calendarComponents, from: notification.deliverAt),
                repeats: false
            )
        }
    }

    /// Reconstructs a `LocalNotification` from a pending request, the inverse of `schedule`'s
    /// mapping, so `pendingNotifications()` can show a caller what is scheduled. A calendar
    /// trigger reads back as a wall-clock anchor at the matched moment; an interval trigger reads
    /// back as an interval anchor at the moment it was scheduled to fire.
    ///
    /// The interval trigger's `timeInterval` is the original duration, measured from when the
    /// request was added, so rebuilding the moment as that duration from now would slide the
    /// reported delivery later by however long ago the scheduling happened: read the list ten
    /// minutes on and every interval notification would claim to be ten minutes further off than
    /// it is. The stamp written by `systemUserInfo(for:)` is the moment itself, so the readback is
    /// correct whenever it happens.
    static func notification(from request: UNNotificationRequest) -> LocalNotification {
        let content = request.content
        var userInfo = content.userInfo as? [String: String] ?? [:]
        let anchor: NotificationDeliveryAnchor
        let deliverAt: Date
        switch request.trigger {
        case let calendar as UNCalendarNotificationTrigger:
            // No stamp is written on this path, so nothing is taken off: whatever the caller put
            // in its user info, including a value under the reserved key, is what comes back.
            anchor = .wallClock
            deliverAt = Calendar.current.date(from: calendar.dateComponents) ?? Date()
        case let interval as UNTimeIntervalNotificationTrigger:
            anchor = .interval
            // Without a stamp the request came from somewhere other than this adapter, and the
            // trigger's own next fire date is the best answer available.
            deliverAt = Self.takeStamp(from: &userInfo)
                ?? interval.nextTriggerDate()
                ?? Date().addingTimeInterval(interval.timeInterval)
        default:
            anchor = .interval
            deliverAt = Self.takeStamp(from: &userInfo) ?? Date()
        }
        return LocalNotification(
            id: request.identifier,
            title: content.title,
            body: content.body,
            deliverAt: deliverAt,
            threadIdentifier: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
            playsSound: content.sound != nil,
            badge: content.badge?.intValue,
            userInfo: userInfo,
            interruptionLevel: interruptionLevel(from: content.interruptionLevel),
            deliveryAnchor: anchor
        )
    }

    public func cancel(id: String) async {
        await centre.removePending(withIdentifiers: [id])
        // Delivered ones too: a rest alert still sitting in Notification Centre after the next
        // set has started is worse than no alert.
        await centre.removeDelivered(withIdentifiers: [id])
    }

    public func cancelAll() async {
        await centre.removeAllPending()
    }

    public func clearDelivered() async {
        await centre.removeAllDelivered()
    }

    public func pendingIdentifiers() async -> [String] {
        await centre.pendingIdentifiers()
    }

    public func pendingNotifications() async -> [LocalNotification] {
        await centre.pendingNotifications()
    }
}
#endif
