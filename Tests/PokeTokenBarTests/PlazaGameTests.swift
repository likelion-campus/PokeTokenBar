import XCTest
@testable import PokeTokenBar

/// The minigame lobby and 폭탄 돌리기 rules, with several Macs' engines exchanging what they know.
final class PlazaGameTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A plaza of engines. `gone` members are not in anyone's plaza and neither tick nor hear anything. `cutOff` members
    /// (asleep and woken, or off the network) keep ticking but reach nobody, and nobody reaches them.
    private struct Plaza {
        var engines: [String: PlazaGameEngine]
        var gone: Set<String> = []
        var cutOff: Set<String> = []

        init(_ ids: [String], seed: UInt64 = 7) {
            engines = Dictionary(uniqueKeysWithValues: ids.map { id in
                var e = PlazaGameEngine(me: id)
                e.makeSeed = { seed }
                return (id, e)
            })
        }

        subscript(id: String) -> PlazaGameEngine {
            get { engines[id]! }
            set { engines[id] = newValue }
        }

        func present(for id: String) -> Set<String> {
            cutOff.contains(id) ? [] : Set(engines.keys).subtracting(gone).subtracting(cutOff).subtracting([id])
        }

        /// Everyone ticks, then everyone hears everyone, until nothing changes.
        mutating func step(_ now: Date) {
            for _ in 0..<8 {
                var changed = false
                for id in engines.keys.sorted() where !gone.contains(id) {
                    let present = present(for: id)
                    let joins = Set(present.filter { engines[$0]!.joined != nil && engines[$0]!.joined == engines[id]!.state?.id })
                    if engines[id]!.tick(now: now, present: present, joins: joins, connected: !cutOff.contains(id)) { changed = true }
                }
                for id in engines.keys.sorted() where !gone.contains(id) && !cutOff.contains(id) {
                    for other in engines.keys.sorted() where other != id && !gone.contains(other) && !cutOff.contains(other) {
                        if engines[id]!.learn(engines[other]!.state, from: other, now: now) { changed = true }
                    }
                }
                if !changed { return }
            }
        }

        var states: [PlazaGameState?] { engines.keys.sorted().filter { !gone.contains($0) }.map { engines[$0]!.state } }
    }

    /// Opens a game by `a`, everyone in `joiners` says yes, and recruiting runs out. Returns the moment play begins.
    private func started(_ plaza: inout Plaza, host: String = "a", joiners: [String]) -> TimeInterval {
        XCTAssertTrue(plaza[host].open(.bomb, now: at(0)))
        plaza.step(at(1))
        for id in joiners { plaza[id].answer(join: true, now: at(2)) }
        plaza.step(at(PlazaGame.recruitSeconds))
        return PlazaGame.recruitSeconds + PlazaGame.countdownSeconds
    }

    // MARK: - Lobby

    func testAnOpenedGameReachesEveryoneAndRecruits() {
        var plaza = Plaza(["a", "b", "c"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        XCTAssertEqual(plaza["b"].phase(now: at(1)), .recruiting)
        XCTAssertEqual(plaza["c"].state?.host, "a")
        XCTAssertEqual(plaza["a"].joined, plaza["a"].state?.id, "the host is in from the start")
        XCTAssertNil(plaza["b"].joined, "nobody is in without saying so")
    }

    func testTheHostLocksInWhoSaidYesWhenRecruitingEnds() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b"])
        let s = plaza["c"].state
        XCTAssertEqual(s?.players, ["a", "b"], "c never answered, so c watches")
        XCTAssertEqual(s?.startsAt, t0.timeIntervalSince1970 + start)
        XCTAssertEqual(plaza["b"].phase(now: at(start - 1)), .countdown)
        XCTAssertEqual(plaza["b"].phase(now: at(start)), .playing)
        XCTAssertTrue(plaza["b"].isPlaying)
        XCTAssertFalse(plaza["c"].isPlaying)
        XCTAssertTrue(["a", "b"].contains(s?.bomb?.holder ?? ""))
    }

    func testSayingNoKeepsMeOutAndIsNotSent() {
        var plaza = Plaza(["a", "b", "c"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        plaza["b"].answer(join: true, now: at(2))
        plaza["b"].answer(join: false, now: at(3))
        plaza["c"].answer(join: true, now: at(3))
        XCTAssertNil(plaza["b"].joined)
        XCTAssertEqual(plaza["b"].declined, plaza["b"].state?.id)
        plaza.step(at(PlazaGame.recruitSeconds))
        XCTAssertEqual(plaza["a"].state?.players, ["a", "c"])
    }

    func testAGameWithOnePlayerIsCancelledWhenRecruitingEnds() {
        var plaza = Plaza(["a", "b"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(PlazaGame.recruitSeconds - 1))
        XCTAssertEqual(plaza["b"].phase(now: at(PlazaGame.recruitSeconds - 1)), .recruiting)
        plaza.step(at(PlazaGame.recruitSeconds))
        XCTAssertEqual(plaza["b"].phase(now: at(PlazaGame.recruitSeconds)), .ended)
        XCTAssertNil(plaza["b"].state?.winner)
        XCTAssertNil(plaza["b"].state?.startsAt)
    }

    func testTheHostCanStartEarlyOnlyOnceTwoAreIn() {
        var plaza = Plaza(["a", "b"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza["a"].requestStart()
        plaza.step(at(5))
        XCTAssertEqual(plaza["a"].phase(now: at(5)), .recruiting, "alone, the request waits")
        plaza["b"].answer(join: true, now: at(6))
        plaza.step(at(7))
        XCTAssertEqual(plaza["b"].state?.startsAt, t0.timeIntervalSince1970 + 7 + PlazaGame.countdownSeconds)
        // Only the host's request counts.
        var other = Plaza(["a", "b"])
        XCTAssertTrue(other["a"].open(.bomb, now: at(0)))
        other.step(at(1))
        other["b"].answer(join: true, now: at(2))
        other["b"].requestStart()
        other.step(at(5))
        XCTAssertEqual(other["a"].phase(now: at(5)), .recruiting)
    }

    func testNoSecondGameOpensOverALiveOneAndARematchWaitsAMoment() {
        var plaza = Plaza(["a", "b"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        XCTAssertFalse(plaza["b"].open(.bomb, now: at(2)))
        plaza.step(at(PlazaGame.recruitSeconds))   // cancelled: only the host
        let ended = PlazaGame.recruitSeconds
        XCTAssertFalse(plaza["b"].open(.bomb, now: at(ended + PlazaGame.rematchDelay - 1)))
        XCTAssertTrue(plaza["b"].open(.bomb, now: at(ended + PlazaGame.rematchDelay)))
        plaza.step(at(ended + PlazaGame.rematchDelay + 1))
        XCTAssertEqual(plaza["a"].state?.host, "b", "the newer game replaces the ended one everywhere")
        XCTAssertEqual(plaza["a"].phase(now: at(ended + PlazaGame.rematchDelay + 1)), .recruiting)
    }

    func testARecruitingGameWhoseHostLeftIsForgotten() {
        var plaza = Plaza(["a", "b", "c"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        plaza["b"].answer(join: true, now: at(2))
        plaza.gone = ["a"]
        let dead = PlazaGame.recruitSeconds + PlazaGame.hostGrace
        plaza.step(at(dead - 1))
        XCTAssertEqual(plaza["b"].phase(now: at(dead - 1)), .recruiting)
        plaza.step(at(dead))
        XCTAssertNil(plaza["b"].state)
        XCTAssertNil(plaza["b"].joined)
        XCTAssertTrue(plaza["c"].open(.bomb, now: at(dead)))
    }

    func testTheHostLeavingWhileRecruitingCancelsForEveryone() {
        var plaza = Plaza(["a", "b"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        plaza["a"].leave(now: at(5), present: ["b"])
        plaza.step(at(5))
        XCTAssertEqual(plaza["b"].phase(now: at(5)), .ended)
        XCTAssertNil(plaza["b"].state?.winner)
    }

    // MARK: - The bomb

    func testAHitFromTheHolderHandsTheBombOverAndEveryoneAgrees() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let holder = plaza["a"].state!.bomb!.holder
        let target = ["a", "b", "c"].first { $0 != holder }!
        let bystander = ["a", "b", "c"].first { $0 != holder && $0 != target }!
        XCTAssertFalse(plaza[target].hit(by: holder, now: at(start - 0.5)), "not before the bomb is live")
        XCTAssertFalse(plaza[target].hit(by: bystander, now: at(start + 1)), "only the holder's hit counts")
        XCTAssertTrue(plaza[target].hit(by: holder, now: at(start + 1)))
        plaza.step(at(start + 1))
        XCTAssertEqual(Set(plaza.states.map { $0?.bomb?.holder }), [target])
        XCTAssertEqual(plaza[holder].state?.bomb?.from, holder)
    }

    func testTheBombCannotGoStraightBackForTwoSeconds() {
        var plaza = Plaza(["a", "b"])
        let start = started(&plaza, joiners: ["b"])
        let holder = plaza["a"].state!.bomb!.holder, other = holder == "a" ? "b" : "a"
        XCTAssertTrue(plaza[other].hit(by: holder, now: at(start + 1)))
        plaza.step(at(start + 1))
        XCTAssertFalse(plaza[holder].hit(by: other, now: at(start + 1 + PlazaBomb.returnImmunity - 0.1)))
        XCTAssertTrue(plaza[holder].hit(by: other, now: at(start + 1 + PlazaBomb.returnImmunity)))
    }

    func testASpectatorOrAnOutPlayerNeverTakesTheBomb() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b"])
        let holder = plaza["a"].state!.bomb!.holder
        XCTAssertFalse(plaza["c"].hit(by: holder, now: at(start + 1)))
        XCTAssertEqual(plaza["c"].state?.bomb?.holder, holder)
    }

    func testTheHolderBlowsUpWhenTheFuseRunsOutAndTheLastOneWins() {
        var plaza = Plaza(["a", "b"])
        let start = started(&plaza, joiners: ["b"])
        let s = plaza["a"].state!
        let holder = s.bomb!.holder, other = holder == "a" ? "b" : "a"
        let fuse = PlazaBomb.fuse(seed: s.seed, round: 1)
        XCTAssertTrue(PlazaBomb.fuseRange.contains(fuse))
        plaza.step(at(start + fuse - 0.1))
        XCTAssertEqual(plaza[other].phase(now: at(start + fuse - 0.1)), .playing)
        plaza.step(at(start + fuse))
        XCTAssertEqual(plaza[other].phase(now: at(start + fuse)), .ended)
        XCTAssertEqual(plaza[other].state?.winner, other)
        XCTAssertEqual(plaza[other].state?.bomb?.out, [holder])
        XCTAssertEqual(Set(plaza.states).count, 1)
    }

    func testWithThreeTheGameGoesOnToASecondBombAfterAPause() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let s = plaza["a"].state!
        let first = s.bomb!.holder
        let boom = start + PlazaBomb.fuse(seed: s.seed, round: 1)
        plaza.step(at(boom))
        let next = plaza["a"].state!
        XCTAssertNil(next.endedAt)
        XCTAssertEqual(next.bomb?.round, 2)
        XCTAssertEqual(next.bomb?.out, [first])
        XCTAssertNotEqual(next.bomb?.holder, first)
        XCTAssertEqual(next.bomb?.roundStartsAt, t0.timeIntervalSince1970 + boom + PlazaBomb.intermission)
        XCTAssertFalse(plaza[first].isPlaying)
        // No hand-over during the pause.
        let holder = next.bomb!.holder
        let target = ["a", "b", "c"].first { $0 != holder && $0 != first }!
        XCTAssertFalse(plaza[target].hit(by: holder, now: at(boom + 1)))
        // The second bomb ends it.
        let boom2 = boom + PlazaBomb.intermission + PlazaBomb.fuse(seed: s.seed, round: 2)
        plaza.step(at(boom2))
        XCTAssertEqual(plaza[first].state?.winner, target)
        XCTAssertEqual(Set(plaza.states).count, 1)
    }

    func testFusesDifferByRoundAndSeedAndStayHiddenInRange() {
        var seen: Set<Int> = []
        for seed in UInt64(1)...40 {
            for round in 1...4 {
                let f = PlazaBomb.fuse(seed: seed, round: round)
                XCTAssertTrue(PlazaBomb.fuseRange.contains(f))
                seen.insert(Int(f))
            }
        }
        XCTAssertGreaterThan(seen.count, 12, "fuses spread over the range")
        XCTAssertNotEqual(PlazaBomb.fuse(seed: 3, round: 1), PlazaBomb.fuse(seed: 3, round: 2))
    }

    func testAHolderWhoLeftThePlazaIsPutOutByTheReferee() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let holder = plaza["a"].state!.bomb!.holder
        plaza.gone = [holder]
        plaza.step(at(start + 1))
        XCTAssertEqual(plaza.states.compactMap { $0?.bomb?.holder }.first, holder, "a blink of absence is forgiven")
        plaza.step(at(start + 1 + PlazaBomb.absenceGrace))
        let s = plaza.states.first!!
        XCTAssertEqual(s.bomb?.out, [holder])
        XCTAssertEqual(s.bomb?.round, 2)
        XCTAssertEqual(Set(plaza.states).count, 1)
    }

    func testAHolderWhoseMacNeverReportsIsPutOutAfterTheGrace() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let s = plaza["a"].state!
        let holder = s.bomb!.holder
        let boom = start + PlazaBomb.fuse(seed: s.seed, round: 1)
        // The holder's engine is frozen (it still counts as present): tick only the others.
        let others = ["a", "b", "c"].filter { $0 != holder }
        func tickOthers(_ now: Date) {
            for id in others { plaza[id].tick(now: now, present: Set(["a", "b", "c"]).subtracting([id]), joins: []) }
            for id in others { for o in others where o != id { plaza[id].learn(plaza[o].state, now: now) } }
        }
        tickOthers(at(boom + PlazaBomb.absenceGrace - 0.1))
        XCTAssertEqual(plaza[others[0]].state?.bomb?.round, 1)
        tickOthers(at(boom + PlazaBomb.absenceGrace))
        XCTAssertEqual(plaza[others[0]].state?.bomb?.out, [holder])
        XCTAssertEqual(plaza[others[0]].state, plaza[others[1]].state)
    }

    func testLeavingAsHolderBlowsMeUpAndPlayersWhoAreGoneCannotWin() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let holder = plaza["a"].state!.bomb!.holder
        let others = ["a", "b", "c"].filter { $0 != holder }
        // One of the others is already gone when the holder leaves: the one still here wins.
        plaza.gone = [others[1]]
        plaza[holder].leave(now: at(start + 2), present: plaza.present(for: holder))
        plaza.step(at(start + 2))
        XCTAssertEqual(plaza[others[0]].state?.winner, others[0])
        XCTAssertEqual(Set(plaza[others[0]].state?.bomb?.out ?? []), [holder, others[1]])
    }

    func testLeavingDuringTheCountdownKeepsTheNextRoundAfterTheStart() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let holder = plaza["a"].state!.bomb!.holder
        plaza[holder].leave(now: at(start - 2.5), present: plaza.present(for: holder))
        let s = plaza[holder].state!
        XCTAssertGreaterThanOrEqual(s.bomb!.roundStartsAt, s.startsAt!)
        XCTAssertNotNil(PlazaGame.accepted(s, now: at(start - 2.5)), "teammates accept what the leaver wrote")
    }

    // MARK: - Leaving, cut-off Macs and consent (the 2026-11-22 audit)

    /// Before: any player leaving re-dealt the bomb with a fresh fuse, so closing the plaza a second before the blast
    /// saved the holder.
    func testANonHolderLeavingKeepsTheBombAndItsFuse() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let before = plaza["a"].state!
        let holder = before.bomb!.holder
        let leaver = ["a", "b", "c"].first { $0 != holder }!
        plaza[leaver].leave(now: at(start + 5), present: plaza.present(for: leaver))
        plaza.step(at(start + 5))
        let s = plaza[holder].state!
        XCTAssertEqual(s.bomb?.out, [leaver])
        XCTAssertEqual(s.bomb?.round, 1, "no new round")
        XCTAssertEqual(s.bomb?.holder, holder)
        XCTAssertEqual(s.bomb?.roundStartsAt, before.bomb?.roundStartsAt, "the fuse keeps running")
        XCTAssertEqual(Set(plaza.states).count, 1)
        XCTAssertNotNil(PlazaGame.accepted(s, now: at(start + 5)))
    }

    func testTheLastOpponentLeavingEndsTheGameForTheOneWhoStayed() {
        var plaza = Plaza(["a", "b"])
        let start = started(&plaza, joiners: ["b"])
        let holder = plaza["a"].state!.bomb!.holder, other = holder == "a" ? "b" : "a"
        plaza[other].leave(now: at(start + 5), present: plaza.present(for: other))
        plaza.step(at(start + 5))
        XCTAssertEqual(plaza[holder].state?.winner, holder)
    }

    /// Before: a Mac that slept through the game woke with nobody in sight, made itself the referee, put everyone else
    /// out and published "I won", which beat the running game on every Mac once it reconnected.
    func testAMacCutOffFromEveryoneNeitherWinsNorEndsTheGame() {
        var plaza = Plaza(["a", "b", "c", "d", "e"])
        let start = started(&plaza, joiners: ["b", "c", "d", "e"])
        let s0 = plaza["a"].state!
        let holder = s0.bomb!.holder
        let sleeper = s0.players.first { $0 != holder }!
        plaza.cutOff = [sleeper]
        let boom = start + PlazaBomb.fuse(seed: s0.seed, round: 1)
        for now in stride(from: start + 1, through: boom + PlazaBomb.absenceGrace + 1, by: 1) { plaza.step(at(now)) }
        XCTAssertNil(plaza[sleeper].state?.endedAt, "it ends nobody's game")
        XCTAssertNil(plaza[sleeper].state?.winner)
        XCTAssertEqual(plaza[sleeper].state?.bomb?.out, [sleeper], "after a while it only steps out itself")
        XCTAssertEqual(plaza[sleeper].lostConnection, s0.id)
        let others = plaza[holder].state!
        XCTAssertNil(others.endedAt, "the rest play on")
        XCTAssertEqual(others.bomb?.round, 2)
        // Back on the network: the running game wins, with the sleeper out.
        plaza.cutOff = []
        plaza.step(at(boom + PlazaBomb.absenceGrace + 2))
        XCTAssertEqual(Set(plaza.states).count, 1)
        XCTAssertNil(plaza[sleeper].state?.endedAt)
        XCTAssertTrue(plaza[sleeper].state?.bomb?.out.contains(sleeper) == true)
        XCTAssertEqual(plaza[sleeper].state?.bomb?.out.count, 2, "the one who blew up, and the sleeper")
    }

    func testAShortCutOffKeepsMyPlace() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let holder = plaza["a"].state!.bomb!.holder
        let blinker = ["a", "b", "c"].first { $0 != holder }!
        plaza.cutOff = [blinker]
        plaza.step(at(start + 1))
        plaza.step(at(start + 1 + PlazaGame.isolationLimit - 0.5))
        plaza.cutOff = []
        plaza.step(at(start + 1 + PlazaGame.isolationLimit))
        XCTAssertEqual(plaza[blinker].state?.bomb?.out, [])
        XCTAssertTrue(plaza[blinker].isPlaying)
    }

    func testACutOffHolderBlowsUpAloneAndPutsNobodyElseOut() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let s0 = plaza["a"].state!
        let holder = s0.bomb!.holder
        plaza.cutOff = [holder]
        plaza.step(at(start + 1))
        // Its fuse runs out before the isolation limit would.
        plaza[holder].tick(now: at(start + PlazaBomb.fuse(seed: s0.seed, round: 1)), present: [], joins: [], connected: false)
        XCTAssertEqual(plaza[holder].state?.bomb?.out, [holder])
        XCTAssertNil(plaza[holder].state?.endedAt)
    }

    /// Before: the next holder wore the bomb through the countdown and the pause, and everyone else was told to get
    /// away from them: a head start longer than the map.
    func testWhoGetsTheNextBombIsHiddenThroughThePauseBetweenRounds() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let s0 = plaza["a"].state!
        func view(_ id: String, _ now: Date) -> PlazaGameView {
            PlazaGameView.make(engine: plaza[id], now: now, joinedCount: 3, canPlay: true, flash: nil, name: { $0 })
        }
        XCTAssertNil(view("a", at(start - 1)).holder, "the countdown")
        XCTAssertEqual(view("a", at(start - 1)).hint, L(.ko).plazaGameScatterHint)
        XCTAssertEqual(view("a", at(start + 1)).holder, s0.bomb?.holder, "live")
        let boom = start + PlazaBomb.fuse(seed: s0.seed, round: 1)
        plaza.step(at(boom))
        let next = plaza["a"].state!.bomb!
        XCTAssertEqual(next.round, 2, "test precondition")
        for id in ["a", "b", "c"] where id != s0.bomb?.holder {
            XCTAssertNil(view(id, at(boom + 1)).holder, "the pause: nobody wears the bomb yet")
            XCTAssertEqual(view(id, at(boom + 1)).hint, L(.ko).plazaGameScatterHint, "and the next holder reads the same line as the rest")
        }
        XCTAssertEqual(view("a", at(boom + PlazaBomb.intermission)).holder, next.holder)
    }

    /// Before: with the holder counted among "those here", a silent holder with the smallest ID was its own referee on
    /// every other Mac, so nobody put it out. The old test passed because its seed made "b" the holder.
    func testASilentHolderWithTheSmallestIDStillHasAReferee() throws {
        let ids = ["a", "b", "c"]
        let seed = try XCTUnwrap((UInt64(1)...200).first { PlazaBomb.firstHolder(seed: $0, round: 1, alive: ids) == "a" })
        var plaza = Plaza(ids, seed: seed)
        let start = started(&plaza, joiners: ["b", "c"])
        XCTAssertEqual(plaza["b"].state?.bomb?.holder, "a", "test precondition")
        let boom = start + PlazaBomb.fuse(seed: seed, round: 1)
        for id in ["b", "c"] { plaza[id].tick(now: at(boom + PlazaBomb.absenceGrace), present: Set(ids).subtracting([id]), joins: []) }
        XCTAssertEqual(plaza["b"].state?.bomb?.out, ["a"], "b, the first player who is not the holder, speaks")
        XCTAssertEqual(plaza["c"].state?.bomb?.out, [], "and only b")
    }

    /// Before: a Mac played whenever the list named it. A late N (or a made-up list) locked in someone who never said yes.
    func testListedWithoutMyYesIStepOutAndTheBombStaysWhereItIs() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b"])
        var forged = plaza["a"].state!
        let holder = forged.bomb!.holder
        forged.players = ["a", "b", "c"]
        forged.bomb!.pass += 1   // newer than what c knows, so c takes it
        XCTAssertNotNil(PlazaGame.accepted(forged, now: at(start + 1)), "test precondition: the list itself is within bounds")
        plaza["c"].learn(forged, from: "a", now: at(start + 1))
        XCTAssertFalse(plaza["c"].isPlayer, "named, but never said yes")
        plaza["c"].tick(now: at(start + 1), present: ["a", "b"], joins: [])
        XCTAssertEqual(plaza["c"].state?.bomb?.out, ["c"])
        XCTAssertEqual(plaza["c"].state?.bomb?.holder, holder)
        XCTAssertEqual(plaza["c"].state?.bomb?.round, 1)
        XCTAssertFalse(plaza["c"].hit(by: holder, now: at(start + 2)), "and takes no bomb")
    }

    /// Before: anyone's presence could carry an invitation naming any host.
    func testAnInvitationCountsOnlyFromItsHostsOwnMac() {
        var a = PlazaGameEngine(me: "a")
        XCTAssertTrue(a.open(.bomb, now: at(0)))
        var b = PlazaGameEngine(me: "b")
        b.learn(a.state, from: "c", now: at(1))
        XCTAssertNil(b.state, "c cannot invite in a's name")
        b.learn(a.state, from: "a", now: at(1))
        XCTAssertEqual(b.state?.host, "a")
        // A game already running is passed on by anyone (a late Mac still sees it).
        var plaza = Plaza(["a", "b", "c"])
        _ = started(&plaza, joiners: ["b"])
        var late = PlazaGameEngine(me: "d")
        late.learn(plaza["c"].state, from: "c", now: at(PlazaGame.recruitSeconds + 1))
        XCTAssertNotNil(late.state)
    }

    /// Before: open, cancel, wait five seconds, open again put a new card on every plaza each time.
    func testAHostWhoseGameWasCancelledWaitsBeforeInvitingAgain() {
        var plaza = Plaza(["a", "b"])
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(0)))
        plaza.step(at(1))
        plaza["a"].leave(now: at(5), present: ["b"])
        plaza.step(at(5))
        XCTAssertFalse(plaza["a"].open(.bomb, now: at(5 + PlazaGame.rematchDelay + 1)), "my own Mac refuses")
        XCTAssertEqual(plaza["a"].opensIn(now: at(15)), PlazaGame.reopenDelay - 10)
        // A Mac that opens one anyway is not heard.
        let again = PlazaGameState(id: "a@again", kind: "bomb", host: "a", opensAt: t0.timeIntervalSince1970 + 15)
        plaza["b"].learn(again, from: "a", now: at(15))
        XCTAssertNotEqual(plaza["b"].state?.id, "a@again")
        // The teammate is not held back by my cancelled game.
        XCTAssertTrue(plaza["b"].canOpen(now: at(5 + PlazaGame.rematchDelay)))
        XCTAssertTrue(plaza["a"].open(.bomb, now: at(5 + PlazaGame.reopenDelay)))
        plaza.step(at(5 + PlazaGame.reopenDelay))
        XCTAssertEqual(plaza["b"].phase(now: at(5 + PlazaGame.reopenDelay)), .recruiting)
    }

    /// Before: a count sent at its limit made the engine's next move out of bounds; the state was dropped, learned again
    /// and moved again five times a second.
    func testAGameAtItsPassLimitEndsInsteadOfLeavingTheBounds() {
        var plaza = Plaza(["a", "b"])
        let start = started(&plaza, joiners: ["b"])
        var s = plaza["a"].state!
        s.bomb!.pass = PlazaGame.maxPass
        let holder = s.bomb!.holder, other = holder == "a" ? "b" : "a"
        for id in ["a", "b"] { plaza[id].learn(s, from: holder, now: at(start + 1)) }
        XCTAssertFalse(plaza[other].hit(by: holder, now: at(start + 1)), "no more passes")
        let boom = start + PlazaBomb.fuse(seed: s.seed, round: 1)
        plaza.step(at(boom))
        XCTAssertEqual(plaza[other].phase(now: at(boom)), .ended)
        XCTAssertNil(plaza[other].state?.winner)
        XCTAssertNotNil(PlazaGame.accepted(plaza[holder].state, now: at(boom)), "what the engine wrote is within its own bounds")
    }

    func testTheLongestGameEndsInsideAGamesLife() {
        let longest = PlazaGame.recruitSeconds + PlazaGame.countdownSeconds
            + Double(PlazaGame.maxPlayers - 1) * (PlazaBomb.fuseRange.upperBound + PlazaBomb.intermission)
        XCTAssertLessThan(longest, PlazaGame.maxLife)
    }

    // MARK: - Merging and hostile input

    func testMergingIsTheSameInEitherOrder() {
        var plaza = Plaza(["a", "b", "c"])
        let start = started(&plaza, joiners: ["b", "c"])
        let base = plaza["a"].state!
        var passed = base
        passed.bomb!.holder = base.players.first { $0 != base.bomb!.holder }!
        passed.bomb!.pass += 1
        var raced = passed   // two Macs took the same hit number: the smaller ID keeps the bomb
        raced.bomb!.holder = base.players.last { $0 != base.bomb!.holder && $0 != passed.bomb!.holder }!
        var out = passed
        out.bomb!.out = [passed.bomb!.holder]
        out.bomb!.pass += 1
        var ended = out
        ended.endedAt = base.startsAt! + 20
        var newer = PlazaGameState(id: "z@1", kind: "bomb", host: "c", opensAt: base.opensAt + 100)
        newer.endedAt = nil
        let all: [PlazaGameState?] = [nil, base, passed, raced, out, ended, newer]
        for x in all {
            for y in all {
                XCTAssertEqual(PlazaGame.merged(x, y), PlazaGame.merged(y, x))
                for z in all {
                    XCTAssertEqual(PlazaGame.merged(PlazaGame.merged(x, y), z), PlazaGame.merged(x, PlazaGame.merged(y, z)))
                }
            }
        }
        XCTAssertEqual(PlazaGame.merged(base, passed), passed)
        XCTAssertEqual(PlazaGame.merged(passed, raced)?.bomb?.holder, min(passed.bomb!.holder, raced.bomb!.holder))
        XCTAssertEqual(PlazaGame.merged(ended, out), ended)
        XCTAssertEqual(PlazaGame.merged(ended, newer), newer)
        _ = start
    }

    func testOutOfBoundsStatesAreDropped() {
        var plaza = Plaza(["a", "b"])
        let start = started(&plaza, joiners: ["b"])
        let good = plaza["a"].state!
        let now = at(start + 1)
        XCTAssertEqual(PlazaGame.accepted(good, now: now), good)
        func bad(_ change: (inout PlazaGameState) -> Void, _ why: String, line: UInt = #line) {
            var s = good
            change(&s)
            XCTAssertNil(PlazaGame.accepted(s, now: now), why, line: line)
        }
        bad({ $0.id = "" }, "empty id")
        bad({ $0.id = String(repeating: "x", count: 65) }, "long id")
        bad({ $0.kind = String(repeating: "k", count: 33) }, "long kind")
        bad({ $0.opensAt = .nan }, "nan")
        bad({ $0.opensAt = now.timeIntervalSince1970 + 61 }, "from the future")
        bad({ $0.startsAt = .infinity }, "infinite start")
        bad({ $0.startsAt = $0.opensAt + 500 }, "a start long after recruiting")
        bad({ $0.players = ["a"] }, "one player")
        bad({ $0.players = ["a", "a"] }, "the same player twice")
        bad({ $0.players = (0..<65).map { "p\($0)" } }, "too many players")
        bad({ $0.bomb?.holder = "stranger" }, "a holder who is not playing")
        bad({ $0.bomb?.out = ["stranger"] }, "an out member who is not playing")
        bad({ $0.bomb?.out = ["a", "b"] }, "everyone out but still running")
        bad({ $0.bomb?.pass = -1 }, "negative pass")
        bad({ $0.bomb?.round = 0 }, "round zero")
        bad({ $0.bomb?.round = 2 }, "a second round with nobody out")
        bad({ $0.bomb?.pass = PlazaGame.maxPass + 1 }, "more passes than a game has")
        bad({ $0.players = (0...PlazaGame.maxPlayers).map { "p\($0)" } }, "one player too many")
        bad({ $0.bomb?.roundStartsAt = .nan }, "nan round")
        bad({ $0.bomb?.from = "stranger" }, "handed over by a stranger")
        bad({ $0.winner = "a" }, "a winner without an end")
        bad({ $0.endedAt = now.timeIntervalSince1970; $0.winner = "stranger" }, "a stranger wins")
        bad({ $0.startsAt = nil }, "players without a start")
        XCTAssertNil(PlazaGame.accepted(good, now: at(PlazaGame.maxLife)), "outlived the limit")
        // A recruiting game stamped ahead of my clock: only the clock bound can refuse it.
        let early = PlazaGameState(id: "a@1", kind: "bomb", host: "a", opensAt: now.timeIntervalSince1970 + PlazaGame.clockSlack)
        XCTAssertNotNil(PlazaGame.accepted(early, now: now))
        var future = early
        future.opensAt += 1
        XCTAssertNil(PlazaGame.accepted(future, now: now), "opened in my future")
        var ended = good
        ended.endedAt = now.timeIntervalSince1970
        XCTAssertNotNil(PlazaGame.accepted(ended, now: now))
        XCTAssertNil(PlazaGame.accepted(ended, now: now.addingTimeInterval(PlazaGame.endedKeep)))
        // A hostile state never replaces what I know.
        var mine = plaza["a"]
        var hostile = good
        hostile.bomb?.holder = "stranger"
        hostile.bomb?.pass = 9
        XCTAssertFalse(mine.learn(hostile, now: now))
        XCTAssertEqual(mine.state, good)
    }

    func testAGameOfAKindThisVersionDoesNotKnowIsPassedOnButNotJoined() {
        var e = PlazaGameEngine(me: "b")
        let s = PlazaGameState(id: "a@1", kind: "racing", host: "a", opensAt: t0.timeIntervalSince1970)
        XCTAssertTrue(e.learn(s, now: at(1)))
        e.answer(join: true, now: at(2))
        XCTAssertNil(e.joined)
        XCTAssertFalse(e.open(.bomb, now: at(3)), "it still holds the plaza's one game slot")
        XCTAssertEqual(e.state, s)
    }

    func testTheGameStateSurvivesTheWire() throws {
        var plaza = Plaza(["a", "b"])
        _ = started(&plaza, joiners: ["b"])
        let s = plaza["a"].state!
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(PlazaGameState.self, from: data), s)
    }
}

// MARK: - The ring under a player

extension PlazaGameTests {
    /// The ring is hollow (the shadow and the feet show through), coloured by the mark, with a dark line outside.
    func testTheRingIsAHollowEllipseInTheMarksColour() async {
        let size = PlazaGameMarkArt.size(forShadow: CGSize(width: 34, height: 11))
        XCTAssertEqual(size.width, 46)
        XCTAssertEqual(size.height, 19)
        let alive = PlazaGameMarkArt.image(width: size.width, height: size.height, mark: .alive).pixels
        let out = PlazaGameMarkArt.image(width: size.width, height: size.height, mark: .out).pixels
        XCTAssertEqual(alive[size.width / 2, size.height / 2].a, 0, "nothing in the middle")
        XCTAssertEqual(alive[0, 0].a, 0, "nothing in the corners")
        XCTAssertEqual(alive[0, size.height / 2], PlazaRGBA(r: 0x14, g: 0x16, b: 0x1F, a: 255), "the dark line outside")
        XCTAssertEqual(alive[2, size.height / 2], PlazaRGBA(r: 0xF2, g: 0xC1, b: 0x4E, a: 255), "the band")
        XCTAssertEqual(out[2, size.height / 2], PlazaRGBA(r: 0x8C, g: 0x8F, b: 0x99, a: 255))
        XCTAssertEqual(alive[PlazaGameMarkArt.line + PlazaGameMarkArt.band + 1, size.height / 2].a, 0, "hollow right inside the band")
    }

    /// A member's mark: the holder first, then still in, then out; nobody else has one.
    func testAMembersMark() async {
        var view = PlazaGameView()
        view.alive = ["a", "b"]
        view.out = ["c"]
        view.holder = "a"
        XCTAssertEqual(["a", "b", "c", "d"].map(view.mark), [.holder, .alive, .out, nil])
    }
    // MARK: - The holder's pace and reach

    /// Whoever holds the bomb is half again as fast on every step, in the pond and the hot spring too. The plunge into
    /// water is a jump of a fixed length and stays as it is.
    func testEveryStepOfTheHolderIsHalfAgainAsFastButThePlunge() throws {
        let map = PlazaMapData.map
        func tiles(_ ok: (TilePoint) -> Bool) -> [TilePoint] {
            (0..<map.height).flatMap { y in (0..<map.width).map { TilePoint(x: $0, y: y) } }.filter(ok)
        }
        func pair(_ a: (TilePoint) -> Bool, _ b: (TilePoint) -> Bool) throws -> (TilePoint, TilePoint) {
            for from in tiles(a) {
                let to = TilePoint(x: from.x + 1, y: from.y)
                if b(to) { return (from, to) }
            }
            throw XCTSkip("the map has no such pair of tiles")
        }
        let land = try pair(map.isWalkable, map.isWalkable)
        let pond = try pair({ map.isWater($0) && !map.isHotSpring($0) }, { map.isWater($0) && !map.isHotSpring($0) })
        let spring = try pair(map.isHotSpring, map.isHotSpring)
        let ashore = try pair(map.isWater, map.isWalkable)
        let plunge = try pair(map.isWalkable, map.isWater)
        func holder(_ p: (TilePoint, TilePoint), running: Bool = false) -> TimeInterval {
            PlazaBomb.stepDuration(from: p.0, to: p.1, running: running, isWater: map.isWater)
        }
        XCTAssertEqual(PlazaBomb.holderSpeedUp, 1.5)
        XCTAssertEqual(holder(land, running: true), PlazaWalker.runStepDuration / 1.5, accuracy: 1e-12)
        XCTAssertEqual(holder(land, running: true), PlazaBomb.holderRunStepDuration)
        XCTAssertEqual(holder(land), PlazaWalker.stepDuration / 1.5, accuracy: 1e-12)
        XCTAssertEqual(holder(pond), PlazaPond.swimStepDuration / 1.5, accuracy: 1e-12)
        XCTAssertEqual(holder(spring), PlazaPond.swimStepDuration / 1.5, accuracy: 1e-12, "the hot spring is water too")
        XCTAssertEqual(holder(pond, running: true), PlazaPond.swimStepDuration / 1.5, accuracy: 1e-12)
        XCTAssertEqual(holder(ashore), PlazaWalker.stepDuration / 1.5, accuracy: 1e-12)
        XCTAssertEqual(holder(plunge), PlazaPond.plungeStepDuration)
    }

    /// The bomb reaches two tiles past touching (one for each screen's lag), straight or around a corner.
    func testTheBombReachesTwoTilesPastTouching() {
        let me = PlazaBody(foot: TilePoint(x: 10, y: 6), size: 1)
        func holder(_ dx: Int, _ dy: Int) -> PlazaBody { PlazaBody(foot: TilePoint(x: 10 + dx, y: 6 + dy), size: 1) }
        XCTAssertEqual(holder(1, 0).gap(to: me), 1)
        XCTAssertEqual(holder(-3, 0).gap(to: me), 3)
        XCTAssertEqual(holder(2, 2).gap(to: me), 4)
        XCTAssertEqual(holder(0, 0).gap(to: me), 0)
        for (dx, dy, reaches) in [(1, 0, true), (0, -2, true), (3, 0, true), (2, 1, true), (4, 0, false), (2, 2, false), (0, 4, false)] {
            XCTAssertEqual(PlazaBomb.reaches(holder(dx, dy), me), reaches, "(\(dx), \(dy))")
            XCTAssertEqual(PlazaBomb.reaches(me, holder(dx, dy)), reaches, "the same from the other side")
        }
        XCTAssertTrue(holder(1, 0).touches(me))
        XCTAssertFalse(holder(1, 1).touches(me), "touching is unchanged: no diagonals")
    }

    // MARK: - Drawing quiz payload

    private func drawState(turn: Int, step: Int, word: String? = nil) -> PlazaGameState {
        var s = PlazaGameState(id: "a@1", kind: "draw", host: "a", opensAt: 1_800_000_000)
        s.startsAt = 1_800_000_030
        s.players = ["a", "b"]
        var d = PlazaDrawState(order: ["a", "b", "a", "b"], turn: turn, step: step, scores: [:])
        if turn > 0 { d.last = .init(turn: turn - 1, drawer: "a", word: word, solver: nil) }
        s.draw = d
        return s
    }

    func testADrawStateWithMoreProgressWins() {
        let low = drawState(turn: 1, step: 5), high = drawState(turn: 2, step: 1)
        XCTAssertEqual(PlazaGame.merged(low, high), high)
        XCTAssertEqual(PlazaGame.merged(high, low), high)
        let early = drawState(turn: 1, step: 2), later = drawState(turn: 1, step: 3)
        XCTAssertEqual(PlazaGame.merged(early, later), later)
        XCTAssertEqual(PlazaGame.merged(later, early), later)
        let hidden = drawState(turn: 1, step: 3), shown = drawState(turn: 1, step: 3, word: "사과")
        XCTAssertEqual(PlazaGame.merged(hidden, shown), shown)
        XCTAssertEqual(PlazaGame.merged(shown, hidden), shown)
    }

    func testACopyWithoutTheDrawPayloadLoses() {
        let full = drawState(turn: 0, step: 0)
        var stripped = full
        stripped.draw = nil
        XCTAssertEqual(PlazaGame.merged(full, stripped), full)
        XCTAssertEqual(PlazaGame.merged(stripped, full), full)
    }

    func testARecruitingGameCarriesNoDrawPayload() {
        var s = drawState(turn: 0, step: 0)
        s.startsAt = nil
        s.players = []
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        XCTAssertNil(PlazaGame.accepted(s, now: now))
        s.draw = nil
        XCTAssertNotNil(PlazaGame.accepted(s, now: now))
    }

    func testAGameOfAnotherKindCarriesNoDrawPayload() {
        var s = drawState(turn: 0, step: 0)
        s.kind = PlazaGameKind.bomb.rawValue
        let now = Date(timeIntervalSince1970: 1_800_000_031)
        XCTAssertNil(PlazaGame.accepted(s, now: now), "a bomb game with a draw payload")
        s.draw = nil
        s.bomb = PlazaBombState(round: 1, roundStartsAt: 1_800_000_030, holder: "a")
        XCTAssertNotNil(PlazaGame.accepted(s, now: now))
    }

    // MARK: - Berry five payload

    private func berryState(players: Int = 3, _ edit: (inout PlazaBerryState) -> Void = { _ in }) -> PlazaGameState {
        var s = PlazaGameState(id: "a@1", kind: "berry", host: "p0", opensAt: 1_800_000_000)
        s.startsAt = 1_800_000_030
        s.players = (0..<players).map { "p\($0)" }
        var b = PlazaBerryState(seats: players)
        edit(&b)
        s.berry = b
        return s
    }

    func testABerryStateWithMoreProgressWins() {
        let flips = berryState { $0.flips = [0, 1, 2, 0, 1]; $0.step = 9 }
        let cleared = berryState { $0.flips = [0, 1, 2]; $0.clears = [3]; $0.step = 2 }
        XCTAssertEqual(PlazaGame.merged(flips, cleared), cleared, "more clears beats more flips")
        XCTAssertEqual(PlazaGame.merged(cleared, flips), cleared)
        let fewer = berryState { $0.flips = [0, 1]; $0.step = 9 }
        let more = berryState { $0.flips = [0, 1, 2]; $0.step = 3 }
        XCTAssertEqual(PlazaGame.merged(fewer, more), more, "more flips beats more steps")
        XCTAssertEqual(PlazaGame.merged(more, fewer), more)
        let slow = berryState { $0.flips = [0]; $0.step = 1 }
        let fast = berryState { $0.flips = [0]; $0.step = 2 }
        XCTAssertEqual(PlazaGame.merged(slow, fast), fast, "more steps wins")
        XCTAssertEqual(PlazaGame.merged(fast, slow), fast)
    }

    func testTwoDealersWithTheSameStepAgreeEverywhere() {
        let a = berryState { $0.flips = [0, 1]; $0.step = 4; $0.scores = [1, 0, 0] }
        let b = berryState { $0.flips = [0, 1]; $0.step = 4; $0.scores = [0, 1, 0] }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(PlazaGame.merged(a, b), PlazaGame.merged(b, a))
        XCTAssertNotEqual(PlazaGame.precedes(a, b), PlazaGame.precedes(b, a), "a strict order, never a tie both ways")
    }

    func testACopyWithoutTheBerryPayloadLoses() {
        let full = berryState()
        var stripped = full
        stripped.berry = nil
        XCTAssertEqual(PlazaGame.merged(stripped, full), full)
        XCTAssertEqual(PlazaGame.merged(full, stripped), full)
    }

    func testARecruitingGameCarriesNoBerryPayload() {
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        var s = PlazaGameState(id: "a@1", kind: "berry", host: "p0", opensAt: 1_800_000_000)
        XCTAssertNotNil(PlazaGame.accepted(s, now: now))
        s.berry = PlazaBerryState(seats: 2)
        XCTAssertNil(PlazaGame.accepted(s, now: now))
    }

    func testABerryPayloadOnAnotherKindIsRefused() {
        let now = Date(timeIntervalSince1970: 1_800_000_031)
        var s = berryState(players: 2)
        XCTAssertNotNil(PlazaGame.accepted(s, now: now))
        s.kind = PlazaGameKind.bomb.rawValue
        XCTAssertNil(PlazaGame.accepted(s, now: now))
        s.kind = PlazaGameKind.draw.rawValue
        XCTAssertNil(PlazaGame.accepted(s, now: now))
    }

    func testBerryFiveIsCappedAtEightPlayers() {
        let now = Date(timeIntervalSince1970: 1_800_000_031)
        var nine = berryState(players: 9) { _ in }
        nine.berry = nil
        XCTAssertNil(PlazaGame.accepted(nine, now: now), "9 refused for berry")
        var eight = nine
        eight.players.removeLast()
        XCTAssertNotNil(PlazaGame.accepted(eight, now: now))
        var bomb = nine
        bomb.kind = PlazaGameKind.bomb.rawValue
        bomb.players = (0..<20).map { "p\($0)" }
        XCTAssertNotNil(PlazaGame.accepted(bomb, now: now), "the bomb game still takes 20")
        XCTAssertEqual(PlazaGameKind.berry.maxPlayers, 8)
        XCTAssertEqual(PlazaGameKind.draw.maxPlayers, 8)
        XCTAssertEqual(PlazaGameKind.bomb.maxPlayers, 20)
    }

    func testTheMenuOffersEveryGame() {
        XCTAssertEqual(PlazaGameMenu().kinds, PlazaGameKind.allCases)
        XCTAssertEqual(PlazaGameMenu().kinds, [.bomb, .draw, .berry])
    }

    /// A joiner the lock left out (9th of a quiz, 21st of a bomb game) is not in the game and keeps no flag for it.
    func testAJoinerTheLockLeftOutKeepsNoJoinedFlag() {
        for (kind, ids) in [(PlazaGameKind.draw, (0..<9).map { "p\($0)" }), (.bomb, (0..<21).map { String(format: "p%02d", $0) })] {
            var plaza = Plaza(ids)
            XCTAssertTrue(plaza[ids[0]].open(kind, now: at(0)))
            plaza.step(at(1))
            for id in ids.dropFirst() { plaza[id].answer(join: true, now: at(2)) }
            XCTAssertEqual(plaza[ids.last!].joined, plaza[ids[0]].state?.id)
            plaza.step(at(PlazaGame.recruitSeconds))
            let players = plaza[ids[0]].state?.players ?? []
            XCTAssertEqual(players.count, kind.maxPlayers)
            XCTAssertFalse(players.contains(ids.last!))
            XCTAssertNil(plaza[ids.last!].joined, "\(kind): the cut joiner drops its flag")
            for id in players { XCTAssertNotNil(plaza[id].joined, "\(kind): a listed player keeps it") }
        }
    }
}
