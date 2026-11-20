import XCTest
import Network
@testable import PokeTokenBar

/// The Network.framework side of the transport contract. The scenarios live in `TeamTransportContract.swift`.
@MainActor
final class MacTransportHarness: TeamTransportHarness {
    typealias Transport = BonjourTeamTransport
    typealias Endpoint = NWEndpoint

    private var transports: [BonjourTeamTransport] = []

    func make(linkLimit: Int) -> BonjourTeamTransport {
        let t = BonjourTeamTransport(advertise: false, linkLimit: linkLimit)
        transports.append(t)
        return t
    }

    func loopbackEndpoint(of t: BonjourTeamTransport) async throws -> NWEndpoint {
        let ok = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(ok, "listener did not become ready")
        return .hostPort(host: "127.0.0.1", port: try XCTUnwrap(t.listenerPort))
    }

    func listenerPort(of t: BonjourTeamTransport) -> UInt16? { t.listenerPort?.rawValue }
    func connect(_ t: BonjourTeamTransport, to e: NWEndpoint) { t.connect(to: e) }
    func injectDiscovered(_ t: BonjourTeamTransport, name: String, endpoint e: NWEndpoint) { t.injectDiscovered(name, endpoint: e) }
    func plannedDials(_ t: BonjourTeamTransport, now: Date) -> [String] { t.plannedDials(now: now) }
    func linkCount(_ t: BonjourTeamTransport) -> Int { t.linkCount }
    func peerIDs(_ t: BonjourTeamTransport) -> [TeamPeerID] { t.peerIDs }
    func sendRaw(_ t: BonjourTeamTransport, _ data: Data, to peer: TeamPeerID) { t.sendRaw(data, to: peer) }
    func willSleep(_ t: BonjourTeamTransport) { t.handleWillSleep() }
    func didWake(_ t: BonjourTeamTransport) { t.handleDidWake() }
    func restart(_ t: BonjourTeamTransport) { t.restart() }
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
