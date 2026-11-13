import Foundation

struct TeamHello: Codable, Equatable, Sendable {
    var memberID: String
    var nickname: String
    var protocolVersion: Int
    /// The plaza character (not necessarily the member's current companion elsewhere).
    var current: TeamMonSummary
}

/// Token totals a member shows teammates in the plaza roster. Tokens only: never cost or limits.
struct TeamUsage: Codable, Equatable, Sendable {
    var today: Int
    var week: Int
    var month: Int

    /// Larger than any real total, and short enough to fit the roster when shown ("999.99B").
    static let maxTokens = 999_990_000_000

    /// What a teammate sent, each total kept within 0...`maxTokens`.
    var bounded: TeamUsage {
        func keep(_ n: Int) -> Int { min(max(n, 0), Self.maxTokens) }
        return TeamUsage(today: keep(today), week: keep(week), month: keep(month))
    }
}

/// Where a member is in the plaza and how they look, and their token totals. Nothing about cost, limits or the Mac.
struct TeamPresence: Codable, Equatable, Sendable {
    var nickname: String
    var character: TeamMonSummary
    var inPlaza: Bool
    var tile: TilePoint?
    var facing: PlazaDirection?
    var isWalking: Bool
    /// No keyboard or mouse input for a while. Left out when false, so earlier versions read the frame as before.
    var isIdle: Bool?
    /// The name colour the member picked (an RGB value from the plaza palette). Left out when none was picked;
    /// earlier versions ignore it and keep the colour from the member ID.
    var nameColor: UInt32?
    /// Running (Shift) on the current step. Left out when false; earlier versions ignore it and follow at walking pace.
    var isRunning: Bool?
    /// The latest plaza item slot this member knows was taken (`PlazaItems`), by them or anyone. Every member
    /// passes it on, so a plaza opened after the picker left still hides that item. Left out when none; earlier
    /// versions ignore it.
    var takenItemSlot: Int?
    /// When this member's campfire focus ends. Left out when not focusing; earlier versions ignore it. A receiver
    /// keeps it only inside `PlazaFocus.accepted`'s window.
    var focusEndsAt: Date?
    /// Diving in the plaza pond. Left out when not diving; earlier versions ignore it.
    var isDiving: Bool?
    /// The evolution stage of the shown Pokemon. Left out at stage 1; a receiver keeps it within 1...3.
    var evolutionStage: Int?
    /// The team's plaza schedule as this member knows it. Left out when never changed; earlier versions ignore it.
    @LossyOptional var schedule: PlazaSchedule?
    /// The plaza Ditto, sent only by the member who hosts it. Left out otherwise; unreadable or earlier-version
    /// values become nil without hurting the rest of the frame.
    @LossyOptional var ditto: PlazaDittoState?
    /// My plaza window is open and runs the Ditto. Left out when false.
    @LossyOptional var dittoReady: Bool?
    /// A Ditto's disguise: the member whose real look the sender shows in the plaza. Left out when not disguised;
    /// earlier versions ignore it and draw a Ditto.
    @LossyOptional var mimicOf: String?
    /// The last plaza ice break this member knows. Every member passes it on. Left out when none.
    @LossyOptional var iceBreak: PlazaIceBreak?
    /// The sender's token totals for today, this week and this month. Left out until their first usage reading;
    /// earlier versions leave it out and ignore it.
    @LossyOptional var usage: TeamUsage?
}

/// 읽을 수 없는 값(나중 버전의 모양, 잘못된 값)을 nil 로 읽는 선택값. 이 필드만 너그럽고 나머지 필드는 합성 Codable 그대로라,
/// 새 필드를 더해도 키 목록이나 `init(from:)` 을 따로 고칠 일이 없다. nil 은 인코딩에서 빠진다.
@propertyWrapper
struct LossyOptional<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode(Value.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    /// 키가 없어도 nil 로 읽는다(합성 디코더는 이 오버로드를 고른다).
    func decode<V>(_ type: LossyOptional<V>.Type, forKey key: Key) throws -> LossyOptional<V> {
        (try? decodeIfPresent(type, forKey: key)) ?? LossyOptional(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    /// nil 이면 키를 쓰지 않아 이전 버전이 프레임을 전과 같이 읽는다.
    mutating func encode<V>(_ value: LossyOptional<V>, forKey key: Key) throws {
        if value.wrappedValue != nil { try encode(value.wrappedValue, forKey: key) }
    }
}

enum TeamEmoteKind: String, Codable, CaseIterable, Sendable {
    case heart, lol, party, exclaim, question
    /// 몸통박치기 (Space menu): the target's Mac moves the target one tile away from the sender. Earlier versions
    /// cannot decode it and skip the frame. With target `PlazaDitto.sceneKey` it hit the Ditto in its own form: the
    /// Ditto's host turns it into the sender, and nobody is pushed. Versions before that skip such a tackle.
    case tackle
    /// 점프 (J): the sender hops with dust at its feet. Earlier versions skip it the same way.
    case jump
    /// 단체 사진 (G): a five-second countdown starts on every open plaza, ending in a flash. Earlier versions skip it.
    case groupPhoto
    /// The sender picked up the plaza item of `TeamEmote.itemSlot`, so it is gone for everyone. Earlier versions skip it.
    case pickup
    /// 불꽃놀이 (F): one shell of `TeamEmote.fireworkStyle` rises from the sender and bursts. Earlier versions skip it.
    case firework
    /// 춤 (D): the sender dances one round of `TeamEmote.danceStyle`. A looping dancer sends one per round. Earlier versions
    /// skip it. The ♪ bubble the plaza shows over every dancer is drawn from this kind but is never sent.
    case dance
    /// Someone found the Ditto copy of `TeamEmote.targetMemberID`. Earlier versions skip it.
    case decoyFound
    /// The Ditto copy jumped. Earlier versions skip it.
    case decoyJump
    /// The Ditto copy tackled `TeamEmote.targetMemberID`, sent by the Ditto's host. The target's Mac moves the target one tile
    /// away from the copy. Earlier versions skip it.
    case decoyTackle
    /// 물귀신 (C while diving): the sender surfaces and drags the target, on the shore beside it, into the water. The target's Mac
    /// moves the target. Earlier versions skip it.
    case pull
    /// 눈뭉치 (V on snow days): one ball along `TeamEmote.snowballDirection`. `targetMemberID` is the member or `PlazaDitto.sceneKey` it hits,
    /// nil on a miss; `pushTiles` as for a tackle. The hit Mac pushes itself when the ball lands. Earlier versions skip it.
    case snowball
    /// A Ditto teammate's 몸통박치기 on `targetMemberID`: lunge and star, nobody is pushed. Its presence's `mimicOf` says what it
    /// did to the sender's disguise; the target's Mac reveals the target if disguised. Earlier versions skip it.
    case mimicTackle
    /// The sender's disguise was found by `targetMemberID`. Sent before the presence that drops `mimicOf`. Earlier versions skip it.
    case mimicFound
    /// 기도 (A while an egg): the sender prayed over its own egg. Shown as a bubble over the sender with a wobble, and only
    /// while the sender is an egg. The prayer count lives in the sender's save and is never sent. Earlier versions skip it.
    case pray

    var notifiesTarget: Bool {
        switch self {
        case .heart, .lol, .party: true
        case .exclaim, .question, .tackle, .jump, .groupPhoto, .pickup, .firework, .dance, .decoyFound, .decoyJump, .decoyTackle, .pull, .snowball, .mimicTackle, .mimicFound, .pray: false
        }
    }

    /// The sender did something else, so their plaza dance stops. `decoyJump` is sent by the Ditto host for the copy, not by the
    /// host acting; `groupPhoto` keeps the dance like photo mode does; `pickup` only follows a walk, which already stopped it.
    /// A new kind must choose.
    var endsSendersDance: Bool {
        switch self {
        case .heart, .lol, .party, .exclaim, .question, .tackle, .jump, .firework, .decoyFound, .snowball, .mimicTackle, .pray: true
        case .groupPhoto, .pickup, .dance, .decoyJump, .decoyTackle, .pull, .mimicFound: false
        }
    }
}

struct TeamEmote: Codable, Equatable, Sendable {
    var kind: TeamEmoteKind
    var targetMemberID: String?
    /// A greeting (Space beside a teammate): the bubble shows over the target too. Left out when false, so
    /// earlier versions read it as an ordinary emote over the sender.
    var isShared: Bool?
    /// A tackle: how many tiles the target slides, the tackler's evolution stage. Left out for one tile, which is
    /// all that earlier versions push, so they read the same thing.
    var pushTiles: Int?

    /// A pickup: the item slot that was picked up.
    var itemSlot: Int?

    /// A firework: the `PlazaFireworkStyle.id` to burst. A style this version does not know becomes the default one.
    var fireworkStyle: String?

    /// A dance: the `PlazaDance.Style.id` to dance. A style this version does not know becomes the first one.
    var danceStyle: String?
    /// A dance: when the sender began dancing (seconds since 1970), the same in every round until they stop. Teammates
    /// dancing close together follow whoever began first. Left out by earlier versions.
    var danceSince: Double?
    /// A greeting aimed at the Ditto copy. Left out when false.
    var overDecoy: Bool?
    /// A snowball: the way it was thrown. Left out by every other kind.
    var snowballDirection: PlazaDirection?
    /// A jump that breaks the plaza ice: the broken pond and the breaker's wall clock (§6). Left out by every other jump and kind; earlier
    /// versions see a plain jump. Unreadable values become nil.
    @LossyOptional var iceBreak: PlazaIceBreak?

    /// A tackle pushes one to three tiles, like the three evolution stages.
    static let pushTileRange = 1...3
    /// `n` (a stage, or what a teammate sent) kept within `pushTileRange`. Left out means one tile.
    static func pushTiles(_ n: Int?) -> Int {
        min(max(n ?? 1, pushTileRange.lowerBound), pushTileRange.upperBound)
    }
}

/// A short line said in the plaza. It is shown for a moment and never stored or forwarded.
struct TeamChat: Codable, Equatable, Sendable {
    /// v2.5.607 and earlier cut at 40 and drop a received line that is longer, so they do not show 41 to 60.
    static let maxCharacters = 60
    /// One Character can hold any number of combining marks, so the Character count bounds nothing.
    static let maxBytes = 480
    var text: String
    /// A megaphone line: teammates outside the plaza get a notification too. Left out when false, so earlier
    /// versions read it as an ordinary line.
    var isLoud: Bool?

    /// One line ready to send: line breaks and invisible controls become spaces, the ends are trimmed, and it
    /// is cut to `maxCharacters` and `maxBytes`. nil when nothing is left. A received line must already be in this form.
    static func prepared(_ raw: String) -> String? {
        let line = String(raw.map { isControl($0) ? " " : $0 })
        var text = String(line.trimmingCharacters(in: .whitespaces).prefix(maxCharacters))
        while text.utf8.count > maxBytes { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A format character alone is a Character of its own (zero-width space, text direction override).
    /// Inside an emoji sequence it is part of a longer Character and stays.
    private static func isControl(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        return c.isNewline || scalars.contains { $0.properties.generalCategory == .control }
            || (scalars.count == 1 && scalars.first?.properties.generalCategory == .format)
    }
}

/// Messages peers exchange. `live` is true for something that just happened (publish/react),
/// false for a sync response; receivers decide pop-ins/bubbles from `live` only, never from clocks.
enum TeamMessage: Codable, Equatable, Sendable {
    case hello(TeamHello)
    case inventory(eventIDs: [String], reactionIDs: [String])
    case events([TeamEvent], live: Bool)
    case reactions([TeamReaction], live: Bool)
    case profileRequest
    case profile(TeamMemberProfile)
    case presence(TeamPresence)
    case emote(TeamEmote)
    case chat(TeamChat)
}

enum TeamWire {
    /// Changing any raw value or case name on the wire needs a bump here (`TeamWireTests` pins them).
    static let protocolVersion = 1
    static let maxFrameBytes = 1_048_576
    /// The longest ID, species name, form or date a peer may send. A real one is far shorter. Rows stay small enough
    /// that a batch always fits in a frame; one row too big used to stop its whole batch from syncing.
    static let maxFieldBytes = 64

    enum WireError: Error { case frameTooLarge, malformed }

    /// The top-level key of an encoded `TeamMessage`.
    private static let knownKinds: Set<String> = [
        "hello", "inventory", "events", "reactions", "profileRequest", "profile", "presence", "emote", "chat",
    ]

    /// 4-byte big-endian length + JSON. Dates use Foundation's default (exact Double seconds).
    static func encode(_ m: TeamMessage) throws -> Data {
        let body = try JSONEncoder().encode(m)
        guard body.count <= maxFrameBytes else { throw WireError.frameTooLarge }
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    /// Decodes without touching the content, so any JSON value fits.
    private struct Anything: Decodable {}

    /// One list item that may be of a kind this version does not know; it decodes to nil instead of failing.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct LossyList<T: Decodable>: Decodable {
        let items: [Lossy<T>]
        let live: Bool
        private enum CodingKeys: String, CodingKey { case items = "_0", live }
    }

    /// nil means a message kind this version does not know: the frame is skipped, the link stays.
    private static func decode(_ body: Data) throws -> TeamMessage? {
        let decoder = JSONDecoder()
        guard let keys = try? decoder.decode([String: Anything].self, from: body), keys.count == 1,
              let kind = keys.keys.first else { throw WireError.malformed }
        guard knownKinds.contains(kind) else { return nil }
        do {
            switch kind {
            case "events":
                let frame = try decoder.decode([String: LossyList<TeamEvent>].self, from: body)["events"]
                return frame.map { .events($0.items.compactMap(\.value), live: $0.live) }
            case "reactions":
                let frame = try decoder.decode([String: LossyList<TeamReaction>].self, from: body)["reactions"]
                return frame.map { .reactions($0.items.compactMap(\.value), live: $0.live) }
            default:
                return try decoder.decode(TeamMessage.self, from: body)
            }
        } catch {
            // Presence (apart from the plaza schedule it carries), emotes and chat are ephemeral, so a value a later version added (an
            // emote kind, a direction) is skipped like an unknown key instead of cooling the sender down.
            if kind == "presence" || kind == "emote" || kind == "chat" { return nil }
            throw WireError.malformed
        }
    }

    struct FrameDecoder {
        private var buffer = Data()

        mutating func append(_ chunk: Data) throws -> [TeamMessage] {
            buffer.append(chunk)
            var out: [TeamMessage] = []
            while buffer.count >= 4 {
                let s = buffer.startIndex
                let length = buffer[s..<s + 4].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= TeamWire.maxFrameBytes else { throw WireError.frameTooLarge }
                guard buffer.count >= 4 + length else { break }
                let body = buffer[s + 4..<s + 4 + length]
                buffer = Data(buffer[(s + 4 + length)...])
                if let message = try TeamWire.decode(Data(body)) { out.append(message) }
            }
            return out
        }
    }
}
