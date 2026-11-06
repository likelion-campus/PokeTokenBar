import Foundation
@testable import PokeTokenBar

/// One simulated connection between two fake transports.
@MainActor
final class FakeConnection {
    let initiator: FakeTeamTransport
    let acceptor: FakeTeamTransport
    let initiatorPeer: TeamPeerID
    let acceptorPeer: TeamPeerID

    init(initiator: FakeTeamTransport, acceptor: FakeTeamTransport, initiatorPeer: TeamPeerID, acceptorPeer: TeamPeerID) {
        self.initiator = initiator
        self.acceptor = acceptor
        self.initiatorPeer = initiatorPeer
        self.acceptorPeer = acceptorPeer
    }

    func peerID(on transport: FakeTeamTransport) -> TeamPeerID {
        transport === initiator ? initiatorPeer : acceptorPeer
    }
}

/// Connects fake transports in memory. Messages and callbacks are queued and drained in order, so a
/// callback never runs inside the call that caused it.
@MainActor
final class FakeTransportHub {
    struct DisconnectCall: Equatable {
        let peer: TeamPeerID
        let kept: TeamPeerID?
    }

    private var queue: [() -> Void] = []
    private var draining = false
    private var holding = false
    private var counter = 0

    func makeTransport() -> FakeTeamTransport { FakeTeamTransport(hub: self) }

    /// Both sides see a new connection; the dialing side reports `initiatedByMe`.
    @discardableResult
    func connect(_ initiator: FakeTeamTransport, to acceptor: FakeTeamTransport) -> FakeConnection {
        counter += 1
        let connection = FakeConnection(initiator: initiator, acceptor: acceptor,
                                        initiatorPeer: "conn\(counter)-i", acceptorPeer: "conn\(counter)-a")
        initiator.links[connection.initiatorPeer] = connection
        acceptor.links[connection.acceptorPeer] = connection
        holding = true
        initiator.onPeerConnected?(connection.initiatorPeer, true)
        acceptor.onPeerConnected?(connection.acceptorPeer, false)
        holding = false
        drain()
        return connection
    }

    /// The one connection `transport` has.
    func connection(of transport: FakeTeamTransport) -> FakeConnection { transport.links.values.first! }

    /// The connection ends and both sides are told.
    func disconnect(_ connection: FakeConnection) {
        for side in [connection.initiator, connection.acceptor] {
            guard side.links.removeValue(forKey: connection.peerID(on: side)) != nil else { continue }
            let peer = connection.peerID(on: side)
            enqueue { side.onPeerDisconnected?(peer) }
        }
        drain()
    }

    /// `transport` forgets the connection without a callback and the other side is never told
    /// (a dead link that still looks alive over there).
    func sever(_ connection: FakeConnection, silentlyOn transport: FakeTeamTransport) {
        transport.links[connection.peerID(on: transport)] = nil
    }

    func enqueue(_ work: @escaping () -> Void) {
        queue.append(work)
        drain()
    }

    private func drain() {
        guard !draining, !holding else { return }
        draining = true
        while !queue.isEmpty { queue.removeFirst()() }
        draining = false
    }
}

@MainActor
final class FakeTeamTransport: TeamTransporting {
    var onPeerConnected: ((TeamPeerID, Bool) -> Void)?
    var onPeerDisconnected: ((TeamPeerID) -> Void)?
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)?
    var onPeerBadFrame: ((TeamPeerID) -> Void)?

    private unowned let hub: FakeTransportHub
    fileprivate var links: [TeamPeerID: FakeConnection] = [:]

    private(set) var isRunning = false
    private(set) var startedCodes: [TeamCode] = []
    private(set) var stopCount = 0
    private(set) var sent: [(peer: TeamPeerID, message: TeamMessage)] = []
    private(set) var disconnectCalls: [FakeTransportHub.DisconnectCall] = []
    private(set) var refuseCalls: [TeamPeerID] = []

    fileprivate init(hub: FakeTransportHub) { self.hub = hub }

    var linkCount: Int { links.count }
    var peerIDs: [TeamPeerID] { Array(links.keys) }
    func hasLink(_ connection: FakeConnection) -> Bool { links[connection.peerID(on: self)] === connection }

    func sentMessages(where match: (TeamMessage) -> Bool) -> Int { sent.filter { match($0.message) }.count }

    func start(code: TeamCode) {
        if isRunning { tearDown() }
        isRunning = true
        startedCodes.append(code)
    }

    func stop() {
        stopCount += 1
        tearDown()
        isRunning = false
    }

    func send(_ m: TeamMessage, to peer: TeamPeerID) {
        guard let connection = links[peer] else { return }
        sent.append((peer, m))
        let other = connection.initiator === self ? connection.acceptor : connection.initiator
        let otherPeer = connection.peerID(on: other)
        hub.enqueue {
            // A link the other side already forgot swallows the message.
            guard other.links[otherPeer] === connection else { return }
            other.onMessage?(otherPeer, m)
        }
    }

    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?) {
        disconnectCalls.append(.init(peer: peer, kept: kept))
        guard let connection = links.removeValue(forKey: peer) else { return }
        notifyOtherSide(of: connection)
    }

    func refuse(_ peer: TeamPeerID) {
        refuseCalls.append(peer)
        guard let connection = links.removeValue(forKey: peer) else { return }
        notifyOtherSide(of: connection)
    }

    /// Silent for this side; the other side sees the socket close.
    private func tearDown() {
        let old = links.values
        links = [:]
        for connection in old { notifyOtherSide(of: connection) }
    }

    private func notifyOtherSide(of connection: FakeConnection) {
        let other = connection.initiator === self ? connection.acceptor : connection.initiator
        let otherPeer = connection.peerID(on: other)
        guard other.links[otherPeer] === connection else { return }
        other.links[otherPeer] = nil
        hub.enqueue { other.onPeerDisconnected?(otherPeer) }
    }
}
