import XCTest
@testable import PokeTokenBar

/// Berry five's rules: the deck, the table, the transitions and the bounds on what arrives from other Macs.
final class PlazaBerryTests: XCTestCase {
    typealias B = PlazaBerry
    typealias State = PlazaBerryState

    private func card(_ b: PlazaBerry.Berry, _ n: Int) -> PlazaBerry.Card { .init(berry: b, count: n) }

    private func game(seats: Int = 3, seed: UInt64 = 5, _ edit: (inout State) -> Void = { _ in }) -> PlazaGameState {
        var s = PlazaGameState(id: "g", kind: "berry", host: "p0", opensAt: 1_800_000_000, startsAt: 1_800_000_030,
                               players: (0..<seats).map { "p\($0)" }, seed: seed)
        var b = State(seats: seats)
        edit(&b)
        s.berry = b
        return s
    }

    private func bell(game id: String = "g", clears: Int = 0, flip: Int, ms: Int = 400, right: Bool = true, serial: Int = 1) -> PlazaBerryBell {
        .init(game: id, clears: clears, flip: flip, ms: ms, right: right, serial: serial)
    }

    /// Flips seats in turn until the table shows five of a berry; the flips so far and that flip number.
    private func firstFive(seed: UInt64, seats: Int) -> (flips: [Int], flip: Int)? {
        let d = B.decks(seed: seed, seats: seats)
        var b = State(seats: seats)
        for i in 0..<B.deckSize {
            b.flips.append(i % seats)
            if !B.fives(B.table(b, decks: d, flip: b.flips.count, clear: 0)).isEmpty { return (b.flips, b.flips.count) }
        }
        return nil
    }

    private func withFive(seats: Int = 3) -> (seed: UInt64, flips: [Int], flip: Int) {
        for seed in UInt64(1)...200 {
            if let f = firstFive(seed: seed, seats: seats), f.flip >= 2 { return (seed, f.flips, f.flip) }
        }
        XCTFail("no seed shows five")
        return (1, [], 0)
    }

    // MARK: - Deck

    func testADeckHasFourteenOfEachBerryInTheSpecMix() {
        let deck = B.decks(seed: 1, seats: 1)[0]
        XCTAssertEqual(deck.count, 56)
        for berry in B.Berry.allCases {
            let mine = deck.filter { $0.berry == berry }
            XCTAssertEqual(mine.count, 14)
            for (count, cards) in [(1, 5), (2, 3), (3, 3), (4, 2), (5, 1)] {
                XCTAssertEqual(mine.filter { $0.count == count }.count, cards, "\(berry) x\(count)")
            }
        }
    }

    func testTheDealIsOneAtATimeFromSeatZero() {
        let d = B.decks(seed: 9, seats: 3)
        XCTAssertEqual(d.map(\.count), [19, 19, 18])
        XCTAssertEqual(d[1][0], B.decks(seed: 9, seats: 1)[0][1])
        XCTAssertEqual(d[0][1], B.decks(seed: 9, seats: 1)[0][3])
    }

    private func fnv(seed: UInt64, seats: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for deck in B.decks(seed: seed, seats: seats) {
            for c in deck {
                h ^= UInt64(c.berry.rawValue * 8 + c.count)
                h = h &* 0x0000_0100_0000_01B3
            }
        }
        return h
    }

    func testTheSameSeedDealsTheSameCardsOnEverySystem() {
        let pinned: [Int: UInt64] = [
            2: 10_913_690_581_757_726_841, 3: 558_266_141_002_816_359, 4: 8_467_681_955_437_618_211, 5: 7_971_601_515_711_174_541,
            6: 9_438_913_283_864_810_365, 7: 14_330_188_447_551_517_131, 8: 152_866_572_340_981_807,
        ]
        for seats in 2...8 { XCTAssertEqual(fnv(seed: 7, seats: seats), pinned[seats], "\(seats) seats") }
        XCTAssertGreaterThanOrEqual(Set((1...20).map { fnv(seed: UInt64($0), seats: 3) }).count, 2)
    }

    // MARK: - Table

    func testTheTableIsEachSeatsTopCardSinceTheLastClear() {
        let d = B.decks(seed: 3, seats: 3)
        let b = State(seats: 3)
        var s = b
        s.flips = [0, 1, 2, 0]
        XCTAssertEqual(B.table(s, decks: d, flip: 4, clear: 0), [d[0][1], d[1][0], d[2][0]])
        XCTAssertEqual(B.table(s, decks: d, flip: 3, clear: 0), [d[0][0], d[1][0], d[2][0]])
        s.clears = [3]
        XCTAssertEqual(B.table(s, decks: d, flip: 4, clear: 1), [d[0][1], nil, nil])
    }

    func testOnlyExactlyFiveOfOneBerryRings() {
        XCTAssertEqual(B.fives([card(.oran, 3), card(.oran, 2)]), [.oran])
        XCTAssertEqual(B.fives([card(.oran, 3), card(.oran, 3)]), [])
        XCTAssertEqual(B.fives([card(.oran, 4), card(.sitrus, 1)]), [])
        XCTAssertEqual(B.fives([card(.oran, 5)]), [.oran])
        XCTAssertEqual(B.fives([card(.oran, 2), card(.sitrus, 5), card(.oran, 3), nil]), [.oran, .sitrus])
    }

    // MARK: - Flips

    func testAFlipTurnsTheNextPlayingSeatWithCards() {
        let s = game()
        XCTAssertEqual(B.nextSeat(s, playing: [0, 1, 2]), 0)
        XCTAssertEqual(B.nextSeat(s, playing: [1, 2]), 1)
        let after1 = game { $0.flips = [0, 1] }
        XCTAssertEqual(B.nextSeat(after1, playing: [0, 2]), 2)
        XCTAssertEqual(B.nextSeat(after1, playing: [0, 1]), 0, "wraps")
        XCTAssertNil(B.nextSeat(after1, playing: []))
        // Seat 2 holds 18 cards: after 18 flips of it the deck is empty and it is passed.
        let drained = game { $0.flips = Array(repeating: 2, count: 18) }
        XCTAssertEqual(B.nextSeat(drained, playing: [2]), nil)
        XCTAssertEqual(B.nextSeat(drained, playing: [1, 2]), 1)
        let flipped = B.flipped(s, seat: 0)
        XCTAssertEqual(flipped?.berry?.flips, [0])
        XCTAssertEqual(flipped?.berry?.step, 1)
        XCTAssertNil(B.flipped(drained, seat: 2), "no cards left")
    }

    // MARK: - Clears and bells

    func testAClearScoresSweepsAndEndsAtFive() {
        let f = withFive()
        var s = game(seed: f.seed) { $0.flips = f.flips; $0.clears = []; $0.step = 7 }
        let b = bell(flip: f.flip, ms: 321, serial: 2)
        let c = B.cleared(s, seat: 1, bell: b, playing: [0, 1, 2], at: 1_800_000_100)
        XCTAssertEqual(c?.berry?.scores, [0, 1, 0])
        XCTAssertEqual(c?.berry?.clears, [f.flips.count])
        XCTAssertEqual(c?.berry?.last, .init(seat: 1, ms: 321, right: true, flip: f.flip, clear: 0))
        XCTAssertEqual(c?.berry?.step, 8)
        XCTAssertEqual(c?.berry?.judged, [0, 2, 0])
        XCTAssertNil(c?.endedAt)
        s.berry?.scores = [0, 4, 0]
        let won = B.cleared(s, seat: 1, bell: b, playing: [0, 1, 2], at: 1_800_000_100)
        XCTAssertEqual(won?.endedAt, 1_800_000_100)
        XCTAssertEqual(won?.winner, "p1")
        // Nobody left holds cards: the game ends with the top scorer.
        var spent = game(seed: f.seed) { $0.flips = f.flips; $0.scores = [3, 1, 0] }
        let d = B.decks(seed: f.seed, seats: 3)
        let all = (0..<3).flatMap { seat in Array(repeating: seat, count: d[seat].count - f.flips.filter { $0 == seat }.count) }
        spent.berry?.flips += all
        XCTAssertEqual(spent.berry?.flips.count, 56)
        let last = B.cleared(spent, seat: 1, bell: bell(flip: f.flip, serial: 1), playing: [0, 1, 2], at: 1_800_000_100)
        XCTAssertEqual(last?.endedAt, 1_800_000_100)
        XCTAssertEqual(last?.winner, "p0")
    }

    func testAWrongBellCostsOnePointOncePerSerialAndNeverBelowZero() {
        let s = game { $0.scores = [0, 2, 0]; $0.flips = [0, 1]; $0.judged = [0, 1, 0] }
        let p = B.penalized(s, seat: 1, bell: bell(flip: 2, ms: 0, right: false, serial: 3))
        XCTAssertEqual(p?.berry?.scores, [0, 1, 0])
        XCTAssertEqual(p?.berry?.judged, [0, 3, 0])
        XCTAssertEqual(p?.berry?.step, 1)
        XCTAssertNil(B.penalized(p!, seat: 1, bell: bell(flip: 2, ms: 0, right: false, serial: 3)), "same serial again")
        XCTAssertNil(B.penalized(p!, seat: 1, bell: bell(flip: 2, ms: 0, right: false, serial: 2)), "an older serial")
        let zero = B.penalized(p!, seat: 0, bell: bell(flip: 2, ms: 0, right: false, serial: 1))
        XCTAssertEqual(zero?.berry?.scores[0], 0)
        XCTAssertEqual(zero?.berry?.judged[0], 1)
        XCTAssertEqual(zero?.berry?.last?.seat, 0)
        XCTAssertEqual(zero?.berry?.last?.right, false)
    }

    func testTheEndWithoutFivePointsNamesTheTopScorerOrNobody() {
        let tie = B.ended(game { $0.scores = [3, 1, 3] }, at: 1_800_000_050)
        XCTAssertEqual(tie.endedAt, 1_800_000_050)
        XCTAssertNil(tie.winner)
        XCTAssertEqual(B.ended(game { $0.scores = [1, 4, 2] }, at: 1_800_000_050).winner, "p1")
    }

    func testTheStepCapEndsTheGameWithNoWinner() {
        let s = game { $0.scores = [3, 0, 0]; $0.step = B.maxStep; $0.flips = [0] }
        let f = B.flipped(s, seat: 1)
        XCTAssertNotNil(f?.endedAt)
        XCTAssertNil(f?.winner)
        XCTAssertLessThanOrEqual(f?.berry?.step ?? .max, B.maxStep)
        XCTAssertNotNil(B.penalized(s, seat: 0, bell: bell(flip: 1, right: false))?.endedAt)
    }

    func testARightBellCountsOnlyWhenItsTableHadFive() {
        let f = withFive()
        let s = game(seed: f.seed) { $0.flips = f.flips }
        XCTAssertTrue(B.isValidRight(bell(flip: f.flip), in: s))
        let before = game(seed: f.seed) { $0.flips = Array(f.flips.dropLast()) }
        XCTAssertFalse(B.isValidRight(bell(flip: f.flip - 1), in: before), "a flip without five")
        XCTAssertFalse(B.isValidRight(bell(flip: f.flip + 1), in: s), "beyond flips.count")
        XCTAssertFalse(B.isValidRight(bell(game: "other", flip: f.flip), in: s))
        XCTAssertFalse(B.isValidRight(bell(flip: f.flip, right: false), in: s))
        let cleared = game(seed: f.seed) { $0.flips = f.flips; $0.clears = [f.flip] }
        XCTAssertFalse(B.isValidRight(bell(clears: 0, flip: f.flip), in: cleared), "a past clear")
        XCTAssertFalse(B.isValidRight(bell(clears: 1, flip: f.flip), in: cleared), "at the clear's flip")
        XCTAssertFalse(B.isValidRight(bell(clears: 2, flip: f.flip), in: cleared), "a clear that has not happened")
    }

    func testAWrongBellNeedsATableWithoutFive() {
        let f = withFive()
        let s = game(seed: f.seed) { $0.flips = f.flips }
        XCTAssertFalse(B.isValidWrong(bell(flip: f.flip, right: false), seat: 0, in: s), "that table had five")
        XCTAssertTrue(B.isValidWrong(bell(flip: f.flip - 1, ms: 0, right: false), seat: 0, in: s))
        XCTAssertFalse(B.isValidWrong(bell(flip: f.flip - 1, ms: 0, right: true), seat: 0, in: s))
        XCTAssertFalse(B.isValidWrong(bell(flip: 0, ms: 0, right: false), seat: 0, in: s), "an empty table")
        XCTAssertFalse(B.isValidWrong(bell(flip: f.flip - 1, ms: 0, right: false, serial: 1), seat: 0,
                                      in: game(seed: f.seed) { $0.flips = f.flips; $0.judged = [1, 0, 0] }), "already judged")
    }

    // MARK: - Bounds

    private func honest() -> State {
        var b = State(seats: 8)
        b.flips = (0..<12).map { $0 % 8 }
        b.clears = [5, 9]
        b.scores = [0, 1, 2, 3, 4, 5, 0, 1]
        b.judged = [0, 3, 0, 0, 1, 0, 0, 9]
        b.last = .init(seat: 1, ms: 400, right: true, flip: 9, clear: 1)
        b.step = 20
        return b
    }

    func testAPayloadOutOfBoundsIsRefused() {
        XCTAssertEqual(B.accepted(honest(), players: 8), honest())
        func bad(_ why: String, players: Int = 8, line: UInt = #line, _ edit: (inout State) -> Void) {
            var b = honest()
            edit(&b)
            XCTAssertNil(B.accepted(b, players: players), why, line: line)
        }
        XCTAssertNil(B.accepted(honest(), players: 9), "9 players")
        bad("57 flips") { $0.flips = (0..<57).map { $0 % 8 } }
        bad("a flip seat past the players") { $0.flips[0] = 8 }
        bad("a negative flip seat") { $0.flips[0] = -1 }
        bad("a seat flipped more than its deck holds") { $0.flips = Array(repeating: 0, count: 8); $0.clears = []; $0.last = nil }
        bad("clears not increasing") { $0.clears = [9, 5] }
        bad("clears repeating") { $0.clears = [5, 5] }
        bad("a clear of 0") { $0.clears = [0, 5] }
        bad("a clear above flips.count") { $0.clears = [5, 13] }
        bad("more clears than flips") { $0.flips = [0]; $0.clears = [1, 2]; $0.last = nil }
        bad("short scores") { $0.scores.removeLast() }
        bad("long scores") { $0.scores.append(0) }
        bad("short judged") { $0.judged.removeLast() }
        bad("a score of 6") { $0.scores[0] = 6 }
        bad("a score of -1") { $0.scores[0] = -1 }
        bad("judged above the serial cap") { $0.judged[0] = B.maxSerial + 1 }
        bad("a negative judged") { $0.judged[0] = -1 }
        bad("last seat out of range") { $0.last?.seat = 8 }
        bad("last flip out of range") { $0.last?.flip = 13 }
        bad("last clear out of range") { $0.last?.clear = 3 }
        bad("last ms out of range") { $0.last?.ms = B.maxReactionMS + 1 }
        bad("negative step") { $0.step = -1 }
        bad("step above the cap") { $0.step = B.maxStep + 1 }
        XCTAssertNotNil(B.accepted(State(seats: 2), players: 2))
    }

    func testABellOutOfBoundsIsDropped() {
        let ok = bell(flip: 3)
        XCTAssertEqual(PlazaBerryBell.accepted(ok), ok)
        XCTAssertNil(PlazaBerryBell.accepted(nil))
        func bad(_ why: String, line: UInt = #line, _ edit: (inout PlazaBerryBell) -> Void) {
            var b = ok
            edit(&b)
            XCTAssertNil(PlazaBerryBell.accepted(b), why, line: line)
        }
        bad("empty game") { $0.game = "" }
        bad("long game") { $0.game = String(repeating: "x", count: 65) }
        bad("clears -1") { $0.clears = -1 }
        bad("clears 57") { $0.clears = 57 }
        bad("flip 57") { $0.flip = 57 }
        bad("ms -1") { $0.ms = -1 }
        bad("ms too long") { $0.ms = B.maxReactionMS + 1 }
        bad("serial 0") { $0.serial = 0 }
        bad("serial too high") { $0.serial = B.maxSerial + 1 }
    }
}
