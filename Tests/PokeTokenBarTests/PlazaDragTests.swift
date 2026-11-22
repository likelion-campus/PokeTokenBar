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

    /// Two class-1 bodies touch only with their feet on neighbouring tiles, so these are the numbers the rule always gave them.
    func testTwoSmallBodiesSlideAsFarAsTheStepBack() {
        for k in 1...3 {
            XCTAssertEqual(PlazaDrag.slide(victim: p(18, 12), puller: p(19, 12), direction: .right, pushTiles: k, isOpen: open), k)
            XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), direction: .left, pushTiles: k, isOpen: open), k)
            XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 13), direction: .down, pushTiles: k, isOpen: open), k)
            XCTAssertEqual(PlazaDrag.slide(victim: p(17, 14), puller: p(17, 13), direction: .up, pushTiles: k, isOpen: open), k)
        }
    }

    /// Every pair of classes with the feet on neighbouring tiles, in every direction, for every step back: the target slides
    /// exactly as far as I stepped and the two feet keep the offset they had. Never zero unless something blocks, never a new overlap.
    func testTheTargetKeepsItsPlaceBesideMeForEveryClassPair() {
        let victim = p(20, 15)
        for pc in 1...3 { for tc in 1...3 { for dir in PlazaDirection.allCases { for k in 1...3 {
            let name = "puller \(pc) target \(tc) \(dir) k \(k)"
            let puller = PlazaWalker.offset(victim, dir)
            let v = PlazaBody(foot: victim, size: tc), pl = PlazaBody(foot: puller, size: pc)
            XCTAssertEqual(PlazaDrag.direction(puller: pl, target: v), dir, "\(name): the bodies touch")
            let n = PlazaDrag.slide(victim: victim, puller: puller, direction: dir, pushTiles: k, isOpen: open)
            XCTAssertEqual(n, k, name)
            var end = victim, stepped = puller
            for _ in 0..<n { end = PlazaWalker.offset(end, dir) }
            for _ in 0..<k { stepped = PlazaWalker.offset(stepped, dir) }
            XCTAssertEqual(end.x - stepped.x, victim.x - puller.x, name)
            XCTAssertEqual(end.y - stepped.y, victim.y - puller.y, name)
        } } } }
    }

    func testTheRelativeOffsetIsKeptForEveryReachablePair() {
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
            let n = PlazaDrag.slide(victim: target, puller: foot, direction: dir, pushTiles: k, isOpen: open)
            XCTAssertEqual(n, k, "puller \(pc) target \(tc) \(b) offset \(off) k \(k)")
            var end = target, stepped = foot
            for _ in 0..<n { end = PlazaWalker.offset(end, dir) }
            for _ in 0..<k { stepped = PlazaWalker.offset(stepped, dir) }
            XCTAssertEqual(end.x - stepped.x, target.x - foot.x)
            XCTAssertEqual(end.y - stepped.y, target.y - foot.y)
        }
        XCTAssertGreaterThan(checked, 500)
    }

    /// Feet on one tile: the spec's (d - 1) + k with d = 0. (A drag needs a line, so this is only the rule's own corner.)
    func testFeetOnOneTileEndBesideMe() {
        XCTAssertEqual(PlazaDrag.slide(victim: p(5, 5), puller: p(5, 5), direction: .right, pushTiles: 1, isOpen: open), 0)
        XCTAssertEqual(PlazaDrag.slide(victim: p(5, 5), puller: p(5, 5), direction: .right, pushTiles: 3, isOpen: open), 2)
    }

    func testTheSlideStopsBeforeTheFirstClosedTile() {
        func closed(_ t: TilePoint) -> (TilePoint) -> Bool { { $0 != t } }
        // the target's path is (17,13) (my old tile), (17,14), (17,15)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 13), direction: .down, pushTiles: 3, isOpen: closed(p(17, 14))), 1)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 13), direction: .down, pushTiles: 3, isOpen: closed(p(17, 13))), 0)
        XCTAssertEqual(PlazaDrag.slide(victim: p(17, 12), puller: p(17, 13), direction: .down, pushTiles: 3, isOpen: closed(p(17, 16))), 3)
    }

    func testAskedTilesStayWithinOneToThree() {
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), direction: .left, pushTiles: 99, isOpen: open), 3)
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), direction: .left, pushTiles: 0, isOpen: open), 1)
        XCTAssertEqual(PlazaDrag.slide(victim: p(20, 12), puller: p(19, 12), direction: .left, pushTiles: -5, isOpen: open), 1)
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

    func testAskingNeverStartsTheSecondOnlyRecordingDoes() {
        var s = PlazaShove()
        XCTAssertTrue(s.allows("a", now: t0))
        XCTAssertTrue(s.allows("a", now: t0), "asking records nothing")
        XCTAssertTrue(s.lastMoved.isEmpty)
        s.record("a", now: t0)
        XCTAssertFalse(s.allows("a", now: t0.addingTimeInterval(0.99)))
        XCTAssertTrue(s.allows("a", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(s.allows("a", now: t0.addingTimeInterval(-1)), "a clock that went back")
    }

    /// One app claiming many member IDs must not get a move per ID: across all senders only `maxMovesPerWindow` moves per second.
    func testManySenderIDsMoveMeAtMostThreeTimesASecond() {
        XCTAssertEqual(PlazaShove.maxMovesPerWindow, 3)
        var s = PlazaShove()
        var moved = 0
        for i in 0..<10 where s.admit("sybil\(i)", now: t0.addingTimeInterval(Double(i) / 20)) { moved += 1 }
        XCTAssertEqual(moved, 3)
        XCTAssertEqual(s.lastMoved.count, 3, "refused moves record nothing, so the table stays at the cap")
        // The window slides: once the first move is a second old, one more is let through.
        XCTAssertTrue(s.admit("late", now: t0.addingTimeInterval(1.0)))
    }

    /// Ordinary play: two friends tackling in turn, each once a second, are never held by the cap.
    func testTwoFriendsTacklingInTurnAreNeverHeldByTheCap() {
        var s = PlazaShove()
        for i in 0..<20 {
            XCTAssertTrue(s.admit(i.isMultiple(of: 2) ? "a" : "b", now: t0.addingTimeInterval(Double(i) * 0.5)), "\(i)")
        }
    }
}
