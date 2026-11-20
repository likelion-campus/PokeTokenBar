// PlazaFireworksTests+Mac: the firework tests that need the shortcut guide's size (the panel, measured with the Mac's real text)
import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaFireworksTests {
    private func guideSize(snowDay: Bool = false) throws -> CGSize {
        let model = PlazaShortcutGuideModel()
        model.season = snowDay ? .winter : .summer
        let panel = PlazaShortcutGuidePanel(model: model, toggle: PlazaBackgroundTogglePanel(model: PlazaBackgroundModel()))
        let size = panel.size(in: .zero, scale: 1, text: PlatformPlaza.graphics.text)
        return CGSize(width: size.width - 2 * PlazaPanelStyle.strokeRoom, height: size.height - 2 * PlazaPanelStyle.strokeRoom)
    }

    /// `coveredWidth` is written by hand, so a longer row must not outgrow it unnoticed.
    func testTheGuideFitsItsCoveredWidth() async throws {
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + (try guideSize()).width, PlazaShortcutGuide.coveredWidth)
    }

    /// The V row of snow days must not outgrow the smallest window or the covered width either.
    func testTheSnowDayGuideFitsTheSmallestWindowAndItsWidth() async throws {
        let size = try guideSize(snowDay: true)
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + size.width, PlazaShortcutGuide.coveredWidth)
        XCTAssertLessThanOrEqual(46 + size.height, PlazaWindowController.minContentSize.height)
    }
}

extension PlazaFireworksTests {
    /// Adding the F row made the unfolded guide taller than the smallest window. It sits 46 points below the top.
    func testTheGuideFitsTheSmallestWindow() async throws {
        XCTAssertLessThanOrEqual(46 + (try guideSize()).height, PlazaWindowController.minContentSize.height)
    }
}
