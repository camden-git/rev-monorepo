import Foundation

/// consecutive-day drive streaks: how many days in a row the player has driven
public struct DriveStreak: Equatable, Sendable {
    /// the active run ending today or yesterday, 0 if the last drive was older than yesterday
    public var current: Int
    /// the longest run of consecutive calendar days ever
    public var longest: Int

    public init(current: Int, longest: Int) {
        self.current = current
        self.longest = longest
    }

    /// fold a set of drive dates into current + longest consecutive-day streaks
    public static func compute(
        driveDates: [Date],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DriveStreak {
        guard !driveDates.isEmpty else { return DriveStreak(current: 0, longest: 0) }

        // collapse to unique calendar days, ascending
        let days = Set(driveDates.map { calendar.startOfDay(for: $0) }).sorted()

        // longest run of consecutive days
        var longest = 1
        var run = 1
        for i in 1..<max(days.count, 1) {
            if calendar.dateComponents([.day], from: days[i - 1], to: days[i]).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        // current run ending today or yesterday (grace day)
        let today = calendar.startOfDay(for: now)
        var current = 0
        if let last = days.last {
            let gap = calendar.dateComponents([.day], from: last, to: today).day ?? .max
            if gap <= 1 {
                current = 1
                var i = days.count - 1
                while i > 0,
                      calendar.dateComponents([.day], from: days[i - 1], to: days[i]).day == 1 {
                    current += 1
                    i -= 1
                }
            }
        }

        return DriveStreak(current: current, longest: longest)
    }
}
