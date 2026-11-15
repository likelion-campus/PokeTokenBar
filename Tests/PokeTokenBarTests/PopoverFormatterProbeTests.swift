import XCTest
@testable import PokeTokenBar

/// Stage 7, Task 1 (R4): what each Foundation formatter the popover could use writes on this system, as
/// `FORMATTER-PROBE|<os>|<language>|<formatter>|<value>` lines in the test log. The Mac run and the Windows CI run print
/// the same inputs, so the two logs make the formatter table in the task report. It asserts only that nothing traps.
final class PopoverFormatterProbeTests: XCTestCase {
    #if os(Windows)
    private static let system = "windows"
    #else
    private static let system = "mac"
    #endif

    func testPrintTheFormatterTable() {
        for language in [AppLanguage.ko, .en, .ja, .fr, .ru] {
            for (name, value) in FormatterProbe.lines(language: language) {
                print("FORMATTER-PROBE|\(Self.system)|\(language.rawValue)|\(name)|\(value)")
            }
            #if !os(Windows)
            // Mac only: swift-corelibs has no RelativeDateTimeFormatter, and marks DateComponentsFormatter
            // `unavailable: Not supported in swift-corelibs-foundation` (the Windows build does not compile a call to it).
            let components = DateComponentsFormatter()
            components.unitsStyle = .abbreviated
            components.maximumUnitCount = 2
            components.allowedUnits = [.day, .hour, .minute, .second]
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = language.displayLocale
            components.calendar = calendar
            for seconds in [7505.0, 190, 45] {
                print("FORMATTER-PROBE|mac|\(language.rawValue)|dateComponents.abbreviated.\(Int(seconds))s|"
                      + FormatterProbe.visible(components.string(from: seconds) ?? "nil"))
            }
            let relative = RelativeDateTimeFormatter()
            relative.locale = language.displayLocale
            relative.unitsStyle = .full
            print("FORMATTER-PROBE|mac|\(language.rawValue)|relativeDateTime.full.-190s|"
                  + FormatterProbe.visible(relative.localizedString(fromTimeInterval: -190)))
            print("FORMATTER-PROBE|mac|\(language.rawValue)|relativeDateTime.full.+7505s|"
                  + FormatterProbe.visible(relative.localizedString(fromTimeInterval: 7505)))
            #endif
        }
        for (name, value) in FormatterProbe.regionLines() {
            print("FORMATTER-PROBE|\(Self.system)|-|\(name)|\(value)")
        }
    }
    /// The Mac's outputs (measured with this probe on macOS 26, 2026-11-16) for the formats the popover uses: the day
    /// stamp, the reset clocks, the recap titles and the relative-time units. The first Windows run gave the same
    /// strings for every one of them (stage 7 Task 1 report), so the Windows popover calls the same formatters with the
    /// app language's locale; this keeps it that way on both systems. Escapes as `FormatterProbe.visible` writes them.
    static let macGoldens: [String: [String: String]] = [
        "ko": [
            "units.wide.2h5m5s": "2시간 5분",
            "units.wide.3m10s": "3분 10초",
            "units.wide.45s": "45초",
            "dateInterval.dMMMy.7days": "2026년 9월 10일~16일",
            "template.MdE": "9. 10. (목)",
            "template.HHmm": "19:26",
            "template.EEEEdHHmm": "10일 목요일 19:26",
            "template.EEEE d MMM": "9월 10일 목요일",
            "template.MMMM y": "2026년 9월",
        ],
        "en": [
            "units.wide.2h5m5s": "2 hours, 5 minutes",
            "units.wide.3m10s": "3 minutes, 10 seconds",
            "units.wide.45s": "45 seconds",
            "dateInterval.dMMMy.7days": "Sep 10<U+2009>–<U+2009>16, 2026",
            "template.MdE": "Thu, 9/10",
            "template.HHmm": "19:26",
            "template.EEEEdHHmm": "Thursday 10, 19:26",
            "template.EEEE d MMM": "Thursday, Sep 10",
            "template.MMMM y": "September 2026",
        ],
        "ja": [
            "units.wide.2h5m5s": "2時間 5分",
            "units.wide.3m10s": "3分 10秒",
            "units.wide.45s": "45秒",
            "dateInterval.dMMMy.7days": "2026年9月10日～16日",
            "template.MdE": "9/10(木)",
            "template.HHmm": "19:26",
            "template.EEEEdHHmm": "10日木曜日 19:26",
            "template.EEEE d MMM": "9月10日 木曜日",
            "template.MMMM y": "2026年9月",
        ],
        "fr": [
            "units.wide.2h5m5s": "2<U+A0>heures et 5 minutes",
            "units.wide.3m10s": "3 minutes et 10<U+A0>secondes",
            "units.wide.45s": "45<U+A0>secondes",
            "dateInterval.dMMMy.7days": "10–16 sept. 2026",
            "template.MdE": "jeu. 10/09",
            "template.HHmm": "19:26",
            "template.EEEEdHHmm": "jeudi 10 19:26",
            "template.EEEE d MMM": "jeudi 10 sept.",
            "template.MMMM y": "septembre 2026",
        ],
    ]

    func testThePopoversFormatsAreTheMacs() {
        for (language, expected) in Self.macGoldens {
            let lines = Dictionary(uniqueKeysWithValues: FormatterProbe.lines(language: AppLanguage(rawValue: language)!).map { ($0.0, $0.1) })
            for (name, value) in expected {
                XCTAssertEqual(lines[name], value, "\(language) \(name)")
            }
        }
    }
}
