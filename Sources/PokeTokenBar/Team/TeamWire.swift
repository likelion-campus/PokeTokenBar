import Foundation

struct TeamHello: Codable, Equatable, Sendable {
    var memberID: String
    var nickname: String
    var protocolVersion: Int
    /// The plaza character (not necessarily the member's current companion elsewhere).
    var current: TeamMonSummary
}

/// Where a member is in the plaza and how they look. Plaza fields only: nothing about usage or the Mac.
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
    /// The latest plaza item slot this member picked up (`PlazaItems`), so a plaza opened later hides that item.
    /// Left out when none; earlier versions ignore it.
    var pickedItemSlot: Int?
}

enum TeamEmoteKind: String, Codable, CaseIterable, Sendable {
    case heart, lol, party, exclaim, question
    /// 몸통박치기 (Space menu): the target's Mac moves the target one tile away from the sender. Earlier versions
    /// cannot decode it and skip the frame.
    case tackle
    /// 점프 (J): the sender hops with dust at its feet. Earlier versions skip it the same way.
    case jump
    /// 단체 사진 (G): a five-second countdown starts on every open plaza, ending in a flash. Earlier versions skip it.
    case groupPhoto
    /// The sender picked up the plaza item of `TeamEmote.itemSlot`, so it is gone for everyone. Earlier versions skip it.
    case pickup

    var notifiesTarget: Bool {
        switch self {
        case .heart, .lol, .party: true
        case .exclaim, .question, .tackle, .jump, .groupPhoto, .pickup: false
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
            // Presence, emotes and chat are ephemeral and never stored, so a value a later version added (an
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
