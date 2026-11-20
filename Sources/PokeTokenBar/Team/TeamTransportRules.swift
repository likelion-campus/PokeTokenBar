import Foundation

/// The decisions every team transport shares, so the Mac (Bonjour + Network.framework) and the Windows
/// (DNS-SD + Schannel) transports cannot drift apart. Pure: no sockets, no clock of its own.
enum TeamTransportRules {
    static let serviceType = "_ptbteam._tcp"
    static let handshakeTimeout: TimeInterval = 10
    static let redialInterval: TimeInterval = 15
    static let listenerRetryDelay: TimeInterval = 5
    /// Inbound links that have not finished their handshake. Anyone on the network can open these without
    /// the team code, so the rest are cancelled.
    static let maxUnfinishedInbound = 32
    /// Dials that have not finished their handshake. Anyone on the network can advertise any number of services
    /// without the team code, and every dial holds a file handle until it fails.
    static let maxUnfinishedOutbound = 32
    /// Links in any state. Each holds a file handle and an app starts with 256, which it also needs for its saves.
    static let maxLinks = 128
    /// What one link may send. An honest app sends a few KB a second and under 1 MB for a full sync, so only a flood
    /// reaches this, and a flood holds the main thread because that is where frames are decoded.
    static let receiveBurst = 4.0 * 1_048_576
    static let receivePerSecond = 256.0 * 1024
    /// Each frame counts for this many bytes on top of its own: tiny frames are cheap to send and not to handle.
    static let frameCost = 1024
    /// The most one read hands over at a time.
    static let maxReadChunk = 65_536

    /// `ptb-` and 12 lowercase hex digits: the DNS-SD instance name one run advertises.
    static func newInstanceName(_ uuid: UUID = UUID()) -> String {
        "ptb-" + String(uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// Whether a new inbound connection is kept: not at the link limit, and not with too many unfinished already.
    static func admitsInbound(linkCount: Int, unfinishedInbound: Int, linkLimit: Int) -> Bool {
        !(linkCount >= linkLimit || unfinishedInbound >= maxUnfinishedInbound)
    }

    /// How many more dials may start now. Never negative.
    static func dialRoom(unfinishedOutbound: Int, linkCount: Int, linkLimit: Int) -> Int {
        max(0, min(maxUnfinishedOutbound - unfinishedOutbound, linkLimit - linkCount))
    }
}

/// What one link's bytes turn into: frames first, then the rate budget. A bad frame is reported before any budget is spent.
struct TeamLinkReceiver {
    enum Outcome: Equatable {
        case messages([TeamMessage])
        case badFrame(String)
        case flood
    }

    private var decoder = TeamWire.FrameDecoder()
    private var budget = TeamTokenBucket(capacity: TeamTransportRules.receiveBurst, perSecond: TeamTransportRules.receivePerSecond)

    init() {}

    mutating func receive(_ chunk: Data, now: Date) -> Outcome {
        let messages: [TeamMessage]
        do { messages = try decoder.append(chunk) } catch { return .badFrame("\(error)") }
        guard budget.take(Double(chunk.count + messages.count * TeamTransportRules.frameCost), now: now) else { return .flood }
        return .messages(messages)
    }
}
