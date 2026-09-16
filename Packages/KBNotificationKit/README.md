# KBNotificationKit

The local-notification seam: a `NotificationScheduler` role protocol, the value types that cross
it, and a `UNUserNotificationCenter` implementation.

**What it is not.** No policy. It does not decide when to prompt, what to say, or whether a timer
deserves an alert; it schedules what it is handed. It also keeps no state of its own beyond what
the notification centre already holds.

## Key types

- `NotificationScheduler` - `schedule`, `cancel(id:)`, `cancelAll`, `pendingIdentifiers`,
  `pendingNotifications`, plus authorization. `requestAuthorization()` asks for the default set;
  `requestAuthorization(options:)` lets the caller choose. `scheduleIfAllowed` is the derived
  convenience. `pendingIdentifiers` is the cheap reconcile call; `pendingNotifications` returns the
  full notifications for a caller that wants to SHOW what is scheduled.
- `LocalNotification` - id, title, body, delivery date, thread, sound, badge, user info,
  interruption level, and delivery anchor.
- `NotificationInterruptionLevel` - how urgently to surface a notification (`passive`, `active`,
  `timeSensitive`, `critical`); a package-owned mirror of `UNNotificationInterruptionLevel`.
- `NotificationDeliveryAnchor` - whether `deliverAt` is an elapsed duration (`interval`) or a point
  on the wall clock (`wallClock`).
- `NotificationAuthorizationOption` - the categories a caller can request (`alert`, `sound`,
  `badge`); `defaultAuthorizationOptions` is `[.alert, .sound]`.
- `NotificationAuthorization` - including `provisional`, the quiet grant.
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
