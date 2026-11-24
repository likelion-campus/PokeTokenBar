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
    /// Bytes handed to a link and not yet taken by the socket, at most. Twice the receive burst: a full feed sync is about
    /// 2 MB and a link may ask for it three times in a row, so an honest receiver never has 8 MB waiting; only a peer
    /// that stopped reading does. The Windows loop has always enforced this; the Mac counts `contentProcessed` for it.
    static let maxQueuedBytes = 2 * Int(receiveBurst)
    /// Unfinished inbound links from one remote address. A handshake takes well under a second, so honest use is one
    /// per teammate dialing at that moment; 8 covers a team waking up behind one NAT, and a host that holds more
    /// leaves the other `maxUnfinishedInbound - 8` slots for everyone else.
    static let maxUnfinishedInboundPerAddress = 8
    /// Inbound links, finished or not, from one remote address. An app keeps one link per teammate (two while a
    /// duplicate is being closed), so 32 is sixteen teammates behind one NAT or VPN gateway: a quarter of `maxLinks`.
    static let maxLinksPerAddress = 32
    /// How long an address that was cut off for flooding stays penalised: a new link from it starts with the tokens
    /// it would have earned since, not with a full burst.
    static let floodPenaltyWindow: TimeInterval = 600
    /// Flooding addresses remembered at once (an IPv6 host can rotate through any number of addresses).
    static let maxRememberedFloods = 64
    /// Discovered service names kept at once, in the dial planner and in the Windows DNS-SD tables. One per running app
    /// on the network, of every team (the service type is shared), plus names that have not been withdrawn yet.
    static let maxDiscoveredNames = 1024

    /// The address without its port, brackets or scope (`fe80::1%en0`): one host is one key, whatever interface it came in on.
    static func addressKey(_ host: String) -> String {
        var h = Substring(host)
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") { h = h[h.index(after: h.startIndex)..<close] }
        if let percent = h.firstIndex(of: "%") { h = h[..<percent] }
        return h.lowercased()
    }

    /// The `count - limit` names with the oldest answer (never answered counts as oldest), to make room for new ones.
    static func evictionVictims(_ names: Set<String>, answeredAt: [String: Date], limit: Int) -> [String] {
        guard names.count > limit else { return [] }
        let sorted = names.sorted {
            let a = answeredAt[$0] ?? .distantPast, b = answeredAt[$1] ?? .distantPast
            return a == b ? $0 < $1 : a < b
        }
        return Array(sorted.prefix(names.count - limit))
    }

    /// `ptb-` and 12 lowercase hex digits: the DNS-SD instance name one run advertises.
    static func newInstanceName(_ uuid: UUID = UUID()) -> String {
        "ptb-" + String(uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// Whether a new inbound connection is kept: not at the link limit, not with too many unfinished already, and not
    /// with too many from the same remote address.
    static func admitsInbound(linkCount: Int, unfinishedInbound: Int, linkLimit: Int,
                              linksFromAddress: Int = 0, unfinishedFromAddress: Int = 0) -> Bool {
        !(linkCount >= linkLimit || unfinishedInbound >= maxUnfinishedInbound
          || linksFromAddress >= maxLinksPerAddress || unfinishedFromAddress >= maxUnfinishedInboundPerAddress)
    }

    /// How many more dials may start now. Never negative.
    static func dialRoom(unfinishedOutbound: Int, linkCount: Int, linkLimit: Int) -> Int {
        max(0, min(maxUnfinishedOutbound - unfinishedOutbound, linkLimit - linkCount))
    }
}

/// Which addresses were cut off for flooding, so a reconnect does not start with a fresh burst. Pure: the caller brings
/// the clock. Bounded: the oldest is forgotten past `maxRememberedFloods`.
struct TeamFloodMemory {
    private var floods: [String: Date] = [:]

    mutating func noteFlood(from address: String, now: Date) {
        floods[address] = now
        floods = floods.filter { now.timeIntervalSince($0.value) < TeamTransportRules.floodPenaltyWindow }
        if floods.count > TeamTransportRules.maxRememberedFloods,
           let oldest = floods.min(by: { $0.value < $1.value })?.key { floods[oldest] = nil }
    }

    /// Tokens a new link from `address` starts with: a full burst (nil), unless it was cut off for flooding lately, then
    /// what the link would have earned since.
    func startingTokens(for address: String?, now: Date) -> Double? {
        guard let address, let at = floods[address] else { return nil }
        let since = now.timeIntervalSince(at)
        guard since < TeamTransportRules.floodPenaltyWindow else { return nil }
        return max(since, 0) * TeamTransportRules.receivePerSecond
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
    private var budget: TeamTokenBucket

    init(startingTokens: Double? = nil) {
        budget = TeamTokenBucket(capacity: TeamTransportRules.receiveBurst, perSecond: TeamTransportRules.receivePerSecond,
                                 startingTokens: startingTokens)
    }

    /// Every frame is charged the frame cost, including the ones this version skips (a kind it does not know): they cost a
    /// parse all the same.
    mutating func receive(_ chunk: Data, now: Date) -> Outcome {
        let messages: [TeamMessage]
        do { messages = try decoder.append(chunk) } catch { return .badFrame("\(error)") }
        guard budget.take(Double(chunk.count + decoder.lastFrameCount * TeamTransportRules.frameCost), now: now) else { return .flood }
        return .messages(messages)
    }
}
