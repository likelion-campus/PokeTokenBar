import XCTest
import Foundation
@testable import PokeTokenBar

final class PlazaSnowTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func mark(_ x: CGFloat, _ y: CGFloat, _ alongX: Bool) -> PlazaSnow.Footprint {
        PlazaSnow.Footprint(center: CGPoint(x: x, y: y), alongX: alongX)
    }

    func testSnowGroundIsGrassFlowersAndShelter() {
        for t in [p(10, 10), p(5, 4), p(22, 4)] { XCTAssertTrue(PlazaSnow.isSnowGround(t, in: map), "\(t)") }
        for t in [p(5, 5), p(5, 13), p(15, 4), p(23, 4), p(23, 15), p(0, 0), p(-1, 5)] {
            XCTAssertFalse(PlazaSnow.isSnowGround(t, in: map), "\(t)")
        }
    }

    func testAStepLeavesTwoMarksBesideThePath() {
        XCTAssertEqual(PlazaSnow.footprints(from: p(10, 10), to: p(11, 10), map: map), [mark(344, 345, true), mark(360, 351, true)])
        XCTAssertEqual(PlazaSnow.footprints(from: p(10, 10), to: p(10, 11), map: map), [mark(339, 356, false), mark(333, 372, false)])
    }

    func testMarksSkipTallGrassAndWater() {
        XCTAssertEqual(PlazaSnow.footprints(from: p(12, 5), to: p(11, 5), map: map), [mark(392, 191, true)])
        XCTAssertEqual(PlazaSnow.footprints(from: p(5, 12), to: p(5, 13), map: map), [])
        XCTAssertEqual(PlazaSnow.footprints(from: p(5, 13), to: p(5, 12), map: map), [])
    }

    func testMarksFadeInThreeSteps() {
        for (age, alpha) in [(0.0, 1.0), (4.49, 1), (4.5, 0.66), (6.49, 0.66), (6.5, 0.33), (8.99, 0.33)] as [(Double, CGFloat)] {
            XCTAssertEqual(PlazaSnow.footprintAlpha(age: age), alpha, "\(age)")
        }
        XCTAssertNil(PlazaSnow.footprintAlpha(age: 9))
    }
}
