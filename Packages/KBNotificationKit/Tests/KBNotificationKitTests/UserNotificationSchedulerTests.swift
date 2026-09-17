#if canImport(UserNotifications)
import Foundation
import Testing
import UserNotifications

@testable import KBNotificationKit

/// A substitute notification centre, standing in for `UNUserNotificationCenter` so the real
/// `UserNotificationScheduler` adapter can be driven without a device or a permission prompt.
/// It records the identifiers and intervals it is handed, answers a configured authorization
/// status, and can be told to reject an `add` so the error mapping is reachable.
private actor RecordingCentre: NotificationCentre {
    var status: UNAuthorizationStatus
    var addError: (any Error)?
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

    init(status: UNAuthorizationStatus = .authorized, addError: (any Error)? = nil) {
        self.status = status
        self.addError = addError
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

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

    func removePending(withIdentifiers ids: [String]) async {
        removedPending.append(contentsOf: ids)
        for id in ids { requests[id] = nil }
    }

    func removeDelivered(withIdentifiers ids: [String]) async {
        removedDelivered.append(contentsOf: ids)
    }

    func removeAllDelivered() async {
        removeAllDeliveredCount += 1
    }

    func removeAllPending() async {
        removeAllCount += 1
        requests.removeAll()
    }

    func pendingIdentifiers() async -> [String] { requests.keys.sorted() }

    func pendingNotifications() async -> [LocalNotification] {
        requests.values.map(UserNotificationScheduler.notification(from:))
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

/// The cases that read pending notifications back out of the adapter. A suite of their own so
/// neither type outgrows the house body-length limit.
@Suite("The production scheduler adapter, read back")
struct UserNotificationSchedulerReadbackTests {
    @Test("an interval readback reports the scheduled moment, however long ago it was scheduled")
    func intervalReadbackDoesNotSlide() async throws {
        // A `UNTimeIntervalNotificationTrigger` stores the original duration, measured from when
        // the request was added, so reconstructing the moment as `Date()` plus that duration
        // slides the reported delivery forward by however long ago the scheduling happened. The
        // readback here happens two seconds after scheduling and is asserted to within a fraction
        // of a second, so a sliding reconstruction cannot pass: it would be two seconds late.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        let moment = Date().addingTimeInterval(1800)

        var intervalNote = notification(id: "interval")
        intervalNote.deliverAt = moment
        intervalNote.deliveryAnchor = .interval
        intervalNote.userInfo = ["route": "review"]
        var wallNote = notification(id: "wall")
        wallNote.deliverAt = moment
        wallNote.deliveryAnchor = .wallClock
        try await scheduler.schedule(intervalNote)
        try await scheduler.schedule(wallNote)

        try await Task.sleep(for: .seconds(2))

        let pending = await scheduler.pendingNotifications()
        let readInterval = try #require(pending.first { $0.id == "interval" })
        let readWall = try #require(pending.first { $0.id == "wall" })

        #expect(abs(readInterval.deliverAt.timeIntervalSince(moment)) < 0.75)
        // Later than the read moment by very nearly the full original duration, rather than by
        // the duration plus the two seconds that have gone by.
        #expect(readInterval.deliverAt.timeIntervalSinceNow < 1799)
        // The wall-clock path was never exposed to this: its components are absolute. It is read
        // back here too so that a fix routed through the shared readback keeps it correct.
        #expect(abs(readWall.deliverAt.timeIntervalSince(moment)) < 1.5)
        #expect(readWall.deliveryAnchor == .wallClock)
        #expect(readInterval.deliveryAnchor == .interval)
        // Nothing the adapter needs for its own reconstruction shows up as a caller's key.
        #expect(readInterval.userInfo == ["route": "review"])

        // A notification read back and scheduled again keeps the same moment rather than drifting
        // a little further out on every pass through the adapter.
        try await scheduler.schedule(readInterval)
        let rescheduled = try #require(await scheduler.pendingNotifications().first { $0.id == "interval" })
        #expect(abs(rescheduled.deliverAt.timeIntervalSince(moment)) < 0.75)
        #expect(rescheduled.userInfo == ["route": "review"])
    }

    @Test("a request this adapter did not stamp still reads back, from the trigger alone")
    func unstampedIntervalRequestReadsBack() throws {
        // The readback has to survive a pending request written by something else, or by an older
        // build: an unreadable stamp is a missing stamp, not a crash and not an empty date. The
        // duration is all such a request carries, so the reconstructed moment is that far off.
        let content = UNMutableNotificationContent()
        content.title = "Foreign"
        content.userInfo = ["route": "review", "com.kristophergbaker.KBNotificationKit.deliverAt": "not a number"]
        let request = UNNotificationRequest(
            identifier: "foreign",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        )

        let read = UserNotificationScheduler.notification(from: request)

        #expect(read.deliveryAnchor == .interval)
        #expect(abs(read.deliverAt.timeIntervalSinceNow - 600) < 5)
        // The reserved key is stripped whether or not it could be read, so it never reaches a
        // caller as one of their own.
        #expect(read.userInfo == ["route": "review"])
    }

    @Test("a caller's own value under the reserved key survives scheduling and readback")
    func reservedKeyCollisionKeepsCallerValue() async throws {
        // The stamp the adapter writes for its own reconstruction lives under a namespaced key.
        // Namespacing makes a collision unlikely, not impossible, and assertion 9 promises every
        // field round-trips: a caller that happens to use that exact key must get its value back
        // rather than have it overwritten on the way in and stripped on the way out.
        let reservedKey = "com.kristophergbaker.KBNotificationKit.deliverAt"
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        let moment = Date().addingTimeInterval(900)

        var note = notification(id: "collide")
        note.deliverAt = moment
        note.deliveryAnchor = .interval
        note.userInfo = [reservedKey: "the caller's own value", "route": "review"]
        try await scheduler.schedule(note)

        let read = try #require(await scheduler.pendingNotifications().first { $0.id == "collide" })
        #expect(read.userInfo == [reservedKey: "the caller's own value", "route": "review"])
        // The caller's value did not become the delivery moment, either: the stamp still works.
        #expect(abs(read.deliverAt.timeIntervalSince(moment)) < 0.75)
        #expect(read.deliveryAnchor == .interval)

        // And it survives a second pass: reading back and rescheduling is a round trip a caller
        // reconciling pending work does routinely.
        try await scheduler.schedule(read)
        let reread = try #require(await scheduler.pendingNotifications().first { $0.id == "collide" })
        #expect(reread.userInfo == [reservedKey: "the caller's own value", "route": "review"])
        #expect(abs(reread.deliverAt.timeIntervalSince(moment)) < 0.75)
    }

    @Test(
        "a colliding caller value round-trips whatever it looks like",
        arguments: ["1234.5", "", "[\"nested\", \"json\"]", "{}", "null"]
    )
    func reservedKeyCollisionShapes(_ callerValue: String) async throws {
        // A caller value that looks like the adapter's own stamp, or like JSON, must not be
        // mistaken for one: the moment and the caller's value are both read back correctly.
        let reservedKey = "com.kristophergbaker.KBNotificationKit.deliverAt"
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        let moment = Date().addingTimeInterval(600)

        var note = notification(id: "shape")
        note.deliverAt = moment
        note.userInfo = [reservedKey: callerValue]
        try await scheduler.schedule(note)

        let read = try #require(await scheduler.pendingNotifications().first { $0.id == "shape" })
        #expect(read.userInfo == [reservedKey: callerValue])
        #expect(abs(read.deliverAt.timeIntervalSince(moment)) < 0.75)
    }

    @Test("a wall-clock caller value under the reserved key comes back untouched")
    func reservedKeyCollisionOnWallClockPath() async throws {
        // The calendar path writes no stamp, so there is nothing to strip on the way out. Asserted
        // because assertion 9 covers both anchor kinds and the readback is shared code.
        let reservedKey = "com.kristophergbaker.KBNotificationKit.deliverAt"
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)

        var note = notification(id: "wall-collide")
        note.deliverAt = Date().addingTimeInterval(3600)
        note.deliveryAnchor = .wallClock
        note.userInfo = [reservedKey: "wall value", "route": "cards"]
        try await scheduler.schedule(note)

        let read = try #require(await scheduler.pendingNotifications().first { $0.id == "wall-collide" })
        #expect(read.userInfo == [reservedKey: "wall value", "route": "cards"])
        #expect(read.deliveryAnchor == .wallClock)
    }

    @Test("scheduling an existing id and reading back returns the later notification")
    func replaceByIdReadsBackLater() async throws {
        // Assertion 9's replace-by-id clause: the readback is the later notification, not a stale
        // earlier one, so the invariant is asserted rather than assumed.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        try await scheduler.schedule(notification(id: "review", inSeconds: 120))

        var later = notification(id: "review", inSeconds: 240)
        later.title = "Later"
        try await scheduler.schedule(later)

        let pending = await scheduler.pendingNotifications()
        #expect(pending.count == 1)
        #expect(pending.first?.title == "Later")
    }
}
#endif
