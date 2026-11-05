import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaPondTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func block(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Set<TilePoint> {
        Set((0..<w).flatMap { dx in (0..<h).map { dy in TilePoint(x: x0 + dx, y: y0 + dy) } })
    }
    private func shore(_ w: Set<TilePoint>, _ t: TilePoint) -> PlazaPondShore {
        PlazaPond.shore(at: t, isWater: { w.contains($0) })
    }

    func testShoreCellsFollowTheWaterSide() {
        let w = block(5, 5, 3, 2)
        XCTAssertEqual(shore(w, p(6, 4)), .cell(col: 3, row: 6))
        XCTAssertEqual(shore(w, p(6, 7)), .cell(col: 3, row: 8))
        XCTAssertEqual(shore(w, p(4, 5)), .cell(col: 2, row: 7))
        XCTAssertEqual(shore(w, p(8, 5)), .cell(col: 4, row: 7))
        XCTAssertEqual(shore(w, p(4, 4)), .cell(col: 2, row: 6))
        XCTAssertEqual(shore(w, p(8, 4)), .cell(col: 4, row: 6))
        XCTAssertEqual(shore(w, p(4, 7)), .cell(col: 2, row: 8))
        XCTAssertEqual(shore(w, p(8, 7)), .cell(col: 4, row: 8))
        // inner corners: water on two adjacent sides of the land cell
        XCTAssertEqual(shore([p(1, 2), p(2, 1)], p(1, 1)), .cell(col: 3, row: 10)) // S+E
        XCTAssertEqual(shore([p(1, 2), p(0, 1)], p(1, 1)), .cell(col: 2, row: 10)) // S+W
        XCTAssertEqual(shore([p(1, 0), p(2, 1)], p(1, 1)), .cell(col: 3, row: 9))  // N+E
        XCTAssertEqual(shore([p(1, 0), p(0, 1)], p(1, 1)), .cell(col: 2, row: 9))  // N+W
        XCTAssertEqual(shore(w, p(20, 20)), .notShore)
        XCTAssertEqual(shore([p(1, 0), p(1, 2)], p(1, 1)), .unsupported)
        XCTAssertEqual(shore([p(0, 0), p(2, 2)], p(1, 1)), .unsupported)
    }

    func testZMeansPlungeShoreJumpJumpDiveSurface() {
        let w: Set<TilePoint> = [p(6, 5)]
        func act(_ t: TilePoint, _ f: PlazaDirection, diving: Bool = false, canMove: Bool = true,
                 free: Bool = true) -> PlazaPondAction {
            PlazaPond.action(tile: t, facing: f, isDiving: diving, canMove: canMove,
                             isWater: { w.contains($0) }, isFree: { _ in free })
        }
        XCTAssertEqual(act(p(5, 5), .right), .plunge(.right))
        XCTAssertEqual(act(p(5, 5), .right, free: false), .shoreJump)
        XCTAssertEqual(act(p(5, 5), .right, canMove: false), .shoreJump)
        XCTAssertEqual(act(p(5, 5), .up), .shoreJump)
        XCTAssertEqual(act(p(1, 1), .right), .jump)
        XCTAssertEqual(act(p(6, 5), .right), .dive)
        XCTAssertEqual(act(p(6, 5), .right, diving: true), .surface)
        // An egg (cannot move) in the water only hops, or surfaces if it was already diving.
        XCTAssertEqual(act(p(6, 5), .right, canMove: false), .jump)
        XCTAssertEqual(act(p(6, 5), .right, diving: true, canMove: false), .surface)
    }

    func testShoreSplashPrefersTheFacedWater() {
        func s(_ t: TilePoint, _ f: PlazaDirection, _ w: Set<TilePoint>) -> TilePoint? {
            PlazaPond.shoreSplashTile(tile: t, facing: f, isWater: { w.contains($0) })
        }
        let t = p(5, 5)
        XCTAssertEqual(s(t, .left, [p(4, 5), p(5, 4)]), p(4, 5))
        XCTAssertEqual(s(t, .down, [p(4, 5), p(5, 4)]), p(5, 4))
        XCTAssertEqual(s(t, .down, [p(6, 5), p(5, 4), p(4, 5)]), p(5, 4))
        XCTAssertEqual(s(t, .down, [p(6, 5), p(4, 5)]), p(6, 5))
        XCTAssertEqual(s(t, .down, [p(4, 5)]), p(4, 5))
        XCTAssertNil(s(t, .down, []))
    }

    func testWetTargetsAreLandActorsInRangeButNotTheSplasher() {
        let water: Set<TilePoint> = [p(10, 10), p(12, 10)]
        let actors: [(id: String?, tile: TilePoint)] = [
            (id: "a", tile: p(10, 12)),  // distance 2, land
            (id: "b", tile: p(13, 10)),  // distance 3
            (id: "c", tile: p(12, 10)),  // in water
            (id: "d", tile: p(11, 11)),  // splasher
            (id: nil, tile: p(9, 9)),    // me
        ]
        let r = PlazaPond.wetTargets(splash: p(10, 10), radius: 2, splasher: "d", actors: actors,
                                     isWater: { water.contains($0) })
        XCTAssertEqual(r, ["a", nil])
        let mine = PlazaPond.wetTargets(splash: p(10, 10), radius: 2, splasher: nil, actors: actors,
                                        isWater: { water.contains($0) })
        XCTAssertEqual(mine, ["a", "d"])
    }

    func testWetTargetsMeasureChebyshevDistance() {
        let actors: [(id: String?, tile: TilePoint)] = [(id: "diag", tile: p(12, 12))]   // Chebyshev 2, Manhattan 4
        XCTAssertEqual(PlazaPond.wetTargets(splash: p(10, 10), radius: 2, splasher: nil, actors: actors,
                                            isWater: { _ in false }), ["diag"])
        XCTAssertEqual(PlazaPond.wetTargets(splash: p(10, 10), radius: 1, splasher: nil, actors: actors,
                                            isWater: { _ in false }), [])
    }

    func testAWaterTileIsNotShore() {
        XCTAssertEqual(shore([p(1, 1), p(2, 1)], p(1, 1)), .notShore)
    }

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

    func testStepDurationsByTileKind() {
        let w: Set<TilePoint> = [p(1, 0), p(2, 0)]
        func d(_ a: TilePoint, _ b: TilePoint, run: Bool = false) -> TimeInterval {
            PlazaPond.stepDuration(from: a, to: b, running: run, isWater: { w.contains($0) })
        }
        XCTAssertEqual(d(p(0, 0), p(1, 0)), 0.36)
        XCTAssertEqual(d(p(1, 0), p(2, 0)), 0.25)
        XCTAssertEqual(d(p(1, 0), p(2, 0), run: true), 0.25)
        XCTAssertEqual(d(p(2, 0), p(3, 0)), 0.15)
        XCTAssertEqual(d(p(5, 5), p(6, 5)), 0.15)
        XCTAssertEqual(d(p(5, 5), p(6, 5), run: true), 0.075)
    }

    func testNearestEdgeWaterForAWalkTarget() {
        let w = block(5, 5, 3, 3)
        let isWater: (TilePoint) -> Bool = { w.contains($0) }
        let isLand: (TilePoint) -> Bool = { !w.contains($0) }
        // centre (6,6): every edge water cell is at Manhattan distance 1; first in scan order wins
        let r = PlazaPond.nearestEdgeWater(to: p(6, 6), isWater: isWater, isLand: isLand)
        XCTAssertEqual(r, p(6, 5))
        XCTAssertEqual(PlazaPond.nearestEdgeWater(to: p(7, 7), isWater: isWater, isLand: isLand), p(7, 7))
        XCTAssertNil(PlazaPond.nearestEdgeWater(to: p(0, 0), isWater: { _ in false }, isLand: { _ in true }))
    }
}
