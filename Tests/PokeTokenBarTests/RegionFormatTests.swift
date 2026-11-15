import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import PokeTokenBar

/// Stage 7, D11: on Windows `Locale.current` is `en_001` and `Calendar.current.firstWeekday` is 2 for everyone, so the
/// popover's grouping and week start come from Win32 through `PlatformCompat`. The conversions run on both systems;
/// the Mac pins its branches to the expressions they stand for, Windows checks the seams against the Win32 reads.
final class RegionFormatTests: XCTestCase {
    func testWindowsFirstDayOfWeekCountsFromMonday() {
        // LOCALE_IFIRSTDAYOFWEEK: 0 = Monday … 6 = Sunday. Calendar: 1 = Sunday … 7 = Saturday.
        let expected = [0: 2, 1: 3, 2: 4, 3: 5, 4: 6, 5: 7, 6: 1]
        for (windows, calendar) in expected {
            XCTAssertEqual(RegionFormat.firstWeekday(windowsValue: windows), calendar, "\(windows)")
        }
        XCTAssertNil(RegionFormat.firstWeekday(windowsValue: -1))
        XCTAssertNil(RegionFormat.firstWeekday(windowsValue: 7))
        XCTAssertEqual(RegionFormat.firstWeekday(windowsText: "6"), 1)
        XCTAssertEqual(RegionFormat.firstWeekday(windowsText: " 0\n"), 2)
        XCTAssertNil(RegionFormat.firstWeekday(windowsText: ""))
        XCTAssertNil(RegionFormat.firstWeekday(windowsText: "x"))
        XCTAssertNil(RegionFormat.firstWeekday(windowsText: nil))
    }

    /// Language and region of a converted locale (identifier spelling differs between Foundations).
    private func parts(_ name: String?) -> String? {
        RegionFormat.locale(windowsName: name).map {
            [$0.language.languageCode?.identifier, $0.region?.identifier].map { $0 ?? "-" }.joined(separator: " ")
        }
    }

    func testWindowsLocaleNamesBecomeFoundationLocales() {
        XCTAssertEqual(parts("ko-KR"), "ko KR")
        XCTAssertEqual(parts("en-US"), "en US")
        XCTAssertEqual(parts("sr-Latn-RS"), "sr RS")
        XCTAssertEqual(RegionFormat.locale(windowsName: "sr-Latn-RS")?.language.script?.identifier, "Latn")
        XCTAssertEqual(parts("de-DE_phoneb"), "de DE", "the sort suffix names a collation")
        XCTAssertEqual(parts("fil"), "fil -")
        for bad in [nil, "", "  ", "!!", "k", "ko-", "ko--KR", "123-KR", "ko-KR-toolongsubtag"] {
            XCTAssertNil(RegionFormat.locale(windowsName: bad), "\(bad ?? "nil")")
        }
    }

    /// The converted locale formats like the region it names (the reason the seam exists).
    func testTheConvertedLocaleGroupsLikeItsRegion() throws {
        let german = try XCTUnwrap(RegionFormat.locale(windowsName: "de-DE"))
        XCTAssertEqual(TokenFormatter.grouped(1_234_567, locale: german), "1.234.567")
        let korean = try XCTUnwrap(RegionFormat.locale(windowsName: "ko-KR"))
        XCTAssertEqual(TokenFormatter.grouped(1_234_567, locale: korean), "1,234,567")
    }

    func testTheRegionCalendarStartsItsWeeksWhereItIsTold() throws {
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        for first in 1...7 {
            let calendar = RegionFormat.calendar(timeZone: seoul, firstWeekday: first, locale: Locale(identifier: "ko_KR"))
            XCTAssertEqual(calendar.identifier, .gregorian)
            XCTAssertEqual(calendar.timeZone, seoul)
            XCTAssertEqual(calendar.firstWeekday, first, "the locale is set first, so it cannot reset the week start")
            let start = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: FormatterProbe.instant)?.start)
            XCTAssertEqual(calendar.component(.weekday, from: start), first)
        }
        XCTAssertEqual(RegionFormat.calendar(timeZone: seoul, firstWeekday: 2, locale: nil).firstWeekday, 2)
    }

    #if os(macOS)
    /// The Mac branches are exactly the expressions they stand for (the one upstream line, `UsageRecap.swift:140`, now
    /// reads `PlatformCompat.firstWeekday`).
    func testMacRegionSeamsAreTodaysExpressions() throws {
        XCTAssertEqual(PlatformCompat.firstWeekday, Calendar.current.firstWeekday)
        XCTAssertEqual(PlatformCompat.regionLocale, Locale.current)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var old = Calendar(identifier: .gregorian)   // RecapPeriod.calendar(timeZone:) before the seam, verbatim
        old.timeZone = zone
        old.firstWeekday = Calendar.current.firstWeekday
        XCTAssertEqual(PlatformCompat.regionCalendar(timeZone: zone), old)
        XCTAssertEqual(RecapPeriod.calendar(timeZone: zone), old)
    }
    #endif

    #if os(Windows)
    /// The seams read what Windows says, not corelibs' `en_001`.
    func testWindowsSeamsFollowTheWin32RegionalFormat() {
        let first = RegionFormat.firstWeekday(windowsText: WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_IFIRSTDAYOFWEEK)))
        XCTAssertNotNil(first, "LOCALE_IFIRSTDAYOFWEEK: \(WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_IFIRSTDAYOFWEEK)) ?? "nil")")
        XCTAssertEqual(PlatformCompat.firstWeekday, first ?? Calendar.current.firstWeekday)
        XCTAssertEqual(PlatformCompat.regionCalendar(timeZone: .current).firstWeekday, PlatformCompat.firstWeekday)
        let name = WinUILanguage.win32LocaleName()
        XCTAssertEqual(PlatformCompat.regionLocale.identifier, RegionFormat.locale(windowsName: name)?.identifier ?? Locale.current.identifier)
        let decimal = WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_SDECIMAL)) ?? "."
        let windows = WinUILanguage.win32NumberFormat("1234567")?.components(separatedBy: decimal).first
        print("REGION-PROBE|windows|localeName=\(name ?? "-")|IFIRSTDAYOFWEEK=\(WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_IFIRSTDAYOFWEEK)) ?? "-")"
              + "|firstWeekday=\(PlatformCompat.firstWeekday)|corelibs=\(Calendar.current.firstWeekday)"
              + "|grouped=\(FormatterProbe.visible(TokenFormatter.grouped(1_234_567, locale: PlatformCompat.regionLocale)))"
              + "|GetNumberFormatEx=\(FormatterProbe.visible(windows ?? "-"))")
        XCTAssertEqual(TokenFormatter.grouped(1_234_567, locale: PlatformCompat.regionLocale), windows)
    }
    #endif
}
