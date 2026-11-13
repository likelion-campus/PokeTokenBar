import XCTest
import Foundation
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension PlazaPondTests {
    @MainActor
    func testNumbers() {
        XCTAssertEqual(PlazaPond.splashRadius(stage: 0), 1)
        XCTAssertEqual(PlazaPond.splashRadius(stage: 2), 2)
        XCTAssertEqual(PlazaPond.splashRadius(stage: 5), 3)
        XCTAssertEqual(PlazaPond.diveLimit(types: ["water", "flying"]), 15)
        XCTAssertEqual(PlazaPond.diveLimit(types: ["fire"]), 6)
        XCTAssertEqual(PlazaPond.diveLimit(types: nil), 6)
        XCTAssertEqual(PlazaPond.swimSink(spriteHeight: 72), 72 - 32.4, accuracy: 0.0001)
        XCTAssertEqual(PlazaPond.swimSink(spriteHeight: 8), 0)
        XCTAssertEqual(PlazaPond.swimSink(spriteHeight: 20), 10)
        XCTAssertEqual(PlazaPond.plungeStepDuration, 0.36)
        XCTAssertEqual(PlazaPond.plungeStepDuration, PlazaActor.jumpDuration)
    }
}
