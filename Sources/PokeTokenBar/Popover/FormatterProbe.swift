import Foundation

/// What Foundation's date, duration and number formatters write, one `name = value` pair each, for one app language
/// (stage 7, Task 1: R4). The same lines come from the Mac's Foundation in `PopoverFormatterProbeTests` and from
/// Windows' swift-corelibs / swift-foundation in that test and in `--language-probe`, so the two can be put side by side.
/// Inputs are fixed (an instant, Seoul time, set durations) so both systems format the same thing. Diagnostics only:
/// nothing in the app formats through it.
enum FormatterProbe {
    /// 2026-09-10 10:26:40 UTC, a Thursday (19:26:40 in Seoul).
    static let instant = Date(timeIntervalSince1970: 1_789_036_000)
    static let zone = TimeZone(identifier: "Asia/Seoul") ?? TimeZone(secondsFromGMT: 9 * 3600)!

    static func lines(language: AppLanguage) -> [(String, String)] {
        let locale = language.displayLocale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var out: [(String, String)] = []

        let units: Set<Duration.UnitsFormatStyle.Unit> = [.days, .hours, .minutes, .seconds]
        let widths: [(String, Duration.UnitsFormatStyle.UnitWidth)] = [("wide", .wide), ("abbreviated", .abbreviated), ("narrow", .narrow)]
        for (name, width) in widths {
            let style = Duration.UnitsFormatStyle(allowedUnits: units, width: width, maximumUnitCount: 2).locale(locale)
            out.append(("units.\(name).2h5m5s", style.format(.seconds(7505))))
            out.append(("units.\(name).3m10s", style.format(.seconds(190))))
            out.append(("units.\(name).45s", style.format(.seconds(45))))
        }

        var relative = Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide)
        relative.locale = locale
        relative.calendar = calendar
        let now = Date()
        out.append(("relativeStyle.numeric.wide.-190s", relative.format(now.addingTimeInterval(-190))))
        out.append(("relativeStyle.numeric.wide.+7505s", relative.format(now.addingTimeInterval(7505))))

        let interval = DateIntervalFormatter()
        interval.locale = locale
        interval.calendar = calendar
        interval.timeZone = zone
        interval.dateTemplate = "dMMMy"
        out.append(("dateInterval.dMMMy.7days", interval.string(from: instant, to: instant.addingTimeInterval(6 * 86_400))))

        for template in ["MdE", "HHmm", "EEEEdHHmm", "EEEE d MMM", "MMMM y"] {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate(template)
            out.append(("template.\(template)", f.string(from: instant)))
        }

        let styled = DateFormatter()
        styled.locale = locale
        styled.timeZone = zone
        styled.dateStyle = .medium
        styled.timeStyle = .short
        out.append(("dateStyle.medium.short", styled.string(from: instant)))

        out.append(("formatStyle.date.numeric",
                    instant.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: zone))))

        var symbols = Calendar(identifier: .gregorian)
        symbols.locale = locale
        out.append(("calendar.veryShortStandaloneWeekdaySymbols", symbols.veryShortStandaloneWeekdaySymbols.joined(separator: " ")))
        let names = DateFormatter()
        names.locale = locale
        out.append(("dateFormatter.shortStandaloneWeekdaySymbols", (names.shortStandaloneWeekdaySymbols ?? []).joined(separator: " ")))
        out.append(("dateFormatter.veryShortStandaloneMonthSymbols", (names.veryShortStandaloneMonthSymbols ?? []).joined(separator: " ")))
        return out.map { ($0.0, visible($0.1)) }
    }

    /// `TokenFormatter.grouped(1234567)` in a few regional formats, and what this process's Foundation reports as
    /// the user's region and first weekday next to the `PlatformCompat` seams.
    static func regionLines() -> [(String, String)] {
        var out: [(String, String)] = []
        for id in ["de_DE", "fr_FR", "ko_KR", "en_US", "en_001", "ru_RU", "de_CH"] {
            out.append(("grouped.\(id)", TokenFormatter.grouped(1_234_567, locale: Locale(identifier: id))))
        }
        out.append(("grouped.Locale.current", TokenFormatter.grouped(1_234_567)))
        out.append(("grouped.PlatformCompat.regionLocale", TokenFormatter.grouped(1_234_567, locale: PlatformCompat.regionLocale)))
        out.append(("Locale.current", Locale.current.identifier))
        out.append(("PlatformCompat.regionLocale", PlatformCompat.regionLocale.identifier))
        out.append(("Calendar.current.firstWeekday", "\(Calendar.current.firstWeekday)"))
        out.append(("PlatformCompat.firstWeekday", "\(PlatformCompat.firstWeekday)"))
        return out.map { ($0.0, visible($0.1)) }
    }

    /// `DateComponentsFormatter` (abbreviated, two units) — the popover formatter SwiftUI's `.relative` resembles.
    /// swift-corelibs declares it but every `string(from:)` is `NSUnsupported()`, so on Windows this traps: only the
    /// language probe's isolated child process calls it there (`--formatter-trap`).
    static func dateComponentsAbbreviated(_ seconds: TimeInterval, language: AppLanguage) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.day, .hour, .minute, .second]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.displayLocale
        f.calendar = calendar
        return visible(f.string(from: seconds) ?? "nil")
    }

    /// Non-ASCII spaces and invisible marks as `<U+202F>` so a log line shows which one a locale used.
    static func visible(_ text: String) -> String {
        text.unicodeScalars.map { s in
            s.properties.isWhitespace && s != " " || s.properties.generalCategory == .format
                ? "<U+\(String(s.value, radix: 16, uppercase: true))>" : String(s)
        }.joined()
    }
}
