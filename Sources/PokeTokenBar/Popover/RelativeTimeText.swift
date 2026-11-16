import Foundation

/// The Windows popover's relative times — "Updated 3 minutes, 10 seconds", a reset "in 2 hours, 5 minutes", the stale
/// badge — where the Mac writes `Text(date, style: .relative)` (stage 7, D10). SwiftUI's style does not exist on
/// Windows and `RelativeDateTimeFormatter` is missing from corelibs (`DateComponentsFormatter` is marked unavailable),
/// so the words come from swift-foundation's `Duration.UnitsFormatStyle` (ICU) in the app language: wide units, at most
/// two, the time either side of `now` (no "ago" / "in": the caller's label says which). The wording may differ from
/// SwiftUI's; that is a listed difference.
///
/// The value shown is whole seconds — time passed rounded down, time left rounded up, so a countdown never says 0
/// before the moment — then cut to the two units shown: seconds under an hour, minutes under a day, hours after that.
/// `nextChange` gives the next instant that text changes, for the popover clock (D10: one timer, armed at the earliest
/// change among the visible texts).
enum RelativeTimeText {
    static func text(for date: Date, now: Date, language: AppLanguage, coarse: Bool = false) -> String {
        format(seconds: displayedSeconds(for: date, now: now, coarse: coarse), language: language)
    }

    /// The first instant after `now` at which `text(for: date, now:)` reads differently.
    static func nextChange(for date: Date, now: Date, coarse: Bool = false) -> Date {
        let current = displayedSeconds(for: date, now: now, coarse: coarse)
        let candidates = [1, 30, 60, 3600].map { boundary(unit: $0, for: date, now: now) }.sorted()
        return candidates.first { displayedSeconds(for: date, now: $0, coarse: coarse) != current } ?? candidates.last!
    }

    /// The whole seconds the text shows.
    static func displayedSeconds(for date: Date, now: Date, coarse: Bool = false) -> Int {
        let ms = milliseconds(date, now)
        let past = ms <= 0
        let raw = past ? -ms / 1000 : (ms + 999) / 1000
        let unit = granularity(raw, coarse: coarse)
        return past ? raw / unit * unit : (raw + unit - 1) / unit * unit
    }

    static func format(seconds: Int, language: AppLanguage) -> String {
        Duration.UnitsFormatStyle(allowedUnits: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)
            .locale(language.displayLocale)
            .format(.seconds(seconds))
    }

    /// The smallest unit shown for `seconds`. `coarse` (the Windows popover, D18): half minutes in the first minute, then whole minutes, so
    /// an open popover wakes at most twice in the first minute and once a minute after ("2 minutes", not "2 minutes, 5 seconds"); the Mac's
    /// SwiftUI text counts seconds under an hour, and that stays the default.
    private static func granularity(_ seconds: Int, coarse: Bool = false) -> Int {
        if coarse { return seconds < 60 ? 30 : seconds < 86_400 ? 60 : 3600 }
        return seconds < 3600 ? 1 : seconds < 86_400 ? 60 : 3600
    }

    /// `date - now` in whole milliseconds, so boundary instants built from it compare exactly.
    private static func milliseconds(_ date: Date, _ now: Date) -> Int {
        Int((date.timeIntervalSince(now) * 1000).rounded())
    }

    /// The next instant after `now` at which the time passed (or left) crosses a multiple of `unit` seconds.
    private static func boundary(unit: Int, for date: Date, now: Date) -> Date {
        let ms = milliseconds(date, now), step = unit * 1000
        let wait: Int
        if ms <= 0 {   // passed: the elapsed time grows to the next multiple
            let elapsed = -ms
            wait = (elapsed / step + 1) * step - elapsed
        } else {       // left: the remaining time falls to the multiple below its rounded-up value
            wait = ms - ((ms + step - 1) / step - 1) * step
        }
        return now.addingTimeInterval(Double(wait) / 1000)
    }
}
