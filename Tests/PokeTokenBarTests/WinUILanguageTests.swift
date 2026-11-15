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
