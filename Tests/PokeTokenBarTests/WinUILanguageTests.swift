#if os(Windows)
import XCTest
@testable import PokeTokenBar

@MainActor
final class WinUILanguageTests: XCTestCase {
    private func apis(ui: [String], locale: String?) -> WinUILanguage.APIs {
        .init(uiLanguages: { ui }, localeName: { locale })
    }

    func testInjectedApiResults() async {
        XCTAssertEqual(AppLanguage.systemDefault(for: WinUILanguage.preferred(apis(ui: ["ko-KR", "en-US"], locale: "en-US")).first), .ko)
        XCTAssertEqual(AppLanguage.systemDefault(for: WinUILanguage.preferred(apis(ui: ["ja-JP"], locale: nil)).first), .ja)
        XCTAssertEqual(AppLanguage.systemDefault(for: WinUILanguage.preferred(apis(ui: ["en-US"], locale: "ko-KR")).first), .en)
        XCTAssertEqual(AppLanguage.systemDefault(for: WinUILanguage.preferred(apis(ui: ["zh-Hans-CN"], locale: "ko-KR")).first), .en)
        XCTAssertEqual(AppLanguage.systemDefault(for: WinUILanguage.preferred(apis(ui: [], locale: "ko-KR")).first), .ko)
        XCTAssertEqual(WinUILanguage.preferred(apis(ui: [], locale: nil)), [])
    }

    func testMultiStringParsing() async {
        let units = Array("ko-KR".utf16) + [0] + Array("en-US".utf16) + [0, 0]
        XCTAssertEqual(WinUILanguage.multiString(units), ["ko-KR", "en-US"])
        XCTAssertEqual(WinUILanguage.multiString([0, 0]), [])
        XCTAssertEqual(WinUILanguage.multiString(Array("fr-FR".utf16)), ["fr-FR"], "an unterminated tail is kept")
    }

    /// The trigger of the defect: corelibs' list is empty on Windows while Win32 has the display languages.
    func testTheRealApisGiveTheDisplayLanguageWhereCorelibsGivesNone() async {
        let win32 = WinUILanguage.win32UILanguages()
        XCTAssertFalse(win32.isEmpty, "GetUserPreferredUILanguages returns the display languages on any Windows")
        XCTAssertEqual(PlatformCompat.preferredUILanguages, WinUILanguage.preferred())
        XCTAssertEqual(AppLanguage.systemDefault, AppLanguage.systemDefault(for: win32.first))
    }

    func testMigrationSavesTheDetectedLanguageOnceAndOnlyOverAnUnchosenEnglish() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("companion.json")
        try Data("{\"language\":\"en\"}".utf8).write(to: file)
        let defaults = TestDefaults.make(suite: "ptb.test.language.\(UUID().uuidString)")
        let store = CompanionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(store.language, .en)
        WinUILanguage.migrateStoredLanguage(companion: store, defaults: defaults, detected: .ko)
        XCTAssertEqual(store.language, .ko)
        store.setLanguage(.en)  // a later explicit choice
        WinUILanguage.migrateStoredLanguage(companion: store, defaults: defaults, detected: .ko)
        XCTAssertEqual(store.language, .en, "the migration runs once")
        let reloaded = CompanionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(reloaded.language, .en)
    }
}
#endif

#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Defect found with the language one: Foundation's Windows `TimeZone.current` feeds the LOCALIZED zone name to ICU.
@MainActor
final class WinTimeZoneTests: XCTestCase {
    func testIcuKnowsTheEnglishZoneIdButNotTheLocalizedName() async {
        XCTAssertEqual(WinTimeZone.iana(forWindowsID: "Korea Standard Time"), "Asia/Seoul")
        XCTAssertEqual(WinTimeZone.iana(forWindowsID: "UTC"), "Etc/UTC", "a zone whose StandardName differs from its id")
        XCTAssertNil(WinTimeZone.iana(forWindowsID: "대한민국 표준시"), "the Korean StandardName: why Foundation falls back to GMT")
        XCTAssertNil(WinTimeZone.iana(forWindowsID: "Coordinated Universal Time"), "UTC's English StandardName fails the same way")
    }

    func testPublishedZoneBecomesTimeZoneCurrentAndAUserTZWins() async {
        let saved = ProcessInfo.processInfo.environment["TZ"]
        defer { PlatformCompat.setEnvironment("TZ", saved); NSTimeZone.resetSystemTimeZone() }
        PlatformCompat.setEnvironment("TZ", nil)
        guard let name = WinTimeZone.publishSystemZone() else { return XCTFail("the OS ICU resolves this machine's zone") }
        NSTimeZone.resetSystemTimeZone()
        XCTAssertEqual(TimeZone.current.secondsFromGMT(), TimeZone(identifier: name)?.secondsFromGMT(), "UTC is spelled GMT by Foundation: compare the offset")
        XCTAssertNotEqual(TimeZone.current.identifier, "")
        // The trigger of the launch crash: a DateFormatter on the published zone must not trap.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        XCTAssertFalse(f.string(from: Date()).isEmpty)
        PlatformCompat.setEnvironment("TZ", "Asia/Seoul")  // set by the user, not by us
        XCTAssertNil(WinTimeZone.publishSystemZone())
        XCTAssertEqual(ProcessInfo.processInfo.environment["TZ"], "Asia/Seoul")
    }
}
#endif
