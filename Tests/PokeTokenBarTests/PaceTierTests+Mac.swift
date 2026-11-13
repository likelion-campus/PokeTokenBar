import XCTest
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension PaceTierTests {
    /// The fallback lands on the colors `limitColor` draws, so rows without a pace look as before.
    func testTheFallbackTiersMatchTheThresholdColors() {
        XCTAssertEqual(PaceTier.onPace.color, .green)
        XCTAssertEqual(PaceTier.over.color, .orange)
        XCTAssertEqual(PaceTier.wayOver.color, .red)
    }
}
