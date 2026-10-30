import XCTest
@testable import PokeTokenBar

final class PlazaTargetingTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testFacingTileIsNextToMe() {
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .up), p(5, 4))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .down), p(5, 6))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .left), p(4, 5))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .right), p(6, 5))
    }

    func testTargetPrefersFacingTile() {
        let members = ["b": p(6, 5), "a": p(5, 5), "c": p(6, 5)]
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: members), "b")
    }

    func testTargetFallsBackToSameTile() {
        let members = ["z": p(5, 5), "y": p(5, 5), "far": p(9, 9)]
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: members), "y")
    }

    func testTargetIsNilWhenNobodyNear() {
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["far": p(9, 9)]))
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: [:]))
    }
}
