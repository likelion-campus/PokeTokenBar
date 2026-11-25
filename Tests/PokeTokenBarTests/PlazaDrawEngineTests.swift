import XCTest
@testable import PokeTokenBar

/// The drawing quiz's timers, the drawer and the referee, with several Macs' engines exchanging what they know. Each
/// Mac reads its own clock (`skew`), so a game that runs the same with clocks a minute apart is the point.
final class PlazaDrawEngineTests: XCTestCase {
    private let word = "사과"

    private struct Room {
        var engines: [String: PlazaGameEngine]
        var skew: [String: Double]
        var base: Double = 1_800_000_000
        /// Not heard from at all: asleep or off the network. They keep ticking, reach nobody, and nobody reaches them.
        var cutOff: Set<String> = []
        var gone: Set<String> = []
        /// Here and heard, but their app does not act (hung): they never tick.
        var frozen: Set<String> = []
        /// Present, but not counted among those who joined (left out of every `joins`).
        var notJoining: Set<String> = []

        init(_ ids: [String], skew: [String: Double] = [:], seed: UInt64 = 7) {
            engines = Dictionary(uniqueKeysWithValues: ids.map { id in
                var e = PlazaGameEngine(me: id)
                e.makeSeed = { seed }
                return (id, e)
            })
            self.skew = skew
        }

        subscript(id: String) -> PlazaGameEngine {
            get { engines[id]! }
            set { engines[id] = newValue }
        }

        func now(_ id: String) -> Date { Date(timeIntervalSince1970: base + (skew[id] ?? 0)) }

        func present(for id: String) -> Set<String> {
            cutOff.contains(id) ? [] : Set(engines.keys).subtracting(gone).subtracting(cutOff).subtracting([id])
        }

        func joins(for id: String) -> Set<String> {
            present(for: id).filter { engines[$0]!.joined != nil && engines[$0]!.joined == engines[id]!.state?.id && !notJoining.contains($0) }
        }

        /// Everyone ticks, then everyone hears everyone, until nothing changes.
        mutating func exchange() {
            for _ in 0..<12 {
                var changed = false
                for id in engines.keys.sorted() where !gone.contains(id) && !frozen.contains(id) {
                    if engines[id]!.tick(now: now(id), present: present(for: id), joins: joins(for: id), connected: !cutOff.contains(id)) { changed = true }
                }
                for id in engines.keys.sorted() where !gone.contains(id) && !cutOff.contains(id) {
                    for other in engines.keys.sorted() where other != id && !gone.contains(other) && !cutOff.contains(other) {
                        if engines[id]!.learn(engines[other]!.state, from: other, now: now(id)) { changed = true }
                    }
                }
                if !changed { return }
            }
        }

        /// Advances the shared time one second at a time, exchanging after each. 0 only exchanges.
        mutating func step(_ seconds: Int = 0) {
            if seconds == 0 { exchange() }
            for _ in 0..<seconds {
                base += 1
                exchange()
            }
        }

        var live: [String] { engines.keys.sorted().filter { !gone.contains($0) } }
        var drawState: PlazaDrawState? { engines[live.first(where: { engines[$0]!.state?.draw != nil }) ?? live[0]]!.state?.draw }
        func drawerID() -> String? { live.first { engines[$0]!.isDrawer } }
    }

    /// Opens a drawing quiz by `host`, the others join, recruiting runs out and the host locks. Returns the base time of the lock.
    @discardableResult
    private func start(_ room: inout Room, host: String = "c") -> Double {
        XCTAssertTrue(room[host].open(.draw, now: room.now(host)))
        room.step()
        for id in room.live where id != host { room[id].answer(join: true, now: room.now(id)) }
        for _ in 0..<(Int(PlazaGame.recruitSeconds) + 5) where room[host].state?.startsAt == nil { room.step(1) }
        XCTAssertNotNil(room[host].state?.startsAt)
        return room.base
    }

    /// Steps until the current drawer's word field is open. Returns the drawer.
    private func untilEntry(_ room: inout Room) -> String {
        for _ in 0..<60 {
            if let d = room.drawerID(), room[d].state?.draw?.entryAt != nil, room[d].state?.draw?.drawAt == nil { return d }
            room.step(1)
        }
        XCTFail("the word field never opened")
        return room.live[0]
    }

    /// Plays turns until the game ends: each drawer sets the word, the next joined player in id order guesses it 5 s later.
    private func play(_ room: inout Room, results: inout [Int: PlazaDrawState.Result]) {
        for _ in 0..<400 {
            for id in room.live { if let r = room[id].state?.draw?.last { results[r.turn] = r } }
            if room.live.allSatisfy({ room[$0].state?.endedAt != nil }) { return }
            guard let d = room.drawerID() else { room.step(1); continue }
            guard let draw = room[d].state?.draw, draw.entryAt != nil, draw.drawAt == nil else { room.step(1); continue }
            XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
            room.step(5)
            let playing = Set(room.live.filter { room[$0].joined != nil && !room.notJoining.contains($0) })
            let sorted = playing.sorted()
            let guesser = sorted[(sorted.firstIndex(of: d)! + 1) % sorted.count]
            XCTAssertTrue(room[d].guess(word, from: guesser, now: room.now(d), playing: playing))
            room.step()
        }
        XCTFail("the game never ended")
    }

    private func finalScores(_ room: Room) -> [[String: Int]] { room.live.map { room[$0].state?.draw?.scores ?? [:] } }

    // MARK: - Whole games

    func testAGameOfThreeRunsSixTurnsAndRanks() {
        var room = Room(["a", "b", "c"])
        start(&room)
        var results: [Int: PlazaDrawState.Result] = [:]
        play(&room, results: &results)
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(Set(finalScores(room)).count, 1, "every Mac holds the same scores")
        for id in room.live {
            XCTAssertNotNil(room[id].state?.endedAt)
            XCTAssertEqual(room[id].drawPhase(now: room.now(id)), .over)
        }
        let total = finalScores(room)[0].values.reduce(0, +)
        XCTAssertEqual(total, 6 * (PlazaDraw.guessPoints + PlazaDraw.drawerPoints))
    }

    func testTheSameGameEndsTheSameWithClocksFortyFiveSecondsApart() {
        var plain = Room(["a", "b", "c"])
        start(&plain)
        var plainResults: [Int: PlazaDrawState.Result] = [:]
        play(&plain, results: &plainResults)

        // The first drawer's clock is 45 s slow. The existing plaza checks bound the other clock: a Mac whose clock is
        // 45 s ahead of the host drops a recruiting game at once (`phase`), and a stamp more than `clockSlack` (60 s)
        // ahead of a Mac's own clock is refused, so +14 is the furthest a second clock can go from the slow one.
        let seed = (1...200).first { PlazaDraw.order(players: ["a", "b", "c"], seed: UInt64($0))[0] == "b" }.map(UInt64.init)!
        var room = Room(["a", "b", "c"], skew: ["a": 14, "b": -45, "c": 0], seed: seed)
        let lockedAt = start(&room)
        var first: String?
        for _ in 0..<8 where first == nil || room[first!].state?.draw?.entryAt == nil {
            first = first ?? room.drawState?.order[0]
            room.step(1)
        }
        XCTAssertEqual(first, "b", "the first drawer's clock is the slow one")
        XCTAssertNotNil(room["b"].state?.draw?.entryAt)
        XCTAssertLessThanOrEqual(room.base - lockedAt, 4, "its field opens within 4 s of the lock on the shared time")
        var results: [Int: PlazaDrawState.Result] = [:]
        play(&room, results: &results)
        XCTAssertEqual(results.count, plainResults.count)
        XCTAssertEqual(finalScores(room)[0].values.reduce(0, +), finalScores(plain)[0].values.reduce(0, +))
        XCTAssertEqual(Set(finalScores(room)).count, 1)
        XCTAssertEqual(room.live.compactMap { room[$0].state?.endedAt }.count, 3, "every Mac saw the end")
    }

    // MARK: - One turn

    func testNoWordInTwentySecondsPassesTheTurn() {
        var room = Room(["a", "b", "c"])
        start(&room)
        _ = untilEntry(&room)
        room.step(19)
        XCTAssertEqual(room.drawState?.turn, 0)
        room.step(1)
        XCTAssertEqual(room.drawState?.turn, 1)
        XCTAssertNil(room.drawState?.last?.word)
        XCTAssertNil(room.drawState?.last?.solver)
        XCTAssertEqual(room.drawState?.scores.values.reduce(0, +), 0)
    }

    func testSixtySecondsOfDrawingEndsWithTheWordShown() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(59)
        XCTAssertEqual(room.drawState?.turn, 0)
        room.step(1)
        XCTAssertEqual(room.drawState?.turn, 1)
        XCTAssertEqual(room.drawState?.last?.word, word)
        XCTAssertNil(room.drawState?.last?.solver)
    }

    func testHintsArePublishedAtThirtyAndFortyFiveSeconds() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        let watcher = room.live.first { $0 != d }!
        room.step(29)
        XCTAssertNil(room[watcher].state?.draw?.letters)
        room.step(1)
        XCTAssertEqual(room[watcher].state?.draw?.letters, 2)
        XCTAssertNil(room[watcher].state?.draw?.initials)
        room.step(14)
        XCTAssertNil(room[watcher].state?.draw?.initials)
        room.step(1)
        XCTAssertEqual(room[watcher].state?.draw?.initials, PlazaDraw.initials(word))
    }

    func testAGuessFromSomeoneNotPlayingIsIgnored() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(3)
        let before = room[d].state
        XCTAssertFalse(room[d].guess(word, from: "z", now: room.now(d), playing: ["a", "b", "c"]))
        XCTAssertFalse(room[d].guess(word, from: d, now: room.now(d), playing: ["a", "b", "c"]), "the drawer's own line is ignored")
        XCTAssertFalse(room[d].guess("바나나", from: room.live.first { $0 != d }!, now: room.now(d), playing: ["a", "b", "c"]))
        XCTAssertEqual(room[d].state, before)
        XCTAssertEqual(room[d].state?.draw?.turn, 0)
    }

    func testTheWordStaysOnTheDrawersMachineUntilTheTurnEnds() throws {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(10)
        XCTAssertEqual(room[d].myWord, word)
        XCTAssertTrue(room[d].blocksOwnLine("이건 \(word) 야"))
        for id in room.live {
            let json = String(decoding: try JSONEncoder().encode(room[id].state), as: UTF8.self)
            XCTAssertFalse(json.contains(word), "\(id)'s state carries the word")
            if id != d { XCTAssertNil(room[id].myWord) }
        }
        let guesser = room.live.first { $0 != d }!
        XCTAssertTrue(room[d].guess(word, from: guesser, now: room.now(d), playing: Set(room.live)))
        room.step()
        for id in room.live {
            XCTAssertEqual(room[id].state?.draw?.last?.word, word)
            XCTAssertNil(room[id].myWord)
        }
        XCTAssertFalse(room[d].blocksOwnLine(word), "the turn is over")
    }

    // MARK: - The referee

    func testADrawerWhoSleptDoesNotEndTheGameForEveryone() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(2)
        let beforeSleep = room[d].state
        room.cutOff = [d]
        room.step(40)
        XCTAssertEqual(room[d].state, beforeSleep, "it wrote nothing while cut off")
        let other = room.live.first { $0 != d }!
        XCTAssertGreaterThanOrEqual(room[other].state?.draw?.turn ?? 0, 2, "the referee ended its turn and two more passed")
        XCTAssertNil(room[other].state?.endedAt)
        XCTAssertNil(room[other].state?.draw?.last?.solver)
        room.cutOff = []
        room.step(2)
        XCTAssertEqual(room[d].state, room[other].state, "it takes the others' state")
        XCTAssertNil(room[d].state?.endedAt, "the game is still running")
    }

    func testTheDrawerAndTheRefereeEndingAtOnceAgree() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(2)
        let others = room.live.filter { $0 != d }
        let referee = others[0], guesser = others[1]
        // The referee sees the drawer gone for 3 s and writes its end; the drawer ends the same turn with the word.
        // Neither has heard the other.
        let drawerFirst = room[d].guess(word, from: guesser, now: room.now(d), playing: Set(room.live))
        XCTAssertTrue(drawerFirst)
        room.base += 1
        XCTAssertFalse(room.engines[referee]!.tick(now: room.now(referee), present: [guesser], joins: [guesser]), "absence starts")
        room.base += 3
        XCTAssertTrue(room.engines[referee]!.tick(now: room.now(referee), present: [guesser], joins: [guesser]))
        XCTAssertNil(room[referee].state?.draw?.last?.word)
        XCTAssertEqual(room[referee].state?.draw?.turn, room[d].state?.draw?.turn)
        room.step()
        let states = room.live.map { room[$0].state }
        XCTAssertEqual(Set(states).count, 1, "one state everywhere")
        XCTAssertEqual(states[0]?.draw?.last?.word, word, "the drawer's result with the word wins")
        XCTAssertEqual(states[0]?.draw?.last?.solver, guesser)
    }

    func testADrawerMissingForAMomentLosesOneTurnNotTheGame() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = untilEntry(&room)
        let order = room.drawState!.order
        let missing = order[1]
        XCTAssertNotEqual(missing, d)
        XCTAssertTrue(room[d].setWord(word, now: room.now(d)))
        room.step(3)
        room.notJoining = [missing]
        let guesser = room.live.first { $0 != d && $0 != missing }!
        XCTAssertTrue(room[d].guess(word, from: guesser, now: room.now(d), playing: Set(room.live).subtracting([missing])))
        room.step()
        XCTAssertEqual(room.drawState?.turn, 2, "the missing player's next turn is skipped")
        XCTAssertEqual(room.drawState?.order, order, "the order is kept whole")
        room.notJoining = []
        var results: [Int: PlazaDrawState.Result] = [:]
        play(&room, results: &results)
        XCTAssertNil(results[1], "no result for the skipped turn")
        XCTAssertEqual(results[4]?.drawer, missing, "it draws in the second round")
        XCTAssertNotNil(room[d].state?.endedAt)
    }

    func testClosingThePlazaTakesMeOutAndIDoNotComeBack() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = room.drawState!.order[0]
        room.engines[d]!.leave(now: room.now(d), present: room.present(for: d))
        XCTAssertNil(room[d].joined)
        var results: [Int: PlazaDrawState.Result] = [:]
        for _ in 0..<5 {
            room.step(1)
            XCTAssertFalse(room[d].isDrawer, "reopening the plaza does not bring me back")
            XCTAssertNil(room[d].joined)
        }
        play(&room, results: &results)
        XCTAssertNil(results[0]?.word, "the referee passed my turn")
        XCTAssertEqual(results[0]?.drawer, d)
        XCTAssertEqual(results.values.filter { $0.drawer == d }.count, 1, "my second turn was skipped")
        XCTAssertEqual(room[d].state?.draw?.scores[d], 0)
    }

    func testTheRefereeWaitsOutTheWholeTurnForADrawerWhoIsStillHere() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = room.drawState!.order[0]
        room.frozen = [d]
        let limit = Int(PlazaDraw.revealSeconds + PlazaDraw.wordSeconds + PlazaDraw.drawSeconds + PlazaDraw.refereeSlack)
        room.step(limit - 2)
        XCTAssertEqual(room.drawState?.turn, 0, "the slack is still running")
        room.step(4)
        XCTAssertEqual(room.drawState?.turn, 1)
        XCTAssertNil(room.drawState?.last?.word)
        XCTAssertNil(room.drawState?.last?.solver)
    }

    // MARK: - Old copies, isolation, life

    func testACopyWithoutTheDrawPayloadIsNeverPlayedOrRefereed() {
        var room = Room(["a", "b", "c"])
        XCTAssertTrue(room["c"].open(.draw, now: room.now("c")))
        room.step()
        let recruiting = room["c"].state
        for id in ["a", "b"] { room[id].answer(join: true, now: room.now(id)) }
        for _ in 0..<(Int(PlazaGame.recruitSeconds) + 5) where room["c"].state?.startsAt == nil { room.step(1) }
        var stripped = room["c"].state!
        stripped.draw = nil
        var old = PlazaGameEngine(me: "a")
        old.learn(recruiting, from: "c", now: room.now("a"))
        old.answer(join: true, now: room.now("a"))
        XCTAssertNotNil(old.joined)
        old.learn(stripped, from: "c", now: room.now("a"))
        XCTAssertEqual(old.state, stripped)
        let before = old.state
        for _ in 0..<150 {
            room.base += 1
            XCTAssertFalse(old.tick(now: room.now("a"), present: ["b", "c"], joins: ["b", "c"]))
            XCTAssertNil(old.drawPhase(now: room.now("a")))
        }
        XCTAssertEqual(old.state, before)
    }

    func testAnIsolatedMachineWritesNothingAndStepsOut() {
        var room = Room(["a", "b", "c"])
        start(&room)
        let d = room.drawState!.order[0]
        let before = room[d].state
        room.cutOff = [d]
        room.step(9)
        XCTAssertNil(room[d].lostConnection)
        room.step(2)
        XCTAssertEqual(room[d].state, before, "it wrote nothing")
        XCTAssertNil(room[d].joined)
        XCTAssertEqual(room[d].lostConnection, before?.id)
    }

    func testEightTurnsWithTheRefereeEveryTimeStayInsideTheGameLife() {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var room = Room(ids)
        start(&room, host: "a")
        let opened = room["a"].state!.opensAt
        XCTAssertEqual(room.drawState?.order.count, 8)
        for _ in 0..<8 {
            guard let turn = room.drawState?.turn, let d = room.drawState?.order[safe: turn] else { break }
            room.cutOff = [d]
            for _ in 0..<30 where room.drawState?.turn == turn && room.live.contains(where: { room[$0].state?.endedAt == nil }) { room.step(1) }
        }
        room.cutOff = []
        room.step(2)
        for id in ids {
            let ended = room[id].state?.endedAt
            XCTAssertNotNil(ended, "\(id) saw the end")
            XCTAssertLessThan(ended ?? .infinity, opened + PlazaGame.maxLife)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
