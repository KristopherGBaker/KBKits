public import Foundation

/// A `NotificationScheduler` that records what it was asked to do.
///
/// Public, like the other Kits' fakes: scheduling logic is worth testing and a real notification
/// centre cannot be driven from a test.
public actor StubNotificationScheduler: NotificationScheduler {
    /// Everything currently pending, by id.
    public private(set) var pending: [String: LocalNotification] = [:]
    /// Every schedule call in order, including ones that replaced an earlier notification.
    public private(set) var scheduled: [LocalNotification] = []
    public private(set) var cancelled: [String] = []
    /// What has been delivered and not yet cleared or cancelled, one entry per id, in the order
    /// `deliver(id:at:)` put them there. Nothing arrives here on its own: a test says when a
    /// pending notification fires.
    public private(set) var delivered: [DeliveredNotification] = []
    /// How many times the delivered set was cleared. A count rather than a list, because the call
    /// names nothing: it takes no identifiers, and what it removed is gone from `delivered`.
    public private(set) var deliveredClears = 0
    public private(set) var authorizationRequests = 0
    /// The authorisation categories requested, in order, one entry per `requestAuthorization`
    /// call. A no-argument call records `defaultAuthorizationOptions`.
    public private(set) var requestedOptions: [Set<NotificationAuthorizationOption>] = []

    private var status: NotificationAuthorization
    /// The switches fixed by `setSwitches`, or nil to report what `status` implies. Its own
    /// `authorization` is never read: the current `status` always stands in for it.
    private var fixedSwitches: NotificationDeliverySettings?

    public init(status: NotificationAuthorization = .authorized) {
        self.status = status
    }

    public func authorization() async -> NotificationAuthorization { status }

    /// What `status` implies, until `setSwitches` fixes the three switches. The authorisation is
    /// always the current status, so a test can refuse delivery without touching the switches.
    public func deliverySettings() async -> NotificationDeliverySettings {
        guard var settings = fixedSwitches else { return NotificationDeliverySettings(assuming: status) }
        settings.authorization = status
        return settings
    }

    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        await requestAuthorization(options: defaultAuthorizationOptions)
    }

    @discardableResult
    public func requestAuthorization(options: Set<NotificationAuthorizationOption>) async -> NotificationAuthorization {
        authorizationRequests += 1
        requestedOptions.append(options)
        if status == .notDetermined { status = .authorized }
        return status
    }

    public func schedule(_ notification: LocalNotification) async {
        scheduled.append(notification)
        // Matching the real centre: a delivery moment already in the past schedules nothing and
        // removes any pending notification with the same id. This holds for both anchor kinds,
        // because a wall-clock moment in the past has no future occurrence either.
        guard notification.deliverAt > Date() else {
            pending[notification.id] = nil
            return
        }
        pending[notification.id] = notification
    }

    /// Fires the pending notification `id` at `moment`, the way the system does: it leaves the
    /// pending set and joins the delivered one, replacing any earlier delivered copy of the same
    /// id. Returns false, and changes nothing, when nothing with that id is pending.
    @discardableResult
    public func deliver(id: String, at moment: Date) -> Bool {
        guard let notification = pending.removeValue(forKey: id) else { return false }
        delivered.removeAll { $0.id == id }
        delivered.append(DeliveredNotification(notification: notification, deliveredAt: moment))
        return true
    }

    /// Removes the pending notification and its delivered copy, as the real adapter does.
    public func cancel(id: String) async {
        cancelled.append(id)
        pending[id] = nil
        delivered.removeAll { $0.id == id }
    }

    /// Empties the schedule and leaves the delivered set alone, as the real adapter does.
    public func cancelAll() async {
        cancelled.append(contentsOf: pending.keys)
        pending.removeAll()
    }

    /// Empties the delivered set and counts the call. The pending set is left alone, which is the
    /// real behaviour: delivered and pending are different sets, and clearing the first schedules
    /// and unschedules nothing.
    public func clearDelivered() async {
        deliveredClears += 1
        delivered.removeAll()
    }

    public func pendingIdentifiers() async -> [String] {
        pending.keys.sorted()
    }

    public func pendingNotifications() async -> [LocalNotification] {
        pending.values.sorted { $0.id < $1.id }
    }

    public func deliveredNotifications() async -> [DeliveredNotification] {
        delivered.sorted { $0.deliveredAt < $1.deliveredAt }
    }

    public func setStatus(_ status: NotificationAuthorization) {
        self.status = status
    }

    /// Fixes the three switches `deliverySettings()` reports, without changing the status. Later
    /// `setStatus` calls leave them as set, the way Settings keeps a switch the user turned off.
    public func setSwitches(
        alert: NotificationSettingState,
        sound: NotificationSettingState,
        badge: NotificationSettingState
    ) {
        fixedSwitches = NotificationDeliverySettings(authorization: status, alert: alert, sound: sound, badge: badge)
    }
}
