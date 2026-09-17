import Foundation
import Testing
@testable import KBNotificationKit

/// A conformer written the way an external one would have been before this change: it implements
/// exactly the members that existed then, and nothing else. It must still compile, which proves
/// the new protocol members carry defaults and the new `LocalNotification` fields are defaulted.
/// The real consumer lives in another repository and is not built by this repo's verification, so
/// a source break would otherwise pass green here.
private struct LegacyConformer: NotificationScheduler {
    func authorization() async -> NotificationAuthorization { .authorized }

    @discardableResult
    func requestAuthorization() async -> NotificationAuthorization { .authorized }

    func schedule(_ notification: LocalNotification) async throws {}

    func cancel(id: String) async {}

    func cancelAll() async {}

    func pendingIdentifiers() async -> [String] { [] }
}

@Suite("Source compatibility")
struct SourceCompatibilityTests {
    @Test("A pre-change conformer still satisfies the protocol via defaults")
    func legacyConformerCompiles() async throws {
        let scheduler: any NotificationScheduler = LegacyConformer()

        // The no-argument authorisation call still exists.
        _ = await scheduler.requestAuthorization()

        // The new members resolve to their defaults on a conformer that does not implement them.
        _ = await scheduler.requestAuthorization(options: [.alert, .sound, .badge])
        #expect(await scheduler.pendingNotifications().isEmpty)
        // Clearing the delivered set defaults to doing nothing, which is the only honest default:
        // a conformer that knows nothing about delivery cannot clear one.
        await scheduler.clearDelivered()

        // The initializer form that existed before this change, with no new arguments supplied.
        let note = LocalNotification(
            id: "rest",
            title: "Rest over",
            body: "Back to it.",
            deliverAt: Date().addingTimeInterval(90)
        )
        try await scheduler.schedule(note)
        #expect(note.interruptionLevel == .active)
        #expect(note.deliveryAnchor == .interval)
    }
}
