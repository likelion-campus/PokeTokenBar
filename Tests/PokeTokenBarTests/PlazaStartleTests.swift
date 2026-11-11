import XCTest
@testable import PokeTokenBar

/// The startle rule: a jump from tall grass makes the teammate right beside it, outside the grass, hop.
/// Patch A covers x 5-11, y 5-8; row 4 above it is open ground.
final class PlazaStartleTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func isGrass(_ t: TilePoint) -> Bool { map.tile(at: t) == .tallGrass }

    func testAJumpFromGrassStartlesTheNeighbourOutside() {
        XCTAssertTrue(PlazaStartle.startles(jumper: p(7, 5), victim: p(7, 4), isGrass: isGrass))
    }

    func testAJumpFromOpenGroundStartlesNobody() {
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 4), victim: p(8, 4), isGrass: isGrass))
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 4), victim: p(7, 5), isGrass: isGrass), "the one in the grass is not the one surprised")
    }

    func testANeighbourAlsoInTheGrassIsNotStartled() {
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 5), victim: p(8, 5), isGrass: isGrass),
                       "so a startled hop never startles a third member")
    }

    func testOnlyTheTileRightBesideCounts() {
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 5), victim: p(7, 3), isGrass: isGrass))
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 5), victim: p(6, 4), isGrass: isGrass), "diagonal")
        XCTAssertFalse(PlazaStartle.startles(jumper: p(7, 5), victim: p(7, 5), isGrass: isGrass), "same tile")
    }

    func testTargetsAreTheNeighboursAJumpWouldStartleInIDOrder() {
        let members = ["b": p(7, 4), "a": p(4, 5), "in": p(8, 5), "far": p(7, 2)]
        XCTAssertEqual(PlazaStartle.targets(me: p(5, 5), members: members, isGrass: isGrass), ["a"])
        XCTAssertEqual(PlazaStartle.targets(me: p(7, 5), members: members, isGrass: isGrass), ["b"])
        XCTAssertEqual(PlazaStartle.targets(me: p(7, 4), members: members, isGrass: isGrass), [], "I am not hidden")
        let two = ["b": p(5, 4), "a": p(4, 5)]
        XCTAssertEqual(PlazaStartle.targets(me: p(5, 5), members: two, isGrass: isGrass), ["a", "b"])
    }
}
