import XCTest
import Network
@testable import PokeTokenBar

/// The Network.framework side of the transport contract. The scenarios live in `TeamTransportContract.swift`.
@MainActor
final class MacTransportHarness: TeamTransportHarness {
    typealias Transport = BonjourTeamTransport
    typealias Endpoint = NWEndpoint

    private var transports: [BonjourTeamTransport] = []
    private let startedAt = Date()
    private var events: [String] = []

    /// Every link, listener, restart, sleep and reachability event of every transport made here, with seconds since the harness
    /// began: what `contractConnectedPair` prints when a pair does not come up. States, ports and error codes only.
    var diagnosticRecord: String { events.joined(separator: "\n") }

    private func record(_ line: String) {
        events.append(String(format: "%7.3f ", Date().timeIntervalSince(startedAt)) + line)
    }

    func make(linkLimit: Int) -> BonjourTeamTransport {
        let t = BonjourTeamTransport(advertise: false, linkLimit: linkLimit)
        let n = transports.count
        t.stateTrace = { [weak self] line in self?.record("t\(n) \(line)") }
        transports.append(t)
        return t
    }

    func loopbackEndpoint(of t: BonjourTeamTransport) async throws -> NWEndpoint {
        let ok = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(ok, "listener did not become ready")
        return .hostPort(host: "127.0.0.1", port: try XCTUnwrap(t.listenerPort))
    }

    func listenerPort(of t: BonjourTeamTransport) -> UInt16? { t.listenerPort?.rawValue }
    func connect(_ t: BonjourTeamTransport, to e: NWEndpoint) {
        record("t\(transports.firstIndex { $0 === t } ?? -1) connect(to:) \(e)")
        t.connect(to: e)
    }
    func injectDiscovered(_ t: BonjourTeamTransport, name: String, endpoint e: NWEndpoint) { t.injectDiscovered(name, endpoint: e) }
    func plannedDials(_ t: BonjourTeamTransport, now: Date) -> [String] { t.plannedDials(now: now) }
    func linkCount(_ t: BonjourTeamTransport) -> Int { t.linkCount }
    func peerIDs(_ t: BonjourTeamTransport) -> [TeamPeerID] { t.peerIDs }
    func sendRaw(_ t: BonjourTeamTransport, _ data: Data, to peer: TeamPeerID) { t.sendRaw(data, to: peer) }
    func willSleep(_ t: BonjourTeamTransport) { t.handleWillSleep() }
    func didWake(_ t: BonjourTeamTransport) { t.handleDidWake() }
    func restart(_ t: BonjourTeamTransport) {
        record("t\(transports.firstIndex { $0 === t } ?? -1) harness restart")
        t.restart()
    }
    func failDiscovery(_ t: BonjourTeamTransport) { t.browserStateChanged(.failed(.posix(.ECONNABORTED))) }

    /// Accepts TCP and never speaks TLS, like a rogue service holding a dial open.
    func silentSink() async throws -> (endpoint: NWEndpoint, close: () -> Void) {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { $0.start(queue: .main) }
        listener.start(queue: .main)
        let ready = await contractWaitUntil(5) { listener.port != nil && listener.port?.rawValue != 0 }
        XCTAssertTrue(ready)
        return (.hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), { listener.cancel() })
    }

    /// Plain TCP never completes the TLS-PSK handshake, so every one of these stays unfinished.
    func plainTCP(toPortOf t: BonjourTeamTransport, count: Int) async throws -> () -> Void {
        let port = try XCTUnwrap(t.listenerPort)
        let raw = (0..<count).map { _ in NWConnection(host: "127.0.0.1", port: port, using: .tcp) }
        raw.forEach { $0.start(queue: .main) }
        return { raw.forEach { $0.cancel() } }
    }

    func rawTLS(to e: NWEndpoint, code: TeamCode) async throws -> (send: (Data) -> Void, close: () -> Void) {
        let raw = NWConnection(to: e, using: BonjourTeamTransport.parameters(code: code))
        raw.start(queue: .main)
        let up = await contractWaitUntil(5) { raw.state == .ready }
        XCTAssertTrue(up)
        return ({ raw.send(content: $0, completion: .idempotent) }, { raw.cancel() })
    }

    func tearDown() {
        for t in transports { t.stop() }
        transports = []
    }
}

@MainActor
final class TeamTransportTests: XCTestCase {
    private let harness = MacTransportHarness()

    override func tearDown() async throws { harness.tearDown() }

    /// Mac-only: the contract cannot say when a browser is "healthy".
    func testAHealthyBrowserChangesNothing() async throws {
        let (a, _, _, _) = try await contractConnectedPair(harness)
        var aDown = 0
        a.onPeerDisconnected = { _ in aDown += 1 }
        a.browserStateChanged(.ready)
        XCTAssertEqual(aDown, 0, "a healthy browser changes nothing")
        XCTAssertNotNil(a.listenerPort)
    }


    /// A message near the frame limit (about 0.9 MB), so a few of them fill the queue.
    private static var bigMessage: TeamMessage {
        .inventory(eventIDs: (0..<20_000).map { _ in UUID().uuidString }, reactionIDs: [])
    }

    /// Mac-only: everything handed to a link in one go stays queued until the main thread runs again, so a burst bigger than
    /// the limit is exactly a peer that is not taking bytes.
    func testALinkWithTooManyBytesWaitingIsDropped() async throws {
        let (a, _, aPeer, _) = try await contractConnectedPair(harness)
        var downs = 0
        a.onPeerDisconnected = { _ in downs += 1 }
        for _ in 0..<12 { a.send(Self.bigMessage, to: aPeer) }
        XCTAssertEqual(downs, 1, "past 8 MB waiting the link is closed")
        XCTAssertNil(a.queuedBytes(of: aPeer))
    }

    /// A healthy link takes what it is given, so the count goes back to zero and the next burst starts from an empty queue.
    func testQueuedBytesDrainOnAHealthyLink() async throws {
        let (a, _, aPeer, _) = try await contractConnectedPair(harness)
        var downs = 0
        a.onPeerDisconnected = { _ in downs += 1 }
        for _ in 0..<6 { a.send(Self.bigMessage, to: aPeer) }
        XCTAssertGreaterThan(a.queuedBytes(of: aPeer) ?? 0, 4_000_000)
        let drained = await contractWaitUntil(10) { a.queuedBytes(of: aPeer) == 0 }
        XCTAssertTrue(drained, "contentProcessed gave every byte back")
        for _ in 0..<6 { a.send(Self.bigMessage, to: aPeer) }
        XCTAssertEqual(downs, 0, "6 MB after 6 MB is not 12 MB waiting")
    }

    /// The most an honest receiver leaves waiting is three full feed syncs (about 2 MB each).
    func testThreeFullFeedSyncsInOneGoAreNotDropped() async throws {
        let (a, _, aPeer, _) = try await contractConnectedPair(harness)
        var downs = 0
        a.onPeerDisconnected = { _ in downs += 1 }
        for _ in 0..<6 { a.send(Self.bigMessage, to: aPeer) }
        XCTAssertEqual(downs, 0)
        XCTAssertGreaterThan(a.queuedBytes(of: aPeer) ?? 0, 4_000_000)
    }

    func testSameCodePeersExchangeMessagesOverLoopback() async throws { try await TeamTransportContract.sameCodePeersExchangeMessagesOverLoopback(harness) }

    func testDifferentCodeNeverDeliversMessages() async throws { try await TeamTransportContract.differentCodeNeverDeliversMessages(harness) }

    func testMalformedFrameDisconnects() async throws { try await TeamTransportContract.malformedFrameDisconnects(harness) }

    func testStopSilencesCallbacks() async throws { try await TeamTransportContract.stopSilencesCallbacks(harness) }

    func testDisconnectIsSilentAndUnknownPeerIsNoOp() async throws { try await TeamTransportContract.disconnectIsSilentAndUnknownPeerIsNoOp(harness) }

    func testSleepReportsDisconnectsAndWakeRestartsOnlyRunningTransport() async throws { try await TeamTransportContract.sleepReportsDisconnectsAndWakeRestartsOnlyRunningTransport(harness) }

    func testOwnerStoppingInsideDisconnectCallbackPreventsRestart() async throws { try await TeamTransportContract.ownerStoppingInsideDisconnectCallbackPreventsRestart(harness) }

    func testFailedDiscoveryRestartsLikeAFailedListener() async throws { try await TeamTransportContract.failedDiscoveryRestartsLikeAFailedListener(harness) }

    func testUnfinishedInboundLinksAreCapped() async throws { try await TeamTransportContract.unfinishedInboundLinksAreCapped(harness) }

    func testDialsToRogueServicesAreCapped() async throws { try await TeamTransportContract.dialsToRogueServicesAreCapped(harness) }

    func testAFloodOfNamesCostsLittleOnceTheDialsAreFull() async throws { try await TeamTransportContract.aFloodOfNamesCostsLittleOnceTheDialsAreFull(harness) }

    func testDialsLeaveRoomForTheLinkLimit() async throws { try await TeamTransportContract.dialsLeaveRoomForTheLinkLimit(harness) }

    func testInboundLinksStopAtTheLinkLimit() async throws { try await TeamTransportContract.inboundLinksStopAtTheLinkLimit(harness) }

    func testAFinishedLinkDoesNotUseUpADialSlot() async throws { try await TeamTransportContract.aFinishedLinkDoesNotUseUpADialSlot(harness) }

    func testALinkPouringInBytesIsDropped() async throws { try await TeamTransportContract.aLinkPouringInBytesIsDropped(harness) }

    func testALinkPouringInTinyFramesIsDropped() async throws { try await TeamTransportContract.aLinkPouringInTinyFramesIsDropped(harness) }

    func testASyncAndARunAreNotDropped() async throws { try await TeamTransportContract.aSyncAndARunAreNotDropped(harness) }

    func testFailedDialIsClosedAndWaitsForCooldown() async throws { try await TeamTransportContract.failedDialIsClosedAndWaitsForCooldown(harness) }

    func testABadFrameHoldsTheNameOffForFiveMinutes() async throws { try await TeamTransportContract.aBadFrameHoldsTheNameOffForFiveMinutes(harness) }

    func testAFloodedNamedPeerWaitsForTheRefusalCooldown() async throws { try await TeamTransportContract.aFloodedNamedPeerWaitsForTheRefusalCooldown(harness) }

    func testDisconnectCoveredByKeptConnectionStopsRedialUntilKeptEnds() async throws { try await TeamTransportContract.disconnectCoveredByKeptConnectionStopsRedialUntilKeptEnds(harness) }

    func testAnUnfinishedHandshakeEndsAfterTheTimeout() async throws { try await TeamTransportContract.anUnfinishedHandshakeEndsAfterTheTimeout(harness) }

    func testRemoteStopIsReportedOnce() async throws { try await TeamTransportContract.remoteStopIsReportedOnce(harness) }

    func testSendToAnUnreadyOrUnknownPeerIsDropped() async throws { try await TeamTransportContract.sendToAnUnreadyOrUnknownPeerIsDropped(harness) }

    func testOwnerDisconnectInsideOnMessageStopsTheBatch() async throws { try await TeamTransportContract.ownerDisconnectInsideOnMessageStopsTheBatch(harness) }

    func testRefusedPeerWaitsForTheRefusalCooldown() async throws { try await TeamTransportContract.refusedPeerWaitsForTheRefusalCooldown(harness) }

    func testRestartReportsLiveLinksThenComesBack() async throws { try await TeamTransportContract.restartReportsLiveLinksThenComesBack(harness) }
}
