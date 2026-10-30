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
    static let protocolVersion = 1
    static let maxFrameBytes = 1_048_576

    enum WireError: Error { case frameTooLarge, malformed }

    /// 4-byte big-endian length + JSON. Dates use Foundation's default (exact Double seconds).
    static func encode(_ m: TeamMessage) throws -> Data {
        let body = try JSONEncoder().encode(m)
        guard body.count <= maxFrameBytes else { throw WireError.frameTooLarge }
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
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
                do {
                    out.append(try JSONDecoder().decode(TeamMessage.self, from: body))
                } catch {
                    throw WireError.malformed
                }
            }
            return out
        }
    }
}
