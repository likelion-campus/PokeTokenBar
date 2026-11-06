import XCTest
import Network
@testable import PokeTokenBar

@MainActor
final class TeamTransportTests: XCTestCase {
    private var transports: [BonjourTeamTransport] = []

    override func tearDown() async throws {
        for t in transports { t.stop() }
        transports = []
    }

    private func makeTransport(linkLimit: Int = BonjourTeamTransport.maxLinks) -> BonjourTeamTransport {
        let t = BonjourTeamTransport(advertise: false, linkLimit: linkLimit)
        transports.append(t)
        return t
    }

    /// Accepts TCP and never speaks TLS, like a rogue service holding a dial open.
    private func silentSink() async throws -> (listener: NWListener, endpoint: NWEndpoint) {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { $0.start(queue: .main) }
        listener.start(queue: .main)
        let ready = await waitUntil(5) { listener.port != nil && listener.port?.rawValue != 0 }
        XCTAssertTrue(ready)
        return (listener, .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)))
    }

    private func newCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func loopback(_ t: BonjourTeamTransport) async throws -> NWEndpoint {
        let ok = await waitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(ok, "listener did not become ready")
        return .hostPort(host: "127.0.0.1", port: try XCTUnwrap(t.listenerPort))
    }

    private let hello = TeamMessage.profileRequest

    func testSameCodePeersExchangeMessagesOverLoopback() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: (TeamPeerID, Bool)?, bPeer: (TeamPeerID, Bool)?
        var aGot: [TeamMessage] = [], bGot: [TeamMessage] = []
        a.onPeerConnected = { aPeer = ($0, $1) }
        b.onPeerConnected = { bPeer = ($0, $1) }
        a.onMessage = { _, m in aGot.append(m) }
        b.onMessage = { _, m in bGot.append(m) }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))

        let connected = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(connected)
        XCTAssertEqual(aPeer?.1, false)
        XCTAssertEqual(bPeer?.1, true)

        b.send(hello, to: try XCTUnwrap(bPeer).0)
        a.send(.emote(TeamEmote(kind: .heart, targetMemberID: nil)), to: try XCTUnwrap(aPeer).0)
        let delivered = await waitUntil(5) { !aGot.isEmpty && !bGot.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(aGot, [hello])
        XCTAssertEqual(bGot, [.emote(TeamEmote(kind: .heart, targetMemberID: nil))])
    }

    func testDifferentCodeNeverDeliversMessages() async throws {
        let a = makeTransport(), b = makeTransport()
        var events = 0
        for t in [a, b] {
            t.onPeerConnected = { _, _ in events += 1 }
            t.onMessage = { _, _ in events += 1 }
        }
        a.start(code: newCode()); b.start(code: newCode())
        b.connect(to: try await loopback(a))
        let leaked = await waitUntil(3) { events > 0 }
        XCTAssertFalse(leaked)
    }

    func testMalformedFrameDisconnects() async throws {
        let code = newCode()
        let a = makeTransport()
        var connected: TeamPeerID?, disconnected: TeamPeerID?
        a.onPeerConnected = { id, _ in connected = id }
        a.onPeerDisconnected = { disconnected = $0 }
        a.start(code: code)
        let endpoint = try await loopback(a)

        let raw = NWConnection(to: endpoint, using: BonjourTeamTransport.parameters(code: code))
        raw.start(queue: .main)
        defer { raw.cancel() }
        let up = await waitUntil(5) { connected != nil }
        XCTAssertTrue(up)
        raw.send(content: Data([0xFF, 0xFF, 0xFF, 0xFF]), completion: .idempotent)
        let dropped = await waitUntil(5) { disconnected != nil }
        XCTAssertTrue(dropped)
        XCTAssertEqual(disconnected, connected)
    }

    func testStopSilencesCallbacks() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var aEvents = 0
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))
        let up = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.onMessage = { _, _ in aEvents += 1 }
        a.onPeerDisconnected = { _ in aEvents += 1 }
        a.stop()
        b.send(hello, to: try XCTUnwrap(bPeer))
        let leaked = await waitUntil(1) { aEvents > 0 }
        XCTAssertFalse(leaked)
    }

    func testDisconnectIsSilentAndUnknownPeerIsNoOp() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var bDisconnected = false, aDisconnected = false
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.onPeerDisconnected = { _ in aDisconnected = true }
        b.onPeerDisconnected = { _ in bDisconnected = true }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))
        let up = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.disconnect("no-such-peer", coveredBy: nil)
        XCTAssertFalse(aDisconnected)
        a.disconnect(try XCTUnwrap(aPeer), coveredBy: nil)
        let remoteSawIt = await waitUntil(5) { bDisconnected }
        XCTAssertTrue(remoteSawIt)
        XCTAssertFalse(aDisconnected, "owner-initiated disconnect is not reported back")
    }

    func testSleepReportsDisconnectsAndWakeRestartsOnlyRunningTransport() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var aDown: [TeamPeerID] = []
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.onPeerDisconnected = { aDown.append($0) }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))
        let up = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.handleWillSleep()
        XCTAssertEqual(aDown, [try XCTUnwrap(aPeer)])
        XCTAssertNil(a.listenerPort)

        a.handleDidWake()
        let back = await waitUntil(5) { a.listenerPort != nil }
        XCTAssertTrue(back, "wake restarts a transport that was running")

        a.stop()
        a.handleDidWake()
        XCTAssertNil(a.listenerPort, "wake must not restart a transport the owner stopped")
    }

    func testOwnerStoppingInsideDisconnectCallbackPreventsRestart() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))
        let up = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.onPeerDisconnected = { _ in a.stop() }
        a.restart()
        a.handleDidWake()
        let came = await waitUntil(0.5) { a.listenerPort != nil }
        XCTAssertFalse(came, "a transport stopped from the disconnect callback must stay stopped")
    }

    func testFailedBrowserRestartsLikeAFailedListener() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var aDown: [TeamPeerID] = []
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.onPeerDisconnected = { aDown.append($0) }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await loopback(a))
        let up = await waitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.browserStateChanged(.ready)
        XCTAssertTrue(aDown.isEmpty, "a healthy browser changes nothing")
        a.browserStateChanged(.failed(.posix(.ECONNABORTED)))
        XCTAssertEqual(aDown, [try XCTUnwrap(aPeer)])
        XCTAssertNil(a.listenerPort)
        let back = await waitUntil(8) { a.listenerPort != nil }
        XCTAssertTrue(back, "the transport comes back by itself after the retry delay")
    }

    func testUnfinishedInboundLinksAreCapped() async throws {
        let a = makeTransport()
        a.start(code: newCode())
        _ = try await loopback(a)
        let port = try XCTUnwrap(a.listenerPort)
        // Plain TCP never completes the TLS-PSK handshake, so every one of these stays unfinished.
        let raw = (0..<(BonjourTeamTransport.maxUnfinishedInbound + 8)).map { _ in
            NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        }
        defer { raw.forEach { $0.cancel() } }
        raw.forEach { $0.start(queue: .main) }
        let full = await waitUntil(5) { a.linkCount >= BonjourTeamTransport.maxUnfinishedInbound }
        XCTAssertTrue(full)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(a.linkCount, BonjourTeamTransport.maxUnfinishedInbound)
    }

    /// Anyone on the network can advertise a thousand services without the team code. Before the cap every one
    /// was dialed at once, which took all 256 file handles an app gets: saves failed and no teammate could connect.
    func testDialsToRogueServicesAreCapped() async throws {
        let sink = try await silentSink()
        defer { sink.listener.cancel() }
        let a = makeTransport()
        a.start(code: newCode())
        for i in 0..<1000 { a.injectDiscovered("ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(a.linkCount, BonjourTeamTransport.maxUnfinishedOutbound)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(a.linkCount, BonjourTeamTransport.maxUnfinishedOutbound, "they stay unfinished, so nothing more is dialed")
    }

    func testDialsLeaveRoomForTheLinkLimit() async throws {
        let sink = try await silentSink()
        defer { sink.listener.cancel() }
        let a = makeTransport(linkLimit: 3)
        a.start(code: newCode())
        for i in 0..<10 { a.injectDiscovered("ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(a.linkCount, 3)
    }

    func testInboundLinksStopAtTheLinkLimit() async throws {
        let a = makeTransport(linkLimit: 2)
        a.start(code: newCode())
        _ = try await loopback(a)
        let port = try XCTUnwrap(a.listenerPort)
        let raw = (0..<6).map { _ in NWConnection(host: "127.0.0.1", port: port, using: .tcp) }
        defer { raw.forEach { $0.cancel() } }
        raw.forEach { $0.start(queue: .main) }
        let full = await waitUntil(5) { a.linkCount >= 2 }
        XCTAssertTrue(full)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(a.linkCount, 2)
    }

    /// The cap only counts unfinished dials, so a finished link leaves room for the next one.
    func testAFinishedLinkDoesNotUseUpADialSlot() async throws {
        let code = newCode()
        let server = makeTransport()
        server.start(code: code)
        let real = try await loopback(server)
        let a = makeTransport()
        a.start(code: code)
        var connected = 0
        a.onPeerConnected = { _, _ in connected += 1 }
        a.injectDiscovered("ptb-teammate", endpoint: real)
        let up = await waitUntil(5) { connected == 1 }
        XCTAssertTrue(up)
        let sink = try await silentSink()
        defer { sink.listener.cancel() }
        for i in 0..<100 { a.injectDiscovered("ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(a.linkCount, BonjourTeamTransport.maxUnfinishedOutbound + 1)
    }

    /// Two connected transports. Bytes written with `sendRaw` on the second reach the first.
    private func connectedPair() async throws -> (receiver: BonjourTeamTransport, sender: BonjourTeamTransport, peer: TeamPeerID) {
        let code = newCode()
        let receiver = makeTransport(), sender = makeTransport()
        receiver.start(code: code); sender.start(code: code)
        var peer: TeamPeerID?
        sender.onPeerConnected = { id, _ in peer = id }
        sender.connect(to: try await loopback(receiver))
        let up = await waitUntil(5) { peer != nil && receiver.linkCount == 1 }
        XCTAssertTrue(up)
        return (receiver, sender, try XCTUnwrap(peer))
    }

    /// Big frames decode on the main thread, so a link pouring them in would hold it for as long as it liked.
    func testALinkPouringInBytesIsDropped() async throws {
        let (receiver, sender, peer) = try await connectedPair()
        var bad = 0
        receiver.onPeerBadFrame = { _ in bad += 1 }
        let id = String(repeating: "x", count: 1_000_000)
        let frame = try TeamWire.encode(.inventory(eventIDs: [id], reactionIDs: []))
        for _ in 0..<6 { sender.sendRaw(frame, to: peer) }
        let dropped = await waitUntil(5) { bad == 1 }
        XCTAssertTrue(dropped)
        XCTAssertEqual(receiver.linkCount, 0)
    }

    /// Small frames cost little to send and more to handle, so each one counts for more than its bytes.
    func testALinkPouringInTinyFramesIsDropped() async throws {
        let (receiver, sender, peer) = try await connectedPair()
        var delivered = 0, bad = 0
        receiver.onMessage = { _, _ in delivered += 1 }
        receiver.onPeerBadFrame = { _ in bad += 1 }
        let frame = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        let flood = Data(repeating: 0, count: 0) + (0..<6000).reduce(into: Data()) { d, _ in d.append(frame) }
        sender.sendRaw(flood, to: peer)
        let dropped = await waitUntil(5) { bad == 1 }
        XCTAssertTrue(dropped)
        XCTAssertLessThan(delivered, 6000, "the rest of a flood is not handled")
    }

    /// What an honest app sends at its busiest: a full sync, well under the burst, then a run across the plaza.
    func testASyncAndARunAreNotDropped() async throws {
        let (receiver, sender, peer) = try await connectedPair()
        var bad = 0, delivered = 0
        receiver.onPeerBadFrame = { _ in bad += 1 }
        receiver.onMessage = { _, _ in delivered += 1 }
        let row = TeamReaction(id: UUID().uuidString, eventID: UUID().uuidString, authorID: UUID().uuidString,
                               authorNickname: "닉네임", kind: .cute, text: nil, createdAt: Date())
        let batch = try TeamWire.encode(.reactions(Array(repeating: row, count: TeamSession.batchSize), live: false))
        for _ in 0..<33 { sender.sendRaw(batch, to: peer) }
        let moved = TeamPresence(nickname: "닉네임", character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                 inPlaza: true, tile: TilePoint(x: 3, y: 3), facing: .down, isWalking: true)
        let step = try TeamWire.encode(.presence(moved))
        for _ in 0..<300 { sender.sendRaw(step, to: peer) }
        let all = await waitUntil(5) { delivered == 333 }
        XCTAssertTrue(all)
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(receiver.linkCount, 1)
    }

    func testFailedDialIsClosedAndWaitsForCooldown() async throws {
        let a = makeTransport(), b = makeTransport()
        a.start(code: newCode()); b.start(code: newCode())
        b.injectDiscovered("x", endpoint: try await loopback(a))
        XCTAssertEqual(b.linkCount, 1)

        let later = Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
        let failed = await waitUntil(5) { b.plannedDials(now: later) == ["x"] }
        XCTAssertTrue(failed, "the failed dial should end and become due again after the cooldown")
        XCTAssertEqual(b.linkCount, 0)
        XCTAssertEqual(b.plannedDials(now: Date()), [], "no redial inside the cooldown")
    }

    func testDisconnectCoveredByKeptConnectionStopsRedialUntilKeptEnds() async throws {
        let code = newCode()
        let a = makeTransport(), b = makeTransport()
        var bPeers: [TeamPeerID] = []
        b.onPeerConnected = { id, _ in bPeers.append(id) }
        a.start(code: code); b.start(code: code)
        let endpoint = try await loopback(a)
        b.injectDiscovered("x", endpoint: endpoint)
        let first = await waitUntil(5) { bPeers.count == 1 }
        XCTAssertTrue(first)
        b.connect(to: endpoint)
        let second = await waitUntil(5) { bPeers.count == 2 }
        XCTAssertTrue(second)

        b.disconnect(bPeers[0], coveredBy: bPeers[1])
        XCTAssertEqual(b.plannedDials(now: Date()), [])
        b.disconnect(bPeers[1], coveredBy: nil)
        XCTAssertEqual(b.plannedDials(now: Date()), ["x"])
    }
}
