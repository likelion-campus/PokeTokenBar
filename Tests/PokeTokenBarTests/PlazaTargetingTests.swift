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

    func testTargetFallsBackToTilesBesideMe() {
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["n": p(5, 4)]), "n")
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["w": p(4, 5), "s": p(5, 6)]), "s",
                       "up, down, left, right order")
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["n": p(5, 4), "e": p(6, 5)]), "e",
                       "the facing tile still comes first")
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["d": p(6, 6)]), "diagonal is not beside")
    }

    func testTargetIsNilWhenNobodyNear() {
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["far": p(9, 9)]))
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: [:]))
    }

    func testSpaceReachesTheCampfireLikeTheBoard() {
        let map = PlazaMapData.map
        XCTAssertEqual(PlazaInteraction.target(from: p(23, 14), facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .campfire, facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: p(22, 15), facing: .up, map: map, members: [:]),
                       PlazaInteractionHit(target: .campfire, facing: .right))
        XCTAssertEqual(PlazaInteraction.target(from: p(22, 15), facing: .up, map: map, members: ["m": p(22, 14)]),
                       PlazaInteractionHit(target: .member("m"), facing: .up), "a member on the faced tile beats a side pit")
    }
}
