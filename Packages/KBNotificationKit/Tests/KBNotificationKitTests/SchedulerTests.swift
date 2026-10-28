import Foundation
import Testing
@testable import KBNotificationKit

private func notification(
    id: String = "rest",
    inSeconds: TimeInterval = 90,
    title: String = "Rest over"
) -> LocalNotification {
    LocalNotification(
        id: id,
        title: title,
        body: "Back to it.",
        deliverAt: Date().addingTimeInterval(inSeconds)
    )
}

@Suite("Notification scheduling")
struct SchedulerTests {
    @Test("Scheduling the same id replaces the pending one rather than stacking")
    func sameIdReplaces() async throws {
        // The whole ergonomics of the package: one logical timer means one id, and a caller
        // never has to cancel before scheduling.
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(title: "First"))
        await scheduler.schedule(notification(title: "Second"))

        #expect(await scheduler.pendingIdentifiers() == ["rest"])
        #expect(await scheduler.pending["rest"]?.title == "Second")
        #expect(await scheduler.scheduled.count == 2)
    }

    @Test("A delivery date in the past schedules nothing")
    func pastDeliveryIsNotAnError() async throws {
        // A rest timer whose end has already passed should simply not fire; treating it as an
        // error would make every late save a failure.
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(inSeconds: -30))
        #expect(await scheduler.pendingIdentifiers().isEmpty)
    }

    @Test("Cancelling removes it; cancelling everything empties the list")
    func cancelling() async throws {
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "a"))
        await scheduler.schedule(notification(id: "b"))
        await scheduler.cancel(id: "a")
        #expect(await scheduler.pendingIdentifiers() == ["b"])

        await scheduler.cancelAll()
        #expect(await scheduler.pendingIdentifiers().isEmpty)
    }

    @Test("The stub records a delivered clear and keeps the schedule")
    func clearingDelivered() async throws {
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "a"))

        await scheduler.clearDelivered()

        #expect(await scheduler.deliveredClears == 1)
        // The two sets are separate here for the same reason they are separate on the real centre:
        // a caller that clears its lock screen has not cancelled anything.
        #expect(await scheduler.pendingIdentifiers() == ["a"])
        #expect(await scheduler.cancelled.isEmpty)
    }

    @Test("scheduleIfAllowed stays silent without permission, and never prompts")
    func scheduleIfAllowed() async throws {
        // The prompt is a decision an app makes deliberately, at a moment the user understands,
        // never as a side effect of a background action.
        let denied = StubNotificationScheduler(status: .denied)
        try await denied.scheduleIfAllowed(notification())
        #expect(await denied.pendingIdentifiers().isEmpty)
        #expect(await denied.authorizationRequests == 0)

        let undetermined = StubNotificationScheduler(status: .notDetermined)
        try await undetermined.scheduleIfAllowed(notification())
        #expect(await undetermined.pendingIdentifiers().isEmpty)
        #expect(await undetermined.authorizationRequests == 0)

        let allowed = StubNotificationScheduler(status: .authorized)
        try await allowed.scheduleIfAllowed(notification())
        #expect(await allowed.pendingIdentifiers() == ["rest"])
    }

    @Test("A provisional grant still delivers")
    func provisionalDelivers() async throws {
        #expect(NotificationAuthorization.provisional.allowsDelivery)
        #expect(NotificationAuthorization.authorized.allowsDelivery)
        #expect(NotificationAuthorization.denied.allowsDelivery == false)
        #expect(NotificationAuthorization.notDetermined.allowsDelivery == false)

        let scheduler = StubNotificationScheduler(status: .provisional)
        try await scheduler.scheduleIfAllowed(notification())
        #expect(await scheduler.pendingIdentifiers() == ["rest"])
    }

    @Test("Asking moves an undetermined status forward; a denial is left alone")
    func requestingAuthorization() async throws {
        let fresh = StubNotificationScheduler(status: .notDetermined)
        #expect(await fresh.requestAuthorization() == .authorized)
        #expect(await fresh.authorizationRequests == 1)

        let denied = StubNotificationScheduler(status: .denied)
        #expect(await denied.requestAuthorization() == .denied)
    }

    @Test("The no-argument request asks for exactly alert and sound")
    func defaultAuthorizationOptionSet() async throws {
        // The rest-timer default must not change when a caller upgrades: no badge unless asked.
        let scheduler = StubNotificationScheduler(status: .notDetermined)
        _ = await scheduler.requestAuthorization()
        #expect(await scheduler.requestedOptions == [[.alert, .sound]])
        #expect(await scheduler.requestedOptions.last == defaultAuthorizationOptions)
        #expect(await scheduler.requestedOptions.last?.contains(.badge) == false)
    }

    @Test("A caller can add badge to the requested options")
    func badgeAuthorizationOptionSet() async throws {
        // The spaced-repetition consumer: the number on the icon IS the content, so it asks.
        let scheduler = StubNotificationScheduler(status: .notDetermined)
        _ = await scheduler.requestAuthorization(options: [.alert, .sound, .badge])
        #expect(await scheduler.requestedOptions == [[.alert, .sound, .badge]])
        #expect(await scheduler.requestedOptions.last?.contains(.badge) == true)
    }

    @Test("pendingNotifications returns the whole notification, not just the id")
    func pendingNotificationsExposeContent() async throws {
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "b", title: "Second"))
        await scheduler.schedule(notification(id: "a", title: "First"))

        let pending = await scheduler.pendingNotifications()
        #expect(pending.map(\.id) == ["a", "b"])
        #expect(pending.first?.title == "First")
        // The cheaper reconcile call still works and agrees.
        #expect(await scheduler.pendingIdentifiers() == ["a", "b"])
    }

    @Test("A wall-clock delivery moment in the past schedules nothing and clears its id")
    func pastWallClockIsNotAnError() async throws {
        // Assertion 7 for the stub: the past-moment rule is not specific to interval anchoring.
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "review", inSeconds: 60))
        #expect(await scheduler.pendingIdentifiers() == ["review"])

        var past = notification(id: "review", inSeconds: -60)
        past.deliveryAnchor = .wallClock
        await scheduler.schedule(past)
        #expect(await scheduler.pendingIdentifiers().isEmpty)
        #expect(await scheduler.pendingNotifications().isEmpty)
    }

    @Test("The interruption level and anchor default to today's behaviour")
    func newFieldsDefault() async throws {
        let note = notification()
        #expect(note.interruptionLevel == .active)
        #expect(note.deliveryAnchor == .interval)
    }
}

/// The per-switch settings and the delivered set, on the value types and the stub. A suite of its
/// own so neither type outgrows the house body-length limit.
@Suite("Delivery settings and the delivered set")
struct DeliveryTests {
    @Test(
        "Assuming an authorisation turns every switch on only when it delivers",
        arguments: NotificationAuthorization.allCases
    )
    func assumingAuthorization(_ authorization: NotificationAuthorization) {
        let settings = NotificationDeliverySettings(assuming: authorization)
        let expected: NotificationSettingState = authorization.allowsDelivery ? .enabled : .disabled
        #expect(settings.authorization == authorization)
        #expect(settings.alert == expected)
        #expect(settings.sound == expected)
        #expect(settings.badge == expected)
    }

    @Test("Only an allowed authorisation is assumed to enable the switches")
    func assumingNamedCases() {
        // Spelled out per case as well, so a change to `allowsDelivery` cannot carry the test above
        // along with it unnoticed.
        for allowed in [NotificationAuthorization.authorized, .provisional] {
            let settings = NotificationDeliverySettings(assuming: allowed)
            #expect([settings.alert, settings.sound, settings.badge] == [.enabled, .enabled, .enabled])
        }
        for refused in [NotificationAuthorization.denied, .notDetermined, .unavailable] {
            let settings = NotificationDeliverySettings(assuming: refused)
            #expect([settings.alert, settings.sound, settings.badge] == [.disabled, .disabled, .disabled])
        }
    }

    @Test("Only an enabled switch is enabled")
    func isEnabled() {
        #expect(NotificationSettingState.enabled.isEnabled)
        #expect(NotificationSettingState.disabled.isEnabled == false)
        #expect(NotificationSettingState.notSupported.isEnabled == false)
    }

    @Test("The stub's switches follow its status until they are set, then stay set")
    func stubSwitches() async {
        let denied = StubNotificationScheduler(status: .denied)
        #expect(await denied.deliverySettings() == NotificationDeliverySettings(assuming: .denied))

        let fresh = StubNotificationScheduler(status: .notDetermined)
        await fresh.requestAuthorization()
        #expect(await fresh.deliverySettings() == NotificationDeliverySettings(assuming: .authorized))

        let scheduler = StubNotificationScheduler()
        await scheduler.setStatus(.denied)
        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(assuming: .denied))
        await scheduler.setStatus(.provisional)
        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(assuming: .provisional))

        await scheduler.setSwitches(alert: .enabled, sound: .disabled, badge: .notSupported)
        #expect(await scheduler.authorization() == .provisional)
        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(
            authorization: .provisional, alert: .enabled, sound: .disabled, badge: .notSupported
        ))

        // A later status change is a different fact from a switch the user turned off.
        await scheduler.setStatus(.denied)
        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(
            authorization: .denied, alert: .enabled, sound: .disabled, badge: .notSupported
        ))
    }

    @Test("Delivering moves a pending notification into the delivered set, and nothing else does")
    func stubDeliver() async throws {
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "a"))
        await scheduler.schedule(notification(id: "b"))
        let scheduledA = try #require(await scheduler.pending["a"])
        let moment = Date()

        #expect(await scheduler.deliver(id: "a", at: moment))
        #expect(await scheduler.pendingIdentifiers() == ["b"])
        #expect(await scheduler.deliveredNotifications() == [
            DeliveredNotification(notification: scheduledA, deliveredAt: moment)
        ])

        // Nothing pending under the id: no change, whether it never existed or already fired.
        for id in ["missing", "a"] {
            #expect(await scheduler.deliver(id: id, at: moment) == false)
            #expect(await scheduler.pendingIdentifiers() == ["b"])
            #expect(await scheduler.delivered.map(\.id) == ["a"])
        }

        await scheduler.deliver(id: "b", at: moment.addingTimeInterval(-60))
        #expect(await scheduler.deliveredNotifications().map(\.id) == ["b", "a"])
    }

    @Test("Delivering an id again replaces its earlier delivered copy")
    func stubDeliverReplaces() async throws {
        let scheduler = StubNotificationScheduler()
        let first = Date()
        let second = first.addingTimeInterval(120)
        await scheduler.schedule(notification(id: "a", title: "v1"))
        await scheduler.deliver(id: "a", at: first)
        await scheduler.schedule(notification(id: "a", title: "v2"))
        await scheduler.deliver(id: "a", at: second)

        let delivered = await scheduler.delivered
        #expect(delivered.count == 1)
        #expect(delivered.first?.notification.title == "v2")
        #expect(delivered.first?.deliveredAt == second)
    }

    @Test("Clearing the delivered set empties it, counts the call and keeps the schedule")
    func stubClearDelivered() async throws {
        let scheduler = StubNotificationScheduler()
        await scheduler.schedule(notification(id: "a"))
        await scheduler.schedule(notification(id: "b"))
        await scheduler.deliver(id: "a", at: Date())
        #expect(await scheduler.delivered.isEmpty == false)
        let clearsBefore = await scheduler.deliveredClears

        await scheduler.clearDelivered()

        #expect(await scheduler.delivered.isEmpty)
        #expect(await scheduler.deliveredNotifications().isEmpty)
        #expect(await scheduler.deliveredClears == clearsBefore + 1)
        #expect(await scheduler.pendingIdentifiers() == ["b"])
    }

    @Test("Cancelling an id takes its delivered copy; cancelling everything does not")
    func stubCancelDelivered() async throws {
        let scheduler = StubNotificationScheduler()
        for id in ["a", "b"] {
            await scheduler.schedule(notification(id: id))
            await scheduler.deliver(id: id, at: Date())
        }

        await scheduler.cancel(id: "a")
        #expect(await scheduler.delivered.map(\.id) == ["b"])
        #expect(await scheduler.cancelled == ["a"])

        await scheduler.schedule(notification(id: "c"))
        await scheduler.cancelAll()
        #expect(await scheduler.delivered.map(\.id) == ["b"])
        #expect(await scheduler.pendingIdentifiers().isEmpty)
    }
}
