import XCTest
@testable import PokeTokenBar

final class PlazaCaptionThemeTests: XCTestCase {
    func testColoursAreThePlazaPanelPaletteAsColorRefs() {
        let c = PlazaCaptionTheme.plaza
        XCTAssertEqual(c.caption, 0x5C4F1D)   // hint fill 0x1D4F5C, COLORREF is BGR
        XCTAssertEqual(c.text, 0xF0F8F8)      // cream 0xF8F8F0
        XCTAssertEqual(c.border, 0xBDB75F)    // banner stroke 0x5FB7BD
    }

    func testAlphaIsDroppedAndOutOfRangeIsClamped() {
        XCTAssertEqual(PlazaCaptionTheme.colorRef(PlazaColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.2)), 0x0000FF)
        XCTAssertEqual(PlazaCaptionTheme.colorRef(PlazaColor(srgbRed: 2, green: -1, blue: 0.5)), 0x8000FF)
    }

    func testAppliedOnlyOnWindows11OrNewerWithoutHighContrast() {
        XCTAssertFalse(PlazaCaptionTheme.shouldApply(buildNumber: 19045, highContrast: false))   // Windows 10
        XCTAssertFalse(PlazaCaptionTheme.shouldApply(buildNumber: 21999, highContrast: false))
        XCTAssertTrue(PlazaCaptionTheme.shouldApply(buildNumber: 22000, highContrast: false))
        XCTAssertTrue(PlazaCaptionTheme.shouldApply(buildNumber: 26100, highContrast: false))
        XCTAssertFalse(PlazaCaptionTheme.shouldApply(buildNumber: 26100, highContrast: true))    // B alone: new build, high contrast
        XCTAssertFalse(PlazaCaptionTheme.shouldApply(buildNumber: 19045, highContrast: true))
    }
}
