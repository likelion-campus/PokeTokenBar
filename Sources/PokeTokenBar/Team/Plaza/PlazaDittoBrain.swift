import Foundation

/// What the Ditto's brain needs to know about the plaza each tick.
struct PlazaDittoWorld {
    var map: PlazaMap
    /// Every character's tile except the Ditto's own.
    var blocked: Set<TilePoint>
    /// Members (me included) that `canBeCopied`, with their tiles.
    var copyable: [String: TilePoint]
    /// Every member in the plaza with a tile, to find the real one while copying.
    var present: [String: TilePoint]
}

enum PlazaDittoBrainEvent: Equatable { case transformed(String), turnedBack, jumped }

/// The host's Ditto: wanders as a Ditto, copies a teammate standing next to it, flees, idles as the copy,
/// and turns back after the time limit or when the real one leaves. Pure logic: no SpriteKit, no network.
struct PlazaDittoBrain {
    private(set) var state: PlazaDittoState

    private var rng: PlazaSplitMix64
    private var route: [TilePoint] = []
    private var routeRuns = false
    private var fleeing = false
    private var waitUntil: Date
    private var stepEnd: Date?

    // Timings and odds.
    private static let dittoWait: ClosedRange<Double> = 2...6
    private static let copyWait: ClosedRange<Double> = 6...20
    private static let dittoWalkMax = 4
    private static let copyWalkMax = 3
    /// Copy idling, per action: jump, walk (1 in 10 of those run), otherwise stay and maybe turn.
    private static let jumpChance = 0.05
    private static let walkChance = 0.35
    private static let runShare = 0.10
    private static let turnChance = 0.5

    /// Carry on from `resuming` when it is given and its tile is ground and not blocked; otherwise start in Ditto form on a
    /// random free ground tile, `since = now`, no rest.
    init(resuming: PlazaDittoState?, world: PlazaDittoWorld, now: Date, seed: UInt64) {
        var rng = PlazaSplitMix64(seed: seed)
        var start: PlazaDittoState
        if var s = resuming, PlazaDitto.isGround(s.tile, in: world.map), !world.blocked.contains(s.tile) {
            s.isWalking = nil
            s.isRunning = nil
            start = s
        } else {
            let tile = Self.randomFreeTile(world: world, rng: &rng)
            start = PlazaDittoState(tile: tile, facing: .down, isWalking: nil, isRunning: nil,
                                    decoyOf: nil, since: now, restUntil: nil)
        }
        let range = start.isDecoy ? Self.copyWait : Self.dittoWait
        self.state = start
        self.waitUntil = now.addingTimeInterval(Self.uniform(range, &rng))
        self.rng = rng
    }

    /// Advance to `now`. Steps one tile per step duration; may emit events.
    mutating func tick(now: Date, world: PlazaDittoWorld) -> [PlazaDittoBrainEvent] {
        var events: [PlazaDittoBrainEvent] = []

        if let id = state.decoyOf,
           now.timeIntervalSince(state.since) >= PlazaDitto.decoyLimit || world.copyable[id] == nil {
            turnBack(now: now)
            return [.turnedBack]
        }

        // A route's next step starts where the last one ended, not when a coarse tick noticed, so the pace does not depend on
        // how often it is ticked. It never starts so far back that the step would already be over (a long gap does not replay).
        var chainedFrom: Date?
        if let end = stepEnd, now >= end {
            stepEnd = nil
            chainedFrom = end
            if route.isEmpty { state.isWalking = nil; state.isRunning = nil }
        }

        if !state.isDecoy, state.restUntil.map({ now >= $0 }) ?? true,
           let id = PlazaDitto.copyTarget(ditto: state.tile, copyable: world.copyable) {
            copy(id, now: now)
            events.append(.transformed(id))
        }

        guard stepEnd == nil else { return events }

        if let next = route.first {
            if world.blocked.contains(next) || !PlazaDitto.isGround(next, in: world.map) {
                route = []
                state.isWalking = nil
                state.isRunning = nil
                waitUntil = now.addingTimeInterval(PlazaWalker.stepDuration)
            } else {
                let duration = routeRuns ? PlazaWalker.runStepDuration : PlazaWalker.stepDuration
                step(to: next, from: chainedFrom.map { max($0, now.addingTimeInterval(-duration)) } ?? now)
            }
            return events
        }

        guard now >= waitUntil else { return events }
        if fleeing {
            planFlee(world: world)
            fleeing = !route.isEmpty
            routeRuns = false
            if route.isEmpty { waitUntil = now.addingTimeInterval(Self.uniform(Self.copyWait, &rng)) }
            return events
        }
        if state.isDecoy {
            idleAsCopy(now: now, world: world, events: &events)
        } else {
            planWalk(maxSteps: Self.dittoWalkMax, world: world)
            routeRuns = false
            if route.isEmpty { waitUntil = now.addingTimeInterval(Self.uniform(Self.dittoWait, &rng)) }
        }
        return events
    }

    /// A step or a route is under way, so the next tick is wanted at once.
    var isMoving: Bool { stepEnd != nil || !route.isEmpty }

    /// When the brain next has something to do on its own while it stands: the end of its wait, the copy's time limit, the end of
    /// its rest. Never in the past. Nothing else (a neighbour arriving) is a deadline; that comes from the world changing.
    func nextWake(now: Date) -> Date {
        var wake = waitUntil
        if state.isDecoy { wake = min(wake, state.since.addingTimeInterval(PlazaDitto.decoyLimit)) }
        if let rest = state.restUntil, rest > now { wake = min(wake, rest) }
        return max(wake, now)
    }

    /// Someone tackled the copy: turn back where it stands. No-op in Ditto form.
    mutating func found(now: Date) {
        guard state.isDecoy else { return }
        turnBack(now: now)
    }

    /// Someone tackled the Ditto form: copy them at once, even while resting and even when someone else is beside it.
    /// Nothing happens when they can't be copied or when it is already a copy. Returns whether it transformed.
    mutating func tackled(by id: String, now: Date, world: PlazaDittoWorld) -> Bool {
        guard !state.isDecoy, world.copyable[id] != nil else { return false }
        copy(id, now: now)
        return true
    }

    /// The Ditto is dancing along with someone: stand until `until`. A flee goes on; a walk under way goes on too, since
    /// its route runs before the wait is looked at and its last step sets a fresh wait.
    mutating func hold(until: Date) {
        guard !fleeing else { return }
        waitUntil = max(waitUntil, until)
    }

    // MARK: - Behaviour

    /// Become `id` and flee from them on the next tick (after the step under way, if any).
    private mutating func copy(_ id: String, now: Date) {
        state = state.copying(id, now: now)
        fleeing = true
        route = []
        waitUntil = now
    }

    private mutating func turnBack(now: Date) {
        state = state.turnedBack(now: now)
        route = []
        fleeing = false
        stepEnd = nil
        waitUntil = now.addingTimeInterval(Self.uniform(Self.dittoWait, &rng))
    }

    private mutating func idleAsCopy(now: Date, world: PlazaDittoWorld, events: inout [PlazaDittoBrainEvent]) {
        let roll = rng.unit()
        waitUntil = now.addingTimeInterval(Self.uniform(Self.copyWait, &rng))
        if roll < Self.jumpChance {
            events.append(.jumped)
        } else if roll < Self.jumpChance + Self.walkChance {
            planWalk(maxSteps: Self.copyWalkMax, world: world)
            routeRuns = rng.unit() < Self.runShare
            // The wait after the walk is set when its last step starts.
        } else if rng.unit() < Self.turnChance {
            state.facing = PlazaDirection.allCases[Int(rng.unit() * 4) % 4]
        }
    }

    private mutating func step(to next: TilePoint, from start: Date) {
        route.removeFirst()
        state.facing = PlazaPathfinder.direction(from: state.tile, to: next)
        state.tile = next
        let duration = routeRuns ? PlazaWalker.runStepDuration : PlazaWalker.stepDuration
        let end = start.addingTimeInterval(duration)
        stepEnd = end
        state.isWalking = true
        state.isRunning = routeRuns ? true : nil
        if route.isEmpty {
            fleeing = false
            let range = state.isDecoy ? Self.copyWait : Self.dittoWait
            waitUntil = end.addingTimeInterval(Self.uniform(range, &rng))
        }
    }

    private mutating func planWalk(maxSteps: Int, world: PlazaDittoWorld) {
        let reach = Self.reach(from: state.tile, world: world, maxDist: maxSteps)
        let all = reach.dist.filter { $0.value >= 1 }.keys.sorted(by: Self.order)
        guard !all.isEmpty else { route = []; return }
        let want = 1 + Int(rng.unit() * Double(maxSteps))
        let exact = all.filter { reach.dist[$0] == want }
        let pool = exact.isEmpty ? all : exact
        route = Self.path(to: pool[Int(rng.unit() * Double(pool.count)) % pool.count], reach: reach)
    }

    private mutating func planFlee(world: PlazaDittoWorld) {
        route = []
        guard let id = state.decoyOf, let real = world.present[id],
              Self.manhattan(state.tile, real) < PlazaDitto.fleeDistance else { return }
        let reach = Self.reach(from: state.tile, world: world, maxDist: nil)
        let tiles = reach.dist.filter { $0.value >= 1 }.keys.sorted(by: Self.order)
        let far = tiles.filter { Self.manhattan($0, real) >= PlazaDitto.fleeDistance }
        let target: TilePoint?
        if !far.isEmpty {
            let nearest = far.map { reach.dist[$0]! }.min()!
            let pool = far.filter { reach.dist[$0] == nearest }
            target = pool[Int(rng.unit() * Double(pool.count)) % pool.count]
        } else {
            // Walk as far as possible: the reachable tile farthest from the real one, if that beats standing still.
            let best = tiles.max { a, b in
                let da = Self.manhattan(a, real), db = Self.manhattan(b, real)
                return da != db ? da < db : reach.dist[a]! > reach.dist[b]!
            }
            target = best.flatMap { Self.manhattan($0, real) > Self.manhattan(state.tile, real) ? $0 : nil }
        }
        if let target { route = Self.path(to: target, reach: reach) }
    }

    // MARK: - Helpers

    private static func uniform(_ r: ClosedRange<Double>, _ rng: inout PlazaSplitMix64) -> Double {
        r.lowerBound + rng.unit() * (r.upperBound - r.lowerBound)
    }

    private static func manhattan(_ a: TilePoint, _ b: TilePoint) -> Int { abs(a.x - b.x) + abs(a.y - b.y) }

    private static func order(_ a: TilePoint, _ b: TilePoint) -> Bool { (a.y, a.x) < (b.y, b.x) }

    private static func randomFreeTile(world: PlazaDittoWorld, rng: inout PlazaSplitMix64) -> TilePoint {
        let map = world.map
        for _ in 0..<500 {
            let p = TilePoint(x: Int(rng.unit() * Double(map.width)), y: Int(rng.unit() * Double(map.height)))
            if PlazaDitto.isGround(p, in: map), !world.blocked.contains(p) { return p }
        }
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                if PlazaDitto.isGround(p, in: map), !world.blocked.contains(p) { return p }
            }
        }
        return map.spawn
    }

    private struct Reach {
        var dist: [TilePoint: Int]
        var prev: [TilePoint: TilePoint]
    }

    /// Breadth-first over ground tiles that are not blocked, four directions. `dist[start] == 0`.
    private static func reach(from start: TilePoint, world: PlazaDittoWorld, maxDist: Int?) -> Reach {
        var dist: [TilePoint: Int] = [start: 0]
        var prev: [TilePoint: TilePoint] = [:]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let d = dist[cur]!
            if let maxDist, d >= maxDist { continue }
            for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                let n = TilePoint(x: cur.x + dx, y: cur.y + dy)
                guard dist[n] == nil, PlazaDitto.isGround(n, in: world.map), !world.blocked.contains(n) else { continue }
                dist[n] = d + 1
                prev[n] = cur
                queue.append(n)
            }
        }
        return Reach(dist: dist, prev: prev)
    }

    /// Tiles from just after the start up to and including `target`.
    private static func path(to target: TilePoint, reach: Reach) -> [TilePoint] {
        var tiles: [TilePoint] = []
        var cur = target
        while let p = reach.prev[cur] { tiles.append(cur); cur = p }
        return tiles.reversed()
    }
}
