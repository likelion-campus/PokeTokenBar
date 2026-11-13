import XCTest
@testable import PokeTokenBar

final class PlazaIceTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private let T = 1_800_000_000.0
    private var ponds: [PlazaIce.Pond] { PlazaIce.ponds(in: PlazaMapData.map) }
    private var L: TilePoint { p(5, 13) }
    private var R: TilePoint { p(32, 14) }
    private var B: TilePoint { p(20, 24) }
    private func br(_ pond: TilePoint, _ at: Double) -> PlazaIceBreak { PlazaIceBreak(at: at, pond: pond) }

    func testPondsAreFoundInRowMajorOrderOfTheirFirstTile() throws {
        let found = ponds
        XCTAssertEqual(found.map(\.anchor), [p(5, 13), p(32, 14), p(20, 24)])
        XCTAssertEqual(found.map { $0.tiles.count }, [30, 49, 9])
        let r = found[1]
        XCTAssertEqual([r.minX, r.maxX, r.minY, r.maxY], [32, 38, 14, 20])
        let dry = try PlazaMap(rows: ["SN..", "...."])
        XCTAssertEqual(PlazaIce.ponds(in: dry), [])
    }

    func testPondsJoinOnlyThroughTheFourSides() throws {
        let map = try PlazaMap(rows: ["SN....", "ww.w..", "..w...", "......"])
        let found = PlazaIce.ponds(in: map)
        XCTAssertEqual(found.map(\.anchor), [p(0, 1), p(3, 1), p(2, 2)])
        XCTAssertEqual(found.map { $0.tiles.count }, [2, 1, 1])
    }

    private func date(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    func testTheFrozenPondFollowsTheLastBreakAMinuteLater() {
        let ps = ponds
        let late = date(T + 60)
        XCTAssertEqual(PlazaIce.frozenIndex(last: nil, now: date(T), ponds: ps), 0)
        XCTAssertNil(PlazaIce.frozenIndex(last: br(L, T), now: date(T + 59.9), ponds: ps))
        XCTAssertNil(PlazaIce.frozenIndex(last: br(L, T), now: date(T - 500), ponds: ps))
        // The draw is pinned: break L at T freezes B (2), not the rotation's R.
        XCTAssertEqual(PlazaIce.frozenIndex(last: br(L, T), now: late, ponds: ps), 2)
        XCTAssertEqual(PlazaIce.frozenIndex(last: br(R, T), now: late, ponds: ps), 2)
        XCTAssertEqual(PlazaIce.frozenIndex(last: br(B, T), now: late, ponds: ps), 1)
        XCTAssertNil(PlazaIce.frozenIndex(last: br(L, T), now: late, ponds: []))
        XCTAssertNil(PlazaIce.frozenIndex(last: nil, now: late, ponds: []))
        XCTAssertEqual(PlazaIce.frozenIndex(last: br(p(6, 13), T), now: late, ponds: ps), 0)
    }

    /// Values computed by an independent script (FNV-1a of "plaza-ice-next-<at bits>-<x>-<y>", SplitMix64, % candidates).
    func testTheDrawIsPinnedToTheSeedString() {
        let ps = ponds
        func pick(_ pond: TilePoint, _ at: Double) -> Int? {
            PlazaIce.frozenIndex(last: br(pond, at), now: date(at + 60), ponds: ps)
        }
        XCTAssertEqual(pick(L, 1_792_818_060.123456), 2)
        XCTAssertEqual(pick(L, T + 1), 1)
        XCTAssertEqual(pick(R, T + 1), 2)
        XCTAssertEqual(pick(B, T + 1), 0)
        XCTAssertEqual(pick(L, T + 2), 1)
        XCTAssertEqual(pick(B, T + 4), 0)
    }

    func testTheFrozenPondIsNeverTheBrokenOneAndEveryOtherPondGetsPicked() {
        let ps = ponds
        for (i, pond) in [L, R, B].enumerated() {
            var seen = Set<Int>()
            for k in 0..<200 {
                let at = T + Double(k) * 7.31
                let idx = PlazaIce.frozenIndex(last: br(pond, at), now: date(at + 60), ponds: ps)
                XCTAssertNotNil(idx)
                XCTAssertNotEqual(idx, i, "pond \(i) at \(at)")
                if let idx { seen.insert(idx) }
            }
            XCTAssertEqual(seen, Set([0, 1, 2]).subtracting([i]), "both other ponds get picked after pond \(i)")
        }
    }

    func testTheDrawIsADeterministicFunctionOfTheBreakEvenAfterTheWire() throws {
        let ps = ponds
        for at in [T, 1_792_818_060.123456, 1_800_000_007.987654321, 1_790_000_000.5, 0.1, 1e-7, 1_234_567_890.000001] {
            let b = br(L, at)
            let first = PlazaIce.frozenIndex(last: b, now: date(at + 60), ponds: ps)
            XCTAssertEqual(PlazaIce.frozenIndex(last: b, now: date(at + 500), ponds: ps), first)
            let json = try JSONEncoder().encode(b)
            let back = try JSONDecoder().decode(PlazaIceBreak.self, from: json)
            XCTAssertEqual(back.at.bitPattern, at.bitPattern, "JSON keeps every bit of \(at)")
            XCTAssertEqual(PlazaIce.frozenIndex(last: back, now: date(at + 60), ponds: ps), first)
            var decoder = TeamWire.FrameDecoder()
            let msg = TeamMessage.emote(TeamEmote(kind: .jump, targetMemberID: nil, iceBreak: b))
            let got = try decoder.append(try TeamWire.encode(msg))
            guard case .emote(let e)? = got.first, let wired = e.iceBreak else { return XCTFail("emote lost its break") }
            XCTAssertEqual(wired.at.bitPattern, at.bitPattern)
            XCTAssertEqual(PlazaIce.frozenIndex(last: wired, now: date(at + 60), ponds: ps), first)
        }
    }

    func testTheDrawEdgeCases() throws {
        let ps = ponds
        let one = [ps[1]]
        XCTAssertEqual(PlazaIce.frozenIndex(last: br(R, T), now: date(T + 60), ponds: one), 0, "one pond refreezes itself")
        XCTAssertNil(PlazaIce.frozenIndex(last: br(R, T), now: date(T + 59), ponds: one))
        XCTAssertNil(PlazaIce.frozenIndex(last: br(R, T), now: date(T + 60), ponds: []))
        XCTAssertEqual(PlazaIce.frozenIndex(last: nil, now: date(T), ponds: ps), 0)
        let two = [ps[0], ps[1]]
        for k in 0..<20 {
            let at = T + Double(k)
            XCTAssertEqual(PlazaIce.frozenIndex(last: br(L, at), now: date(at + 60), ponds: two), 1)
            XCTAssertEqual(PlazaIce.frozenIndex(last: br(R, at), now: date(at + 60), ponds: two), 0)
        }
    }

    func testFreezeAlphaFadesInOverASecondFromAtPlusAMinute() {
        let ps = ponds
        func alpha(_ s: Double, _ last: PlazaIceBreak?) -> CGFloat { PlazaIce.freezeAlpha(now: date(s), last: last, ponds: ps) }
        XCTAssertEqual(alpha(T + 60, br(L, T)), 0)
        XCTAssertEqual(alpha(T + 60.5, br(L, T)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(alpha(T + 61, br(L, T)), 1)
        XCTAssertEqual(alpha(T + 300, br(L, T)), 1)
        XCTAssertEqual(alpha(T, nil), 1)
        XCTAssertEqual(alpha(T, br(p(6, 13), T)), 1)
    }

    func testMergeKeepsTheLaterBreakThenTheLaterPond() {
        let ps = ponds
        XCTAssertEqual(PlazaIce.merged(br(L, T), br(R, T - 1), ponds: ps), br(L, T))
        XCTAssertEqual(PlazaIce.merged(br(L, T - 1), br(R, T), ponds: ps), br(R, T))
        XCTAssertEqual(PlazaIce.merged(br(L, T), br(R, T), ponds: ps), br(R, T), "equal at: the later pond")
        XCTAssertEqual(PlazaIce.merged(br(B, T), br(R, T), ponds: ps), br(B, T))
        XCTAssertEqual(PlazaIce.merged(nil, br(R, T), ponds: ps), br(R, T))
        XCTAssertEqual(PlazaIce.merged(br(R, T), nil, ponds: ps), br(R, T))
        XCTAssertNil(PlazaIce.merged(nil, nil, ponds: ps))
        XCTAssertEqual(PlazaIce.merged(br(R, T), br(R, T), ponds: ps), br(R, T))
    }

    func testThreeBreaksInTheSameMinuteEndOnTheLastOne() {
        let ps = ponds
        var last: PlazaIceBreak?
        for b in [br(L, T), br(R, T + 20), br(B, T + 40)] { last = PlazaIce.merged(last, b, ponds: ps) }
        XCTAssertEqual(last, br(B, T + 40))
        XCTAssertEqual(PlazaIce.frozenIndex(last: last, now: date(T + 100), ponds: ps), 1, "the draw after B at T + 40")
    }

    func testAcceptedBoundsTheClockAndDropsUnknownPonds() {
        let ps = ponds
        let now = Date(timeIntervalSince1970: T)
        XCTAssertEqual(PlazaIce.accepted(br(L, T + 60), now: now, ponds: ps), br(L, T + 60))
        XCTAssertNil(PlazaIce.accepted(br(L, T + 61), now: now, ponds: ps))
        XCTAssertEqual(PlazaIce.accepted(br(L, T - 100_000), now: now, ponds: ps), br(L, T - 100_000))
        for bad in [Double.nan, .infinity, -.infinity] { XCTAssertNil(PlazaIce.accepted(br(L, bad), now: now, ponds: ps)) }
        XCTAssertNil(PlazaIce.accepted(br(p(6, 13), T), now: now, ponds: ps))
        XCTAssertNil(PlazaIce.accepted(nil, now: now, ponds: ps))
    }

    func testMergeRanksUnknownPondsLastOnATie() {
        let ps = ponds
        XCTAssertEqual(PlazaIce.merged(br(L, T), br(p(6, 13), T), ponds: ps), br(L, T))
        XCTAssertEqual(PlazaIce.merged(br(p(6, 13), T), br(L, T), ponds: ps), br(L, T))
    }

    func testCentreAndNearestTile() {
        let ps = ponds
        XCTAssertEqual(ps.map(\.center), [p(9, 14), p(35, 17), p(21, 25)])
        let r = ps[1]
        XCTAssertEqual(r.nearestTile(to: p(31, 17)), p(32, 17))
        XCTAssertEqual(r.nearestTile(to: p(30, 13)), p(32, 14))
        XCTAssertEqual(r.nearestTile(to: p(40, 25)), p(38, 20))
        XCTAssertEqual(r.nearestTile(to: p(34, 16)), p(34, 16))
    }

    func testCrackRingsAndTheirStep() {
        let r = ponds[1]
        var counts: [Int: Int] = [:]
        for t in r.tiles { counts[PlazaIce.ring(of: t, hit: p(32, 17)), default: 0] += 1 }
        XCTAssertEqual(counts, [0: 1, 1: 5, 2: 9, 3: 11, 4: 7, 5: 9, 6: 7])
        XCTAssertEqual(PlazaIce.crackStep(maxRing: 6), 0.055)
        XCTAssertEqual(PlazaIce.crackStep(maxRing: 9), 0.33 / 9)
        XCTAssertEqual(PlazaIce.crackStep(maxRing: 0), 0.055)
    }

    func testShardTilesSpreadFromTheHit() {
        let ps = ponds
        XCTAssertEqual(PlazaIce.shardTiles(pond: ps[1], hit: p(32, 17)),
                       [p(32, 17), p(37, 15), p(36, 19), p(34, 15), p(35, 17), p(33, 19)])
        XCTAssertEqual(PlazaIce.shardTiles(pond: ps[0], hit: p(5, 14)),
                       [p(5, 14), p(13, 14), p(9, 14), p(7, 14), p(11, 14), p(6, 14)])
        XCTAssertEqual(PlazaIce.shardTiles(pond: ps[2], hit: p(20, 24)),
                       [p(20, 24), p(22, 26), p(22, 24), p(20, 26), p(21, 25), p(21, 24)])
    }

    func testTheBreakTimeline() {
        XCTAssertEqual(PlazaIce.iceAlpha(elapsed: 0.49), 1)
        XCTAssertEqual(PlazaIce.iceAlpha(elapsed: 0.575), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlazaIce.iceAlpha(elapsed: 0.65), 0)
        XCTAssertEqual(PlazaIce.iceAlpha(elapsed: 0.7), 0)
        XCTAssertNil(PlazaIce.shardFrame(burst: 0, elapsed: 0.25))
        XCTAssertEqual(PlazaIce.shardFrame(burst: 0, elapsed: 0.27), 0)
        XCTAssertEqual(PlazaIce.shardFrame(burst: 0, elapsed: 0.34), 1)
        XCTAssertEqual(PlazaIce.shardFrame(burst: 0, elapsed: 0.41), 2)
        XCTAssertNil(PlazaIce.shardFrame(burst: 0, elapsed: 0.48))
        XCTAssertNil(PlazaIce.shardFrame(burst: 5, elapsed: 0.45))
        XCTAssertEqual(PlazaIce.shardFrame(burst: 5, elapsed: 0.47), 0)
        XCTAssertEqual(PlazaIce.shardFrame(burst: 5, elapsed: 0.62), 2)
        XCTAssertNil(PlazaIce.shardFrame(burst: 5, elapsed: 0.68))
        XCTAssertEqual(PlazaIce.breakEnd, PlazaIce.shardStart + 5 * PlazaIce.shardStagger + 3 * PlazaIce.shardFrameLength,
                       accuracy: 1e-9)
    }

    func testCrackCellsAreFixedPerTileAndUseAllSix() {
        XCTAssertEqual(PlazaIce.crackCell(at: p(32, 14)), 5)
        XCTAssertEqual(PlazaIce.crackCell(at: p(35, 17)), 0)
        XCTAssertEqual(PlazaIce.crackCell(at: p(20, 24)), 8)
        let cells = ponds[1].tiles.map { PlazaIce.crackCell(at: $0) }
        XCTAssertEqual(Set(cells.map { $0 % 6 }).count, 6)
        XCTAssertEqual(cells.filter { $0 >= 6 }.count, 25)
    }
}
