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
            // Mac only: corelibs has no RelativeDateTimeFormatter, and its DateComponentsFormatter is NSUnsupported().
            for seconds in [7505.0, 190, 45] {
                print("FORMATTER-PROBE|mac|\(language.rawValue)|dateComponents.abbreviated.\(Int(seconds))s|"
                      + FormatterProbe.dateComponentsAbbreviated(seconds, language: language))
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
}
