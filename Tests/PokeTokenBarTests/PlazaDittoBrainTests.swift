import XCTest
@testable import PokeTokenBar

final class PlazaDittoBrainTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let map = PlazaMapData.map
    private let dt = 0.05

    /// A ground tile with plenty of open ground around it and its east neighbour also ground.
    private func openTile() -> TilePoint {
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                guard PlazaDitto.isGround(p, in: map), PlazaDitto.isGround(TilePoint(x: x + 1, y: y), in: map) else { continue }
                var n = 0
                for dy in -8...8 { for dx in -8...8 where PlazaDitto.isGround(TilePoint(x: x + dx, y: y + dy), in: map) { n += 1 } }
                if n >= 150 { return p }
            }
        }
        XCTFail("no open ground"); return map.spawn
    }

    private func world(blocked: Set<TilePoint> = [], copyable: [String: TilePoint] = [:],
                       present: [String: TilePoint]? = nil) -> PlazaDittoWorld {
        PlazaDittoWorld(map: map, blocked: blocked, copyable: copyable, present: present ?? copyable)
    }

    private func dittoState(at p: TilePoint, rest: Date? = nil) -> PlazaDittoState {
        PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: nil, since: t0, restUntil: rest)
    }

    private func manhattan(_ a: TilePoint, _ b: TilePoint) -> Int { abs(a.x - b.x) + abs(a.y - b.y) }

    func testItStartsOnFreeGroundAndNeverStepsOffIt() {
        let start = openTile()
        let blocked: Set<TilePoint> = [TilePoint(x: start.x - 1, y: start.y), TilePoint(x: start.x, y: start.y - 1),
                                       TilePoint(x: start.x, y: start.y + 1)]
        let w = world(blocked: blocked)
        var brain = PlazaDittoBrain(resuming: dittoState(at: start), world: w, now: t0, seed: 7)
        var now = t0
        var moved = Set<TilePoint>()
        while now.timeIntervalSince(t0) < 600 {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: w)
            let tile = brain.state.tile
            moved.insert(tile)
            XCTAssertTrue(PlazaDitto.isGround(tile, in: map), "\(tile)")
            XCTAssertFalse(blocked.contains(tile), "\(tile)")
        }
        XCTAssertGreaterThan(moved.count, 3, "it should wander")
        // A fresh start picks free ground too.
        let fresh = PlazaDittoBrain(resuming: nil, world: world(blocked: [start]), now: t0, seed: 3)
        XCTAssertTrue(PlazaDitto.isGround(fresh.state.tile, in: map))
        XCTAssertNotEqual(fresh.state.tile, start)
        XCTAssertFalse(fresh.state.isDecoy)
        XCTAssertNil(fresh.state.restUntil)
        XCTAssertEqual(fresh.state.since, t0)
    }

    func testItResumesAGivenState() {
        let p = openTile()
        let since = t0.addingTimeInterval(-100)
        let s = PlazaDittoState(tile: p, facing: .left, isWalking: nil, isRunning: nil, decoyOf: "m", since: since, restUntil: nil)
        let brain = PlazaDittoBrain(resuming: s, world: world(copyable: ["m": TilePoint(x: p.x, y: p.y + 20)]), now: t0, seed: 1)
        XCTAssertEqual(brain.state.tile, p)
        XCTAssertEqual(brain.state.decoyOf, "m")
        XCTAssertEqual(brain.state.since, since)
        // A resumed state on a blocked tile is not trusted.
        let b2 = PlazaDittoBrain(resuming: s, world: world(blocked: [p]), now: t0, seed: 1)
        XCTAssertNotEqual(b2.state.tile, p)
        XCTAssertFalse(b2.state.isDecoy)
    }

    func testItCopiesANeighbourOnlyAfterResting() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let rest = t0.addingTimeInterval(180)
        let w = world(blocked: [m], copyable: ["m": m])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p, rest: rest), world: w, now: t0, seed: 5)
        var now = t0
        var transformedAt: Date?
        while now.timeIntervalSince(t0) < 185 {
            now = now.addingTimeInterval(dt)
            // The Ditto may walk away while resting, so keep "m" next to it.
            let here = brain.state.tile
            let next = TilePoint(x: here.x + 1, y: here.y)
            let wm = world(blocked: [next], copyable: ["m": next])
            if brain.tick(now: now, world: wm).contains(.transformed("m")), transformedAt == nil { transformedAt = now }
            if transformedAt != nil { break }
        }
        let at = try? XCTUnwrap(transformedAt)
        XCTAssertNotNil(at)
        if let at {
            XCTAssertGreaterThanOrEqual(at, rest)
            XCTAssertLessThanOrEqual(at.timeIntervalSince(rest), dt + 0.001)
        }
        XCTAssertEqual(brain.state.decoyOf, "m")
        XCTAssertNil(brain.state.restUntil)
    }

    func testItDoesNotCopyFromAcrossTheField() {
        let p = openTile()
        let far = TilePoint(x: p.x + 5, y: p.y)
        let w = world(copyable: ["m": far])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 9)
        var now = t0
        var events: [PlazaDittoBrainEvent] = []
        // The Ditto waits at least 2 s before its first walk, so nothing can bring it next to "m" within 1 s.
        while now.timeIntervalSince(t0) < 1 {
            now = now.addingTimeInterval(dt)
            events += brain.tick(now: now, world: w)
        }
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(brain.state.isDecoy)
    }

    func testTheCopyGetsAtLeastEightTilesAway() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let w = world(blocked: [m], copyable: ["m": m])
        // Start the Ditto beside "m" with no rest: it copies on the first tick.
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 11)
        var now = t0.addingTimeInterval(dt)
        XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
        let copiedAt = now
        while now.timeIntervalSince(copiedAt) < 15 {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: w)
        }
        XCTAssertGreaterThanOrEqual(manhattan(brain.state.tile, m), PlazaDitto.fleeDistance)
        XCTAssertTrue(PlazaDitto.isGround(brain.state.tile, in: map))
    }

    func testTheCopyMostlyStands() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let w = world(blocked: [m], copyable: ["m": m])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 21)
        var now = t0.addingTimeInterval(dt)
        XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
        // Let the flee finish, then measure.
        let fleeEnd = now.addingTimeInterval(30)
        while now < fleeEnd { now = now.addingTimeInterval(dt); _ = brain.tick(now: now, world: w) }
        // Keep "m" far away and put it in the world so the copy stays valid; its real tile is irrelevant after the flee.
        var walking = 0.0
        let end = fleeEnd.addingTimeInterval(600)
        while now < end {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: w)
            if brain.state.isDecoy, brain.state.isWalking == true { walking += dt }
            if !brain.state.isDecoy { break } // 900 s limit reached; the window above stays under it
        }
        XCTAssertLessThan(walking / 600, 0.30)
        XCTAssertTrue(brain.state.isDecoy)
    }

    func testTheCopyIdlesAfterTheFlee() {
        var jumps = 0, turns = 0
        for seed in UInt64(21)...24 {
            let p = openTile()
            let m = TilePoint(x: p.x + 1, y: p.y)
            let w = world(blocked: [m], copyable: ["m": m])
            var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: seed)
            var now = t0.addingTimeInterval(dt)
            XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
            // Flee phase: from the copy until its first stop. It must walk, never run.
            var walked = false
            while now.timeIntervalSince(t0) < 60 {
                now = now.addingTimeInterval(dt)
                _ = brain.tick(now: now, world: w)
                if brain.state.isWalking == true { walked = true; XCTAssertNotEqual(brain.state.isRunning, true, "flee ran") }
                else if walked { break }
            }
            XCTAssertGreaterThanOrEqual(manhattan(brain.state.tile, m), PlazaDitto.fleeDistance)
            // Idle phase.
            var walking = 0.0, steps = 0
            var last = brain.state
            let end = now.addingTimeInterval(600)
            while now < end {
                now = now.addingTimeInterval(dt)
                jumps += brain.tick(now: now, world: w).filter { $0 == .jumped }.count
                let s = brain.state
                XCTAssertTrue(s.isDecoy)
                if s.isWalking == true { walking += dt }
                if s.tile != last.tile { steps += 1 }
                else if s.facing != last.facing, s.isWalking != true { turns += 1 }
                if s.isWalking != true, steps > 0 {
                    XCTAssertTrue((1...3).contains(steps), "idle walk of \(steps) tiles")
                    steps = 0
                }
                last = s
            }
            XCTAssertLessThan(walking / 600, 0.30)
        }
        XCTAssertGreaterThan(jumps, 0, "a copy should sometimes jump")
        XCTAssertGreaterThan(turns, 0, "a copy should sometimes turn")
    }

    func testTheCopyTurnsBackAfterFifteenMinutes() {
        let p = openTile()
        let since = t0
        let s = PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: "m", since: since, restUntil: nil)
        let w = world(copyable: ["m": TilePoint(x: p.x, y: p.y + 30)])
        var brain = PlazaDittoBrain(resuming: s, world: w, now: t0, seed: 2)
        XCTAssertTrue(brain.tick(now: t0.addingTimeInterval(899), world: w).isEmpty)
        XCTAssertTrue(brain.state.isDecoy)
        let at = t0.addingTimeInterval(900)
        XCTAssertEqual(brain.tick(now: at, world: w), [.turnedBack])
        XCTAssertNil(brain.state.decoyOf)
        XCTAssertEqual(brain.state.restUntil, at.addingTimeInterval(180))
        XCTAssertTrue(brain.tick(now: at.addingTimeInterval(1), world: w).isEmpty)
    }

    func testTheCopyTurnsBackWhenTheRealOneLeaves() {
        let p = openTile()
        let s = PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: "m", since: t0, restUntil: nil)
        let far = TilePoint(x: p.x, y: p.y + 30)
        var brain = PlazaDittoBrain(resuming: s, world: world(copyable: ["m": far]), now: t0, seed: 2)
        XCTAssertTrue(brain.tick(now: t0.addingTimeInterval(1), world: world(copyable: ["m": far])).isEmpty)
        let ev = brain.tick(now: t0.addingTimeInterval(2), world: world(copyable: [:], present: ["m": far]))
        XCTAssertEqual(ev, [.turnedBack])
        XCTAssertFalse(brain.state.isDecoy)
    }

    func testFoundTurnsBackAndRests() {
        let p = openTile()
        let s = PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: "m", since: t0, restUntil: nil)
        var brain = PlazaDittoBrain(resuming: s, world: world(copyable: ["m": TilePoint(x: p.x, y: p.y + 30)]), now: t0, seed: 4)
        let at = t0.addingTimeInterval(30)
        brain.found(now: at)
        XCTAssertFalse(brain.state.isDecoy)
        XCTAssertEqual(brain.state.tile, p)
        XCTAssertEqual(brain.state.restUntil, at.addingTimeInterval(180))

        var plain = PlazaDittoBrain(resuming: dittoState(at: p), world: world(), now: t0, seed: 4)
        let before = plain.state
        plain.found(now: at)
        XCTAssertEqual(plain.state, before)
    }

    func testATackleCopiesTheTacklerEvenWhileResting() {
        let p = openTile()
        let me = TilePoint(x: p.x + 1, y: p.y)
        let rest = t0.addingTimeInterval(180)
        // "a" is beside it too and would win an ordinary copy (smallest ID); the tackler wins a tackle.
        let a = TilePoint(x: p.x, y: p.y + 1)
        let w = world(blocked: [me, a], copyable: ["a": a, "me": me])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p, rest: rest), world: w, now: t0, seed: 5)
        let at = t0.addingTimeInterval(10)
        XCTAssertTrue(brain.tackled(by: "me", now: at, world: w))
        XCTAssertEqual(brain.state.decoyOf, "me")
        XCTAssertEqual(brain.state.since, at)
        XCTAssertNil(brain.state.restUntil)
        // Then it flees from the tackler like any copy.
        var now = at
        while now.timeIntervalSince(at) < 10 {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: w)
        }
        XCTAssertGreaterThanOrEqual(manhattan(brain.state.tile, me), PlazaDitto.fleeDistance)
        XCTAssertEqual(brain.state.decoyOf, "me")
    }

    func testATackleByAnyoneWhoCannotBeCopiedOrOnACopyDoesNothing() {
        let p = openTile()
        let me = TilePoint(x: p.x + 1, y: p.y)
        let rest = t0.addingTimeInterval(180)
        // An egg, someone idle or focusing, or an older version: present but not copyable.
        let w = world(blocked: [me], copyable: [:], present: ["me": me])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p, rest: rest), world: w, now: t0, seed: 5)
        let before = brain.state
        XCTAssertFalse(brain.tackled(by: "me", now: t0.addingTimeInterval(1), world: w))
        XCTAssertEqual(brain.state, before)

        let copy = PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: "m", since: t0, restUntil: nil)
        let wc = world(blocked: [me], copyable: ["me": me, "m": TilePoint(x: p.x, y: p.y + 30)])
        var copying = PlazaDittoBrain(resuming: copy, world: wc, now: t0, seed: 5)
        XCTAssertFalse(copying.tackled(by: "me", now: t0.addingTimeInterval(1), world: wc))
        XCTAssertEqual(copying.state, copy)
    }

    func testItWaitsWhenSomeoneStepsIntoItsPath() {
        let p = openTile()
        let w = world()
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 13)
        var now = t0
        // Run until it is mid-walk.
        var guardCount = 0
        while brain.state.isWalking != true && guardCount < 4000 {
            now = now.addingTimeInterval(dt); _ = brain.tick(now: now, world: w); guardCount += 1
        }
        XCTAssertEqual(brain.state.isWalking, true)
        // Block every neighbour of its current tile except where it came from is unknowable; block all four.
        let here = brain.state.tile
        let ring: Set<TilePoint> = [TilePoint(x: here.x + 1, y: here.y), TilePoint(x: here.x - 1, y: here.y),
                                    TilePoint(x: here.x, y: here.y + 1), TilePoint(x: here.x, y: here.y - 1)]
        let walled = world(blocked: ring)
        for _ in 0..<200 {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: walled)
            XCTAssertFalse(ring.contains(brain.state.tile), "stepped into a blocked tile")
            XCTAssertEqual(brain.state.tile, here)
        }
    }

    /// The pace of a route must not depend on how often the brain is ticked: each step starts where the last one ended.
    func testAStepStartsWhereThePreviousOneEndedAtCoarseTicks() {
        let p = openTile()
        let w = world()
        let coarse = 0.1, d = PlazaWalker.stepDuration
        // Find a seed whose first walk is at least three steps long, at a fine tick.
        for seed in 1...200 as ClosedRange<UInt64> {
            var fine = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: seed)
            var now = t0
            var changes = 0, last = fine.state.tile
            while now.timeIntervalSince(t0) < 30, changes < 3 {
                now = now.addingTimeInterval(0.01)
                _ = fine.tick(now: now, world: w)
                if fine.state.tile != last { changes += 1; last = fine.state.tile }
                else if changes > 0, !fine.isMoving { break }
            }
            guard changes >= 3 else { continue }
            var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: seed)
            now = t0
            var times: [TimeInterval] = []
            var tile = brain.state.tile
            while now.timeIntervalSince(t0) < 30, times.count < 3 {
                now = now.addingTimeInterval(coarse)
                _ = brain.tick(now: now, world: w)
                if brain.state.tile != tile { times.append(now.timeIntervalSince(t0)); tile = brain.state.tile }
            }
            XCTAssertEqual(times.count, 3)
            // Step 3 begins when step 2 ends: two step durations after step 1, to within one coarse tick.
            XCTAssertLessThanOrEqual(times[2] - times[0], 2 * d + 0.0501, "\(times)")
            return
        }
        XCTFail("no seed walks three steps")
    }

    func testItAsksForATickAtOnceOnlyWhileMoving() {
        let p = openTile()
        let w = world()
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 5)
        XCTAssertFalse(brain.isMoving)
        XCTAssertGreaterThan(brain.nextWake(now: t0), t0, "it stands for a while first")
        var now = t0
        while !brain.isMoving, now.timeIntervalSince(t0) < 60 { now = now.addingTimeInterval(0.05); _ = brain.tick(now: now, world: w) }
        XCTAssertTrue(brain.isMoving)
        while brain.isMoving, now.timeIntervalSince(t0) < 120 { now = now.addingTimeInterval(0.05); _ = brain.tick(now: now, world: w) }
        XCTAssertFalse(brain.isMoving)
        XCTAssertGreaterThanOrEqual(brain.nextWake(now: now), now)
    }
    // MARK: - Coverage gaps (nextWake, flee without a route, boxed-in wander)

    private func decoyState(at p: TilePoint, since: Date) -> PlazaDittoState {
        PlazaDittoState(tile: p, facing: .down, isWalking: nil, isRunning: nil, decoyOf: "m", since: since, restUntil: nil)
    }

    /// A wall of every tile at Manhattan distance `radius + 1` from `p`: four-way movement cannot cross it.
    private func wall(around p: TilePoint, radius: Int) -> Set<TilePoint> {
        var out = Set<TilePoint>()
        let r = radius + 1
        for dx in -r...r {
            let dy = r - abs(dx)
            out.insert(TilePoint(x: p.x + dx, y: p.y + dy))
            out.insert(TilePoint(x: p.x + dx, y: p.y - dy))
        }
        return out
    }

    func testNextWakeIsTheCopysTimeLimitWhenThatComesBeforeItsWait() {
        let p = openTile()
        // 5 s of the copy's 900 s left; its wait is at least 6 s.
        let brain = PlazaDittoBrain(resuming: decoyState(at: p, since: t0.addingTimeInterval(-895)),
                                    world: world(copyable: ["m": TilePoint(x: p.x, y: p.y + 30)]), now: t0, seed: 3)
        XCTAssertEqual(brain.nextWake(now: t0), t0.addingTimeInterval(5))
    }

    func testNextWakeIsTheEndOfARestWhenThatComesBeforeItsWait() {
        let p = openTile()
        // Rest ends in 1 s; a Ditto waits at least 2 s.
        let brain = PlazaDittoBrain(resuming: dittoState(at: p, rest: t0.addingTimeInterval(1)), world: world(), now: t0, seed: 3)
        XCTAssertEqual(brain.nextWake(now: t0), t0.addingTimeInterval(1))
        // Once the rest is over it no longer pulls the wake in.
        XCTAssertGreaterThanOrEqual(brain.nextWake(now: t0.addingTimeInterval(1.5)), t0.addingTimeInterval(2))
    }

    /// The real one is already 8+ tiles away when the flee is planned: the copy has nowhere to flee from, so it idles.
    func testACopyWhoseRealOneIsAlreadyFarDoesNotFlee() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let far = TilePoint(x: p.x, y: p.y + 30)
        let w = world(blocked: [m], copyable: ["m": m], present: ["m": far])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 11)
        var now = t0.addingTimeInterval(dt)
        XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
        XCTAssertFalse(brain.isMoving)
        XCTAssertNotEqual(brain.state.isWalking, true)
        XCTAssertEqual(brain.state.tile, p)
        // It waits a copy's 6...20 s, then idles as a copy (still the copy, never a Ditto).
        XCTAssertGreaterThanOrEqual(brain.nextWake(now: now), now.addingTimeInterval(6 - 0.001))
        let end = now.addingTimeInterval(5)
        while now < end { now = now.addingTimeInterval(dt); _ = brain.tick(now: now, world: w); XCTAssertEqual(brain.state.tile, p) }
        XCTAssertTrue(brain.state.isDecoy)
    }

    /// No tile to flee to (boxed in): the copy stays, waits like a copy, and keeps being the copy.
    func testABoxedInCopyHasNowhereToFleeAndWaits() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let ring: Set<TilePoint> = [m, TilePoint(x: p.x - 1, y: p.y), TilePoint(x: p.x, y: p.y - 1), TilePoint(x: p.x, y: p.y + 1)]
        let w = world(blocked: ring, copyable: ["m": m])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 11)
        var now = t0.addingTimeInterval(dt)
        XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
        XCTAssertFalse(brain.isMoving)
        XCTAssertEqual(brain.state.tile, p)
        XCTAssertGreaterThanOrEqual(brain.nextWake(now: now), now.addingTimeInterval(6 - 0.001))
        let end = now.addingTimeInterval(60)
        while now < end { now = now.addingTimeInterval(dt); _ = brain.tick(now: now, world: w); XCTAssertEqual(brain.state.tile, p) }
        XCTAssertTrue(brain.state.isDecoy)
    }

    /// Walled into a pocket one tile wide, a wanted distance of 2...4 has no tile at exactly that distance; it still takes a
    /// shorter walk instead of standing forever.
    func testAWalledInDittoStillWalksTheShorterRoutes() {
        let p = openTile()
        let pocket = wall(around: p, radius: 1)
        let w = world(blocked: pocket)
        for seed in 1...30 as ClosedRange<UInt64> {
            var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: seed)
            var now = t0
            var moved = false
            while now.timeIntervalSince(t0) < 7 {
                now = now.addingTimeInterval(dt)
                _ = brain.tick(now: now, world: w)
                XCTAssertLessThanOrEqual(manhattan(brain.state.tile, p), 1, "seed \(seed) left the pocket")
                if brain.state.tile != p { moved = true }
            }
            XCTAssertTrue(moved, "seed \(seed) never walked")
        }
    }

    /// Walled into a small pocket, no tile is 8 away from the real one: the copy still walks as far from it as the pocket allows.
    func testACopyInAPocketFleesAsFarAsThePocketAllows() {
        let p = openTile()
        let m = TilePoint(x: p.x + 1, y: p.y)
        let pocket = wall(around: p, radius: 2).union([m])
        let w = world(blocked: pocket, copyable: ["m": m])
        var brain = PlazaDittoBrain(resuming: dittoState(at: p), world: w, now: t0, seed: 11)
        var now = t0.addingTimeInterval(dt)
        XCTAssertTrue(brain.tick(now: now, world: w).contains(.transformed("m")))
        var walked = false
        while now.timeIntervalSince(t0) < 5 {
            now = now.addingTimeInterval(dt)
            _ = brain.tick(now: now, world: w)
            if brain.state.isWalking == true { walked = true } else if walked { break }
        }
        XCTAssertTrue(walked)
        XCTAssertGreaterThan(manhattan(brain.state.tile, m), 1, "it moved away from the real one")
        XCTAssertLessThanOrEqual(manhattan(brain.state.tile, p), 2, "and stayed in the pocket")
    }
}
