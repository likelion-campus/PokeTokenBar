import XCTest
@testable import PokeTokenBar

/// The in-app update's texts (`Platform/WindowsUpdateStrings.swift`): every language keeps the version placeholder and says
/// something; the Korean failure line is the plan's (D8 step 8).
final class WindowsUpdateStringsTests: XCTestCase {
    func testEveryLanguageKeepsTheVersionAndHasEveryText() {
        let sentinel = "ZQXVERSION"
        for language in AppLanguage.allCases {
            let l = L(language)
            XCTAssertTrue(l.updateDownloading(sentinel).contains(sentinel), "\(language.rawValue).updateDownloading")
            for (name, text) in [("updateChecking", l.updateChecking), ("updateStartingSetup", l.updateStartingSetup),
                                 ("updateInstallFailed", l.updateInstallFailed), ("updateSetupRunning", l.updateSetupRunning)] {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue).\(name)")
            }
            XCTAssertNotEqual(l.updateInstallFailed, l.updateSetupRunning, language.rawValue)
        }
        XCTAssertEqual(L(.ko).updateInstallFailed, "업데이트를 설치하지 못했어요. 릴리스 페이지에서 직접 설치해 주세요.")
        XCTAssertEqual(L(.en).updateDownloading("2.5.640"), "Downloading version 2.5.640…")
    }
}
