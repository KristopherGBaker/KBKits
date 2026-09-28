public import Foundation

/// A reading/learning streak, computed purely from the set of days the learner was active.
/// Ported from an earlier reading app's streak summary.
///
/// Days are represented as integers (days since a reference epoch in the learner's own time
/// zone) so this stays free of `Calendar`/`TimeZone` — the app maps `Date` → day number (see
/// `ActivityDay`) and hands the result here. The streak is the run of consecutive active days
/// ending at *today* or *yesterday*: a day not yet studied keeps the streak alive (grace)
/// until the day rolls over, matching how learners expect "don't break the chain" to behave.
public struct StreakSummary: Equatable, Sendable {
    /// Length of the current streak in days (0 when broken).
    public let count: Int
    /// Whether the learner has already been active *today* — drives the "done for today"
    /// affordance vs. the nudge to keep the chain alive.
    public let includesToday: Bool

    public init(count: Int, includesToday: Bool) {
        self.count = count
        self.includesToday = includesToday
    }

    public static let none = StreakSummary(count: 0, includesToday: false)

    /// Whether there's a live streak to celebrate. (`count` is a day tally, not a
    /// collection; `signum` sidesteps the empty_count lint's false positive.)
    public var isActive: Bool { count.signum() == 1 }

    /// Compute the streak from the set of active day numbers, as of `today`.
    ///
    /// - The streak counts consecutive days backward from `today`, or from `yesterday` when
    ///   today isn't active yet (grace — the chain isn't broken until a whole day is missed).
    /// - If neither today nor yesterday is active, the streak is broken (`.none`).
    public static func from(activeDays: Set<Int>, today: Int) -> StreakSummary {
        let includesToday = activeDays.contains(today)
        // The streak's most recent day: today if active, else yesterday (grace), else broken.
        let anchor: Int
        if includesToday {
            anchor = today
        } else if activeDays.contains(today - 1) {
            anchor = today - 1
        } else {
            return .none
        }
        var count = 0
        var day = anchor
        while activeDays.contains(day) {
            count += 1
            day -= 1
        }
        return StreakSummary(count: count, includesToday: includesToday)
    }
}

/// Maps a `Date` to an integer day number in the learner's own time zone, so streak math
/// stays `Calendar`/`TimeZone`-free. The number is days since the calendar's reference date;
/// only differences matter, so the absolute origin is irrelevant.
public enum ActivityDay {
    /// The day number for `date` in `calendar` (local midnight buckets).
    public static func number(for date: Date, calendar: Calendar = .current) -> Int {
        let startOfDay = calendar.startOfDay(for: date)
        let reference = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.dateComponents([.day], from: reference, to: startOfDay).day ?? 0
    }
}
