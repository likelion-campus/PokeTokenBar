import XCTest
import SwiftUI
import AppKit
@testable import PokeTokenBar

extension PlazaActivityTests {

    // The card's height not depending on the activity is pinned on the panel: `PlazaCardPanelTests.testTheCardIsTheFixedPanelInTheMiddleInEveryState`
    // (it replaced the SwiftUI view's `testCardHeightDoesNotDependOnTheActivity`).

    /// The fixed 380x460 card keeps its header and a usable dex window (two rows of cells) next to the activity section.
    func testProfileCardContentFitsTheFixedPanel() {
        let m = PlazaCardMetrics.self
        let inner = m.panelSize.height - 2 * m.panelInset
        let used = m.spriteSide + m.stackSpacing + m.activityHeight + m.stackSpacing
        XCTAssertGreaterThanOrEqual(inner - used, 2 * m.cellSize.height + m.spacing, "two dex rows stay visible")
        XCTAssertLessThanOrEqual(m.columns * Int(m.cellSize.width) + (m.columns - 1) * Int(m.spacing), Int(m.panelSize.width - 2 * m.panelInset))
    }
}
