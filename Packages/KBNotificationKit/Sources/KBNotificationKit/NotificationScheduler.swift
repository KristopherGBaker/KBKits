public import Foundation

/// Why a notification could not be scheduled.
///
/// The package's whole reason to exist is that a caller learns when delivery could not be set
/// up, rather than believing a notification is pending when it is not. `schedule` reports this
/// instead of swallowing it.
public enum NotificationSchedulingError: Error, Sendable, Equatable, LocalizedError {
    /// The notification centre refused the request. `id` is the notification that failed and
    /// `reason` is the centre's own message, kept as text so the error stays `Equatable` and
    /// `Sendable` without dragging an arbitrary underlying error across the boundary.
    case centreRejected(id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .centreRejected(id, reason):
            "The notification centre could not schedule notification \"\(id)\": \(reason)"
        }
    }
}

/// How urgently the system should surface a notification.
///
/// A package-owned mirror of `UNNotificationInterruptionLevel`, kept separate for the same reason
/// `NotificationAuthorization` refuses to re-export the system enum: a caller should not have to
/// import UserNotifications to express intent, and the package controls its own surface.
///
/// Note that `timeSensitive` only breaks through Focus and Scheduled Summary when the consuming
/// app carries the `com.apple.developer.usernotifications.time-sensitive` entitlement. Whether an
/// app claims that entitlement is the app's decision; this type only lets it say so.
public enum NotificationInterruptionLevel: String, Sendable, Hashable, Codable, CaseIterable {
    /// Delivered quietly, without waking the screen or playing a sound.
    case passive
    /// The default: delivered normally, batched by Scheduled Summary and suppressed by Focus.
    case active
    /// Breaks through Focus and Scheduled Summary, for a notification whose timing is the point.
    case timeSensitive
    /// Breaks through even a ringer switched to silent. Needs the critical-alerts entitlement.
    case critical
}

/// Whether a notification's delivery moment is a duration from now or a point on the wall clock.
///
/// An elapsed duration is right for a countdown ("in four minutes"): it fires that far from the
/// moment the request is accepted. A wall-clock anchor is right for a reminder ("at 9pm"): it
/// fires at that clock time and survives a DST change or a flight across time zones, because it is
/// built from date components rather than a fixed number of seconds.
public enum NotificationDeliveryAnchor: String, Sendable, Hashable, Codable, CaseIterable {
    /// `deliverAt` is treated as an elapsed duration from the moment the request is accepted.
    case interval
    /// `deliverAt` is treated as a point on the wall clock, matched by its date components.
    case wallClock
}

/// A notification to deliver at a moment.
///
/// `id` is chosen by the caller rather than generated, and that is the whole ergonomics of this
/// package: scheduling the same id again REPLACES the pending one. An app with a single rest
/// timer can schedule it on every set without ever thinking about cancellation, because there is
/// only ever one notification with that id.
public struct LocalNotification: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var deliverAt: Date
    /// Groups notifications in Notification Centre. Nil leaves them ungrouped.
    public var threadIdentifier: String?
    public var playsSound: Bool
    /// Shown on the app icon. Nil leaves the badge alone, which is different from setting zero.
    public var badge: Int?
    /// Carried through to the tap handler, for deep-linking.
    public var userInfo: [String: String]
    /// How urgently the system should surface this. Defaults to `.active`, the pre-existing
    /// behaviour, so an upgrading caller is unaffected.
    public var interruptionLevel: NotificationInterruptionLevel
    /// Whether `deliverAt` is an elapsed duration or a wall-clock moment. Defaults to `.interval`,
    /// the pre-existing behaviour, so an upgrading caller is unaffected.
    public var deliveryAnchor: NotificationDeliveryAnchor

    public init(
        id: String,
        title: String,
        body: String,
        deliverAt: Date,
        threadIdentifier: String? = nil,
        playsSound: Bool = true,
        badge: Int? = nil,
        userInfo: [String: String] = [:],
        interruptionLevel: NotificationInterruptionLevel = .active,
        deliveryAnchor: NotificationDeliveryAnchor = .interval
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.deliverAt = deliverAt
        self.threadIdentifier = threadIdentifier
        self.playsSound = playsSound
        self.badge = badge
        self.userInfo = userInfo
        self.interruptionLevel = interruptionLevel
        self.deliveryAnchor = deliveryAnchor
    }
}

/// A category of notification permission an app can request.
///
/// A package-owned mirror of `UNAuthorizationOptions`, kept separate so a caller chooses what to
/// ask for without importing UserNotifications. `badge` is offered because an app whose content
/// IS the number on the icon needs it; a rest timer that would only litter the icon simply omits
/// it, which is why the default set is `[.alert, .sound]`.
public enum NotificationAuthorizationOption: String, Sendable, Hashable, Codable, CaseIterable {
    /// Permission to show an alert banner.
    case alert
    /// Permission to play a sound.
    case sound
    /// Permission to set the number on the app icon.
    case badge
}

/// The default authorisation set: alert and sound, the categories a rest timer needs.
///
/// Named so a caller can add to it (`defaultAuthorizationOptions.union([.badge])`) rather than
/// restating it, and so the default has one definition shared by the protocol and adapters.
public let defaultAuthorizationOptions: Set<NotificationAuthorizationOption> = [.alert, .sound]

/// What the user has agreed to.
///
/// Unlike Health, notification authorisation IS knowable, so this reports the truth rather than
/// a polite approximation. `provisional` is the quiet grant iOS gives when an app asks for it:
/// notifications arrive silently in Notification Centre until the user promotes them.
public enum NotificationAuthorization: String, Sendable, Hashable, Codable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    case provisional
    /// No notification centre on this platform.
    case unavailable

    /// Whether scheduling is worth attempting.
    public var allowsDelivery: Bool {
        self == .authorized || self == .provisional
    }
}

/// Where one notification switch stands in the system's settings.
///
/// A package-owned mirror of `UNNotificationSetting`, kept separate for the same reason as the
/// other mirrors here: a caller reads what the user allowed without importing UserNotifications.
public enum NotificationSettingState: String, Sendable, Hashable, Codable, CaseIterable {
    /// The user has this switch on.
    case enabled
    /// The user has turned this switch off, or never granted it.
    case disabled
    /// The switch does not apply to this app or this device.
    case notSupported

    /// Whether the system will honour this part of a notification.
    public var isEnabled: Bool {
        self == .enabled
    }
}

/// What the user has granted, switch by switch.
///
/// `NotificationAuthorization` answers whether anything is delivered at all. The user can still
/// turn alerts, sounds and the badge off one at a time in Settings while the app stays
/// `authorized`, so a caller that wants to know whether a sound will play, or whether a number on
/// the icon will be seen, reads the matching switch here.
public struct NotificationDeliverySettings: Sendable, Hashable {
    public var authorization: NotificationAuthorization
    /// Whether an alert banner is shown.
    public var alert: NotificationSettingState
    /// Whether a sound is played.
    public var sound: NotificationSettingState
    /// Whether the number on the app icon is set.
    public var badge: NotificationSettingState

    public init(
        authorization: NotificationAuthorization,
        alert: NotificationSettingState,
        sound: NotificationSettingState,
        badge: NotificationSettingState
    ) {
        self.authorization = authorization
        self.alert = alert
        self.sound = sound
        self.badge = badge
    }

    /// The settings a caller assumed before the switches could be read: every switch on when the
    /// authorisation delivers, every switch off when it does not.
    public init(assuming authorization: NotificationAuthorization) {
        let state: NotificationSettingState = authorization.allowsDelivery ? .enabled : .disabled
        self.init(authorization: authorization, alert: state, sound: state, badge: state)
    }
}

/// A notification the system has already delivered, still sitting in Notification Centre.
///
/// Two moments, because they differ: `notification.deliverAt` is the moment it was scheduled for,
/// read back exactly as `pendingNotifications()` reads a pending one, and `deliveredAt` is the
/// moment the system says it actually arrived.
public struct DeliveredNotification: Sendable, Hashable, Identifiable {
    public var notification: LocalNotification
    /// When the system delivered it.
    public var deliveredAt: Date

    /// The notification's own id, so a delivered copy and a pending one are matched by the same key.
    public var id: String { notification.id }

    public init(notification: LocalNotification, deliveredAt: Date) {
        self.notification = notification
        self.deliveredAt = deliveredAt
    }
}

/// Scheduling local notifications.
public protocol NotificationScheduler: Sendable {
    func authorization() async -> NotificationAuthorization

    /// What the user has granted, switch by switch, alongside the authorisation itself.
    ///
    /// An `authorized` app can still have its sound or badge switched off in Settings, so a caller
    /// that sets either one on every notification reads this first to learn whether it will land.
    func deliverySettings() async -> NotificationDeliverySettings

    /// Prompts, once, for the default authorisation set (alert and sound). Returns what the user
    /// chose; a refusal is an answer, not a failure.
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorization

    /// Prompts, once, for the given authorisation categories. Returns what the user chose; a
    /// refusal is an answer, not a failure.
    ///
    /// The categories are the caller's choice: a rest timer asks for alert and sound, while an app
    /// whose content is the number on its icon adds `.badge`. Requesting a category the app never
    /// intends to use is not harmful, but it does show up in the system prompt, so ask for what
    /// the app uses.
    @discardableResult
    func requestAuthorization(options: Set<NotificationAuthorizationOption>) async -> NotificationAuthorization

    /// Schedules a notification, replacing any pending one with the same id.
    ///
    /// Delivering in the past is not an error and not a delivery: a rest timer whose end has
    /// already passed by the time it is scheduled should simply not fire. This holds for a
    /// wall-clock anchor as well as an interval one.
    ///
    /// Throws `NotificationSchedulingError` when the notification centre refuses the request.
    /// A caller has to be able to learn that a notification it asked for is not pending;
    /// swallowing the failure would leave it believing it got a thing it did not get.
    func schedule(_ notification: LocalNotification) async throws

    func cancel(id: String) async
    func cancelAll() async

    /// Removes everything this app has already DELIVERED, clearing what is stacked up in
    /// Notification Centre.
    ///
    /// Pending and delivered are two different sets, and nothing else here touches the second one
    /// wholesale: `cancel(id:)` takes the delivered copy of the one id it cancels, and `cancelAll`
    /// is about the schedule. The case this covers is an app being opened to find a week of its
    /// own announcements still sitting on the lock screen, which it has no way to name one at a
    /// time and no reason to keep: the user is looking at the app itself.
    ///
    /// No identifier filter, because there is nothing to protect from one. Delivered notifications
    /// belong to the app that posted them, so this can only ever reach the caller's own.
    func clearDelivered() async

    /// The ids currently pending, for a caller that wants to reconcile rather than track. This is
    /// the cheaper call; reconcile paths should prefer it to `pendingNotifications()`.
    func pendingIdentifiers() async -> [String]

    /// The notifications currently pending, for a caller that wants to SHOW the user what is
    /// scheduled rather than only reconcile ids. A conformer that keeps no record of the full
    /// notifications may return an empty array; the schedulers shipped here return the real set.
    func pendingNotifications() async -> [LocalNotification]

    /// The notifications already delivered and still in Notification Centre, earliest
    /// `deliveredAt` first.
    ///
    /// This only reports: `clearDelivered()` is what removes them, and neither call touches the
    /// pending set. A caller that clears its delivered stack on coming to the foreground reads
    /// this first if it wants to say when a reminder arrived.
    func deliveredNotifications() async -> [DeliveredNotification]
}

public extension NotificationScheduler {
    /// Prompts for the given authorisation categories by delegating to the no-argument form.
    ///
    /// This default exists only so a type conforming to `NotificationScheduler` before this
    /// method existed keeps compiling: it ignores `options` and asks for whatever the no-argument
    /// call asks for. The schedulers shipped here override it and honour the categories.
    @discardableResult
    func requestAuthorization(options: Set<NotificationAuthorizationOption>) async -> NotificationAuthorization {
        await requestAuthorization()
    }

    /// Clears nothing by default.
    ///
    /// This default exists only so a type conforming to `NotificationScheduler` before this
    /// method existed keeps compiling. The schedulers shipped here override it.
    func clearDelivered() async {}

    /// Returns no pending notifications by default.
    ///
    /// This default exists only so a type conforming to `NotificationScheduler` before this
    /// method existed keeps compiling. The schedulers shipped here override it.
    func pendingNotifications() async -> [LocalNotification] { [] }

    /// Reports every switch as the authorisation implies: all on when it delivers, all off when it
    /// does not.
    ///
    /// This default exists only so a type conforming to `NotificationScheduler` before this
    /// method existed keeps compiling, and it reports what such a caller assumed. The schedulers
    /// shipped here override it.
    func deliverySettings() async -> NotificationDeliverySettings {
        NotificationDeliverySettings(assuming: await authorization())
    }

    /// Returns no delivered notifications by default.
    ///
    /// This default exists only so a type conforming to `NotificationScheduler` before this
    /// method existed keeps compiling. The schedulers shipped here override it.
    func deliveredNotifications() async -> [DeliveredNotification] { [] }

    /// Schedules only if the user has already agreed, without prompting.
    ///
    /// The prompt is a decision an app should make deliberately and at a moment the user
    /// understands, never as a side effect of a background action.
    func scheduleIfAllowed(_ notification: LocalNotification) async throws {
        guard await authorization().allowsDelivery else { return }
        try await schedule(notification)
    }
}
