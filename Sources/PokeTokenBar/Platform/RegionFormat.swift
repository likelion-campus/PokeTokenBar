import Foundation

/// Pure conversions from what Windows says about the user's regional format to Foundation values (stage 7, D11).
/// swift-corelibs Foundation on Windows answers `Locale.current` with `en_001` and `Calendar.current.firstWeekday`
/// with 2 for every user (the PC defects 1 report), so the Windows popover reads the region from Win32 and converts it
/// here. Shared, so the Mac tests the conversions too.
enum RegionFormat {
    /// `LOCALE_IFIRSTDAYOFWEEK` counts from Monday (0 = Monday … 6 = Sunday); `Calendar.firstWeekday` from Sunday
    /// (1 = Sunday … 7 = Saturday). Anything outside 0…6 is not a weekday: nil.
    static func firstWeekday(windowsValue: Int) -> Int? {
        guard (0...6).contains(windowsValue) else { return nil }
        return (windowsValue + 1) % 7 + 1
    }

    /// The same from the string `GetLocaleInfoEx` writes ("6"). Blank or not a number: nil.
    static func firstWeekday(windowsText: String?) -> Int? {
        guard let text = windowsText?.trimmingCharacters(in: .whitespacesAndNewlines), let value = Int(text) else { return nil }
        return firstWeekday(windowsValue: value)
    }

    /// A Windows locale name ("ko-KR", "sr-Latn-RS", "de-DE_phoneb") as a Foundation locale. The alternate-sort suffix
    /// after `_` names a collation, not a region, and is dropped. Empty (the invariant locale), nil, or not a
    /// language-region tag: nil, so the caller keeps its fallback.
    static func locale(windowsName: String?) -> Locale? {
        guard var name = windowsName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let sort = name.firstIndex(of: "_") { name = String(name[..<sort]) }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({ (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return nil }
        return Locale(identifier: parts.joined(separator: "_"))
    }

    /// A gregorian calendar in `timeZone` whose weeks start on `firstWeekday`, with `locale` for weekend rules and
    /// symbols (nil keeps Foundation's default). The heatmap and the recap build their calendar this way.
    static func calendar(timeZone: TimeZone, firstWeekday: Int, locale: Locale?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let locale { calendar.locale = locale }
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}
