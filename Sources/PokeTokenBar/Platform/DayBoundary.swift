import Foundation

/// Local-day arithmetic for the "the day changed" event. Pure, so DST and time-zone cases are testable on any OS.
enum DayBoundary {
    /// The first instant of the local day after the one containing `after` (always later than `after`). A midnight
    /// that does not exist (a DST change that skips 00:00) resolves to the first instant of that day.
    static func nextLocalMidnight(after: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: after)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return after.addingTimeInterval(86_400) }
        let midnight = calendar.startOfDay(for: nextDay)
        return midnight > after ? midnight : after.addingTimeInterval(86_400)
    }

    /// The local day as `yyyy-MM-dd`, the same key `LocalUsageReader.todayKey()` uses.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        LocalUsageReader.localDayFormatter(timeZone: calendar.timeZone).string(from: date)
    }
}
