# KBNotificationKit

The local-notification seam: a `NotificationScheduler` role protocol, the value types that cross
it, and a `UNUserNotificationCenter` implementation.

**What it is not.** No policy. It does not decide when to prompt, what to say, or whether a timer
deserves an alert; it schedules what it is handed. It also keeps no state of its own beyond what
the notification centre already holds.

## Key types

- `NotificationScheduler` - `schedule`, `cancel(id:)`, `cancelAll`, `clearDelivered`,
  `pendingIdentifiers`, `pendingNotifications`, plus authorization. `requestAuthorization()` asks for the default set;
  `requestAuthorization(options:)` lets the caller choose. `scheduleIfAllowed` is the derived
  convenience. `pendingIdentifiers` is the cheap reconcile call; `pendingNotifications` returns the
  full notifications for a caller that wants to SHOW what is scheduled. `deliverySettings` reports
  the alert, sound and badge switches alongside the authorisation; `deliveredNotifications` reports
  what has already arrived and is still in Notification Centre, earliest first.
- `LocalNotification` - id, title, body, delivery date, thread, sound, badge, user info,
  interruption level, and delivery anchor.
- `NotificationInterruptionLevel` - how urgently to surface a notification (`passive`, `active`,
  `timeSensitive`, `critical`); a package-owned mirror of `UNNotificationInterruptionLevel`.
- `NotificationDeliveryAnchor` - whether `deliverAt` is an elapsed duration (`interval`) or a point
  on the wall clock (`wallClock`).
- `NotificationAuthorizationOption` - the categories a caller can request (`alert`, `sound`,
  `badge`); `defaultAuthorizationOptions` is `[.alert, .sound]`.
- `NotificationAuthorization` - including `provisional`, the quiet grant.
- `NotificationSettingState` - where one switch stands (`enabled`, `disabled`, `notSupported`); a
  package-owned mirror of `UNNotificationSetting`. `isEnabled` is true for `enabled` alone.
- `NotificationDeliverySettings` - the authorisation plus the `alert`, `sound` and `badge`
  switches, which a user can turn off one at a time while the app stays `authorized`.
  `init(assuming:)` builds what a caller assumed before the switches could be read.
- `DeliveredNotification` - a delivered notification: the `LocalNotification` it was, whose
  `deliverAt` is the moment it was scheduled for, and `deliveredAt`, the moment it arrived.
- `NotificationSchedulingError` - thrown by `schedule` when the notification centre refuses a
  request, naming the id that failed and the centre's reason.
- `UserNotificationScheduler` - the real one, behind `canImport(UserNotifications)`.
- `StubNotificationScheduler` - public, for a consuming app's tests.

## Invariants

- **The id is chosen by the caller, and scheduling it again REPLACES the pending one.** That is
  the whole ergonomics: an app with one logical timer uses one id and never has to cancel before
  scheduling.
- **A delivery date in the past schedules nothing and is not an error.** A timer whose end has
  already passed should simply not fire; treating it as a failure would make every late save one.
- **A centre refusal is reported, never swallowed.** `schedule` throws `NotificationSchedulingError`
  when the notification centre cannot honour a request, so a caller never believes a notification is
  pending when it is not.
- **`scheduleIfAllowed` never prompts.** The prompt is a decision an app makes deliberately, at a
  moment the user understands, not as a side effect of a background action.
- **Cancelling removes DELIVERED notifications too.** A rest alert still sitting in Notification
  Centre after the next set has started is worse than no alert.
- **`clearDelivered` clears what has been delivered and schedules nothing.** Pending and delivered
  are different sets, and it touches only the second: an app clearing its own stack on being opened
  keeps every reminder it has lined up. It takes no identifiers because there is nothing to protect
  from it - a delivered notification belongs to the app that posted it.
- **Authorisation categories are the caller's choice, defaulting to alert and sound.** A rest
  timer wants no badge, because a number left on the app icon after the alert has been read is
  litter; an app whose content IS the number adds `.badge`. The default set is unchanged, so an
  upgrading caller keeps today's behaviour without asking.
- **A wall-clock anchor fires at a clock time, an interval anchor after a duration.** The default
  is `interval`, the countdown behaviour. A wall-clock notification survives a DST change or a
  time-zone move because it is matched on date components rather than a fixed number of seconds.
- **A past delivery moment schedules nothing under either anchor.** The non-delivery rule is not
  specific to interval anchoring: a wall-clock moment already gone has no future occurrence either.
- **`pendingNotifications` reports the moment that was scheduled, not one that slides.** A system
  interval trigger remembers only its original duration, so the adapter carries the delivery moment
  of an interval-anchored request in its user info under a reserved key of its own and strips that
  key again on readback. A caller's `userInfo` comes back exactly as it went in, and a list read an
  hour after scheduling shows the same delivery moments as one read immediately.
- **The reserved key never eats a caller's value.** A caller that happens to use the adapter's own
  key gets its value back unchanged: the stamp carries the caller's value along with the delivery
  moment and puts it back on readback. The round-trip guarantee has no asterisk.
- **An unknown switch is never reported enabled.** A switch state the package does not know reads
  as `notSupported`, so a caller deciding whether a sound will play or a badge will be seen
  assumes it will not, rather than that it will.
- **`deliveredNotifications` reports, `clearDelivered` removes, and neither touches pending.** An
  app that clears its delivered stack on coming to the foreground reads the set first if it wants
  to say when a reminder arrived; the reminders still lined up are untouched either way. A
  delivered notification reads back like a pending one, reserved stamp stripped and the caller's
  user info intact, with the system's arrival time beside the moment it was scheduled for.
