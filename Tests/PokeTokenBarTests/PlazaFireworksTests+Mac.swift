// PlazaFireworksTests+Mac: the firework tests that need the SwiftUI shortcut guide or its render
import XCTest
import SwiftUI
import AppKit
@testable import PokeTokenBar

extension PlazaFireworksTests {
    private func guideSize(snowDay: Bool = false) throws -> CGSize {
        let model = PlazaShortcutGuideModel()
        model.season = snowDay ? .winter : .summer
        let renderer = ImageRenderer(content: PlazaShortcutGuide(model: model, toggle: {}))
        renderer.scale = 1
        return try XCTUnwrap(renderer.nsImage?.size)
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
