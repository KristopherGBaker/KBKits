import Testing
import Foundation
@testable import KBCore

@Suite("Streak summary")
struct StreakSummaryTests {
    @Test("an unbroken run ending today counts every day and includes today")
    func runEndingToday() {
        let streak = StreakSummary.from(activeDays: [10, 11, 12], today: 12)
        #expect(streak.count == 3)
        #expect(streak.includesToday)
    }

    @Test("yesterday-active keeps the streak alive today (grace) without counting today")
    func graceDay() {
        let streak = StreakSummary.from(activeDays: [10, 11], today: 12)
        #expect(streak.count == 2)
        #expect(!streak.includesToday)
    }

    @Test("a gap of a full day breaks the streak")
    func broken() {
        let streak = StreakSummary.from(activeDays: [8, 9], today: 12)
        #expect(streak == .none)
    }

    @Test("only the run touching today/yesterday counts, not an older island")
    func ignoresOlderIsland() {
        let streak = StreakSummary.from(activeDays: [1, 2, 3, 11, 12], today: 12)
        #expect(streak.count == 2)
    }

    @Test("an empty log is no streak")
    func empty() {
        #expect(StreakSummary.from(activeDays: [], today: 5) == .none)
    }

    @Test("day numbers bucket times on the same local day together")
    func dayNumberBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 8))!
        let laterSameDay = morning.addingTimeInterval(3 * 3600)           // +3h, still the 14th
        let nextDay = morning.addingTimeInterval(24 * 3600)
        #expect(ActivityDay.number(for: morning, calendar: calendar)
            == ActivityDay.number(for: laterSameDay, calendar: calendar))
        #expect(ActivityDay.number(for: nextDay, calendar: calendar)
            == ActivityDay.number(for: morning, calendar: calendar) + 1)
    }
}
