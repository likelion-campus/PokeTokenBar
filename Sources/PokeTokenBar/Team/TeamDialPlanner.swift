import Foundation

typealias TeamPeerID = String

/// Decides which discovered Bonjour endpoints to dial. Pure: no network, no clock of its own.
struct TeamDialPlanner {
    /// Wait after a failed handshake (wrong team code, unreachable) before dialing the same name again.
    static let handshakeRetryCooldown: TimeInterval = 60

    private struct Entry {
        var found = true
        var activePeer: TeamPeerID?
        var coveredBy: TeamPeerID?
        var retryAfter: Date?
    }

    private var entries: [String: Entry] = [:]
    /// Which endpoint name each dialed connection belongs to. Kept after the connection ends so that
    /// `cover` works in either order.
    private var nameForPeer: [TeamPeerID: String] = [:]

    mutating func discovered(_ name: String) {
        if entries[name] == nil { entries[name] = Entry() } else { entries[name]?.found = true }
    }

    mutating func lost(_ name: String) {
        entries[name]?.found = false
    }

    mutating func dialStarted(_ name: String, peer: TeamPeerID) {
        guard entries[name] != nil else { return }
        // Older dials of this name can no longer be covered; forget them.
        nameForPeer = nameForPeer.filter { $0.value != name }
        nameForPeer[peer] = name
        entries[name]?.activePeer = peer
    }

    mutating func connectionEnded(peer: TeamPeerID, handshakeFailed: Bool, now: Date) {
        for name in entries.keys where entries[name]?.coveredBy == peer { entries[name]?.coveredBy = nil }
        guard let name = nameForPeer[peer], entries[name]?.activePeer == peer else { return }
        entries[name]?.activePeer = nil
        if handshakeFailed { entries[name]?.retryAfter = now.addingTimeInterval(Self.handshakeRetryCooldown) }
    }

    /// `peer` is a duplicate of `kept`: do not dial its endpoint again while `kept` is alive.
    mutating func cover(peer: TeamPeerID, by kept: TeamPeerID) {
        guard let name = nameForPeer[peer] else { return }
        entries[name]?.coveredBy = kept
    }

    func dueDials(now: Date) -> [String] {
        entries.filter { name, e in
            e.found && e.activePeer == nil && e.coveredBy == nil && (e.retryAfter.map { now >= $0 } ?? true)
        }.keys.sorted()
    }
}
