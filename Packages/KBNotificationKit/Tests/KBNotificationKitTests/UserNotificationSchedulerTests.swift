#if canImport(UserNotifications)
import Foundation
import Testing
import UserNotifications

@testable import KBNotificationKit

private func notification(
    id: String = "rest",
    inSeconds: TimeInterval = 90
) -> LocalNotification {
    LocalNotification(id: id, title: "Rest over", body: "Back to it.", deliverAt: Date().addingTimeInterval(inSeconds))
}

@Suite("The production scheduler adapter")
struct UserNotificationSchedulerTests {
    @Test("the request carries the caller's id and a positive trigger interval")
    func identifierContract() async throws {
        // The identifier contract is the ergonomics of the package: the id the caller chose is
        // the id on the request, so scheduling the same id again replaces the pending one.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        try await scheduler.schedule(notification(id: "rest-timer", inSeconds: 120))

        #expect(await centre.addedIdentifiers == ["rest-timer"])
        let interval = try #require(await centre.addedIntervals.first)
        #expect(interval > 0)
        #expect(interval <= 120)
    }

    @Test("a centre rejection is reported as a NotificationSchedulingError, not swallowed")
    func errorMapping() async throws {
        // The invariant the package exists for. Before the fix the adapter ended in
        // `try? await center.add(...)` and could not throw, so a caller believed a
        // notification was pending when it was not.
        let rejection = NSError(domain: "UNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "no can do"])
        let centre = RecordingCentre(addError: rejection)
        let scheduler = UserNotificationScheduler(centre: centre)

        await #expect(throws: NotificationSchedulingError.self) {
            try await scheduler.schedule(notification())
        }

        do {
            try await scheduler.schedule(notification(id: "rest"))
            Issue.record("expected schedule to throw")
        } catch let error as NotificationSchedulingError {
            #expect(error == .centreRejected(id: "rest", reason: "no can do"))
            #expect(error.errorDescription?.contains("rest") == true)
        }
    }

    @Test("a past delivery date cancels rather than adding, and does not report a failure")
    func pastDeliveryCancels() async throws {
        // Matching the value type's rule: an end that has already passed is not an error and
        // not a delivery. It must not reach the centre's `add`, so it cannot be rejected.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        try await scheduler.schedule(notification(inSeconds: -30))

        #expect(await centre.addedIdentifiers.isEmpty)
        #expect(await centre.removedPending == ["rest"])
        #expect(await centre.removedDelivered == ["rest"])
    }

    @Test(
        "the system authorization status is mapped",
        arguments: [
            (UNAuthorizationStatus.authorized, NotificationAuthorization.authorized),
            (.provisional, .provisional),
            (.denied, .denied),
            (.notDetermined, .notDetermined)
        ]
    )
    func authorizationMapping(_ status: UNAuthorizationStatus, _ expected: NotificationAuthorization) async {
        // The mapping lives in the real adapter, which the fake never touched before. The
        // ephemeral App Clip grant also maps to authorized because it delivers, but that case
        // is unavailable on macOS so it cannot be constructed here; it is covered on iOS.
        let scheduler = UserNotificationScheduler(centre: RecordingCentre(status: status))
        #expect(await scheduler.authorization() == expected)
    }

    @Test("requesting authorization asks the centre and reports the resulting status")
    func requestAuthorizationPath() async {
        let centre = RecordingCentre(status: .notDetermined)
        let scheduler = UserNotificationScheduler(centre: centre)
        _ = await scheduler.requestAuthorization()
        #expect(await centre.authorizationRequests == 1)

        let authorized = UserNotificationScheduler(centre: RecordingCentre(status: .authorized))
        #expect(await authorized.requestAuthorization() == .authorized)
    }

    @Test("cancelling routes to the centre, delivered notifications included")
    func cancelling() async throws {
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        try await scheduler.schedule(notification(id: "a"))
        try await scheduler.schedule(notification(id: "b"))
        #expect(await scheduler.pendingIdentifiers() == ["a", "b"])

        await scheduler.cancel(id: "a")
        #expect(await centre.removedPending == ["a"])
        #expect(await centre.removedDelivered == ["a"])
        #expect(await scheduler.pendingIdentifiers() == ["b"])

        await scheduler.cancelAll()
        #expect(await centre.removeAllCount == 1)
        #expect(await scheduler.pendingIdentifiers().isEmpty)
    }

    @Test("clearing the delivered set leaves the schedule alone")
    func clearingDelivered() async throws {
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        try await scheduler.schedule(notification(id: "a"))
        try await scheduler.schedule(notification(id: "b"))

        await scheduler.clearDelivered()

        #expect(await centre.removeAllDeliveredCount == 1)
        // Pending and delivered are different sets. An app clearing its lock screen on being
        // opened must not lose the reminders it has lined up for the rest of the week.
        #expect(await scheduler.pendingIdentifiers() == ["a", "b"])
        #expect(await centre.removeAllCount == 0)
        #expect(await centre.removedPending.isEmpty)
    }

    @Test("the no-argument request asks the centre for exactly alert and sound")
    func defaultAuthorizationOptions() async {
        // The rest-timer default must survive the widening: no badge unless the caller asks.
        let centre = RecordingCentre(status: .notDetermined)
        let scheduler = UserNotificationScheduler(centre: centre)
        _ = await scheduler.requestAuthorization()

        #expect(await centre.requestedOptions == [[.alert, .sound]])
        #expect(await centre.requestedOptions.last?.contains(.badge) == false)
    }

    @Test("a caller can add badge to what the centre is asked for")
    func badgeAuthorizationOptions() async {
        let centre = RecordingCentre(status: .notDetermined)
        let scheduler = UserNotificationScheduler(centre: centre)
        _ = await scheduler.requestAuthorization(options: [.alert, .sound, .badge])

        #expect(await centre.requestedOptions == [[.alert, .sound, .badge]])
        #expect(await centre.requestedOptions.last?.contains(.badge) == true)
    }

    @Test("the interruption level reaches the content, and the two cases differ")
    func interruptionLevelReachesContent() async throws {
        // Assertion 4: a mapping that compiled but collapsed both cases to one level would fail
        // here, because the two contents are asserted to differ.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)

        var timeSensitive = notification(id: "urgent")
        timeSensitive.interruptionLevel = .timeSensitive
        var active = notification(id: "calm")
        active.interruptionLevel = .active
        try await scheduler.schedule(timeSensitive)
        try await scheduler.schedule(active)

        #expect(await centre.interruptionLevel(forId: "urgent") == .timeSensitive)
        #expect(await centre.interruptionLevel(forId: "calm") == .active)
        #expect(await centre.interruptionLevel(forId: "urgent") != centre.interruptionLevel(forId: "calm"))
    }

    @Test("the anchor kind chooses the trigger kind, and a calendar trigger matches the moment")
    func anchorKindChoosesTrigger() async throws {
        // Assertion 6: the two fixtures differ only in anchor kind. A change that made both
        // produce the same trigger kind would fail one of the first two expectations.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        let moment = Date().addingTimeInterval(3600)

        var interval = notification(id: "interval")
        interval.deliverAt = moment
        interval.deliveryAnchor = .interval
        var wallClock = notification(id: "wall")
        wallClock.deliverAt = moment
        wallClock.deliveryAnchor = .wallClock
        try await scheduler.schedule(interval)
        try await scheduler.schedule(wallClock)

        #expect(await centre.hasIntervalTrigger(forId: "interval"))
        #expect(await centre.hasCalendarTrigger(forId: "wall"))

        let components = try #require(await centre.calendarComponents(forId: "wall"))
        let expected = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
        #expect(components.year == expected.year)
        #expect(components.month == expected.month)
        #expect(components.day == expected.day)
        #expect(components.hour == expected.hour)
        #expect(components.minute == expected.minute)
    }

    @Test("a past wall-clock moment cancels rather than adding, like the interval case")
    func pastWallClockCancels() async throws {
        // Assertion 7 for the real adapter's calendar path: the documented rule is not specific
        // to interval anchoring.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        var past = notification(id: "review", inSeconds: -30)
        past.deliveryAnchor = .wallClock
        try await scheduler.schedule(past)

        #expect(await centre.addedIdentifiers.isEmpty)
        #expect(await centre.removedPending == ["review"])
        #expect(await centre.removedDelivered == ["review"])
        #expect(await scheduler.pendingNotifications().isEmpty)
    }

    @Test("every field round-trips through pendingNotifications, for both anchor kinds")
    func fieldsRoundTrip() async throws {
        // Assertion 9: the interval and calendar paths are different code, so a field dropped on
        // one would go unseen if only the other were covered.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)

        let intervalMoment = Date().addingTimeInterval(1800)
        let intervalNote = LocalNotification(
            id: "interval",
            title: "Interval title",
            body: "Interval body",
            deliverAt: intervalMoment,
            threadIdentifier: "thread-i",
            playsSound: true,
            badge: 7,
            userInfo: ["route": "review"],
            interruptionLevel: .timeSensitive,
            deliveryAnchor: .interval
        )

        let wallMoment = Date().addingTimeInterval(7200)
        let wallNote = LocalNotification(
            id: "wall",
            title: "Wall title",
            body: "Wall body",
            deliverAt: wallMoment,
            threadIdentifier: "thread-w",
            playsSound: false,
            badge: 3,
            userInfo: ["route": "cards"],
            interruptionLevel: .passive,
            deliveryAnchor: .wallClock
        )

        try await scheduler.schedule(intervalNote)
        try await scheduler.schedule(wallNote)

        let pending = await scheduler.pendingNotifications()
        let readInterval = try #require(pending.first { $0.id == "interval" })
        let readWall = try #require(pending.first { $0.id == "wall" })

        // Interval anchor: the delivery moment reconstructs to within a small tolerance because a
        // UNTimeIntervalNotificationTrigger stores a duration, not a wall-clock instant.
        #expect(readInterval.title == "Interval title")
        #expect(readInterval.body == "Interval body")
        #expect(readInterval.threadIdentifier == "thread-i")
        #expect(readInterval.playsSound == true)
        #expect(readInterval.badge == 7)
        #expect(readInterval.userInfo == ["route": "review"])
        #expect(readInterval.interruptionLevel == .timeSensitive)
        #expect(readInterval.deliveryAnchor == .interval)
        #expect(abs(readInterval.deliverAt.timeIntervalSince(intervalMoment)) < 5)

        // Wall-clock anchor: the delivery moment reconstructs to the second from date components.
        #expect(readWall.title == "Wall title")
        #expect(readWall.body == "Wall body")
        #expect(readWall.threadIdentifier == "thread-w")
        #expect(readWall.playsSound == false)
        #expect(readWall.badge == 3)
        #expect(readWall.userInfo == ["route": "cards"])
        #expect(readWall.interruptionLevel == .passive)
        #expect(readWall.deliveryAnchor == .wallClock)
        let readComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: readWall.deliverAt
        )
        let wallComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: wallMoment
        )
        #expect(readComponents == wallComponents)
    }

}

#endif
