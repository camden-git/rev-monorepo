import Foundation
import Testing
@testable import RevKit

struct DriveStreakTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    /// fixed "now": noon on 2024-03-15
    private let now = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "America/New_York"),
        year: 2024, month: 3, day: 15, hour: 12
    ).date!

    /// a date `daysAgo` days before `now`
    private func day(_ daysAgo: Int, hour: Int = 9) -> Date {
        let base = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }

    private func compute(_ dates: [Date]) -> DriveStreak {
        DriveStreak.compute(driveDates: dates, now: now, calendar: calendar)
    }

    @Test func emptyIsZero() {
        #expect(compute([]) == DriveStreak(current: 0, longest: 0))
    }

    @Test func singleDayToday() {
        #expect(compute([day(0)]) == DriveStreak(current: 1, longest: 1))
    }

    @Test func consecutiveRunCounts() {
        let s = compute([day(0), day(1), day(2), day(3)])
        #expect(s.current == 4)
        #expect(s.longest == 4)
    }

    /// a gap resets the current run but the longest is preserved
    @Test func brokenRunResetsCurrentKeepsLongest() {
        // a 3-day run ending 5 days ago, then a single drive today
        let s = compute([day(7), day(6), day(5), day(0)])
        #expect(s.current == 1)   // only today
        #expect(s.longest == 3)   // the older run
    }

    /// yesterday still counts as a live streak (grace day)
    @Test func yesterdayKeepsStreakCurrent() {
        let s = compute([day(2), day(1)])
        #expect(s.current == 2)
        #expect(s.longest == 2)
    }

    /// a last drive 2+ days ago is no longer current
    @Test func twoDaysAgoIsNotCurrent() {
        let s = compute([day(3), day(2)])
        #expect(s.current == 0)
        #expect(s.longest == 2)
    }

    /// multiple drives on the same day count once
    @Test func sameDayCountsOnce() {
        let s = compute([day(0, hour: 8), day(0, hour: 13), day(1, hour: 20)])
        #expect(s.current == 2)
        #expect(s.longest == 2)
    }
}
