import Foundation

/// 열매 다섯 (berry five): the plaza's third minigame. This file holds what the table draws and the numbers it follows; the rules and the
/// engine come in later files.
enum PlazaBerry {
    /// The four berries. `itemName` is the Pokémon item picture's name (fetched at runtime, never part of the repository); `color` is the
    /// dot a card shows while that picture is missing.
    enum Berry: Int, CaseIterable, Codable, Sendable {
        case oran, sitrus, pecha, cheri

        var itemName: String {
            switch self {
            case .oran: "oran-berry"
            case .sitrus: "sitrus-berry"
            case .pecha: "pecha-berry"
            case .cheri: "cheri-berry"
            }
        }

        var color: PlazaColor {
            switch self {
            case .oran: PlazaColor(hex: 0x3B7BD1)
            case .sitrus: PlazaColor(hex: 0xF2C14E)
            case .pecha: PlazaColor(hex: 0xF09AB8)
            case .cheri: PlazaColor(hex: 0xD2453B)
            }
        }
    }

    /// One face-up card: a berry and how many of it, 1...5.
    struct Card: Hashable, Sendable {
        var berry: Berry
        var count: Int
    }

    private static let uptimeOrigin = ContinuousClock.now

    /// Monotonic seconds since the first call in this process (`ContinuousClock`: on Windows `ProcessInfo.systemUptime` counts system ticks
    /// of about 15.6 ms). Reaction times are differences of this clock on one machine, never of `Date`.
    static func uptime() -> TimeInterval {
        let d = uptimeOrigin.duration(to: ContinuousClock.now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    /// The bell's item picture.
    static let bellItem = "soothe-bell"

    /// How long a card takes from its deck onto its pile.
    static let flipAnimation: TimeInterval = 0.3

    /// Berry centres on a face as fractions of its width and height from the top-left (the mockup's dice layout).
    static let pips: [Int: [CGPoint]] = [
        1: [CGPoint(x: 0.5, y: 0.5)],
        2: [CGPoint(x: 0.30, y: 0.28), CGPoint(x: 0.70, y: 0.72)],
        3: [CGPoint(x: 0.28, y: 0.24), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.72, y: 0.76)],
        4: [CGPoint(x: 0.30, y: 0.27), CGPoint(x: 0.70, y: 0.27), CGPoint(x: 0.30, y: 0.73), CGPoint(x: 0.70, y: 0.73)],
        5: [CGPoint(x: 0.28, y: 0.24), CGPoint(x: 0.72, y: 0.24), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.28, y: 0.76), CGPoint(x: 0.72, y: 0.76)],
    ]
}

// MARK: - Shared state

/// The dealer's record of a berry five game, carried in `PlazaGameState.berry`. Card faces are never sent: every Mac works the table out
/// from the seed, the seats and these lists.
struct PlazaBerryState: Codable, Hashable, Sendable {
    /// The seat turned at each flip; `flips.count` is the spec's `flip`.
    var flips: [Int] = []
    /// `flips.count` at each clear, strictly increasing; `clears.count` is the spec's `clears`.
    var clears: [Int] = []
    /// By seat (the index in `players`).
    var scores: [Int]
    /// By seat: the serial of that player's last bell the dealer acted on (0: none).
    var judged: [Int]
    /// The last bell the dealer acted on.
    var last: Verdict?
    /// +1 with every write.
    var step = 0

    struct Verdict: Codable, Hashable, Sendable {
        var seat: Int
        var ms: Int
        var right: Bool
        var flip: Int
        /// `clears.count` the bell was for.
        var clear: Int
        /// false: a wrong bell that took no point because the score was already 0. A right bell never reads it.
        var tookPoint = true

        init(seat: Int, ms: Int, right: Bool, flip: Int, clear: Int, tookPoint: Bool = true) {
            self.seat = seat; self.ms = ms; self.right = right; self.flip = flip; self.clear = clear; self.tookPoint = tookPoint
        }

        /// A verdict from an older dev build has no `tookPoint`: it took one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seat = try c.decode(Int.self, forKey: .seat)
            ms = try c.decode(Int.self, forKey: .ms)
            right = try c.decode(Bool.self, forKey: .right)
            flip = try c.decode(Int.self, forKey: .flip)
            clear = try c.decode(Int.self, forKey: .clear)
            tookPoint = try c.decodeIfPresent(Bool.self, forKey: .tookPoint) ?? true
        }
    }

    init(seats: Int) {
        scores = Array(repeating: 0, count: seats)
        judged = Array(repeating: 0, count: seats)
    }
}

/// One ring, as the ringing machine saw it. Rides that machine's presence.
struct PlazaBerryBell: Codable, Hashable, Sendable {
    /// `PlazaGameState.id`.
    var game: String
    /// `clears.count` on my screen.
    var clears: Int
    /// `flips.count` on my screen.
    var flip: Int
    /// My reaction; 0 for a wrong bell.
    var ms: Int
    /// My screen showed exactly five.
    var right: Bool
    /// 1, 2, ... per game.
    var serial: Int

    /// A received bell, or nil when any field is out of bounds.
    static func accepted(_ b: PlazaBerryBell?) -> PlazaBerryBell? {
        guard let b, !b.game.isEmpty, b.game.utf8.count <= TeamWire.maxFieldBytes,
              (0...PlazaBerry.deckSize).contains(b.clears), (0...PlazaBerry.deckSize).contains(b.flip),
              (0...PlazaBerry.maxReactionMS).contains(b.ms), (1...PlazaBerry.maxSerial).contains(b.serial) else { return nil }
        return b
    }
}

// MARK: - Rules

extension PlazaBerry {
    static let maxPlayers = 8, deckSize = 56, winScore = 5
    /// Per berry: how many cards show that many berries.
    static let counts: [(count: Int, cards: Int)] = [(1, 5), (2, 3), (3, 3), (4, 2), (5, 1)]
    static let flipSeconds: TimeInterval = 1.5, restSeconds: TimeInterval = 1.5, judgeSeconds: TimeInterval = 0.6
    static let lockoutSeconds: TimeInterval = 1, endWait: TimeInterval = 3, resultSeconds: TimeInterval = 5
    static let maxStep = 100_000, maxSerial = 1_000_000, maxReactionMS = 600_000

    // MARK: Deck

    /// Every seat's deck in flip order: 56 cards shuffled by the seed and dealt one at a time from seat 0. Integer arithmetic only,
    /// so every system deals the same cards.
    static func decks(seed: UInt64, seats: Int) -> [[Card]] {
        var all: [Card] = []
        for berry in Berry.allCases {
            for (count, cards) in counts { all += Array(repeating: Card(berry: berry, count: count), count: cards) }
        }
        var g = PlazaSplitMix64(seed: seed ^ 0xBE77_F1FE)
        for i in stride(from: all.count - 1, to: 0, by: -1) { all.swapAt(i, Int(g.next() % UInt64(i + 1))) }
        var decks = [[Card]](repeating: [], count: max(seats, 1))
        for (j, card) in all.enumerated() { decks[j % decks.count].append(card) }
        return decks
    }

    /// Every seat's top card among the flips after clear `clear` (0: from the start) up to flip `flip`.
    static func table(_ b: PlazaBerryState, decks: [[Card]], flip: Int, clear: Int) -> [Card?] {
        var table = [Card?](repeating: nil, count: decks.count)
        let end = min(max(flip, 0), b.flips.count)
        let start = clear <= 0 ? 0 : (b.clears.indices.contains(clear - 1) ? b.clears[clear - 1] : end)
        var dealt = [Int](repeating: 0, count: decks.count)
        for (i, seat) in b.flips.prefix(end).enumerated() where decks.indices.contains(seat) {
            if i >= start, decks[seat].indices.contains(dealt[seat]) { table[seat] = decks[seat][dealt[seat]] }
            dealt[seat] += 1
        }
        return table
    }

    /// The table now; empty without a payload.
    static func table(_ s: PlazaGameState) -> [Card?] {
        guard let b = s.berry else { return [] }
        return table(b, decks: decks(seed: s.seed, seats: s.players.count), flip: b.flips.count, clear: b.clears.count)
    }

    /// Berries summing to exactly five, in `Berry` order.
    static func fives(_ table: [Card?]) -> [Berry] {
        Berry.allCases.filter { berry in table.reduce(0) { $0 + ($1?.berry == berry ? $1?.count ?? 0 : 0) } == 5 }
    }

    static func deckLeft(_ b: PlazaBerryState, decks: [[Card]], seat: Int) -> Int {
        guard decks.indices.contains(seat) else { return 0 }
        return decks[seat].count - b.flips.filter { $0 == seat }.count
    }

    /// How many cards the seat has turned since the last clear.
    static func under(_ b: PlazaBerryState, seat: Int) -> Int {
        b.flips.suffix(b.flips.count - (b.clears.last ?? 0)).filter { $0 == seat }.count
    }

    /// The next seat to turn after the last flipped one (seat 0 first), among `playing` with cards left; nil if none.
    static func nextSeat(_ s: PlazaGameState, playing: Set<Int>) -> Int? {
        guard let b = s.berry else { return nil }
        let seats = s.players.count
        let d = decks(seed: s.seed, seats: seats)
        let from = (b.flips.last ?? -1) + 1
        return (0..<seats).map { (from + $0) % seats }.first { playing.contains($0) && deckLeft(b, decks: d, seat: $0) > 0 }
    }

    // MARK: Transitions

    /// The state after one write: step + 1. At the step cap the game ends instead, with no winner.
    private static func stepped(_ s: PlazaGameState, _ edit: (inout PlazaBerryState) -> Void, at t: Double?) -> PlazaGameState {
        guard var b = s.berry else { return s }
        if b.step >= maxStep { return ended(s, at: t ?? s.startsAt ?? s.opensAt, noWinner: true) }
        edit(&b)
        b.step += 1
        var next = s
        next.berry = b
        return next
    }

    /// The dealer turned `seat`'s next card. `t` only matters at the step cap (default: the game's start).
    static func flipped(_ s: PlazaGameState, seat: Int, at t: Double? = nil) -> PlazaGameState? {
        guard let b = s.berry, s.endedAt == nil, deckLeft(b, decks: decks(seed: s.seed, seats: s.players.count), seat: seat) > 0 else { return nil }
        return stepped(s, { $0.flips.append(seat) }, at: t)
    }

    /// The right bell of `seat` wins this clear. Ends the game at `t` when that makes five points or no playing seat has cards.
    static func cleared(_ s: PlazaGameState, seat: Int, bell: PlazaBerryBell, playing: Set<Int>, at t: Double) -> PlazaGameState? {
        guard let b = s.berry, s.endedAt == nil, b.scores.indices.contains(seat), b.flips.count > (b.clears.last ?? 0) else { return nil }
        if b.step >= maxStep { return ended(s, at: t, noWinner: true) }
        var next = stepped(s, {
            $0.scores[seat] += 1
            $0.clears.append($0.flips.count)
            $0.judged[seat] = max($0.judged[seat], bell.serial)
            $0.last = .init(seat: seat, ms: bell.ms, right: true, flip: bell.flip, clear: b.clears.count)
        }, at: t)
        guard let nb = next.berry else { return next }
        let d = decks(seed: s.seed, seats: s.players.count)
        if nb.scores[seat] >= winScore || !playing.contains(where: { deckLeft(nb, decks: d, seat: $0) > 0 }) {
            let step = nb.step
            next = ended(next, at: t)
            next.berry?.step = step
        }
        return next
    }

    static func penalized(_ s: PlazaGameState, seat: Int, bell: PlazaBerryBell) -> PlazaGameState? {
        guard let b = s.berry, s.endedAt == nil, b.scores.indices.contains(seat), bell.serial > b.judged[seat] else { return nil }
        let tookPoint = b.scores[seat] > 0
        return stepped(s, {
            $0.scores[seat] = max(0, $0.scores[seat] - 1)
            $0.judged[seat] = bell.serial
            $0.last = .init(seat: seat, ms: bell.ms, right: false, flip: bell.flip, clear: bell.clears, tookPoint: tookPoint)
        }, at: nil)
    }

    /// Ends at `t`; `winner` is the single top scorer among all players (gone ones too), nil on a tie.
    static func ended(_ s: PlazaGameState, at t: Double) -> PlazaGameState { ended(s, at: t, noWinner: false) }

    private static func ended(_ s: PlazaGameState, at t: Double, noWinner: Bool) -> PlazaGameState {
        var next = s
        next.endedAt = t
        guard var b = s.berry else { return next }
        b.step = min(b.step + 1, maxStep)
        next.berry = b
        let top = b.scores.max() ?? 0
        let leaders = b.scores.indices.filter { b.scores[$0] == top && s.players.indices.contains($0) }
        next.winner = !noWinner && leaders.count == 1 ? s.players[leaders[0]] : nil
        return next
    }

    // MARK: Bells

    /// The right bell counts only for the current clear, at a flip after that clear whose own table had exactly five.
    static func isValidRight(_ bell: PlazaBerryBell, in s: PlazaGameState) -> Bool {
        guard bell.right, bell.game == s.id, let b = s.berry, s.endedAt == nil, bell.clears == b.clears.count,
              bell.flip > (b.clears.last ?? 0), bell.flip <= b.flips.count else { return false }
        let d = decks(seed: s.seed, seats: s.players.count)
        return !fives(table(b, decks: d, flip: bell.flip, clear: bell.clears)).isEmpty
    }

    /// A wrong bell costs a point only when it is new, for the current clear, and its table had cards but no five.
    static func isValidWrong(_ bell: PlazaBerryBell, seat: Int, in s: PlazaGameState) -> Bool {
        guard !bell.right, bell.game == s.id, let b = s.berry, s.endedAt == nil, b.judged.indices.contains(seat),
              bell.serial > b.judged[seat], bell.clears == b.clears.count,
              bell.flip > (b.clears.last ?? 0), bell.flip <= b.flips.count else { return false }
        let d = decks(seed: s.seed, seats: s.players.count)
        return fives(table(b, decks: d, flip: bell.flip, clear: bell.clears)).isEmpty
    }

    // MARK: Received payload

    /// Bounds on a received payload (spec §4). nil drops the whole game state.
    static func accepted(_ b: PlazaBerryState, players: Int) -> PlazaBerryState? {
        guard (1...maxPlayers).contains(players), b.flips.count <= deckSize, b.flips.allSatisfy({ (0..<players).contains($0) }),
              b.scores.count == players, b.judged.count == players,
              b.scores.allSatisfy({ (0...winScore).contains($0) }), b.judged.allSatisfy({ (0...maxSerial).contains($0) }),
              (0...maxStep).contains(b.step) else { return nil }
        for seat in 0..<players {
            // The dealer deals card j to seat j % players.
            guard b.flips.filter({ $0 == seat }).count <= (deckSize - seat + players - 1) / players else { return nil }
        }
        guard b.clears.count <= b.flips.count, b.clears.allSatisfy({ (1...b.flips.count).contains($0) }),
              zip(b.clears, b.clears.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        if let v = b.last {
            guard (0..<players).contains(v.seat), (0...b.flips.count).contains(v.flip), (0...b.clears.count).contains(v.clear),
                  (0...maxReactionMS).contains(v.ms) else { return nil }
        }
        return b
    }

    // MARK: Ordering and standings

    /// For `PlazaGame.precedes`: [clears.count, flips.count, step]; [-1, -1, -1] for no payload.
    static func keys(_ b: PlazaBerryState?) -> [Double] {
        guard let b else { return [-1, -1, -1] }
        return [Double(b.clears.count), Double(b.flips.count), Double(b.step)]
    }

    /// The last tie-break of `precedes`: the payload's own text, so two different copies never tie both ways.
    static func tie(_ b: PlazaBerryState?) -> String {
        guard let b else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(b)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Score descending, then id.
    static func ranking(_ s: PlazaGameState) -> [(id: String, score: Int)] {
        let scores = s.berry?.scores ?? []
        return s.players.enumerated().map { (id: $1, score: scores.indices.contains($0) ? scores[$0] : 0) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }
}
