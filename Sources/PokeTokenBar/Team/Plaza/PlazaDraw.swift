import Foundation

/// Drawing quiz state: carried in `PlazaGameState.draw`. Every change is one `step` more, so the furthest copy wins everywhere.
struct PlazaDrawState: Codable, Hashable, Sendable {
    /// Who draws, turn by turn; its count is the number of turns.
    var order: [String]
    /// 0-based; equal to `order.count` when every turn is done.
    var turn: Int = 0
    /// The drawer opened the word field (the drawer's clock).
    var entryAt: Double?
    /// The drawer set a word; drawing runs from here (the drawer's clock).
    var drawAt: Double?
    /// Hint 1, once published.
    var letters: Int?
    /// Hint 2, once published.
    var initials: String?
    /// +1 with every change, whoever makes it.
    var step: Int = 0
    var scores: [String: Int] = [:]
    /// The turn before this one.
    var last: Result?

    struct Result: Codable, Hashable, Sendable {
        var turn: Int
        var drawer: String
        var word: String?
        var solver: String?
    }
}

/// The rules of the drawing quiz that every Mac computes the same way from the shared state. Pure functions on values.
enum PlazaDraw {
    static let maxPlayers = 8, maxTurns = 8
    /// The canvas's nine colours, by canvas value: the paper, then the eight pens (black, red, orange, yellow, green, blue, purple, brown).
    static let palette: [PlazaRGBA] = [0xF6F1E3, 0x2B2233, 0xD2453B, 0xE8862E, 0xF2C14E, 0x3F9D4B, 0x3B7BD1, 0x7D4FC2, 0x8A5A36].map {
        PlazaRGBA(r: UInt8($0 >> 16), g: UInt8(($0 >> 8) & 0xFF), b: UInt8($0 & 0xFF), a: 255)
    }
    static let wordSeconds: TimeInterval = 20, drawSeconds: TimeInterval = 60, revealSeconds: TimeInterval = 6
    static let refereeSlack: TimeInterval = 10
    static let guessPoints = 10, drawerPoints = 5
    static let maxWordCharacters = 12
    /// The word's size on the wire: combining marks make a short word long, and the word is relayed to every Mac.
    static let maxWordBytes = 64
    /// The first hint (how many letters) and the second (the initials) appear this long after drawing begins.
    static let lettersHintSeconds: TimeInterval = drawSeconds / 2, initialsHintSeconds: TimeInterval = drawSeconds * 3 / 4

    // MARK: Order

    /// The players shuffled once by the seed; twice in a row when there are 4 or fewer.
    static func order(players: [String], seed: UInt64) -> [String] {
        var shuffled = players.sorted()
        var g = PlazaSplitMix64(seed: seed)
        var i = shuffled.count - 1
        while i > 0 {
            let j = min(Int(g.unit() * Double(i + 1)), i)
            shuffled.swapAt(i, j)
            i -= 1
        }
        return shuffled.count <= 4 ? shuffled + shuffled : shuffled
    }

    // MARK: Text

    private static func isLetterOrDigit(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    private static func isAllowed(_ u: Unicode.Scalar) -> Bool {
        if u == " " || isLetterOrDigit(u) { return true }
        // A combining mark belongs to the letter before it (an accent, a conjoining vowel).
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark: return true
        default: return false
        }
    }

    /// The word as it is kept (ends trimmed, inner runs of spaces single), or nil when it breaks the rules: only
    /// letters, digits and spaces, at least one letter or digit, 1...12 characters.
    static func word(_ raw: String) -> String? {
        guard raw.unicodeScalars.allSatisfy(isAllowed), raw.unicodeScalars.contains(where: isLetterOrDigit) else { return nil }
        let kept = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (1...maxWordCharacters).contains(kept.count) && kept.utf8.count <= maxWordBytes ? kept : nil
    }

    private static let ignoredPunctuation: Set<Character> = [".", ",", "!", "?", "~", "\u{2026}", "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]

    /// Spaces and punctuation dropped, ASCII letters lowercased. Swift compares `Character`s by canonical equivalence,
    /// so decomposed Hangul equals the precomposed text without any Foundation normalisation.
    private static func cleaned(_ s: String) -> [Character] {
        s.compactMap { c in
            if c.isWhitespace || ignoredPunctuation.contains(c) { return nil }
            return c.isASCII ? Character(c.lowercased()) : c
        }
    }

    /// The whole line is the word, whatever its spacing, punctuation, case or composition.
    static func matches(_ line: String, word: String) -> Bool {
        let a = cleaned(line)
        return !a.isEmpty && a == cleaned(word)
    }

    /// The line holds the word (the drawer may not give it away).
    static func contains(_ line: String, word: String) -> Bool {
        let hay = cleaned(line), needle = cleaned(word)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains { hay[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    /// Spaces not counted.
    static func letters(_ word: String) -> Int { word.filter { !$0.isWhitespace }.count }

    /// The 19 initial consonants in Unicode order, built from scalars (Hangul text lives only in `TeamLocalization`):
    /// U+3131, 3132, 3134, 3137, 3138, 3139, 3141, 3142, 3143, 3145, 3146, 3147, 3148, 3149, 314A, 314B, 314C, 314D, 314E.
    private static let initialConsonants: [Character] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ].map { Character(Unicode.Scalar($0 as UInt32)!) }
    private static let unknownInitial: Character = "\u{25CB}"

    /// One initial consonant per character; a letter or digit that is not Hangul is "○"; spaces dropped.
    static func initials(_ word: String) -> String {
        String(word.filter { !$0.isWhitespace }.map { c -> Character in
            guard let v = c.unicodeScalars.first?.value else { return unknownInitial }
            if (0xAC00...0xD7A3).contains(v) { return initialConsonants[Int(v - 0xAC00) / 588] }
            if (0x1100...0x1112).contains(v) { return initialConsonants[Int(v - 0x1100)] }
            return unknownInitial
        })
    }

    /// What the hints show `elapsed` seconds after drawing began.
    static func hints(elapsed: TimeInterval, word: String) -> (letters: Int?, initials: String?) {
        (elapsed >= lettersHintSeconds ? letters(word) : nil, elapsed >= initialsHintSeconds ? initials(word) : nil)
    }

    // MARK: Transitions

    private static func drawer(_ s: PlazaGameState) -> String? {
        guard let d = s.draw, s.endedAt == nil, d.order.indices.contains(d.turn) else { return nil }
        return d.order[d.turn]
    }

    /// The drawer opened the word field.
    static func opened(_ s: PlazaGameState, by me: String, at t: Double) -> PlazaGameState? {
        guard var d = s.draw, drawer(s) == me, d.entryAt == nil, d.drawAt == nil else { return nil }
        d.entryAt = t
        return stepped(s, d)
    }

    /// The drawer set a word; drawing begins.
    static func wordSet(_ s: PlazaGameState, by me: String, at t: Double) -> PlazaGameState? {
        guard var d = s.draw, drawer(s) == me, d.entryAt != nil, d.drawAt == nil else { return nil }
        d.drawAt = t
        return stepped(s, d)
    }

    /// The drawer publishes a hint it had not yet. nil when it adds nothing.
    static func hinted(_ s: PlazaGameState, by me: String, letters: Int?, initials: String?) -> PlazaGameState? {
        guard var d = s.draw, drawer(s) == me, d.drawAt != nil else { return nil }
        var changed = false
        if let letters, d.letters == nil { d.letters = letters; changed = true }
        if let initials, d.initials == nil { d.initials = initials; changed = true }
        return changed ? stepped(s, d) : nil
    }

    private static func stepped(_ s: PlazaGameState, _ d: PlazaDrawState) -> PlazaGameState {
        var next = s
        next.draw = d
        next.draw?.step += 1
        return next
    }

    /// Ends the current turn: the result, the scores, and the next turn whose drawer is in `playing` (turns of drawers
    /// who are not are skipped, once each). With no such turn, or fewer than two in `playing`, the game ends at `t`
    /// (`endedAt`; `winner` is the single top scorer, nil on a tie).
    static func ended(_ s: PlazaGameState, word: String?, solver: String?, playing: Set<String>, at t: Double) -> PlazaGameState {
        guard var d = s.draw, d.order.indices.contains(d.turn) else { return s }
        let who = d.order[d.turn]
        if let solver, s.players.contains(solver) {
            d.scores[solver, default: 0] += guessPoints
            d.scores[who, default: 0] += drawerPoints
        }
        d.last = .init(turn: d.turn, drawer: who, word: word, solver: solver)
        d.entryAt = nil; d.drawAt = nil; d.letters = nil; d.initials = nil
        var next = s
        if playing.count >= 2, let i = (d.turn + 1..<d.order.count).first(where: { playing.contains(d.order[$0]) }) {
            d.turn = i
        } else {
            d.turn = d.order.count
            next.endedAt = t
            let top = s.players.map { d.scores[$0] ?? 0 }.max() ?? 0
            let leaders = s.players.filter { (d.scores[$0] ?? 0) == top }
            next.winner = leaders.count == 1 ? leaders[0] : nil
        }
        d.step += 1
        next.draw = d
        return next
    }

    // MARK: Received payload

    /// Bounds on a received payload. nil drops the whole game state. A word that fails its bounds is only removed.
    static func accepted(_ d: PlazaDrawState, players: [String]) -> PlazaDrawState? {
        let known = Set(players)
        guard (1...maxTurns).contains(d.order.count), d.order.allSatisfy(known.contains),
              (0...d.order.count).contains(d.turn), d.step >= 0, d.step <= 1_000_000,
              d.scores.allSatisfy({ known.contains($0.key) && (0...(d.order.count * 10)).contains($0.value) }),
              d.entryAt.map(\.isFinite) ?? true, d.drawAt.map(\.isFinite) ?? true,
              d.letters.map({ (0...maxWordCharacters).contains($0) }) ?? true,
              (d.initials?.count ?? 0) <= maxWordCharacters, (d.initials?.utf8.count ?? 0) <= maxWordBytes else { return nil }
        var kept = d
        if let r = d.last {
            guard (0..<d.order.count).contains(r.turn), known.contains(r.drawer), r.solver.map(known.contains) ?? true else { return nil }
            if let w = r.word, word(w) != w { kept.last?.word = nil }
        }
        return kept
    }

    // MARK: Ordering and standings

    /// For `PlazaGame.precedes`: [turn, step, 1 if last?.word != nil else 0]; [-1, -1, -1] for no payload.
    static func keys(_ d: PlazaDrawState?) -> [Double] {
        guard let d else { return [-1, -1, -1] }
        return [Double(d.turn), Double(d.step), d.last?.word != nil ? 1 : 0]
    }

    /// Score descending, then id.
    static func ranking(_ s: PlazaGameState) -> [(id: String, score: Int)] {
        s.players.map { (id: $0, score: s.draw?.scores[$0] ?? 0) }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }
}
