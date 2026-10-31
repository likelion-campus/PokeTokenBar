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
}

enum TeamEmoteKind: String, Codable, CaseIterable, Sendable {
    case heart, lol, party, exclaim, question

    var notifiesTarget: Bool {
        switch self {
        case .heart, .lol, .party: true
        case .exclaim, .question: false
        }
    }
}

struct TeamEmote: Codable, Equatable, Sendable {
    var kind: TeamEmoteKind
    var targetMemberID: String?
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
}

enum TeamWire {
    /// Changing any raw value or case name on the wire needs a bump here (`TeamWireTests` pins them).
    static let protocolVersion = 1
    static let maxFrameBytes = 1_048_576

    enum WireError: Error { case frameTooLarge, malformed }

    /// The top-level key of an encoded `TeamMessage`.
    private static let knownKinds: Set<String> = [
        "hello", "inventory", "events", "reactions", "profileRequest", "profile", "presence", "emote",
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
            // Presence and emotes are ephemeral and never stored, so a value a later version added (an emote
            // kind, a direction) is skipped like an unknown key instead of cooling the sender down.
            if kind == "presence" || kind == "emote" { return nil }
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
