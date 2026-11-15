import XCTest
@testable import PokeTokenBar

/// Defect: a Korean Windows showed the app in English (`Locale.preferredLanguages` is empty there). The pure parts of the
/// fix run on both systems; the Win32 reads are in `WinUILanguageTests`.
final class UILanguagesTests: XCTestCase {
    private func language(ui: [String], locale: String? = nil) -> AppLanguage {
        AppLanguage.systemDefault(for: UILanguages.resolve(ui: ui, localeName: locale).first)
    }

    func testDisplayLanguageDecidesTheAppLanguage() {
        XCTAssertEqual(language(ui: ["ko-KR"]), .ko)
        XCTAssertEqual(language(ui: ["ja-JP"]), .ja)
        XCTAssertEqual(language(ui: ["en-US"]), .en)
        XCTAssertEqual(language(ui: ["zh-Hans-CN"]), .en, "unsupported language falls back to English")
    }

    func testOnlyTheFirstPreferredLanguageCountsLikeOnTheMac() {
        XCTAssertEqual(language(ui: ["zh-Hans-CN", "ko-KR"]), .en, "first unsupported, second supported: the Mac reads only the first")
        XCTAssertEqual(language(ui: ["ko-KR", "en-US"]), .ko)
    }

    func testEmptyListFallsBackToTheUserLocaleName() {
        XCTAssertEqual(UILanguages.resolve(ui: [], localeName: "ko-KR"), ["ko-KR"])
        XCTAssertEqual(language(ui: [], locale: "ko-KR"), .ko)
        XCTAssertEqual(UILanguages.resolve(ui: ["", ""], localeName: nil), [])
        XCTAssertEqual(language(ui: [], locale: nil), .en)
        XCTAssertEqual(language(ui: [], locale: ""), .en)
    }

    func testAListWithEntriesIgnoresTheLocaleName() {
        XCTAssertEqual(UILanguages.resolve(ui: ["en-US"], localeName: "ko-KR"), ["en-US"], "the display language, not the regional format")
    }

    func testStoredEnglishFromBeforeDetectionIsCorrectedOnce() {
        XCTAssertEqual(UILanguages.migratedLanguage(stored: .en, detected: .ko, alreadyMigrated: false), .ko)
        XCTAssertNil(UILanguages.migratedLanguage(stored: .en, detected: .ko, alreadyMigrated: true), "once: a later explicit English stays")
        XCTAssertNil(UILanguages.migratedLanguage(stored: .ja, detected: .ko, alreadyMigrated: false), "another stored language is a choice")
        XCTAssertNil(UILanguages.migratedLanguage(stored: .en, detected: .en, alreadyMigrated: false))
        XCTAssertNil(UILanguages.migratedLanguage(stored: .ko, detected: .ko, alreadyMigrated: false))
    }

    #if os(macOS)
    /// The Mac branch of the seam is exactly the call it replaced.
    func testMacPreferredUILanguagesIsLocalePreferredLanguages() {
        XCTAssertEqual(PlatformCompat.preferredUILanguages, Locale.preferredLanguages)
        XCTAssertEqual(AppLanguage.systemDefault, AppLanguage.systemDefault(for: Locale.preferredLanguages.first))
    }
    #endif
}

/// The flag choice per notification kind (defect: `NIIF_RESPECT_QUIET_TIME` dropped every balloon of a new profile).
final class BalloonFlagsTests: XCTestCase {
    func testNoKindRespectsQuietTime() {
        for kind in BalloonQueue.Kind.allCases {
            for sound in [true, false] {
                let flags = BalloonFlags.infoFlags(kind: kind, sound: sound)
                XCTAssertEqual(flags & BalloonFlags.respectQuietTime, 0, "\(kind) sound=\(sound)")
                XCTAssertNotEqual(flags & BalloonFlags.info, 0, "\(kind) is an info balloon")
                XCTAssertEqual(flags & BalloonFlags.noSound != 0, !sound, "\(kind): NIIF_NOSOUND exactly when silent")
            }
        }
    }

    func testTheFlagValuesAreTheWin32Ones() {
        XCTAssertEqual(BalloonFlags.info, 0x1)       // NIIF_INFO
        XCTAssertEqual(BalloonFlags.noSound, 0x10)   // NIIF_NOSOUND
        XCTAssertEqual(BalloonFlags.respectQuietTime, 0x80)  // NIIF_RESPECT_QUIET_TIME
    }
}

/// Defect: the installer's shortcut carried an AppUserModelID the process never set. The three spellings stay equal.
final class WindowsAppUserModelIDScanTests: XCTestCase {
    func testProcessShortcutAndManifestShareOneId() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: root.appendingPathComponent("Sources/PokeTokenBar/Platform/Windows/WinAppUserModelID.swift"), encoding: .utf8)
        let iss = try String(contentsOf: root.appendingPathComponent("installer/PokeTokenBar.iss"), encoding: .utf8)
        let marker = "static let id = \""
        let start = try XCTUnwrap(swift.range(of: marker)).upperBound
        let id = String(swift[start...].prefix { $0 != "\"" })
        XCTAssertFalse(id.isEmpty)
        let shortcuts = iss.components(separatedBy: .newlines).filter { $0.hasPrefix("Name: \"{user") }  // .newlines: a Windows checkout has CRLF
        XCTAssertFalse(shortcuts.isEmpty)
        for line in shortcuts { XCTAssertTrue(line.contains("AppUserModelID: \"\(id)\""), "\(line)") }
    }
}

/// Defect: publishing the IANA name `Etc/UTC` crashed the app at launch (corelibs DateFormatter traps on `Etc/` names).
final class TimeZoneNamesTests: XCTestCase {
    func testEtcNamesBecomeNamesDateFormatterAccepts() {
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/UTC"), "UTC")
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/GMT"), "UTC")
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/GMT+11"), "GMT-1100", "POSIX sign: Windows UTC-11")
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/GMT-12"), "GMT+1200", "Windows UTC+12")
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/GMT+2"), "GMT-0200")
        XCTAssertEqual(TimeZoneNames.foundationSafe("Etc/GMT-13"), "GMT+1300")
    }

    func testOtherNamesAreKept() {
        for name in ["Asia/Seoul", "America/Los_Angeles", "Europe/Berlin", "Etc/Unknown", "Etc/GMT+99"] {
            XCTAssertEqual(TimeZoneNames.foundationSafe(name), name)
        }
    }

    func testTheResultsAreZonesFoundationKnows() {
        for name in ["Etc/UTC", "Etc/GMT+11", "Etc/GMT-12", "Etc/GMT+2"] {
            XCTAssertNotNil(TimeZone(identifier: TimeZoneNames.foundationSafe(name)), name)
        }
    }
}
