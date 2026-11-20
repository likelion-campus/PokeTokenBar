import XCTest
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension LimitPaceTests {
    func testMarkerFractionMirrorsRemainingDisplayMode() throws {
        XCTAssertEqual(try XCTUnwrap(LimitProgressBar.markerFraction(pace: 0.25, mode: .used)),
                       0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LimitProgressBar.markerFraction(pace: 0.25, mode: .remaining)),
                       0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LimitProgressBar.markerFraction(pace: 1, mode: .remaining)),
                       0, accuracy: 0.0001)
        XCTAssertNil(LimitProgressBar.markerFraction(pace: nil, mode: .used))
        XCTAssertNil(LimitProgressBar.markerFraction(pace: nil, mode: .remaining))
    }
}
