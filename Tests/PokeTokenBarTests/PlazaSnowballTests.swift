import XCTest
@testable import PokeTokenBar

final class PlazaSnowballTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testAimHitsTheFirstTargetAhead() async {
        let a = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(14, 12), "b": p(12, 12)], map: map)
        XCTAssertEqual(a?.end, .actor(id: "b", tile: p(12, 12)))
        XCTAssertEqual(a?.frames, 2)
        let b = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(21, 12)], map: map)
        XCTAssertEqual(b?.end, .ground(p(20, 12)))
        XCTAssertEqual(b?.frames, 10)
        let c = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["x": p(10, 12)], map: map)
        XCTAssertEqual(c?.end, .ground(p(20, 12)))
        let edge = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(20, 12)], map: map)
        XCTAssertEqual(edge?.end, .actor(id: "a", tile: p(20, 12)))
        XCTAssertEqual(edge?.frames, 10)
        let past = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(21, 12)], map: map)
        XCTAssertEqual(past?.end, .ground(p(20, 12)))   // eleven tiles away is out of range
        let d = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["b": p(12, 12), "a": p(12, 12)], map: map)
        XCTAssertEqual(d?.end, .actor(id: "a", tile: p(12, 12)))
    }

    func testAimStopsBeforeObstaclesAndFliesOverWater() async {
        let a = PlazaSnowball.aim(from: p(12, 17), facing: .right, targets: ["m": p(16, 17)], map: map)
        XCTAssertEqual(a?.end, .ground(p(14, 17)))
        let b = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: [:], map: map)
        XCTAssertEqual(b?.end, .ground(p(7, 14)))
        let c = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: ["s": p(13, 14)], map: map)
        XCTAssertEqual(c?.end, .actor(id: "s", tile: p(13, 14)))
    }

    func testVerticalThrowsAimAlongTheColumn() async {
        // Column 10: grass at row 11-12, pond rows 13-15, grass again at row 16.
        let down = PlazaSnowball.aim(from: p(10, 11), facing: .down, targets: [:], map: map)
        XCTAssertEqual(down?.end, .ground(p(10, 21)))   // over the pond, ten tiles on
        XCTAssertEqual(down?.frames, 10)
        let swimmer = PlazaSnowball.aim(from: p(10, 11), facing: .down, targets: ["s": p(10, 14), "t": p(10, 15)], map: map)
        XCTAssertEqual(swimmer?.end, .actor(id: "s", tile: p(10, 14)))
        XCTAssertEqual(swimmer?.frames, 3)
        let up = PlazaSnowball.aim(from: p(10, 16), facing: .up, targets: [:], map: map)
        XCTAssertEqual(up?.end, .ground(p(10, 6)))
        let target = PlazaSnowball.aim(from: p(10, 16), facing: .up, targets: ["a": p(10, 13)], map: map)
        XCTAssertEqual(target?.end, .actor(id: "a", tile: p(10, 13)))
        XCTAssertNil(PlazaSnowball.aim(from: p(10, 3), facing: .up, targets: [:], map: map))   // the tree line above
        XCTAssertNil(PlazaSnowball.aim(from: p(15, 16), facing: .down, targets: [:], map: map)) // the bush at (15,17)
    }

    func testFacingAnObstacleOrTheEdgeThrowsNothing() async {
        XCTAssertNil(PlazaSnowball.aim(from: p(3, 12), facing: .left, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(44, 12), facing: .right, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(14, 17), facing: .right, targets: [:], map: map))
    }

    func testHitsNeedTheSameLineTheRightWayWithinEleven() async {
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .left))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(3, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(2, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 11), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(14, 12), target: p(14, 12), direction: .right))
    }

    func testVerticalHitsNeedTheSameColumnTheRightWayWithinEleven() async {
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 9), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 1), direction: .down))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 16), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 17), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(6, 9), direction: .down))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 8), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 15), direction: .up))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 1), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 0), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(4, 8), direction: .up))
    }

    func testFramesAreTheTileCountFromOneToTen() async {
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .down, end: .actor(id: nil, tile: p(0, 10))).frames, 10)
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .down, end: .actor(id: nil, tile: p(0, 14))).frames, 10)
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .right, end: .ground(p(1, 0))).frames, 1)
    }

    func testTheArcStartsAtTheHandPeaksAndEndsOnTheBodyOrTheGround() async {
        XCTAssertEqual(PlazaSnowball.height(at: 0, endHeight: 24), 14)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 24), 24)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 0), 0)
        XCTAssertEqual(PlazaSnowball.height(at: 0.5, endHeight: 0), 23)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 0), 14)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 30), 15)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 80), 24)
    }

    func testBurstPiecesSpreadToThirtyTwoAndStayUpOnAMiss() async {
        let radius: [CGFloat] = [18, 22, 28, 32], drop: [CGFloat] = [0, 2, 8, 16], glyphs = [1, 0, 1, 2]
        for step in 0..<4 {
            let ground = PlazaSnowball.burstPieces(step: step, onGround: true)
            let air = PlazaSnowball.burstPieces(step: step, onGround: false)
            XCTAssertEqual(ground.count, step == 0 ? 5 : 5)
            XCTAssertEqual(air.count, step == 0 ? 5 : 6)
            if step == 0 {
                for set in [ground, air] {
                    XCTAssertTrue(set.contains { $0.offset == CGVector(dx: 0, dy: 0) && $0.glyph == 0 })
                }
            }
            for piece in air where !(step == 0 && piece.offset == .zero) {
                XCTAssertEqual(piece.glyph, glyphs[step])
                XCTAssertEqual(hypot(piece.offset.dx, piece.offset.dy + drop[step]), radius[step], accuracy: 1e-9)
                XCTAssertLessThanOrEqual(radius[step], 32)
            }
            for piece in ground {
                XCTAssertLessThanOrEqual(abs(piece.offset.dx), 32)
                XCTAssertGreaterThanOrEqual(piece.offset.dy, 0)
            }
        }
    }

    func testShadedGridsAddTheShadeRightAndBelow() async {
        XCTAssertEqual(PlazaSnowballArt.shaded([".W.", "WWW", ".W."]), [".Wo.", "WWWo", "oWo.", ".o.."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["WW", "WS"]), ["WWo", "WSo", "oo."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["W"]), ["Wo", "o."])
    }
}
