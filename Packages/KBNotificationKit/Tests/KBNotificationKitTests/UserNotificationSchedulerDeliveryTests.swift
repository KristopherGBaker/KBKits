#if canImport(UserNotifications)
import Foundation
import Testing
import UserNotifications

@testable import KBNotificationKit

private let reservedKey = "com.kristophergbaker.KBNotificationKit.deliverAt"

/// What the adapter reports about delivery: the per-switch settings and the delivered set. A
/// suite of its own so neither adapter suite outgrows the house body-length limit.
@Suite("The production scheduler adapter, delivery")
struct UserNotificationSchedulerDeliveryTests {
    @Test(
        "each system switch state maps to its own",
        arguments: [
            (UNNotificationSetting.enabled, NotificationSettingState.enabled),
            (.disabled, .disabled),
            (.notSupported, .notSupported)
        ]
    )
    func settingStateMapping(_ setting: UNNotificationSetting, _ expected: NotificationSettingState) {
        #expect(UserNotificationScheduler.settingState(from: setting) == expected)
    }

    @Test("a switch state this build does not know is never reported enabled")
    func unknownSettingIsNotEnabled() throws {
        // A future system adding a case must not read as "the sound will play": a caller acting on
        // a switch it cannot read assumes the part does not land.
        let unknown = try #require(UNNotificationSetting(rawValue: 99))
        let state = UserNotificationScheduler.settingState(from: unknown)
        #expect(state == .notSupported)
        #expect(state.isEnabled == false)
    }

    @Test("the settings read back exactly as the centre reports them, from one read")
    func settingsReadback() async {
        // Every switch differs from the others, so a mapping that crossed two of them would fail.
        let centre = RecordingCentre()
        await centre.configure(status: .authorized, alert: .enabled, sound: .disabled, badge: .notSupported)
        let scheduler = UserNotificationScheduler(centre: centre)

        let settings = await scheduler.deliverySettings()

        #expect(settings == NotificationDeliverySettings(
            authorization: .authorized, alert: .enabled, sound: .disabled, badge: .notSupported
        ))
        #expect(await centre.settingsReads == 1)
    }

    @Test("a second permutation of the settings reads back exactly too")
    func settingsReadbackPermuted() async {
        let centre = RecordingCentre()
        await centre.configure(status: .provisional, alert: .disabled, sound: .notSupported, badge: .enabled)
        let scheduler = UserNotificationScheduler(centre: centre)

        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(
            authorization: .provisional, alert: .disabled, sound: .notSupported, badge: .enabled
        ))
        #expect(await centre.settingsReads == 1)
    }

    @Test("the delivered set reads back in delivery order, stamp stripped and user info intact")
    func deliveredReadback() async throws {
        // Delivered "alpha" first but at the later moment, so the expected order is neither the
        // order the centre holds them in nor the order of their ids.
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        let now = Date()
        let alphaMoment = now.addingTimeInterval(600)
        let zetaMoment = now.addingTimeInterval(900)
        let alphaInfo = ["route": "review"]
        let zetaInfo = ["route": "cards", "deck": "N5"]
        try await scheduler.schedule(LocalNotification(
            id: "alpha", title: "Alpha", body: "First.", deliverAt: alphaMoment, userInfo: alphaInfo
        ))
        try await scheduler.schedule(LocalNotification(
            id: "zeta", title: "Zeta", body: "Second.", deliverAt: zetaMoment, userInfo: zetaInfo
        ))
        // Both requests carry the reserved stamp, so the readback has something to strip.
        #expect(await centre.systemUserInfoKeys(forId: "alpha").contains(reservedKey))
        #expect(await centre.systemUserInfoKeys(forId: "zeta").contains(reservedKey))

        let alphaArrived = now.addingTimeInterval(60)
        let zetaArrived = now.addingTimeInterval(30)
        await centre.deliver(id: "alpha", at: alphaArrived)
        await centre.deliver(id: "zeta", at: zetaArrived)

        let delivered = await scheduler.deliveredNotifications()
        #expect(delivered.map(\.id) == ["zeta", "alpha"])
        let zeta = try #require(delivered.first)
        let alpha = try #require(delivered.last)

        #expect(zeta.deliveredAt == zetaArrived)
        #expect(alpha.deliveredAt == alphaArrived)
        // The scheduled moment and the arrival are two different facts, and both survive.
        #expect(abs(zeta.notification.deliverAt.timeIntervalSince(zetaMoment)) < 0.75)
        #expect(abs(alpha.notification.deliverAt.timeIntervalSince(alphaMoment)) < 0.75)
        #expect(zeta.notification.deliverAt != zeta.deliveredAt)
        #expect(alpha.notification.deliverAt != alpha.deliveredAt)
        #expect(zeta.notification.userInfo == zetaInfo)
        #expect(alpha.notification.userInfo == alphaInfo)
        #expect(alpha.notification.title == "Alpha")
    }

    @Test("clearing the delivered set leaves pending alone, and pending is never reported delivered")
    func clearDeliveredKeepsPending() async throws {
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        for id in ["a", "b", "c"] {
            try await scheduler.schedule(LocalNotification(
                id: id, title: id, body: "", deliverAt: Date().addingTimeInterval(600)
            ))
        }
        await centre.deliver(id: "a", at: Date())

        #expect(await scheduler.deliveredNotifications().map(\.id) == ["a"])
        #expect(await scheduler.pendingIdentifiers() == ["b", "c"])

        await scheduler.clearDelivered()

        #expect(await scheduler.deliveredNotifications().isEmpty)
        #expect(await scheduler.pendingIdentifiers() == ["b", "c"])
    }

    @Test("cancelling an id takes its delivered copy and leaves the other delivered ones")
    func cancelTakesDeliveredCopy() async throws {
        let centre = RecordingCentre()
        let scheduler = UserNotificationScheduler(centre: centre)
        for id in ["a", "b"] {
            try await scheduler.schedule(LocalNotification(
                id: id, title: id, body: "", deliverAt: Date().addingTimeInterval(600)
            ))
            await centre.deliver(id: id, at: Date())
        }

        await scheduler.cancel(id: "a")

        #expect(await scheduler.deliveredNotifications().map(\.id) == ["b"])
    }
}
#endif
