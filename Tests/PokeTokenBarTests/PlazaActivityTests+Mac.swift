import XCTest
import SwiftUI
import AppKit
@testable import PokeTokenBar

extension PlazaActivityTests {

    /// The card is an overlay with a fixed panel: the section's height must not depend on how many rows it has.
    @MainActor func testCardHeightDoesNotDependOnTheActivity() {
        let now = Date()
        var a = PlazaActivity(day: PlazaActivity.dayKey(now)); a.record(.pickup)
        func height(_ a: PlazaActivity?) -> CGFloat {
            NSHostingView(rootView: PlazaCardView(state: .failed(member("지아", a)))).fittingSize.height
        }
        XCTAssertEqual(height(a), height(nil), accuracy: 0.5)
    }

    /// The fixed 380x460 card keeps its header and a usable dex window (two rows of cells) next to the activity section.
    func testProfileCardContentFitsTheFixedPanel() {
        let m = PlazaCardMetrics.self
        let inner = m.panelSize.height - 2 * m.panelInset
        let used = m.spriteSide + m.stackSpacing + m.activityHeight + m.stackSpacing
        XCTAssertGreaterThanOrEqual(inner - used, 2 * m.cellSize.height + m.spacing, "two dex rows stay visible")
        XCTAssertLessThanOrEqual(m.columns * Int(m.cellSize.width) + (m.columns - 1) * Int(m.spacing), Int(m.panelSize.width - 2 * m.panelInset))
    }
}
