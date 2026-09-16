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
