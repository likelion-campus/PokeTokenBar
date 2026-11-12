import XCTest
@testable import PokeTokenBar

final class PlazaWalkerTests: XCTestCase {
    private let open: (TilePoint) -> Bool = { _ in true }
    private func run(_ w: inout PlazaWalker, _ seconds: Double, canEnter: (TilePoint) -> Bool = { _ in true }) {
        var t = 0.0; while t < seconds - 1e-9 { w.advance(by: 1.0 / 60, canEnter: canEnter); t += 1.0 / 60 }
    }

    func testClearInputDropsPendingTap() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.clearInput()
        run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 5, y: 5)); XCTAssertFalse(w.isWalking); XCTAssertEqual(w.facing, .down)
        w.press(.right); w.release(.right); w.clearInput()
        run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 5, y: 5))
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
        let steps = Int(1.0 / PlazaWalker.stepDuration)
        XCTAssertTrue((5 + steps - 1...5 + steps + 1).contains(w.tile.y)); XCTAssertTrue(w.isWalking)
    }

    func testBlockedTurnsWithoutMoving() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.left); w.release(.left)
        run(&w, 0.5, canEnter: { _ in false })
        XCTAssertEqual(w.tile, .init(x: 5, y: 5)); XCTAssertEqual(w.facing, .left)
    }

    func testLastPressedDirectionWins() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        let step = PlazaWalker.stepDuration
        w.press(.right); run(&w, step / 2); w.press(.up); run(&w, step * 2)
        // Up stays held, so the walker keeps going up after the right step; float accumulation decides whether the next step has begun.
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

    /// 0.2s felt slow to react: a step always finishes before a release or a turn counts.
    func testStepIsPointOneFiveSeconds() { XCTAssertEqual(PlazaWalker.stepDuration, 0.15) }

    /// With Shift a step takes half as long, and the step is marked as running while it lasts.
    func testRunningStepTakesHalfAsLong() {
        var w = PlazaWalker(tile: TilePoint(x: 5, y: 5))
        w.wantsToRun = true
        w.press(.right); w.release(.right)
        w.advance(by: PlazaWalker.runStepDuration / 2) { _ in true }
        XCTAssertTrue(w.isRunning)
        XCTAssertEqual(w.footPoint.x, PlazaWalker.footPoint(from: TilePoint(x: 5, y: 5), to: TilePoint(x: 6, y: 5), progress: 0.5).x,
                       accuracy: 1e-9)
        w.advance(by: PlazaWalker.runStepDuration / 2) { _ in true }
        XCTAssertFalse(w.isWalking)
        XCTAssertFalse(w.isRunning)
        XCTAssertEqual(w.tile, TilePoint(x: 6, y: 5))
    }

    /// Held for 0.55s (clear of any step boundary), running covers twice the tiles walking does.
    func testHoldingShiftCoversTwiceTheGround() {
        func tiles(running: Bool) -> Int {
            var w = PlazaWalker(tile: TilePoint(x: 0, y: 5))
            w.wantsToRun = running
            w.press(.right)
            for _ in 0..<55 { w.advance(by: 0.01) { _ in true } }
            return w.tile.x
        }
        XCTAssertEqual(tiles(running: false), 4)
        XCTAssertEqual(tiles(running: true), 8)
    }

    /// Letting go of Shift slows the next step, not the one under way.
    func testShiftChangesTakeEffectOnTheNextStep() {
        var w = PlazaWalker(tile: TilePoint(x: 5, y: 5))
        w.wantsToRun = true
        w.press(.right)
        w.advance(by: 0.01) { _ in true }
        w.wantsToRun = false
        XCTAssertTrue(w.isRunning, "the step under way keeps its pace")
        w.advance(by: PlazaWalker.runStepDuration) { _ in true }
        XCTAssertTrue(w.isWalking)
        XCTAssertFalse(w.isRunning, "the next step walks")
    }

    func testFootPointInterpolatesHalfway() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right)
        w.advance(by: PlazaWalker.stepDuration / 2, canEnter: { _ in true })
        XCTAssertEqual(w.footPoint.x, (5.5 + 0.5) * 32, accuracy: 1.0)
        XCTAssertEqual(w.footPoint.y, 5.875 * 32, accuracy: 0.001)
    }

    func testStepDurationClosureSetsStepLengthAndNilKeepsRules() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.release(.right)
        w.advance(by: 0.1, canEnter: { _ in true }, stepDuration: { _, _, _ in 0.5 })
        XCTAssertTrue(w.isWalking)
        w.advance(by: 0.41, canEnter: { _ in true }, stepDuration: { _, _, _ in 0.5 })
        XCTAssertFalse(w.isWalking)
        w.wantsToRun = true
        w.press(.right); w.release(.right)
        w.advance(by: 0.08, canEnter: { _ in true })
        XCTAssertFalse(w.isWalking, "nil closure keeps the run pace")
    }

    func testPlungeIgnoresCanEnterAndBeatsPendingTap() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.left); w.release(.left)
        w.plunge(.down)
        w.advance(by: 0.01, canEnter: { _ in false }, stepDuration: { _, _, _ in 0.36 })
        XCTAssertEqual(w.tile, .init(x: 5, y: 6)); XCTAssertEqual(w.facing, .down)
        w.advance(by: 0.4, canEnter: { _ in false })
        XCTAssertEqual(w.tile, .init(x: 5, y: 6), "the tap was dropped")
    }

    func testPlungeDropsAPendingPush() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.push(.up, tiles: 3)
        w.plunge(.right)
        w.advance(by: 2, canEnter: { _ in true }, stepDuration: { _, _, _ in 0.36 })
        XCTAssertEqual(w.tile, .init(x: 6, y: 5), "a swimmer is not pushed after the plunge")
    }

    func testIsSlidingOnlyDuringAPushStep() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        XCTAssertFalse(w.isSliding)
        w.push(.right, tiles: 2)
        w.advance(by: 0.05, canEnter: open)
        XCTAssertTrue(w.isSliding)
        run(&w, 0.5)
        XCTAssertFalse(w.isWalking); XCTAssertEqual(w.tile, .init(x: 7, y: 5))
        w.press(.down)
        w.advance(by: 0.05, canEnter: open)
        XCTAssertTrue(w.isWalking); XCTAssertFalse(w.isSliding)
        var d = PlazaWalker(tile: .init(x: 5, y: 5))
        d.plunge(.right)
        d.advance(by: 0.05, canEnter: open)
        XCTAssertTrue(d.isWalking); XCTAssertFalse(d.isSliding)
    }
}
