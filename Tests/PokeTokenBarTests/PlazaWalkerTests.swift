import XCTest
@testable import PokeTokenBar

final class PlazaWalkerTests: XCTestCase {
    private let open: (TilePoint) -> Bool = { _ in true }
    private func run(_ w: inout PlazaWalker, _ seconds: Double, canEnter: (TilePoint) -> Bool = { _ in true }) {
        var t = 0.0; while t < seconds - 1e-9 { w.advance(by: 1.0 / 60, canEnter: canEnter); t += 1.0 / 60 }
    }

    func testTapMovesExactlyOneTile() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.release(.right)
        run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 6, y: 5)); XCTAssertFalse(w.isWalking); XCTAssertEqual(w.facing, .right)
    }

    func testHoldKeepsWalking() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.down); run(&w, 1.0)
        XCTAssertTrue((9...11).contains(w.tile.y)); XCTAssertTrue(w.isWalking)
    }

    func testBlockedTurnsWithoutMoving() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.left); w.release(.left)
        run(&w, 0.5, canEnter: { _ in false })
        XCTAssertEqual(w.tile, .init(x: 5, y: 5)); XCTAssertEqual(w.facing, .left)
    }

    func testLastPressedDirectionWins() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); run(&w, 0.1); w.press(.up); run(&w, 0.4)
        // Up stays held, so the walker keeps going up after the right step; float accumulation decides whether the third step has landed.
        XCTAssertEqual(w.tile.x, 6)
        XCTAssertTrue((3...4).contains(w.tile.y)); XCTAssertEqual(w.facing, .up)
    }

    func testReleaseMidStepFinishesStep() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); run(&w, 0.1); w.release(.right); run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 6, y: 5)); XCTAssertFalse(w.isWalking)
    }

    func testReleaseAllStopsAfterCurrentStep() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.press(.down); run(&w, 0.1); w.releaseAll(); run(&w, 1.0)
        XCTAssertFalse(w.isWalking)
        XCTAssertEqual(abs(w.tile.x - 5) + abs(w.tile.y - 5), 1)
    }

    func testStepIsPointTwoSeconds() { XCTAssertEqual(PlazaWalker.stepDuration, 0.2) }

    func testFootPointInterpolatesHalfway() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right)
        w.advance(by: PlazaWalker.stepDuration / 2, canEnter: { _ in true })
        XCTAssertEqual(w.footPoint.x, (5.5 + 0.5) * 32, accuracy: 1.0)
        XCTAssertEqual(w.footPoint.y, 5.875 * 32, accuracy: 0.001)
    }
}
