# KBNotificationKit

KBNotificationKit is a testable seam for local notifications: a `NotificationScheduler` protocol, the value types that
cross it, a `UNUserNotificationCenter` implementation, and a public stub for tests.

**What it is not.** It has no policy. It does not decide when to prompt, what to say, or whether a timer deserves an
alert; it schedules what it is handed. It keeps no state of its own beyond what the notification center already holds.

## Install

KBNotificationKit is a product of the KBKits package. It has no dependencies.

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBNotificationKit", package: "KBKits")
    ])
]
```

## Quick start

Hold the scheduler as the protocol, so tests can pass the stub:

```swift
import KBNotificationKit

let scheduler: any NotificationScheduler = UserNotificationScheduler()

// Ask once, at a moment the user understands.
await scheduler.requestAuthorization()

// The same id again replaces the pending one, so a single timer never needs a cancel first.
try await scheduler.scheduleIfAllowed(LocalNotification(
    id: "rest-timer",
    title: "Rest over",
    body: "Time for the next set.",
    deliverAt: .now.addingTimeInterval(90)
))
```

In a test, use `StubNotificationScheduler`, an actor that records what it was asked to do:

```swift
let stub = StubNotificationScheduler(status: .authorized)
let notification = LocalNotification(id: "rest-timer", title: "Rest over", body: "", deliverAt: .now.addingTimeInterval(90))
try await stub.scheduleIfAllowed(notification)
#expect(await stub.pending["rest-timer"] != nil)
await stub.deliver(id: "rest-timer", at: .now)
#expect(await stub.deliveredNotifications().count == 1)
```

## Main types

- `NotificationScheduler`: the protocol.
  - `authorization()`, and `requestAuthorization()` for the default set or `requestAuthorization(options:)` for the
    caller's choice. Both return what the user chose; a refusal is an answer, not a failure.
  - `deliverySettings()` reports the alert, sound and badge switches alongside the authorization.
  - `schedule(_:)`, and `scheduleIfAllowed(_:)`, the derived convenience that schedules only when the user has already
    agreed.
  - `cancel(id:)`, `cancelAll()` and `clearDelivered()`.
  - `pendingIdentifiers()` is the cheap reconcile call. `pendingNotifications()` returns the full notifications, for a
    caller that wants to show what is scheduled. `deliveredNotifications()` reports what has already arrived and is
    still in Notification Center, earliest first.
- `LocalNotification`: `id`, `title`, `body`, `deliverAt`, and optional `threadIdentifier`, `playsSound` (default
  true), `badge` (nil leaves the badge alone, which is not the same as zero), `userInfo` (carried to the tap handler),
  `interruptionLevel` (default `.active`) and `deliveryAnchor` (default `.interval`).
- `NotificationInterruptionLevel`: how urgently to surface a notification (`passive`, `active`, `timeSensitive`,
  `critical`). A package-owned mirror of `UNNotificationInterruptionLevel`.
- `NotificationDeliveryAnchor`: whether `deliverAt` is an elapsed duration (`interval`) or a point on the wall clock
  (`wallClock`).
- `NotificationAuthorizationOption`: the categories a caller can request (`alert`, `sound`, `badge`).
  `defaultAuthorizationOptions` is `[.alert, .sound]`; add to it with `defaultAuthorizationOptions.union([.badge])`.
- `NotificationAuthorization`: `notDetermined`, `denied`, `authorized`, `provisional` (the quiet grant) and
  `unavailable` (no notification center on this platform). `allowsDelivery` is true for `authorized` and
  `provisional`.
- `NotificationSettingState`: where one switch stands (`enabled`, `disabled`, `notSupported`). A package-owned mirror
  of `UNNotificationSetting`. `isEnabled` is true for `enabled` alone.
- `NotificationDeliverySettings`: the authorization plus the `alert`, `sound` and `badge` switches, which a user can
  turn off one at a time while the app stays `authorized`. `init(assuming:)` builds what a caller assumed before the
  switches could be read.
- `DeliveredNotification`: a delivered notification. `notification` is the `LocalNotification` it was, whose
  `deliverAt` is the moment it was scheduled for, and `deliveredAt` is the moment it arrived.
- `NotificationSchedulingError`: thrown by `schedule(_:)` when the notification center refuses a request
  (`centreRejected(id:reason:)`, naming the id and the center's reason).
- `UserNotificationScheduler`: the real one, behind `canImport(UserNotifications)`.
- `StubNotificationScheduler`: public, for a consuming app's tests. It exposes `pending`, `scheduled`, `cancelled`,
  `delivered`, `deliveredClears`, `authorizationRequests` and `requestedOptions`. Nothing is delivered on its own:
  `deliver(id:at:)` says when a pending notification fires. `setStatus(_:)` and `setSwitches(alert:sound:badge:)`
  change what it reports.

The protocol's newer requirements (`requestAuthorization(options:)`, `clearDelivered()`, `pendingNotifications()`,
`deliverySettings()`, `deliveredNotifications()`) have default implementations, so a conformer written before they
existed keeps compiling. The schedulers shipped here override every one.

## Behavior

- **The id is chosen by the caller, and scheduling it again replaces the pending one.** That is the whole ergonomics:
  an app with one logical timer uses one id and never has to cancel before scheduling.
- **A delivery date in the past schedules nothing and is not an error,** under either anchor. A timer whose end has
  already passed should simply not fire; treating it as a failure would make every late save one. A wall-clock moment
  already gone has no future occurrence either.
- **A center refusal is reported, never swallowed.** `schedule(_:)` throws `NotificationSchedulingError` when the
  notification center cannot honor a request, so a caller never believes a notification is pending when it is not.
- **`scheduleIfAllowed(_:)` never prompts.** The prompt is a decision an app makes deliberately, at a moment the user
  understands, not as a side effect of a background action.
- **Cancelling removes delivered notifications too.** A rest alert still sitting in Notification Center after the next
  set has started is worse than no alert.
- **`deliveredNotifications()` reports, `clearDelivered()` removes, and neither touches pending.** An app clearing its
  own stack on being opened keeps every reminder it has lined up, and reads the delivered set first if it wants to say
  when a reminder arrived. `clearDelivered()` takes no identifiers because there is nothing to protect from it: a
  delivered notification belongs to the app that posted it.
- **Authorization categories are the caller's choice, defaulting to alert and sound.** A rest timer wants no badge,
  because a number left on the app icon after the alert has been read is litter; an app whose content is the number
  adds `.badge`. Requesting a category the app never uses shows up in the system prompt, so ask for what the app uses.
- **A wall-clock anchor fires at a clock time, an interval anchor after a duration.** The default is `interval`, the
  countdown behavior. A wall-clock notification survives a DST change or a time-zone move because it is matched on
  date components rather than a fixed number of seconds.
- **`pendingNotifications()` reports the moment that was scheduled, not one that slides.** A system interval trigger
  remembers only its original duration, so the adapter carries the delivery moment of an interval-anchored request in
  its user info under a reserved key and strips that key again on readback. A caller's `userInfo` comes back exactly as
  it went in, and a list read an hour after scheduling shows the same delivery moments as one read immediately.
- **The reserved key never eats a caller's value.** A caller that happens to use the adapter's own key gets its value
  back unchanged: the stamp carries the caller's value along with the delivery moment and puts it back on readback.
- **A delivered notification reads back like a pending one,** with the reserved stamp stripped and the caller's user
  info intact, and the system's arrival time beside the moment it was scheduled for.
- **An unknown switch is never reported enabled.** A switch state the package does not know reads as `notSupported`,
  so a caller deciding whether a sound will play or a badge will be seen assumes it will not.

## Tests

From the repository root:

```sh
swift test --filter KBNotificationKitTests
```

The `UserNotificationScheduler` tests run against a recording notification center, never the system one.
