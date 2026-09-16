import Foundation

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
    public private(set) var authorizationRequests = 0
    /// The authorisation categories requested, in order, one entry per `requestAuthorization`
    /// call. A no-argument call records `defaultAuthorizationOptions`.
    public private(set) var requestedOptions: [Set<NotificationAuthorizationOption>] = []

    private var status: NotificationAuthorization

    public init(status: NotificationAuthorization = .authorized) {
        self.status = status
    }

    public func authorization() async -> NotificationAuthorization { status }

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

    public func cancel(id: String) async {
        cancelled.append(id)
        pending[id] = nil
    }

    public func cancelAll() async {
        cancelled.append(contentsOf: pending.keys)
        pending.removeAll()
    }

    public func pendingIdentifiers() async -> [String] {
        pending.keys.sorted()
    }

    public func pendingNotifications() async -> [LocalNotification] {
        pending.values.sorted { $0.id < $1.id }
    }

    public func setStatus(_ status: NotificationAuthorization) {
        self.status = status
    }
}
