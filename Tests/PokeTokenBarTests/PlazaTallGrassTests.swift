import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaTallGrassTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func block(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Set<TilePoint> {
        Set((0..<w).flatMap { dx in (0..<h).map { dy in TilePoint(x: x0 + dx, y: y0 + dy) } })
    }
    private func slice(_ g: Set<TilePoint>, _ t: TilePoint) -> PlazaTallGrassSlice {
        PlazaTallGrass.slice(at: t, isGrass: { g.contains($0) })
    }

    func testSliceFollowsNeighbours() {
        let g = block(10, 10, 3, 3)
        XCTAssertEqual(slice(g, p(10, 10)), PlazaTallGrassSlice(col: 0, row: 0))
        XCTAssertEqual(slice(g, p(11, 10)), PlazaTallGrassSlice(col: 1, row: 0))
        XCTAssertEqual(slice(g, p(11, 11)), PlazaTallGrassSlice(col: 1, row: 1))
        XCTAssertEqual(slice(g, p(12, 12)), PlazaTallGrassSlice(col: 2, row: 2))
        let two = block(0, 0, 2, 2)
        XCTAssertEqual(slice(two, p(0, 0)), PlazaTallGrassSlice(col: 0, row: 0))
        XCTAssertEqual(slice(two, p(1, 0)), PlazaTallGrassSlice(col: 2, row: 0))
        XCTAssertEqual(slice(two, p(0, 1)), PlazaTallGrassSlice(col: 0, row: 2))
        XCTAssertEqual(slice(two, p(1, 1)), PlazaTallGrassSlice(col: 2, row: 2))
        let tall = block(0, 0, 2, 4)
        XCTAssertEqual(slice(tall, p(0, 1)), PlazaTallGrassSlice(col: 0, row: 1))
    }

    private let grass: Set<TilePoint> = [TilePoint(x: 5, y: 5), TilePoint(x: 6, y: 5)]
    private func conceal(_ t: TilePoint, _ step: PlazaStep?, lift: CGFloat = 0) -> CGFloat {
        PlazaTallGrass.concealment(tile: t, step: step, jumpLift: lift, isGrass: { self.grass.contains($0) })
    }

    func testConcealmentStandingInsideAndOutside() {
        XCTAssertEqual(conceal(p(5, 5), nil), 1)
        XCTAssertEqual(conceal(p(1, 1), nil), 0)
    }

    func testConcealmentBlendsAcrossAStep() {
        XCTAssertEqual(conceal(p(5, 5), PlazaStep(from: p(4, 5), to: p(5, 5), progress: 0.25)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(4, 5), PlazaStep(from: p(5, 5), to: p(4, 5), progress: 0.25)), 0.75, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(6, 5), PlazaStep(from: p(5, 5), to: p(6, 5), progress: 0.4)), 1, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(2, 5), PlazaStep(from: p(1, 5), to: p(2, 5), progress: 0.4)), 0, accuracy: 1e-9)
    }

    func testAJumpRevealsAndLandingHidesAgain() {
        XCTAssertEqual(conceal(p(5, 5), nil, lift: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(5, 5), nil, lift: 3.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(5, 5), nil, lift: 7), 0, accuracy: 1e-9)
        XCTAssertEqual(conceal(p(5, 5), nil, lift: 14), 0, accuracy: 1e-9)
    }

    func testMyOpacityNeverDropsBelowFortyPercent() {
        XCTAssertEqual(PlazaTallGrass.opacity(concealment: 1, isMe: true), 0.4, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.opacity(concealment: 1, isMe: false), 0, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.opacity(concealment: 0.3, isMe: false), 0.7, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.opacity(concealment: 0.3, isMe: true), 0.7, accuracy: 1e-9)
    }

    func testThePlateDropsToJustAboveTheGrass() {
        func y(_ c: CGFloat) -> CGFloat { PlazaTallGrass.plateBaseY(spriteTopY: 200, footSceneY: 100, concealment: c) }
        XCTAssertEqual(y(0), 200, accuracy: 1e-9)
        XCTAssertEqual(y(0.25), 165, accuracy: 1e-9)
        XCTAssertEqual(y(0.5), 130, accuracy: 1e-9)
        XCTAssertEqual(y(1), 130, accuracy: 1e-9)
    }

    private func cues(_ a: TilePoint, _ b: TilePoint) -> [PlazaRustleCue] {
        PlazaTallGrass.cues(from: a, to: b, isGrass: { self.grass.contains($0) })
    }

    func testHorizontalStepsSwayTheWayTheyGo() {
        XCTAssertEqual(cues(p(4, 5), p(5, 5)), [PlazaRustleCue(tile: p(5, 5), kind: .sway(1), strong: true, delay: 0)])
        XCTAssertEqual(cues(p(6, 5), p(5, 5)), [
            PlazaRustleCue(tile: p(5, 5), kind: .sway(-1), strong: true, delay: 0),
            PlazaRustleCue(tile: p(6, 5), kind: .sway(-1), strong: false, delay: 0.05),
        ])
    }

    func testVerticalStepsBounce() {
        XCTAssertEqual(cues(p(5, 6), p(5, 5)), [PlazaRustleCue(tile: p(5, 5), kind: .bounce, strong: true, delay: 0)])
        XCTAssertEqual(cues(p(5, 5), p(5, 6)), [PlazaRustleCue(tile: p(5, 5), kind: .bounce, strong: false, delay: 0.05)])
    }

    func testNoCuesOutsideGrass() {
        XCTAssertEqual(cues(p(1, 1), p(2, 1)), [])
    }

    func testSwayAndBounceOffsets() {
        func o(_ k: PlazaRustleKind, _ s: Bool, _ t: TimeInterval) -> String {
            guard let v = PlazaTallGrass.offset(k, strong: s, elapsed: t) else { return "nil" }
            return "\(v.dx),\(v.dy)"
        }
        XCTAssertEqual(o(.sway(1), true, 0.05), "1,0")
        XCTAssertEqual(o(.sway(1), true, 0.15), "-1,0")
        XCTAssertEqual(o(.sway(1), true, 0.25), "0,0")
        XCTAssertEqual(o(.sway(1), true, 0.31), "nil")
        XCTAssertEqual(o(.sway(-1), true, 0.05), "-1,0")
        XCTAssertEqual(o(.sway(1), false, 0.05), "1,0")
        XCTAssertEqual(o(.sway(1), false, 0.15), "0,0")
        XCTAssertEqual(o(.sway(1), false, 0.21), "nil")
        XCTAssertEqual(o(.bounce, true, 0.1), "0,-1")
        XCTAssertEqual(o(.bounce, true, 0.16), "nil")
        XCTAssertEqual(o(.bounce, false, 0.05), "0,-1")
        XCTAssertEqual(o(.bounce, false, 0.11), "nil")
        XCTAssertEqual(PlazaTallGrass.duration(.sway(1), strong: true), 0.3, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.duration(.sway(1), strong: false), 0.2, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.duration(.bounce, strong: true), 0.15, accuracy: 1e-9)
        XCTAssertEqual(PlazaTallGrass.duration(.bounce, strong: false), 0.1, accuracy: 1e-9)
    }

    func testWalkerAndRemoteMotionExposeTheirStep() {
        let start = p(5, 5), next = p(6, 5)
        var w = PlazaWalker(tile: start)
        XCTAssertNil(w.currentStep)
        w.press(.right)
        w.advance(by: 0.075, canEnter: { _ in true })
        XCTAssertEqual(w.currentStep, PlazaStep(from: start, to: next, progress: 0.5))
        w.release(.right)
        w.advance(by: 0.1, canEnter: { _ in true })
        XCTAssertNil(w.currentStep)

        var r = PlazaRemoteMotion(tile: start, facing: .down)
        XCTAssertNil(r.currentStep)
        r.moveTo(next)
        r.advance(by: 0.075)
        XCTAssertEqual(r.currentStep, PlazaStep(from: start, to: next, progress: 0.5))
        r.advance(by: 1)
        XCTAssertNil(r.currentStep)
    }
}
