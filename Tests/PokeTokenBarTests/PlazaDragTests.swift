import XCTest
@testable import PokeTokenBar

final class PlazaDragTests: XCTestCase {
    private let open: (TilePoint) -> Bool = { _ in true }
    private let ground: (TilePoint) -> Bool = { PlazaMapData.map.isWalkable($0) }
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func body(_ x: Int, _ y: Int, _ size: Int) -> PlazaBody { PlazaBody(foot: p(x, y), size: size) }

    func testTheTunablesAreTheSpecsStartingValues() {
        XCTAssertEqual(PlazaShove.receiveCooldown, 1)
        XCTAssertEqual(TeamEmote.pushTileRange, 1...3)
    }

    func testOppositeFlipsEveryDirection() {
        XCTAssertEqual(PlazaDirection.allCases.map(\.opposite), [.down, .up, .right, .left])
        XCTAssertEqual(PlazaDirection.allCases.map { $0.opposite.opposite }, PlazaDirection.allCases)
    }

    func testALineIsARowOrAColumnButNotTheSameTile() {
        let o = p(5, 5)
        XCTAssertEqual(PlazaDrag.line(from: o, to: p(8, 5)), .right)
        XCTAssertEqual(PlazaDrag.line(from: o, to: p(2, 5)), .left)
        XCTAssertEqual(PlazaDrag.line(from: o, to: p(5, 1)), .up)
        XCTAssertEqual(PlazaDrag.line(from: o, to: p(5, 9)), .down)
        XCTAssertNil(PlazaDrag.line(from: o, to: o))
        XCTAssertNil(PlazaDrag.line(from: o, to: p(6, 6)))
    }

    func testADragNeedsTheSameLineAndTouchingBodies() {
        let t = body(5, 5, 1)
        XCTAssertEqual(PlazaDrag.direction(puller: body(6, 5, 1), target: t), .right)
        XCTAssertNil(PlazaDrag.direction(puller: body(7, 5, 1), target: t))
        XCTAssertEqual(PlazaDrag.direction(puller: body(5, 8, 3), target: t), .down)
        XCTAssertNil(PlazaDrag.direction(puller: body(5, 9, 3), target: t))
        XCTAssertNil(PlazaDrag.direction(puller: body(6, 6, 2), target: t))
        XCTAssertNil(PlazaDrag.direction(puller: body(5, 5, 1), target: t))
    }

    func testIStepBackAsFarAsMyStageAndTheOpenGround() {
        for (stage, want) in [(1, 1), (2, 2), (3, 3), (0, 1), (99, 3)] {
            XCTAssertEqual(PlazaDrag.stepBack(from: p(20, 12), direction: .right, stage: stage, isOpen: ground), want, "stage \(stage)")
        }
        XCTAssertEqual(PlazaDrag.stepBack(from: p(44, 12), direction: .right, stage: 3, isOpen: ground), 0)
        XCTAssertEqual(PlazaDrag.stepBack(from: p(38, 10), direction: .right, stage: 3, isOpen: ground), 0)
        XCTAssertEqual(PlazaDrag.stepBack(from: p(36, 10), direction: .right, stage: 3, isOpen: ground), 2)
        XCTAssertEqual(PlazaDrag.stepBack(from: p(10, 12), direction: .down, stage: 3, isOpen: ground), 0)
        let no21: (TilePoint) -> Bool = { $0 != self.p(21, 12) && self.ground($0) }
        let no22: (TilePoint) -> Bool = { $0 != self.p(22, 12) && self.ground($0) }
        XCTAssertEqual(PlazaDrag.stepBack(from: p(20, 12), direction: .right, stage: 3, isOpen: no21), 0)
        XCTAssertEqual(PlazaDrag.stepBack(from: p(20, 12), direction: .right, stage: 3, isOpen: no22), 1)
        let ice: (TilePoint) -> Bool = { $0 == self.p(10, 13) || self.ground($0) }
        XCTAssertEqual(PlazaDrag.stepBack(from: p(10, 12), direction: .down, stage: 1, isOpen: ice), 1)
    }

    func testTheTargetSlidesToBesideMyNewTile() {
        for k in 1...3 {
            XCTAssertEqual(PlazaDrag.slide(victim: p(18, 12), puller: p(19, 12), pushTiles: k, isOpen: open), k)
        }
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 15), pushTiles: 1, isOpen: open), 3)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 15), pushTiles: 2, isOpen: open), 4)
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(21, 13), pushTiles: 1, isOpen: open), 0)
    }

    func testTheEndIsBesideThePullersNewTileForEveryReachablePair() {
        var rng = PlazaSplitMix64(seed: 0xD4A6)
        let target = p(20, 15)
        var checked = 0
        for _ in 0..<5_000 {
            let b = PlazaDirection.allCases[Int(rng.next() % 4)]
            let off = Int(rng.next() % 4) + 1
            var foot = target
            for _ in 0..<off { foot = PlazaWalker.offset(foot, b) }
            let pc = Int(rng.next() % 3) + 1, tc = Int(rng.next() % 3) + 1
            let k = Int(rng.next() % 3) + 1
            guard let dir = PlazaDrag.direction(puller: PlazaBody(foot: foot, size: pc), target: PlazaBody(foot: target, size: tc)) else { continue }
            checked += 1
            let n = PlazaDrag.slide(victim: target, puller: foot, pushTiles: k, isOpen: open)
            var end = target
            for _ in 0..<n { end = PlazaWalker.offset(end, dir) }
            var want = foot
            for _ in 0..<(k - 1) { want = PlazaWalker.offset(want, dir) }
            XCTAssertEqual(end, want)
        }
        XCTAssertGreaterThan(checked, 500)
    }

    func testTheSlideStopsBeforeTheFirstClosedTile() {
        func closed(_ t: TilePoint) -> (TilePoint) -> Bool { { $0 != t } }
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 15), pushTiles: 1, isOpen: closed(p(17, 14))), 1)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 15), pushTiles: 1, isOpen: closed(p(17, 13))), 0)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 15), pushTiles: 1, isOpen: closed(p(17, 16))), 3)
    }

    func testAskedTilesStayWithinOneToThree() {
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), pushTiles: 99, isOpen: open), 3)
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), pushTiles: 0, isOpen: open), 1)
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), pushTiles: -5, isOpen: open), 1)
    }

    // MARK: - PlazaShove

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testASecondMoveWithinASecondIsRefusedAndAtASecondAdmitted() {
        var s = PlazaShove()
        XCTAssertTrue(s.admit("a", now: t0))
        XCTAssertFalse(s.admit("a", now: t0.addingTimeInterval(0.99)))
        XCTAssertTrue(s.admit("a", now: t0.addingTimeInterval(1.0)))
    }

    func testARefusedMoveDoesNotRestartTheSecond() {
        var s = PlazaShove()
        XCTAssertTrue(s.admit("a", now: t0))
        XCTAssertFalse(s.admit("a", now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(s.admit("a", now: t0.addingTimeInterval(1.0)))
    }

    func testEachSenderHasItsOwnSecond() {
        var s = PlazaShove()
        XCTAssertTrue(s.admit("a", now: t0))
        XCTAssertTrue(s.admit("b", now: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(s.admit("a", now: t0.addingTimeInterval(0.2)))
    }

    func testAHundredMovesASecondAreLetThroughOnceASecond() {
        var s = PlazaShove()
        var admitted: [Int] = []
        for i in 0..<300 where s.admit("a", now: t0.addingTimeInterval(Double(i) / 100)) { admitted.append(i) }
        XCTAssertEqual(admitted, [0, 100, 200])
    }

    func testTheRecordKeepsOnlyTheLastSecond() {
        var s = PlazaShove()
        for i in 0..<1000 { _ = s.admit("s\(i)", now: t0.addingTimeInterval(Double(i) / 1000)) }
        XCTAssertTrue(s.admit("x", now: t0.addingTimeInterval(2)))
        XCTAssertEqual(Set(s.lastMoved.keys), ["x"])
    }

    func testAClockThatWentBackLetsTheMoveThrough() {
        var s = PlazaShove()
        XCTAssertTrue(s.admit("a", now: t0))
        XCTAssertTrue(s.admit("a", now: t0.addingTimeInterval(-3600)))
        XCTAssertFalse(s.admit("a", now: t0.addingTimeInterval(-3599.5)))
    }
}
