import Foundation

/// A plaza minigame. A new game adds a case here, its payload on `PlazaGameState`, and its rules beside `PlazaBomb`.
/// The lobby (open, join, countdown, result) is shared by every game.
enum PlazaGameKind: String, CaseIterable, Sendable {
    case bomb
}

/// One minigame as the team knows it: carried in every member's presence and passed on, like the campfire switch.
/// Times are wall-clock seconds since 1970 on the Mac that wrote them.
struct PlazaGameState: Codable, Hashable, Sendable {
    /// Unique per game: the host and the moment it was opened.
    var id: String
    /// A `PlazaGameKind` raw value. A kind this version does not know is kept and passed on, never played.
    var kind: String
    /// Who opened it. Only the host locks the players in.
    var host: String
    var opensAt: Double
    /// When play begins, set by the host as it locks the players in. nil while recruiting.
    var startsAt: Double?
    /// Who plays, sorted. Empty while recruiting.
    var players: [String] = []
    /// Decides the fuses and who holds the bomb first; drawn by the host when it locks.
    var seed: UInt64 = 0
    var endedAt: Double?
    /// The last one standing. nil with `endedAt`: cancelled, or nobody was left.
    var winner: String?
    var bomb: PlazaBombState?
}

/// 폭탄 돌리기. The holder passes the bomb by hitting another player; whoever holds it when the fuse runs out is out.
struct PlazaBombState: Codable, Hashable, Sendable {
    /// 1 for the first bomb; one more after every explosion.
    var round: Int
    /// When this round's bomb goes live. Its fuse runs from here.
    var roundStartsAt: Double
    var holder: String
    /// Passes and explosions so far in the whole game. Only grows, so the latest hand-over wins everywhere.
    var pass: Int = 0
    /// Who handed the bomb over last, and when: they cannot get it straight back.
    var from: String?
    var passedAt: Double?
    /// Out of the game, in order: blown up, or gone from the plaza.
    var out: [String] = []
}

enum PlazaGame {
    /// How long teammates can join after a game opens.
    static let recruitSeconds: TimeInterval = 30
    /// The 3-2-1 before play begins.
    static let countdownSeconds: TimeInterval = 3
    static let minPlayers = 2
    /// Small enough that the longest game (every fuse at its longest) still ends well inside `maxLife`.
    static let maxPlayers = 20
    /// A recruiting game whose host never locked it (the host left) is forgotten this long after recruiting ends.
    static let hostGrace: TimeInterval = 15
    /// No game lives longer than this.
    static let maxLife: TimeInterval = 15 * 60
    /// An ended game is kept (and passed on) this long, so a late Mac still shows the result and no stale state revives.
    static let endedKeep: TimeInterval = 60
    /// A new game can open this long after the last one ended.
    static let rematchDelay: TimeInterval = 5
    /// A received time may be this far ahead of my clock.
    static let clockSlack: TimeInterval = 60
    /// A host whose game was cancelled before it started cannot open another for this long: no invitation loop.
    static let reopenDelay: TimeInterval = 30
    /// A Mac with no teammate connected (asleep, off the network) gives up its place in the game after this long.
    static let isolationLimit: TimeInterval = 10
    /// Passes and explosions in one game. A game that reaches it ends with no winner.
    static let maxPass = 100_000

    enum Phase: Equatable, Sendable { case recruiting, countdown, playing, ended }

    /// nil: nothing to show or play (no game, or one that outlived its limits).
    static func phase(_ s: PlazaGameState?, now: Date) -> Phase? {
        guard let s else { return nil }
        let t = now.timeIntervalSince1970
        if let ended = s.endedAt { return t < ended + endedKeep ? .ended : nil }
        guard t < s.opensAt + maxLife else { return nil }
        guard let starts = s.startsAt else { return t < s.opensAt + recruitSeconds + hostGrace ? .recruiting : nil }
        return t < starts ? .countdown : .playing
    }

    /// A received state, kept only when every field is within bounds and it is still alive. Anything else is nil.
    static func accepted(_ s: PlazaGameState?, now: Date) -> PlazaGameState? {
        guard let s else { return nil }
        let t = now.timeIntervalSince1970
        func okID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= TeamWire.maxFieldBytes }
        func okTime(_ v: Double, from low: Double) -> Bool { v.isFinite && v >= low && v <= t + clockSlack }
        guard okID(s.id), okID(s.host), !s.kind.isEmpty, s.kind.utf8.count <= 32,
              s.opensAt.isFinite, s.opensAt <= t + clockSlack,
              s.players.count <= maxPlayers, s.players.allSatisfy(okID), Set(s.players).count == s.players.count else { return nil }
        if let starts = s.startsAt {
            guard starts.isFinite, starts >= s.opensAt, starts <= s.opensAt + recruitSeconds + hostGrace + countdownSeconds,
                  s.players.count >= minPlayers else { return nil }
        } else {
            guard s.players.isEmpty, s.bomb == nil else { return nil }
        }
        if let ended = s.endedAt { guard okTime(ended, from: s.opensAt) else { return nil } }
        if let winner = s.winner { guard s.endedAt != nil, s.players.contains(winner) else { return nil } }
        if let b = s.bomb {
            // A round only begins after someone went out, so the round can never run ahead of the out list.
            guard let starts = s.startsAt, (1...(b.out.count + 1)).contains(b.round), okTime(b.roundStartsAt, from: starts),
                  s.players.contains(b.holder), (0...maxPass).contains(b.pass),
                  b.out.count < s.players.count || s.endedAt != nil, b.out.count <= s.players.count,
                  b.out.allSatisfy(s.players.contains), Set(b.out).count == b.out.count else { return nil }
            if let from = b.from { guard s.players.contains(from) else { return nil } }
            if let at = b.passedAt { guard at.isFinite, at <= t + clockSlack else { return nil } }
        }
        return phase(s, now: now) == nil ? nil : s
    }

    /// The one every Mac keeps, whichever order the two arrive in. A later game replaces an earlier one; within a game,
    /// ended beats running beats recruiting, and a running game follows the bomb's furthest progress.
    static func merged(_ a: PlazaGameState?, _ b: PlazaGameState?) -> PlazaGameState? {
        guard let a else { return b }
        guard let b else { return a }
        return precedes(a, b) ? b : a
    }

    /// `a` loses to `b`. A total order: equal states never precede each other.
    static func precedes(_ a: PlazaGameState, _ b: PlazaGameState) -> Bool {
        if a.id != b.id { return a.opensAt != b.opensAt ? a.opensAt < b.opensAt : a.id < b.id }
        func rank(_ s: PlazaGameState) -> Int { s.endedAt != nil ? 2 : (s.startsAt != nil ? 1 : 0) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let x = a.bomb, y = b.bomb
        let keysA: [Double] = [Double(x?.out.count ?? -1), Double(x?.pass ?? -1), x?.roundStartsAt ?? 0, a.endedAt ?? 0, a.startsAt ?? 0]
        let keysB: [Double] = [Double(y?.out.count ?? -1), Double(y?.pass ?? -1), y?.roundStartsAt ?? 0, b.endedAt ?? 0, b.startsAt ?? 0]
        for (p, q) in zip(keysA, keysB) where p != q { return p < q }
        let tieA = [x?.holder ?? "", a.winner ?? "", a.players.joined(separator: ","), String(a.seed)]
        let tieB = [y?.holder ?? "", b.winner ?? "", b.players.joined(separator: ","), String(b.seed)]
        for (p, q) in zip(tieA, tieB) where p != q { return p > q }   // the smaller ID keeps the bomb
        return false
    }
}

/// The rules of 폭탄 돌리기 that every Mac computes the same way from the shared state.
enum PlazaBomb {
    /// The fuse of a round, hidden from the players: somewhere in this range.
    static let fuseRange: ClosedRange<TimeInterval> = 15...35
    /// The bomb shows it is about to blow for this long.
    static let urgentSeconds: TimeInterval = 3
    /// The pause between an explosion and the next bomb.
    static let intermission: TimeInterval = 4
    /// Whoever just handed the bomb over cannot get it back for this long.
    static let returnImmunity: TimeInterval = 2
    /// One running step of whoever holds the live bomb: 20 % faster than everyone else (`PlazaWalker.runStepDuration`).
    /// At the same speed a holder never catches a player who keeps running. It stays above `PlazaScene.maxFrameDelta`:
    /// a frame must never cover two tiles, or teammates see the holder jump.
    static let holderRunStepDuration: TimeInterval = PlazaWalker.runStepDuration / 1.2
    /// A holder who is gone from the plaza, or whose Mac did not report the explosion, is put out after this long.
    static let absenceGrace: TimeInterval = 3

    static func alive(_ s: PlazaGameState) -> [String] {
        let out = Set(s.bomb?.out ?? [])
        return s.players.filter { !out.contains($0) }
    }

    private static func generator(seed: UInt64, round: Int, salt: UInt64) -> PlazaSplitMix64 {
        PlazaSplitMix64(seed: seed ^ (UInt64(truncatingIfNeeded: round) &* 0x9E37_79B9_7F4A_7C15) ^ salt)
    }

    static func fuse(seed: UInt64, round: Int) -> TimeInterval {
        var g = generator(seed: seed, round: round, salt: 0xB0B)
        return fuseRange.lowerBound + g.unit() * (fuseRange.upperBound - fuseRange.lowerBound)
    }

    /// Who starts a round with the bomb, among `alive` (not empty).
    static func firstHolder(seed: UInt64, round: Int, alive: [String]) -> String {
        var g = generator(seed: seed, round: round, salt: 0xF00D)
        let sorted = alive.sorted()
        return sorted[min(Int(g.unit() * Double(sorted.count)), sorted.count - 1)]
    }

    /// When the current bomb blows. nil unless a round is set.
    static func explodesAt(_ s: PlazaGameState) -> Double? {
        s.bomb.map { $0.roundStartsAt + fuse(seed: s.seed, round: $0.round) }
    }
}

/// One Mac's part in the team's minigame: what it knows, what it answered, and the moves only it may make. Pure
/// values; the plaza feeds it the clock and who is there, publishes `state` and `joined`, and draws from `state`.
struct PlazaGameEngine {
    let me: String
    private(set) var state: PlazaGameState?
    /// The game I said yes to (sent in my presence so the host counts me in).
    private(set) var joined: String?
    /// The game I said no to (kept here only: the invitation stays away).
    private(set) var declined: String?
    /// The host asked to start before recruiting ends.
    private var startRequested = false
    private var holderAbsentSince: Double?
    private var isolatedSince: Double?
    /// The game I dropped out of because this Mac lost every teammate (the plaza says so instead of naming a loser).
    private(set) var lostConnection: String?
    /// Hosts whose game was cancelled before it started, and when: their next invitation waits `reopenDelay`.
    private var cancelled: [String: Double] = [:]
    /// Draws the seed when I lock a game as its host.
    var makeSeed: () -> UInt64 = { UInt64.random(in: .min ... .max) }

    init(me: String) { self.me = me }

    func phase(now: Date) -> PlazaGame.Phase? { PlazaGame.phase(state, now: now) }

    var isHost: Bool { state?.host == me }

    /// I am in the running game and not out.
    var isPlaying: Bool {
        guard let state, state.startsAt != nil, state.endedAt == nil else { return false }
        return PlazaBomb.alive(state).contains(me)
    }

    /// I am one of the players, and I said yes: a list that names me without my yes does not make me one.
    var isPlayer: Bool {
        guard let state else { return false }
        return state.players.contains(me) && joined == state.id
    }

    /// Takes what `sender` knows (nil: not checked, for tests of the merge alone). True when it changed what I know.
    /// An invitation counts only from its host's own Mac, and not while that host's last cancelled game is fresh.
    @discardableResult
    mutating func learn(_ received: PlazaGameState?, from sender: String? = nil, now: Date) -> Bool {
        let before = state
        var incoming = PlazaGame.accepted(received, now: now)
        if let r = incoming, r.id != state?.id, r.startsAt == nil, r.endedAt == nil {
            if let sender, sender != r.host { incoming = nil }
            if let at = cancelled[r.host], r.opensAt < at + PlazaGame.reopenDelay { incoming = nil }
        }
        state = PlazaGame.merged(PlazaGame.accepted(state, now: now), incoming)
        settle(now: now)
        return state != before
    }

    private mutating func settle(now: Date) {
        if joined != state?.id { joined = nil }
        if declined != state?.id { declined = nil }
        if lostConnection != state?.id { lostConnection = nil }
        if state?.startsAt != nil || state == nil { startRequested = false }
        let t = now.timeIntervalSince1970
        if let s = state, s.startsAt == nil, let ended = s.endedAt { cancelled[s.host] = max(cancelled[s.host] ?? ended, ended) }
        cancelled = cancelled.filter { t < $0.value + PlazaGame.reopenDelay }
    }

    /// How long until I can open a game: 0 when none is alive, the last one ended a moment ago, and my own last game
    /// was not just cancelled. nil while a game is alive.
    func opensIn(now: Date) -> TimeInterval? {
        let t = now.timeIntervalSince1970
        var wait = max(0, (cancelled[me] ?? -.infinity) + PlazaGame.reopenDelay - t)
        switch phase(now: now) {
        case nil: break
        case .ended: wait = max(wait, (state?.endedAt ?? 0) + PlazaGame.rematchDelay - t)
        case .recruiting, .countdown, .playing: return nil
        }
        return wait
    }

    func canOpen(now: Date) -> Bool { opensIn(now: now) == 0 }

    /// Opens a game with me as host and first player.
    @discardableResult
    mutating func open(_ kind: PlazaGameKind, now: Date) -> Bool {
        guard canOpen(now: now) else { return false }
        // Stamped after anything I know, so my new game wins over it everywhere.
        let at = max(now.timeIntervalSince1970, (state?.opensAt ?? -.infinity) + 0.001)
        let id = "\(me.prefix(40))@\(Int64(at * 1000))"
        state = PlazaGameState(id: id, kind: kind.rawValue, host: me, opensAt: at)
        joined = id
        declined = nil
        startRequested = false
        return true
    }

    /// Y or N on the invitation. Only while recruiting, and only for a game this version can play.
    mutating func answer(join: Bool, now: Date) {
        guard let state, phase(now: now) == .recruiting, PlazaGameKind(rawValue: state.kind) != nil, state.host != me else { return }
        joined = join ? state.id : nil
        declined = join ? nil : state.id
    }

    /// The host starts without waiting for recruiting to end (it takes effect once two have joined). Only the host's
    /// tick reads it, so on anyone else's Mac it does nothing.
    mutating func requestStart() { startRequested = true }

    /// I am leaving the plaza: out of the lobby, and out of a running game. Only a holder's leaving ends the round
    /// (the bomb goes off with them); anyone else just steps out and the bomb keeps ticking.
    mutating func leave(now: Date, present: Set<String>) {
        guard var s = state else { return }
        switch phase(now: now) {
        case .recruiting:
            joined = nil
            guard s.host == me else { return }
            s.endedAt = now.timeIntervalSince1970
            state = s
            settle(now: now)
        case .countdown, .playing:
            guard PlazaBomb.alive(s).contains(me) else { return }
            putOut(me, now: now, present: present.subtracting([me]))
        default: break
        }
    }

    /// A hit from `sender` landed on me. True when it handed me the bomb.
    mutating func hit(by sender: String, now: Date) -> Bool {
        guard var s = state, phase(now: now) == .playing, var b = s.bomb, b.holder == sender, sender != me,
              PlazaBomb.alive(s).contains(me), joined == s.id else { return false }
        let t = now.timeIntervalSince1970
        guard t >= b.roundStartsAt, b.pass < PlazaGame.maxPass else { return false }
        if b.from == me, let at = b.passedAt, t - at < PlazaBomb.returnImmunity { return false }
        b.holder = me
        b.from = sender
        b.passedAt = t
        b.pass += 1
        s.bomb = b
        state = s
        return true
    }

    /// Does what only this Mac may do right now. `present`: teammates in the plaza (not me). `joins`: those of them who
    /// said yes to the current game. `connected`: this Mac reaches at least one teammate. True when `state` changed
    /// (publish it).
    @discardableResult
    mutating func tick(now: Date, present: Set<String>, joins: Set<String>, connected: Bool = true) -> Bool {
        let before = state
        state = PlazaGame.accepted(state, now: now)
        settle(now: now)
        guard var s = state else { return before != nil }
        let t = now.timeIntervalSince1970
        let phase = PlazaGame.phase(s, now: now)
        if phase == .countdown || phase == .playing, PlazaBomb.alive(s).contains(me) {
            // Listed without my yes (a late N, a restart, a list someone made up): I step out, quietly.
            if joined != s.id {
                putOut(me, now: now, present: present, sweep: false)
                return state != before
            }
            // Cut off from everyone, I cannot tell who is still there: I judge nobody, and after a while I step out
            // myself. Without this a Mac that slept through the game woke up as its only player and "won" it.
            if !connected {
                holderAbsentSince = nil
                let since = isolatedSince ?? t
                isolatedSince = since
                let myBombBlew = phase == .playing && s.bomb?.holder == me && t >= (PlazaBomb.explodesAt(s) ?? .infinity)
                if t - since >= PlazaGame.isolationLimit { lostConnection = s.id }
                if myBombBlew || lostConnection == s.id { putOut(me, now: now, present: present, sweep: false) }
                return state != before
            }
        }
        isolatedSince = nil
        switch phase {
        case .recruiting where s.host == me:
            let players = (joins.intersection(present).union(joined == s.id ? [me] : [])).sorted()
            let timeUp = t >= s.opensAt + PlazaGame.recruitSeconds
            if players.count >= PlazaGame.minPlayers, timeUp || startRequested {
                s.players = Array(players.prefix(PlazaGame.maxPlayers))
                s.seed = makeSeed()
                s.startsAt = t + PlazaGame.countdownSeconds
                if s.kind == PlazaGameKind.bomb.rawValue {
                    s.bomb = PlazaBombState(round: 1, roundStartsAt: t + PlazaGame.countdownSeconds,
                                            holder: PlazaBomb.firstHolder(seed: s.seed, round: 1, alive: s.players))
                }
                state = s
            } else if timeUp {
                s.endedAt = t   // not enough players: cancelled
                state = s
            }
        case .playing:
            guard let b = s.bomb, let explodes = PlazaBomb.explodesAt(s), t >= b.roundStartsAt else { break }
            let alive = PlazaBomb.alive(s)
            if b.holder == me {
                if t >= explodes { putOut(me, now: now, present: present) }
                break
            }
            // The referee (the first player still here, the holder aside) speaks for a holder who cannot.
            let here = alive.filter { $0 != b.holder && ($0 == me || present.contains($0)) }
            guard here.min() == me else { break }
            if present.contains(b.holder) {
                holderAbsentSince = nil
                if t >= explodes + PlazaBomb.absenceGrace { putOut(b.holder, now: now, present: present) }
            } else {
                let since = holderAbsentSince ?? t
                holderAbsentSince = since
                if t - since >= PlazaBomb.absenceGrace { putOut(b.holder, now: now, present: present) }
            }
        default: break
        }
        if state?.bomb?.holder != s.bomb?.holder || state?.bomb?.round != s.bomb?.round { holderAbsentSince = nil }
        return state != before
    }

    /// `member` is out, and with `sweep` so are the players who are gone. A holder going out ends the round: the next
    /// one starts, or the game ends. Anyone else going out leaves the bomb and its fuse as they are.
    private mutating func putOut(_ member: String, now: Date, present: Set<String>, sweep: Bool = true) {
        guard var s = state, var b = s.bomb else { return }
        let t = now.timeIntervalSince1970
        var out = b.out
        if !out.contains(member) { out.append(member) }
        if sweep {
            for p in PlazaBomb.alive(s).sorted() where p != me && !present.contains(p) && !out.contains(p) { out.append(p) }
        }
        guard out != b.out else { return }
        holderAbsentSince = nil
        guard b.pass < PlazaGame.maxPass else {
            s.endedAt = t   // out of moves: nobody wins
            state = s
            return
        }
        b.out = out
        b.pass += 1
        s.bomb = b
        let alive = PlazaBomb.alive(s)
        if alive.count <= 1 {
            s.endedAt = t
            s.winner = alive.first
        } else if out.contains(b.holder) {
            b.from = nil
            b.passedAt = nil
            b.round += 1
            b.roundStartsAt = max(t + PlazaBomb.intermission, s.startsAt ?? t)
            b.holder = PlazaBomb.firstHolder(seed: s.seed, round: b.round, alive: alive)
            s.bomb = b
        }
        state = s
    }
}
