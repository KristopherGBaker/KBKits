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
