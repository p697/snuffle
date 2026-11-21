import Foundation

/// "Today" and "the same time yesterday" in a project's own time zone, which may differ from the phone's.
public struct ProjectClock: Sendable, Equatable {
    public var now: Date
    public var timeZone: TimeZone
    public var todayStart: Date
    public var yesterdayStart: Date
    /// `now` minus one calendar day, so "昨天此时" stays right across daylight-saving changes.
    public var sameTimeYesterday: Date

    public init(now: Date, timeZoneIdentifier: String?) {
        let zone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.now = now
        self.timeZone = zone
        todayStart = calendar.startOfDay(for: now)
        yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        sameTimeYesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    }

    /// Start of the day `days - 1` days before today, for an N-day history that ends today.
    public func historyStart(days: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: -(days - 1), to: todayStart)!
    }

    /// Hours elapsed today, counting the current partial hour.
    public var hoursSoFar: Int {
        max(1, Int((now.timeIntervalSince(todayStart) / 3600).rounded(.down)) + 1)
    }

    /// "yyyy-MM-dd" for a date in this zone; history rows are keyed by it.
    public func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Every day start from `historyStart(days:)` to today.
    public func dayStarts(days: Int) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let first = historyStart(days: days)
        return (0..<days).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
}
