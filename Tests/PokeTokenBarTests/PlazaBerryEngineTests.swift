import XCTest
@testable import PokeTokenBar

/// Berry five's engine: the dealer, the judging window and each player's screen, with several Macs' engines exchanging
/// what they know. Each Mac has its own wall clock (`skew`), its own monotonic clock (`uptimeZero`) and a receive `lag`.
final class PlazaBerryEngineTests: XCTestCase {
    typealias B = PlazaBerry

    private struct Entry {
        var time: Double
        var state: PlazaGameState?
        var bell: PlazaBerryBell?
    }

    private struct Room {
        var engines: [String: PlazaGameEngine]
        var skew: [String: Double]
        var uptimeZero: [String: Double]
        /// A Mac hears the others' states and bells this much later.
        var lag: [String: Double] = [:]
        var gone: Set<String> = []
        /// Not heard from at all: it reaches nobody and nobody reaches it.
        var cutOff: Set<String> = []
        /// The plaza window shows nothing (`berrySeen(at: nil)`).
        var hidden: Set<String> = []
        /// Closed plaza: never ticked, never learns, not in anyone's `present`, but connected, so its last copy is still heard.
        var closed: Set<String> = []
        /// Present, but left out of every `joins`.
        var notJoining: Set<String> = []
        var origin: Double = 1_800_000_000
        var ticks = 0
        var wrote: [String: Int] = [:]
        var sent: [String: [Entry]] = [:]

        var base: Double { origin + Double(ticks) / 10 }

        init(_ ids: [String], skew: [String: Double] = [:], seed: UInt64 = 7) {
            engines = Dictionary(uniqueKeysWithValues: ids.map { id in
                var e = PlazaGameEngine(me: id)
                e.makeSeed = { seed }
                return (id, e)
            })
            self.skew = skew
            uptimeZero = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, 1000.0 * Double($0 + 1) + 0.37 * Double($0)) })
        }

        subscript(id: String) -> PlazaGameEngine {
            get { engines[id]! }
            set { engines[id] = newValue }
        }

        func now(_ id: String) -> Date { Date(timeIntervalSince1970: base + (skew[id] ?? 0)) }
        func uptime(_ id: String) -> Double { base + uptimeZero[id]! }
        var live: [String] { engines.keys.sorted().filter { !gone.contains($0) && !closed.contains($0) } }
        var dealt: PlazaGameState? { engines["a"]!.state }
        var clears: Int { engines["a"]!.state?.berry?.clears.count ?? 0 }
        var flips: Int { engines["a"]!.state?.berry?.flips.count ?? 0 }

        func present(for id: String) -> Set<String> {
            cutOff.contains(id) ? [] : Set(engines.keys).subtracting(gone).subtracting(cutOff).subtracting(closed).subtracting([id])
        }

        func heard(for id: String) -> Set<String> {
            cutOff.contains(id) ? [] : Set(engines.keys).subtracting(gone).subtracting(cutOff).subtracting([id])
        }

        func joins(for id: String) -> Set<String> {
            present(for: id).filter { engines[$0]!.joined != nil && engines[$0]!.joined == engines[id]!.state?.id && !notJoining.contains($0) }
        }

        func hears(_ id: String, _ other: String) -> Bool { heard(for: id).contains(other) && heard(for: other).contains(id) }

        func entry(for id: String, from other: String) -> Entry? {
            sent[other]?.last { $0.time + (lag[id] ?? 0) <= base + 1e-5 }
        }

        mutating func publish(_ id: String) {
            let e = engines[id]!
            let next = Entry(time: base, state: e.state, bell: e.berryBell)
            if let last = sent[id]?.last, last.state == next.state, last.bell == next.bell { return }
            sent[id, default: []].append(next)
        }

        mutating func hearAll() {
            for id in live {
                for other in present(for: id) { if let j = engines[other]?.joined { engines[id]!.heardPlaying(j) } }
                for other in engines.keys.sorted() where other != id && !gone.contains(other) && hears(id, other) {
                    if let e = entry(for: id, from: other) { engines[id]!.learn(e.state, from: other, now: now(id)) }
                }
            }
        }

        /// One 0.1 s tick: every live Mac ticks with the bells it has heard, then learns, then reports its screen.
        mutating func tick() {
            ticks += 1
            for id in live {
                var bells: [String: PlazaBerryBell] = [:]
                for other in engines.keys where other != id && hears(id, other) { if let b = entry(for: id, from: other)?.bell { bells[other] = b } }
                let heard = heard(for: id)
                if engines[id]!.tick(now: now(id), present: present(for: id), joins: joins(for: id), connected: !heard.isEmpty,
                                     heard: heard, bells: bells) { wrote[id, default: 0] += 1 }
                publish(id)
            }
            hearAll()
            for id in live { engines[id]!.berrySeen(at: hidden.contains(id) ? nil : uptime(id)) }
        }

        mutating func run(for seconds: Double) { run(to: base + seconds) }

        mutating func run(to t: Double) { while base < t - 1e-5 { tick() } }

        /// Opens a game by `host`, the others (but `notJoining`) join, the host locks. Returns the base time of the lock.
        @discardableResult
        mutating func start(host: String = "a") -> Double {
            _ = engines[host]!.open(.berry, now: now(host))
            publish(host)
            tick()
            for id in live where id != host && !notJoining.contains(id) { engines[id]!.answer(join: true, now: now(id)) }
            tick()
            engines[host]!.requestStart()
            for _ in 0..<20 where engines[host]!.state?.startsAt == nil { tick() }
            wrote = [:]
            return base
        }

        @discardableResult
        mutating func ring(_ id: String, extra: Double = 0) -> PlazaBerryRing {
            let r = engines[id]!.ringBerry(now: now(id), uptime: uptime(id) + extra)
            publish(id)
            return r
        }

        mutating func leave(_ id: String) {
            engines[id]!.leave(now: now(id), present: present(for: id))
            publish(id)
            closed.insert(id)
        }

        /// Ticks until the dealer's table shows a five. Returns that base time.
        mutating func untilFive(limit: Int = 2000) -> Double? {
            for _ in 0..<limit {
                if let s = engines["a"]!.state, !B.fives(B.table(s)).isEmpty, s.endedAt == nil { return base }
                tick()
            }
            return nil
        }

        /// The next five on the table is rung by `id` `after` seconds after it showed; true once it is cleared.
        mutating func clearNextFive(by id: String, after: Double = 0.3) -> Bool {
            guard untilFive() != nil else { return false }
            let before = clears
            run(for: after)
            ring(id)
            for _ in 0..<80 where clears == before { tick() }
            return clears > before
        }
    }

    // MARK: - Deals

    private func game(seed: UInt64, seats: Int) -> PlazaGameState {
        var s = PlazaGameState(id: "g", kind: "berry", host: "a", opensAt: 1_800_000_000, startsAt: 1_800_000_030,
                               players: (0..<seats).map { "p\($0)" }, seed: seed)
        s.berry = PlazaBerryState(seats: seats)
        return s
    }

    /// The berries at five after each flip when nobody rings.
    private func noClearFives(seed: UInt64, seats: Int, flips: Int) -> [[B.Berry]] {
        var s = game(seed: seed, seats: seats)
        var out: [[B.Berry]] = []
        for _ in 0..<flips {
            guard let seat = B.nextSeat(s, playing: Set(0..<seats)), let next = B.flipped(s, seat: seat, at: 0) else { break }
            s = next
            out.append(B.fives(B.table(s)))
        }
        return out
    }

    /// Whether a five showed after each flip when every five is rung at once by seat 1 (and cleared).
    private func dealt(seed: UInt64, seats: Int) -> [Bool] {
        var s = game(seed: seed, seats: seats)
        var out: [Bool] = []
        var serial = 0
        for _ in 0..<B.deckSize {
            guard let seat = B.nextSeat(s, playing: Set(0..<seats)), let next = B.flipped(s, seat: seat, at: 0) else { break }
            s = next
            let five = !B.fives(B.table(s)).isEmpty
            out.append(five)
            if five {
                serial += 1
                let bell = PlazaBerryBell(game: "g", clears: s.berry!.clears.count, flip: s.berry!.flips.count, ms: 300, right: true, serial: serial)
                s = B.cleared(s, seat: 1, bell: bell, playing: Set(0..<seats), at: 0) ?? s
                if s.endedAt != nil { break }
            }
        }
        return out
    }

    private func seed(_ matches: (UInt64) -> Bool) -> UInt64 {
        for s in UInt64(1)...100_000 where matches(s) { return s }
        XCTFail("no seed deals what the test needs")
        return 1
    }

    private func firstFive(_ f: [[B.Berry]]) -> Int? { f.firstIndex { !$0.isEmpty } }
    private var earlyFive: UInt64 { seed { s in firstFive(noClearFives(seed: s, seats: 3, flips: 6)) != nil } }
    private var richDeal: UInt64 { seed { s in dealt(seed: s, seats: 3).filter { $0 }.count >= 5 } }
    private var survivingFive: UInt64 {
        seed { s in
            let f = noClearFives(seed: s, seats: 3, flips: 8)
            guard let k = firstFive(f), k + 1 < f.count, f[k].count == 1 else { return false }
            return f[k + 1].contains(f[k][0])
        }
    }

    // MARK: - Whole games

    func testThreePlayersPlayToFivePoints() {
        var room = Room(["a", "b", "c"], seed: richDeal)
        room.start()
        for _ in 0..<5 { XCTAssertTrue(room.clearNextFive(by: "b")) }
        room.run(for: 0.5)
        let s = room["a"].state
        XCTAssertEqual(s?.berry?.scores[1], 5)
        XCTAssertEqual(s?.winner, "b")
        XCTAssertNotNil(s?.endedAt)
        XCTAssertEqual(Set(room.live.map { room[$0].state }).count, 1, "every Mac holds the same state")
        for id in room.live { XCTAssertEqual(room[id].berryPhase(now: room.now(id)), .over) }
    }

    func testTheDealerFlipsEveryOneAndAHalfSecondsAfterThreeSecondsOfCountdown() {
        let seed = seed { s in
            let k = firstFive(noClearFives(seed: s, seats: 3, flips: 6))
            return k.map { (1...3).contains($0) } ?? false
        }
        var room = Room(["a", "b", "c"], seed: seed)
        let lock = room.start()
        room.run(to: lock + 2.9)
        XCTAssertEqual(room.flips, 0)
        room.run(to: lock + 3.0)
        XCTAssertEqual(room.flips, 1)
        room.run(to: lock + 4.4)
        XCTAssertEqual(room.flips, 1)
        room.run(to: lock + 4.5)
        XCTAssertEqual(room.flips, 2)
        room.run(to: lock + 12.05)
        XCTAssertEqual(room.flips, 7)
        XCTAssertEqual(room.dealt?.berry?.flips, [0, 1, 2, 0, 1, 2, 0])
        XCTAssertNotNil(firstFive(noClearFives(seed: seed, seats: 3, flips: 4)), "a five showed on the table and the pace never changed")
        XCTAssertEqual(room.wrote["b"] ?? 0, 0)
        XCTAssertEqual(room.wrote["c"] ?? 0, 0)
        XCTAssertEqual(Set(room.live.map { room[$0].state }).count, 1)
    }

    func testNineAnswersLockTheFirstEightByID() {
        var room = Room(["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        room.start(host: "c")
        XCTAssertEqual(room["c"].state?.players, ["a", "b", "c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(room["c"].state?.berry?.scores.count, 8)
    }

    // MARK: - The judging window

    func testTheFastestReactionWinsAndATieGoesToTheSmallerID() throws {
        let seed = earlyFive
        var room = Room(["a", "b", "c"], seed: seed)
        room.start()
        room.lag["c"] = 0.2
        var t = try XCTUnwrap(room.untilFive())
        let k = room.flips
        room.run(to: t + 0.4)
        XCTAssertEqual(room.ring("b", extra: 0.02), .right)   // 420 ms
        room.run(to: t + 0.5)
        XCTAssertEqual(room.ring("c", extra: 0.01), .right)   // 310 ms on a screen that showed it 0.2 s later
        room.run(for: 1.5)
        var berry = try XCTUnwrap(room.dealt?.berry)
        XCTAssertEqual(berry.scores, [0, 0, 1])
        XCTAssertEqual(berry.clears, [k])
        XCTAssertEqual(Double(berry.last?.ms ?? 0), 310, accuracy: 10)

        var tie = Room(["a", "b", "c"], seed: seed)
        tie.start()
        t = try XCTUnwrap(tie.untilFive())
        tie.run(to: t + 0.3)
        tie.ring("b")
        tie.ring("c")
        tie.run(for: 1.5)
        berry = try XCTUnwrap(tie.dealt?.berry)
        XCTAssertEqual(berry.scores, [0, 1, 0], "the same 300 ms: the smaller id wins")
        XCTAssertEqual(berry.last?.seat, 1)
    }

    func testALateScreenIsJudgedOnItsOwnClock() throws {
        var room = Room(["a", "b", "c"], seed: earlyFive)
        room.start()
        room.lag["c"] = 0.4
        let t = try XCTUnwrap(room.untilFive())
        let k = room.flips
        room.run(to: t + 0.3)
        room.ring("b", extra: 0.05)   // 350 ms
        room.run(to: t + 0.6)
        XCTAssertEqual(room.ring("c"), .right)   // its screen showed the five at + 0.4: 200 ms
        room.run(for: 1.5)
        let berry = try XCTUnwrap(room.dealt?.berry)
        XCTAssertEqual(berry.scores, [0, 0, 1], "the late screen wins on its own clock")
        XCTAssertEqual(berry.last?.flip, k, "the flip c saw")
        XCTAssertEqual(Double(berry.last?.ms ?? 0), 200, accuracy: 10)
    }

    func testAFlipDueInsideTheJudgingWindowOrTheRestWaits() throws {
        var room = Room(["a", "b", "c"], seed: earlyFive)
        room.start()
        let t = try XCTUnwrap(room.untilFive())
        let k = room.flips
        room.run(to: t + 1.2)
        XCTAssertEqual(room.flips, k)
        room.ring("b")   // the window runs to about + 1.9; the next flip was due at + 1.5
        room.run(to: t + 1.7)
        XCTAssertEqual(room.flips, k, "no flip while the window is open")
        XCTAssertEqual(room.clears, 0)
        room.run(to: t + 2.0)
        XCTAssertEqual(room.dealt?.berry?.clears, [k])
        room.run(to: t + 3.3)
        XCTAssertEqual(room.flips, k, "nor within the rest after the clear")
        room.run(to: t + 3.6)
        XCTAssertEqual(room.flips, k + 1)
    }

    func testTheSameGameEndsTheSameWithClocksFortyFiveSecondsApart() {
        let seed = richDeal
        func play(skew: [String: Double]) -> (flips: [Int], clears: [Int], scores: [Int], firstFlip: Double)? {
            var room = Room(["a", "b", "c"], skew: skew, seed: seed)
            if !skew.isEmpty { room.uptimeZero = ["a": 50_000, "b": 7, "c": 900_000] }
            let lock = room.start()
            var first: Double?
            for _ in 0..<60 where first == nil {
                room.tick()
                if room.flips > 0 { first = room.base - lock }
            }
            for _ in 0..<5 { guard room.clearNextFive(by: "b") else { return nil } }
            guard let b = room["a"].state?.berry else { return nil }
            XCTAssertEqual(Set(room.live.map { room[$0].state }).count, 1)
            return (b.flips, b.clears, b.scores, first ?? 99)
        }
        // The dealer runs 45 s ahead; the others stay inside the 60 s `clockSlack` the plaza accepts a stamp ahead by.
        let plain = play(skew: [:])
        let skewed = play(skew: ["a": 45, "b": 0, "c": -14])   // the dealer's own clock is the shifted one
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain?.flips, skewed?.flips)
        XCTAssertEqual(plain?.clears, skewed?.clears)
        XCTAssertEqual(plain?.scores, skewed?.scores)
        XCTAssertLessThanOrEqual(skewed?.firstFlip ?? 99, 3.3)
    }

    func testABellFromAPastClearIsDroppedWithoutPenalty() throws {
        var room = Room(["a", "b", "c"], seed: earlyFive)
        room.start()
        room.lag["c"] = 0.5
        let t = try XCTUnwrap(room.untilFive())
        room.run(to: t + 0.2)
        room.ring("b")
        room.run(to: t + 1.0)
        XCTAssertEqual(room.clears, 1, "b's clear is written")
        XCTAssertEqual(room["c"].state?.berry?.clears.count, 0, "c has not heard it")
        XCTAssertEqual(room.ring("c"), .right, "c's screen still shows the five")
        room.run(for: 3)
        let berry = try XCTUnwrap(room.dealt?.berry)
        XCTAssertEqual(berry.scores, [0, 1, 0])
        XCTAssertEqual(berry.judged[2], 0, "nothing was judged for c")
        XCTAssertEqual(berry.last?.seat, 1)
        XCTAssertEqual(berry.clears.count, 1)
    }

    // MARK: - The bell

    func testAWrongBellCostsAPointOnceAndLocksForASecond() throws {
        let seed = seed { s in
            let d = dealt(seed: s, seats: 3)
            guard let i = d.firstIndex(of: true), i + 1 < d.count else { return false }
            return !d[i + 1]
        }
        var room = Room(["a", "b", "c"], seed: seed)
        room.start()
        XCTAssertTrue(room.clearNextFive(by: "c"))
        let k = room.clears
        for _ in 0..<40 where room.flips == (room.dealt?.berry?.clears.last ?? 0) { room.tick() }
        XCTAssertEqual(room.dealt?.berry?.scores[2], 1)
        XCTAssertTrue(B.fives(B.table(room.dealt!)).isEmpty)
        room.run(for: 0.1)
        XCTAssertEqual(room.ring("c"), .wrong)
        room.run(for: 0.2)
        var berry = try XCTUnwrap(room.dealt?.berry)
        XCTAssertEqual(berry.scores[2], 0)
        XCTAssertEqual(berry.judged[2], 2)
        let step = berry.step
        room.run(for: 0.3)
        XCTAssertTrue(room["c"].berryLocked(uptime: room.uptime("c")))
        XCTAssertEqual(room.ring("c"), .ignored)
        XCTAssertEqual(room["c"].berryBell?.serial, 2)
        room.run(for: 0.6)
        XCTAssertEqual(room.dealt?.berry?.step, step, "ten more dealer ticks take no second point")
        XCTAssertFalse(room["c"].berryLocked(uptime: room.uptime("c")))
        XCTAssertEqual(room.ring("c"), .wrong)
        room.run(for: 0.2)
        berry = try XCTUnwrap(room.dealt?.berry)
        XCTAssertEqual(berry.scores[2], 0, "never below 0")
        XCTAssertEqual(berry.judged[2], 3)
        XCTAssertEqual(berry.step, step + 1)
        XCTAssertEqual(berry.clears.count, k)
    }

    func testSpaceDoesNothingInTheCountdownOnAnEmptyTableOrAfterTheEnd() throws {
        var room = Room(["a", "b", "c"], seed: richDeal)
        room.start()
        room.run(for: 1.0)
        XCTAssertEqual(room.ring("b"), .ignored, "the countdown")
        XCTAssertNil(room["b"].berryBell)
        let t = try XCTUnwrap(room.untilFive())
        room.run(to: t + 0.3)
        XCTAssertEqual(room.ring("b"), .right)
        let bell = try XCTUnwrap(room["b"].berryBell)
        room.run(for: 0.2)
        XCTAssertEqual(room.ring("b"), .ignored, "my right bell awaits its verdict")
        XCTAssertEqual(room["b"].berryBell, bell)
        for _ in 0..<80 where room.clears == 0 { room.tick() }
        XCTAssertEqual(room.clears, 1)
        room.run(for: 0.3)
        XCTAssertEqual(room.ring("c"), .ignored, "the table is empty while the rest runs")
        XCTAssertNil(room["c"].berryBell)
        for _ in 0..<4 { XCTAssertTrue(room.clearNextFive(by: "b")) }
        room.run(for: 0.5)
        XCTAssertNotNil(room["a"].state?.endedAt)
        let last = room["b"].berryBell
        XCTAssertEqual(room.ring("b"), .ignored, "after the end")
        XCTAssertEqual(room["b"].berryBell, last)
    }

    func testAFiveThatSurvivesAnotherFlipKeepsItsStart() throws {
        var room = Room(["a", "b", "c"], seed: survivingFive)
        room.start()
        let t = try XCTUnwrap(room.untilFive())
        let k = room.flips
        room.run(to: t + 1.5)
        XCTAssertEqual(room.flips, k + 1)
        room.run(for: 0.2)
        XCTAssertEqual(room.ring("b"), .right)
        XCTAssertEqual(Double(room["b"].berryBell?.ms ?? 0), 1700, accuracy: 10, "counted from when the five first showed")

        let two = seed { s in
            let f = noClearFives(seed: s, seats: 3, flips: 8)
            guard let k = firstFive(f), k + 1 < f.count, f[k].count == 1 else { return false }
            return f[k + 1].count == 2 && f[k + 1].contains(f[k][0])
        }
        var other = Room(["a", "b", "c"], seed: two)
        other.start()
        let u = try XCTUnwrap(other.untilFive())
        other.run(to: u + 1.7)
        XCTAssertEqual(B.fives(B.table(other.dealt!)).count, 2)
        XCTAssertEqual(other.ring("b"), .right)
        XCTAssertEqual(Double(other["b"].berryBell?.ms ?? 0), 1700, accuracy: 10, "with two berries at five the earlier start counts")
    }

    func testAHiddenPlazaCountsFromWhenTheTableShowedAgain() throws {
        var room = Room(["a", "b", "c"], seed: survivingFive)
        room.start()
        room.hidden = ["b"]
        let t = try XCTUnwrap(room.untilFive())
        room.run(to: t + 1.0)
        XCTAssertEqual(room.ring("b"), .ignored, "a hidden plaza cannot ring")
        room.run(to: t + 2.0)
        room.hidden = []
        room.tick()
        room.run(for: 0.3)
        XCTAssertEqual(room.ring("b"), .right)
        XCTAssertEqual(Double(room["b"].berryBell?.ms ?? 0), 300, accuracy: 10)
    }

    // MARK: - Seats, decks and the end

    func testEmptyDecksAndPlayersWhoLeftAreSkipped() {
        var room = Room(["a", "b", "c"])
        let lock = room.start()
        room.run(to: lock + 6.2)
        XCTAssertEqual(room.dealt?.berry?.flips, [0, 1, 2])
        room.leave("c")
        for _ in 0..<1200 where room.dealt?.endedAt == nil { room.tick() }
        let flips = room.dealt?.berry?.flips ?? []
        XCTAssertEqual(flips.dropFirst(3).filter { $0 == 2 }.count, 0, "c's seat is never turned again")
        XCTAssertEqual(flips.filter { $0 == 0 }.count, 19)
        XCTAssertEqual(flips.filter { $0 == 1 }.count, 19, "each deck runs out and stops being turned")
        XCTAssertEqual(flips.count, 39)
        XCTAssertNotNil(room.dealt?.endedAt)
        XCTAssertEqual(B.table(room.dealt!)[2], B.decks(seed: 7, seats: 3)[2][0], "c's top card counts until the next clear")
    }

    func testABriefDropSkipsOneTurnAndEveryTableAgrees() {
        var room = Room(["a", "b", "c"])
        let lock = room.start()
        room.run(to: lock + 5.0)
        room.notJoining = ["c"]
        room.run(to: lock + 6.2)
        room.notJoining = []
        room.run(to: lock + 12.05)
        let flips = room.dealt?.berry?.flips ?? []
        XCTAssertEqual(Array(flips.prefix(7)), [0, 1, 0, 1, 2, 0, 1], "c's seat is passed once, then turned at its next turn")
        XCTAssertEqual(flips.filter { $0 == 2 }.count, 1, "its cards are kept")
        for id in room.live { XCTAssertEqual(room[id].state?.berry?.flips, flips, "\(id)") }
    }

    func testTheGameEndsWhenTheCardsRunOut() throws {
        var room = Room(["a", "b"])
        room.start()
        var lastFlip = 0.0
        var seen = 0
        for _ in 0..<1500 where room.dealt?.endedAt == nil {
            room.tick()
            if room.flips > seen { seen = room.flips; lastFlip = room.base }
        }
        XCTAssertEqual(seen, 56)
        let ended = try XCTUnwrap(room.dealt?.endedAt)
        XCTAssertEqual(ended - lastFlip, PlazaBerry.endWait, accuracy: 0.25)
        XCTAssertNil(room.dealt?.winner)

        let seed = seed { s in noClearFives(seed: s, seats: 2, flips: 56).last.map { !$0.isEmpty } ?? false }
        var rung = Room(["a", "b"], seed: seed)
        rung.start()
        for _ in 0..<1500 where rung.flips < 56 { rung.tick() }
        let last = rung.base
        rung.run(for: 0.3)
        XCTAssertEqual(rung.ring("b"), .right)
        rung.run(for: 1.5)
        let end = try XCTUnwrap(rung.dealt?.endedAt)
        XCTAssertLessThan(end - last, 1.5, "a clear after the last card ends the game at that clear")
        XCTAssertEqual(rung.dealt?.winner, "b")
        XCTAssertEqual(rung.dealt?.berry?.scores, [0, 1])
    }

    func testFewerThanTwoPlayingEndsAndTheTopScorerWinsEvenIfGone() {
        var room = Room(["a", "b", "c"], seed: richDeal)
        room.start()
        XCTAssertTrue(room.clearNextFive(by: "b"))
        XCTAssertTrue(room.clearNextFive(by: "c"))
        XCTAssertTrue(room.clearNextFive(by: "b"))
        XCTAssertEqual(room.dealt?.berry?.scores, [0, 2, 1])
        room.leave("b")
        room.leave("c")
        room.run(for: 2.5)
        XCTAssertNil(room.dealt?.endedAt, "only after the grace")
        room.run(for: 1.5)
        XCTAssertNotNil(room.dealt?.endedAt)
        XCTAssertEqual(room.dealt?.winner, "b")
    }

    // MARK: - The dealer

    func testTheDealerMissingForThreeSecondsIsReplacedByTheSmallestPlayingID() {
        var room = Room(["a", "b", "c"])
        room.start(host: "c")
        room.gone = ["c"]
        room.tick()
        let t = room.base
        XCTAssertEqual(room["a"].berryDealer, "c")
        room.run(to: t + 2.9)
        XCTAssertEqual(room.flips, 0)
        XCTAssertEqual(room.wrote["a"] ?? 0, 0)
        XCTAssertEqual(room.wrote["b"] ?? 0, 0)
        room.run(to: t + 3.0)
        XCTAssertEqual(room.flips, 1)
        XCTAssertEqual(room.wrote["a"], 1)
        XCTAssertEqual(room.wrote["b"] ?? 0, 0, "never b")
        XCTAssertEqual(room["a"].berryDealer, "a")
        XCTAssertEqual(room["b"].berryDealer, "a")
        room.run(to: t + 4.5)
        XCTAssertEqual(room.flips, 2)
        XCTAssertEqual(room.wrote["b"] ?? 0, 0)
    }

    func testATakeoverDealerJudgesTheBellsItSeesAndNeverTakesAWrongPointTwice() throws {
        let seed = seed { s in
            let d = dealt(seed: s, seats: 3)
            return d.count >= 2 && !d[0] && d.contains(true)
        }
        var room = Room(["a", "b", "c"], seed: seed)
        room.start(host: "c")
        for _ in 0..<60 where room["a"].state?.berry?.flips.count != 1 { room.tick() }
        room.run(for: 0.1)
        XCTAssertEqual(room.ring("a"), .wrong)
        room.run(for: 0.3)
        XCTAssertEqual(room["a"].state?.berry?.judged[0], 1, "the dealer took a's wrong bell off")
        let t = try XCTUnwrap(room.untilFive())
        room.run(to: t + 0.2)
        XCTAssertEqual(room.ring("b"), .right)
        room.run(for: 0.1)   // c has seen it: its window is open
        room.gone = ["c"]
        let before = try XCTUnwrap(room["a"].state?.berry)
        XCTAssertTrue(before.clears.isEmpty)
        for _ in 0..<120 where (room["a"].state?.berry?.clears.count ?? 0) == 0 { room.tick() }
        let berry = try XCTUnwrap(room["a"].state?.berry)
        XCTAssertEqual(berry.clears.count, 1)
        XCTAssertEqual(berry.scores[1], 1, "b wins its clear")
        XCTAssertEqual(berry.step, before.step + 1, "one write: the clear; a's wrong bell was not taken off again")
        room.run(for: 2.0)
        XCTAssertEqual(room["a"].state?.berry?.clears.count, 1, "judged once")
        XCTAssertEqual(room["b"].state?.berry?.scores[1], 1)
    }

    func testTheHostComingBackDealsAgainAndTheTablesAgree() {
        var room = Room(["a", "b", "c"])
        room.start(host: "c")
        room.gone = ["c"]
        room.run(for: 5.0)
        XCTAssertGreaterThan(room.flips, 0, "a dealt meanwhile")
        room.gone = []
        room.hearAll()
        let wrote = room.wrote
        room.run(for: 10.0)
        XCTAssertEqual(room.wrote["a"] ?? 0, wrote["a"] ?? 0, "a no longer writes")
        XCTAssertEqual(room.wrote["b"] ?? 0, wrote["b"] ?? 0)
        XCTAssertGreaterThan(room.wrote["c"] ?? 0, 0, "the host deals again")
        XCTAssertEqual(Set(room.live.map { room[$0].state }).count, 1)
        XCTAssertEqual(room["b"].berryDealer, "c")
    }

    func testACutOffDealerWritesNothingAndStepsOut() {
        var room = Room(["a", "b", "c"])
        room.start(host: "c")
        let before = room["c"].state
        room.cutOff = ["c"]
        room.run(for: 11.0)
        XCTAssertEqual(room["c"].state, before, "it changed nothing while cut off")
        XCTAssertEqual(room.wrote["c"] ?? 0, 0)
        XCTAssertNil(room["c"].joined)
        XCTAssertEqual(room["c"].lostConnection, before?.id)
        XCTAssertGreaterThan(room.flips, 1, "the smallest playing id dealt meanwhile")
        XCTAssertEqual(room["a"].berryDealer, "a")
        XCTAssertEqual(room.wrote["b"] ?? 0, 0)
    }

    func testACopyWithoutTheBerryPayloadIsNeverDealt() {
        var room = Room(["a", "b"])
        _ = room["a"].open(.berry, now: room.now("a"))
        room.publish("a")
        room.tick()
        room["b"].answer(join: true, now: room.now("b"))
        room.tick()
        room["a"].requestStart()
        room.lag["b"] = 100_000   // b hears nothing from here on
        for _ in 0..<10 where room["a"].state?.startsAt == nil { room.tick() }
        var stripped = room["a"].state!
        XCTAssertNotNil(stripped.berry)
        stripped.berry = nil
        var b = room["b"]
        b.learn(stripped, from: "a", now: room.now("b"))
        XCTAssertNil(b.berryPhase(now: room.now("b")))
        let held = b.state
        for i in 1...50 {
            let now = Date(timeIntervalSince1970: room.now("b").timeIntervalSince1970 + Double(i) * 0.1)
            XCTAssertFalse(b.tick(now: now, present: ["a"], joins: ["a"], connected: true, heard: ["a"]))
        }
        XCTAssertEqual(b.state, held)
        XCTAssertNil(b.berryDealer)
    }

    func testTheLongestGameStaysInsideTheGameLife() throws {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var room = Room(ids)
        room.start()
        var next = 0
        for i in 0..<2500 where room.dealt?.endedAt == nil {
            room.tick()
            if i % 11 == 10, let s = room[ids[next % 8]].state, B.fives(B.table(s)).isEmpty {
                room.ring(ids[next % 8])
                next += 1
            }
        }
        let s = try XCTUnwrap(room.dealt)
        let ended = try XCTUnwrap(s.endedAt, "the cards ran out")
        XCTAssertLessThan(ended, s.opensAt + PlazaGame.maxLife)
        XCTAssertEqual(s.berry?.flips.count, 56)
        XCTAssertGreaterThan(next, 20)
    }

    func testTheStepCapEndsTheGameWithNoWinner() {
        var room = Room(["a", "b", "c"], seed: richDeal)
        room.start()
        XCTAssertTrue(room.clearNextFive(by: "b"))
        var s = room["a"].state!
        s.berry?.step = PlazaBerry.maxStep
        room["a"].learn(s, now: room.now("a"))
        room.run(for: 4.0)
        for id in room.live {
            XCTAssertNotNil(room[id].state?.endedAt, id)
            XCTAssertNil(room[id].state?.winner, "b leads but the cap names nobody")
        }
    }

    // MARK: - The lobby defect class

    func testAnEndedBerryGameNeverComesBack() {
        var room = Room(["a", "b", "c"])
        let lock = room.start(host: "b")
        room.run(to: lock + 7.0)
        let id = room["b"].state?.id
        room.leave("a")   // its plaza closed: its running copy keeps arriving
        XCTAssertNil(room["a"].state?.endedAt)
        for _ in 0..<1500 where room["b"].state?.endedAt == nil { room.tick() }
        XCTAssertNotNil(room["b"].state?.endedAt, "the others finished the game")
        var back = false
        for _ in 0..<(Int(PlazaGame.endedKeep) + 20) * 10 {
            room.tick()
            for e in room.live {
                if let s = room[e].state, s.endedAt == nil { back = true }
                let phase = room[e].berryPhase(now: room.now(e))
                if phase != nil, phase != .over { back = true }
            }
        }
        XCTAssertFalse(back, "an ended game never comes back")
        XCTAssertEqual(id, room["a"].state?.id, "a's frozen copy was still there")
    }

    func testAPlayerWhoSleptThroughTheEndDoesNotRestartIt() {
        var room = Room(["a", "b", "c"])
        let lock = room.start()
        room.run(to: lock + 5.0)
        room.cutOff = ["c"]
        for _ in 0..<2000 where room["a"].state?.endedAt == nil { room.tick() }
        XCTAssertNotNil(room["a"].state?.endedAt)
        XCTAssertNil(room["c"].state?.endedAt, "c slept through the end")
        room.run(for: PlazaGame.endedKeep + 10)
        room.cutOff = []
        var back = false
        for _ in 0..<150 {
            room.tick()
            for e in room.live {
                if let s = room[e].state, s.endedAt == nil, e != "c" { back = true }
                if e != "c", let p = room[e].berryPhase(now: room.now(e)), p != .over { back = true }
            }
        }
        XCTAssertFalse(back, "nobody else restarts it")
        let c = room["c"].state
        XCTAssertTrue(c == nil || c?.endedAt != nil, "c adopts the end or drops the game")
    }

    func testLeaversWriteNothingAndTheLastPlayerEndsTheGame() {
        var room = Room(["a", "b", "c"], seed: richDeal)
        room.start()
        XCTAssertTrue(room.clearNextFive(by: "b"))
        let a = room["a"].state, b = room["b"].state
        room.leave("a")
        room.leave("b")
        XCTAssertEqual(room["a"].state, a, "a leaver writes nothing")
        XCTAssertEqual(room["b"].state, b)
        room.run(for: 4.5)
        XCTAssertNotNil(room["c"].state?.endedAt, "c, the one left, ends it on its own clock")
        XCTAssertEqual(room["c"].state?.winner, "b", "the top scorer wins even though gone")
        XCTAssertEqual(room["a"].state, a)
        XCTAssertEqual(room["b"].state, b)
    }

    func testWhenAllPlayersLeaveTogetherAWatcherDropsTheGame() {
        var room = Room(["a", "b", "c", "d"])
        room.notJoining = ["d"]
        let lock = room.start()
        room.run(to: lock + 5.0)
        let before = ["a", "b", "c"].map { room[$0].state }
        for id in ["a", "b", "c"] { room.leave(id) }
        XCTAssertEqual(["a", "b", "c"].map { room[$0].state }, before, "no one wrote when leaving")
        let flips = room["d"].state?.berry?.flips.count
        room.run(for: PlazaDraw.abandonedAfter - 1)
        XCTAssertNotNil(room["d"].state, "still waiting out the grace")
        room.run(for: 3.0)
        XCTAssertNil(room["d"].state, "the watcher dropped the game")
        XCTAssertNil(room["d"].berryPhase(now: room.now("d")))
        XCTAssertNotNil(flips)
        room.run(for: 10.0)
        XCTAssertNil(room["d"].state, "the frozen copies do not bring it back")
        XCTAssertEqual(["a", "b", "c"].map { room[$0].state }, before)
    }

    func testACutOffPlayerClosingThePlazaDoesNotEndTheGame() {
        var room = Room(["a", "b", "c"])
        let lock = room.start()
        room.run(to: lock + 5.0)
        room.cutOff = ["c"]
        room.tick()
        let before = room["c"].state
        room.leave("c")   // its `present` is empty: it cannot tell "everyone left" from "I lost the network"
        XCTAssertEqual(room["c"].state, before)
        XCTAssertNil(room["c"].state?.endedAt)
        let flips = room.flips
        room.run(for: 6.0)
        XCTAssertNil(room["a"].state?.endedAt)
        XCTAssertGreaterThan(room.flips, flips, "the dealer keeps flipping")
        XCTAssertNil(room["b"].state?.endedAt)
    }

    func testAJoinerTheLockLeftOutDropsTheGameWhenTheEightLeave() {
        // Nine say yes and the host "i" sorts last, so the lock leaves it out; "j" only watches and hears "i" say it is playing.
        var room = Room(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"])
        room.notJoining = ["j"]
        let lock = room.start(host: "i")
        XCTAssertEqual(room["i"].state?.players, ["a", "b", "c", "d", "e", "f", "g", "h"])
        room.run(to: lock + 2.9)
        XCTAssertEqual(room.flips, 0)
        XCTAssertNil(room["i"].joined, "the lock left the host out: it keeps no flag")
        room.run(to: lock + 3.5)
        XCTAssertEqual(room.flips, 1, "the smallest playing id deals once the host's grace has run out, about lock + 3 s")
        room.run(to: lock + 8.0)
        XCTAssertEqual(room.wrote["i"] ?? 0, 0)
        XCTAssertEqual(room.wrote["b"] ?? 0, 0)
        for id in ["a", "b", "c", "d", "e", "f", "g", "h"] { room.leave(id) }
        room.run(for: PlazaDraw.abandonedAfter * 3)
        for id in ["i", "j"] {
            XCTAssertNil(room[id].state, "\(id) dropped the game")
            XCTAssertNil(room[id].berryPhase(now: room.now(id)))
        }
        room.run(for: PlazaDraw.abandonedAfter * 3)
        for id in ["i", "j"] { XCTAssertNil(room[id].state, "\(id): it never comes back") }
    }

    func testADealerCutOffAndBackStartsAFreshJudgingWindow() throws {
        var room = Room(["a", "b", "c"], seed: survivingFive)
        room.start()
        let t = try XCTUnwrap(room.untilFive())
        room.run(to: t + 0.5)
        XCTAssertEqual(room.ring("b"), .right)
        room.tick()   // a, the dealer, sees the bell: its window is open
        room.cutOff = ["a"]
        room.run(for: 1.5)   // a stops being the dealer in its own view while the window is still stamped
        room.cutOff = []
        room.tick()
        room.run(for: 0.2)
        XCTAssertEqual(room.ring("c", extra: -2.2), .right, "a faster reaction on a late screen")
        room.run(for: 1.0)
        let berry = try XCTUnwrap(room["a"].state?.berry)
        XCTAssertEqual(berry.clears.count, 1)
        XCTAssertEqual(berry.scores[2], 1, "the new window collected c's bell inside judgeSeconds")
        XCTAssertEqual(berry.scores[1], 0)
    }
}
