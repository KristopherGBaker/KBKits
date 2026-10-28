import Foundation
import Testing
import KBNotificationKit

/// The new public surface, reached the way a consuming app reaches it: a plain import, with no
/// testable import to paper over a member that was left internal. Every name a consumer needs for the
/// per-switch settings and the delivered set is used here, so dropping `public` from one is a
/// compile failure in this file rather than a surprise in the app.
@Suite("Public API, as a consumer sees it")
struct PublicAPITests {
    @Test("NotificationSettingState lists its cases, says which is enabled, and round-trips")
    func settingState() throws {
        #expect(NotificationSettingState.allCases == [.enabled, .disabled, .notSupported])
        #expect(NotificationSettingState.allCases.filter(\.isEnabled) == [.enabled])
        let encoded = try JSONEncoder().encode(NotificationSettingState.allCases)
        let decoded = try JSONDecoder().decode([NotificationSettingState].self, from: encoded)
        #expect(decoded == NotificationSettingState.allCases)
        #expect(NotificationSettingState(rawValue: "notSupported") == .notSupported)
    }

    @Test("NotificationDeliverySettings keeps every field it was built with")
    func deliverySettings() {
        let settings = NotificationDeliverySettings(
            authorization: .provisional,
            alert: .disabled,
            sound: .notSupported,
            badge: .enabled
        )
        #expect(settings.authorization == .provisional)
        #expect(settings.alert == .disabled)
        #expect(settings.sound == .notSupported)
        #expect(settings.badge == .enabled)

        let assumed = NotificationDeliverySettings(assuming: .denied)
        #expect(assumed == NotificationDeliverySettings(
            authorization: .denied, alert: .disabled, sound: .disabled, badge: .disabled
        ))
    }

    @Test("DeliveredNotification keeps both moments and takes its id from the notification")
    func deliveredNotification() {
        let scheduledFor = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let arrived = scheduledFor.addingTimeInterval(5)
        let note = LocalNotification(id: "review", title: "Review", body: "Cards are due.", deliverAt: scheduledFor)
        let delivered = DeliveredNotification(notification: note, deliveredAt: arrived)

        #expect(delivered.id == "review")
        #expect(delivered.notification == note)
        #expect(delivered.deliveredAt == arrived)
        #expect(delivered.notification.deliverAt == scheduledFor)
    }

    @Test("Both new members are reachable through the protocol, backed by the stub")
    func protocolMembersThroughStub() async throws {
        let stub = StubNotificationScheduler()
        let scheduler: any NotificationScheduler = stub
        #expect(await scheduler.deliverySettings() == NotificationDeliverySettings(assuming: .authorized))

        await stub.setSwitches(alert: .enabled, sound: .disabled, badge: .disabled)
        #expect(await scheduler.deliverySettings().sound.isEnabled == false)

        let note = LocalNotification(id: "review", title: "Review", body: "", deliverAt: Date().addingTimeInterval(600))
        try await scheduler.schedule(note)
        let arrived = Date()
        #expect(await stub.deliver(id: "review", at: arrived))
        #expect(await stub.delivered.map(\.id) == ["review"])
        #expect(await scheduler.deliveredNotifications() == [
            DeliveredNotification(notification: note, deliveredAt: arrived)
        ])
    }
}
