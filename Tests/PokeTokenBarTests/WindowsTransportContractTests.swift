#if os(Windows)
import XCTest
import Foundation
import WinSDK
@testable import PokeTokenBar

/// A reachability monitor that reports only when a test fires it: a real connectivity change on the runner must not
/// restart a transport in the middle of a scenario (the Mac harness has the same exposure; here it is closed).
final class QuietReachability: ReachabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var starts = 0, stops = 0

    var onReconnected: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    var started: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopped: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func start() { lock.lock(); starts += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func fire() { onReconnected?() }
}

/// The Windows side of the transport contract (`TeamTransportContract.swift`, the Mac's is `MacTransportHarness`).
/// Loopback only: the transports do not advertise. Plain TCP and the silent sink are raw Winsock; the raw TLS peer is
/// a second `WinSocketLoop` dialling with the team key, written to as the test likes (the Mac uses an `NWConnection`).
@MainActor
final class WindowsTransportHarness: TeamTransportHarness {
    typealias Transport = WindowsTeamTransport
    typealias Endpoint = WinTeamEndpoint

    @MainActor final class RawPeer { var events: [WinSocketEvent] = [] }

    private var transports: [WindowsTeamTransport] = []
    private var rawLoops: [WinSocketLoop] = []
    var listenerRetryDelay = TeamTransportRules.listenerRetryDelay

    func make(linkLimit: Int) -> WindowsTeamTransport {
        let t = WindowsTeamTransport(advertise: false, linkLimit: linkLimit, reachability: QuietReachability(),
                                     listenerRetryDelay: listenerRetryDelay)
        transports.append(t)
        return t
    }

    func keep(_ t: WindowsTeamTransport) { transports.append(t) }

    func loopbackEndpoint(of t: WindowsTeamTransport) async throws -> WinTeamEndpoint {
        let ok = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(ok, "listener did not become ready")
        return .hostPort("127.0.0.1", try XCTUnwrap(t.listenerPort))
    }

    func listenerPort(of t: WindowsTeamTransport) -> UInt16? { t.listenerPort }
    func connect(_ t: WindowsTeamTransport, to e: WinTeamEndpoint) { t.connect(to: e) }
    func injectDiscovered(_ t: WindowsTeamTransport, name: String, endpoint e: WinTeamEndpoint) { t.injectDiscovered(name, endpoint: e) }
    func plannedDials(_ t: WindowsTeamTransport, now: Date) -> [String] { t.plannedDials(now: now) }
    func linkCount(_ t: WindowsTeamTransport) -> Int { t.linkCount }
    func peerIDs(_ t: WindowsTeamTransport) -> [TeamPeerID] { t.peerIDs }
    func sendRaw(_ t: WindowsTeamTransport, _ data: Data, to peer: TeamPeerID) { t.sendRaw(data, to: peer) }
    func willSleep(_ t: WindowsTeamTransport) { t.handleWillSleep() }
    func didWake(_ t: WindowsTeamTransport) { t.handleDidWake() }
    func restart(_ t: WindowsTeamTransport) { t.restart() }
    func failDiscovery(_ t: WindowsTeamTransport) { t.discoveryFailed(code: 1460) }   // ERROR_TIMEOUT

    /// A listener on 127.0.0.1 that never accepts: the kernel completes each TCP handshake from its backlog, and the
    /// TLS ClientHello is never answered, like a rogue service holding a dial open.
    func silentSink() async throws -> (endpoint: WinTeamEndpoint, close: () -> Void) {
        let sink = try XCTUnwrap(RawTCP.silentListener(), "no loopback listener")
        return (.hostPort("127.0.0.1", sink.port), { RawTCP.close(sink.socket) })
    }

    /// Plain TCP never completes the TLS-PSK handshake, so every one of these stays unfinished.
    func plainTCP(toPortOf t: WindowsTeamTransport, count: Int) async throws -> () -> Void {
        let port = try XCTUnwrap(t.listenerPort)
        let sockets = await RawTCP.connections(count, port: port)
        XCTAssertEqual(sockets.count, count, "plain TCP connections refused by the kernel")
        return { sockets.forEach { RawTCP.close($0) } }
    }

    func rawTLS(to e: WinTeamEndpoint, code: TeamCode) async throws -> (send: (Data) -> Void, close: () -> Void) {
        guard case .hostPort(let host, let port) = e else {
            XCTFail("raw TLS needs a host and port")
            throw CancellationError()
        }
        let peer = RawPeer()
        let loop = WinSocketLoop(deliver: { peer.events.append($0) })
        XCTAssertTrue(loop.start())
        rawLoops.append(loop)
        let id = loop.dial([WinSocketAddress(family: .ipv4, host: host, port: port)], code: code)
        let up = await contractWaitUntil(5) { peer.events.contains(.ready(id)) }
        XCTAssertTrue(up, "raw TLS link not ready: \(peer.events)")
        return ({ loop.send($0, on: id) }, { loop.close(id) })
    }

    func tearDown() {
        for t in transports { t.shutdown() }   // joins each socket thread: none piles up across the suite
        transports = []
        for l in rawLoops { l.shutdown() }
        rawLoops = []
    }
}

/// Plain Winsock for the hostile side. Any thread.
enum RawTCP {
    static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    static func v4(_ port: UInt16) -> [UInt8] {
        [2, 0, UInt8(port >> 8), UInt8(port & 0xff), 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    static func boundPort(_ s: SOCKET) -> UInt16 {
        var buffer = [UInt8](repeating: 0, count: 128)
        var length: Int32 = 128
        _ = buffer.withUnsafeMutableBytes { getsockname(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length) }
        return UInt16(buffer[2]) << 8 | UInt16(buffer[3])
    }

    static func silentListener() -> (socket: SOCKET, port: UInt16)? {
        _ = started
        let s = socket(2, 1, 6)
        guard s != SOCKET.max else { return nil }
        let a = v4(0)
        let bound = a.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) } == 0
        guard bound, listen(s, 0x7fff_ffff) == 0 else { _ = closesocket(s); return nil }   // SOMAXCONN
        return (s, boundPort(s))
    }

    /// Blocking connect (completed from the listener's backlog). nil if refused.
    static func connectTCP(_ port: UInt16) -> SOCKET? {
        _ = started
        let s = socket(2, 1, 6)
        guard s != SOCKET.max else { return nil }
        let a = v4(port)
        let r = a.withUnsafeBytes { connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) }
        if r != 0 { _ = closesocket(s); return nil }
        return s
    }

    /// `count` connections from a thread of their own (a blocking connect must not hold the main thread, which
    /// delivers the transport's accepts).
    static func connections(_ count: Int, port: UInt16) async -> [SOCKET] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SOCKET], Never>) in
            Thread {
                var out: [SOCKET] = []
                for _ in 0..<count {
                    if let s = RawTCP.connectTCP(port) { out.append(s) }
                }
                continuation.resume(returning: out)
            }.start()
        }
    }

    static func close(_ s: SOCKET) { _ = closesocket(s) }
}

/// Every contract scenario through the Windows transport. `TeamTransportContractScanTests` checks that none is missing.
@MainActor
final class WindowsTransportContractTests: XCTestCase {
    private let harness = WindowsTransportHarness()

    override func tearDown() async throws { harness.tearDown() }

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

    func testLaterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems() async throws { try await TeamTransportContract.laterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems(harness) }

    func testAnUnfinishedHandshakeEndsAfterTheTimeout() async throws { try await TeamTransportContract.anUnfinishedHandshakeEndsAfterTheTimeout(harness) }

    func testRemoteStopIsReportedOnce() async throws { try await TeamTransportContract.remoteStopIsReportedOnce(harness) }

    func testSendToAnUnreadyOrUnknownPeerIsDropped() async throws { try await TeamTransportContract.sendToAnUnreadyOrUnknownPeerIsDropped(harness) }

    func testOwnerDisconnectInsideOnMessageStopsTheBatch() async throws { try await TeamTransportContract.ownerDisconnectInsideOnMessageStopsTheBatch(harness) }

    func testRefusedPeerWaitsForTheRefusalCooldown() async throws { try await TeamTransportContract.refusedPeerWaitsForTheRefusalCooldown(harness) }

    func testRestartReportsLiveLinksThenComesBack() async throws { try await TeamTransportContract.restartReportsLiveLinksThenComesBack(harness) }

}

/// The Windows transport's own decisions (the contract covers the shared ones): address order and scope, DNS-SD
/// resolve as part of a dial, repeated discovery events, the failures that restart, the order of a teardown, and
/// that nothing is opened before `start`.
@MainActor
final class WindowsTeamTransportTests: XCTestCase {
    private let harness = WindowsTransportHarness()

    override func tearDown() async throws { harness.tearDown() }

    private static func newCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    private func make(linkLimit: Int = TeamTransportRules.maxLinks, advertise: Bool = false,
                      reachability: QuietReachability = QuietReachability(),
                      resolve: WindowsTeamTransport.Resolver? = nil, handshakeTimeout: TimeInterval = TeamTransportRules.handshakeTimeout,
                      retry: TimeInterval = 0.5) -> WindowsTeamTransport {
        let t = WindowsTeamTransport(advertise: advertise, linkLimit: linkLimit, reachability: reachability, resolve: resolve,
                                     handshakeTimeout: handshakeTimeout, listenerRetryDelay: retry)
        harness.keep(t)
        return t
    }

    func testDialOrderPutsIPv4FirstAndScopesLinkLocalIPv6() async {
        let resolved = [
            WinSocketAddress(family: .ipv6, host: "fe80:0:0:0:1c2b:3a4d:5e6f:7a8b", port: 5000, interfaceIndex: 7),
            WinSocketAddress(family: .ipv6, host: "2001:db8:0:0:0:0:0:1", port: 5000, interfaceIndex: 7),
            WinSocketAddress(family: .ipv4, host: "192.168.0.5", port: 5000, interfaceIndex: 7),
            WinSocketAddress(family: .ipv6, host: "fe80:0:0:0:0:0:0:2", port: 5000, interfaceIndex: 0),
        ]
        XCTAssertEqual(WindowsTeamTransport.dialOrder(resolved).map(\.host),
                       ["192.168.0.5", "fe80:0:0:0:1c2b:3a4d:5e6f:7a8b%7", "2001:db8:0:0:0:0:0:1", "fe80:0:0:0:0:0:0:2"])
        XCTAssertTrue(WindowsTeamTransport.isLinkLocal("fe80::1"))
        XCTAssertTrue(WindowsTeamTransport.isLinkLocal("febf:0:0:0:0:0:0:1"))
        XCTAssertFalse(WindowsTeamTransport.isLinkLocal("fec0:0:0:0:0:0:0:1"))
        XCTAssertFalse(WindowsTeamTransport.isLinkLocal("::1"))
        XCTAssertFalse(WindowsTeamTransport.isLinkLocal("192.168.0.5"))
        // What the loop makes of the scoped text: the interface index in sin6_scope_id.
        let bytes = WinSocketLoop.socketAddress(WindowsTeamTransport.dialOrder(resolved)[1])
        XCTAssertEqual(bytes.map { Array($0[24..<28]) }, [7, 0, 0, 0])
    }

    func testANumericSockaddrReadsBackInTheDNSSDForm() async {
        let v4: [UInt8] = [2, 0, 0x1f, 0x90, 10, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0]
        let a = v4.withUnsafeBytes { WinSocketAddress(sockaddr: $0.baseAddress!, length: 16) }
        XCTAssertEqual(a, WinSocketAddress(family: .ipv4, host: "10.0.0.7", port: 8080))
        var v6 = [UInt8](repeating: 0, count: 28)
        v6[0] = 23; v6[2] = 0x13; v6[3] = 0x88
        v6[8] = 0xfe; v6[9] = 0x80; v6[23] = 0x02
        v6[24] = 12
        let b = v6.withUnsafeBytes { WinSocketAddress(sockaddr: $0.baseAddress!, length: 28) }
        XCTAssertEqual(b, WinSocketAddress(family: .ipv6, host: "fe80:0:0:0:0:0:0:2", port: 5000, interfaceIndex: 12))
        XCTAssertNil(v4.withUnsafeBytes { WinSocketAddress(sockaddr: $0.baseAddress!, length: 8) })
    }

    /// The `<host>.local` fallback when DNS-SD answers without addresses: getaddrinfo, IPv4 first.
    private func lookUp(_ host: String, port: UInt16) async -> [WinSocketAddress] {
        await withCheckedContinuation { (c: CheckedContinuation<[WinSocketAddress], Never>) in
            DispatchQueue.global().async { c.resume(returning: WinDNSSD.hostAddresses(host, port: port)) }
        }
    }

    func testHostAddressesLookUpANameIPv4First() async {
        let found = await lookUp("localhost", port: 4321)
        print("TEAMTRANSPORT-REPORT hostAddresses(localhost) -> \(found)")
        XCTAssertTrue(found.contains(WinSocketAddress(family: .ipv4, host: "127.0.0.1", port: 4321)), "\(found)")
        if let v6 = found.firstIndex(where: { $0.family == .ipv6 }) {
            XCTAssertTrue(found[..<v6].allSatisfy { $0.family == .ipv4 }, "\(found)")
        }
        let none = await lookUp("ptb-no-such-host-\(UUID().uuidString.prefix(8)).invalid", port: 1)
        XCTAssertEqual(none, [])
    }

    func testNothingIsOpenedBeforeStartAndShutdownJoinsTheLoop() async throws {
        let reach = QuietReachability()
        let t = make(reachability: reach)
        XCTAssertFalse(t.hasSocketLoop, "no socket thread, no wake socket, no listener before start")
        XCTAssertNil(t.listenerPort)
        t.stop()   // a stop before any start opens nothing either
        XCTAssertFalse(t.hasSocketLoop)
        XCTAssertEqual(reach.started, 0)
        t.start(code: Self.newCode())
        XCTAssertTrue(t.hasSocketLoop)
        XCTAssertEqual(reach.started, 1)
        let up = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(up)
        t.stop()
        XCTAssertNil(t.listenerPort)
        XCTAssertEqual(reach.stopped, 2)
        t.shutdown()
        XCTAssertFalse(t.hasSocketLoop, "shutdown joined and dropped the loop")
    }

    /// A service still being resolved is an unfinished dial: it uses a dial slot and its handshake timer runs.
    func testAServiceBeingResolvedIsAnUnfinishedDialAndTimesOut() async throws {
        var pending: [(String, @MainActor ([WinSocketAddress]) -> Void)] = []
        let t = make(resolve: { name, done in pending.append((name, done)) }, handshakeTimeout: 1)
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        for i in 0..<40 { t.injectDiscovered("ptb-slow-\(i)", endpoint: .service("ptb-slow-\(i)")) }
        XCTAssertEqual(t.linkCount, TeamTransportRules.maxUnfinishedOutbound, "resolves in progress fill the dial slots")
        XCTAssertEqual(pending.count, TeamTransportRules.maxUnfinishedOutbound)
        let ended = await contractWaitUntil(4) { t.linkCount == 0 }
        XCTAssertTrue(ended, "the handshake timer counts the resolve time")
        let cooled = t.plannedDials(now: Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1))
        XCTAssertEqual(Set(pending.map { $0.0 }).subtracting(cooled), [], "every timed-out name waits for the cooldown")
        XCTAssertTrue(Set(pending.map { $0.0 }).isDisjoint(with: t.plannedDials(now: Date())))
        // A late answer for a dial that already ended opens nothing.
        let port = try XCTUnwrap(t.listenerPort)
        for (_, done) in pending { done([WinSocketAddress(family: .ipv4, host: "127.0.0.1", port: port)]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(t.linkCount, 0)
    }

    func testAResolveWithNoAddressIsAFailedDialWithTheCooldown() async throws {
        let t = make(resolve: { _, done in DispatchQueue.main.async { done([]) } })
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        t.injectDiscovered("ptb-gone", endpoint: .service("ptb-gone"))
        XCTAssertEqual(t.linkCount, 1)
        let ended = await contractWaitUntil(2) { t.linkCount == 0 }
        XCTAssertTrue(ended)
        XCTAssertEqual(t.plannedDials(now: Date()), [])
        XCTAssertEqual(t.plannedDials(now: Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)), ["ptb-gone"])
    }

    /// A resolved service is dialled IPv4 first and links; the probe's negotiated view shows the suite and the peer.
    func testAResolvedServiceLinksOverTheTeamSuite() async throws {
        let code = Self.newCode()
        let a = make()
        a.start(code: code)
        _ = try await harness.loopbackEndpoint(of: a)
        let port = try XCTUnwrap(a.listenerPort)
        var asked: [String] = []
        let b = make(resolve: { name, done in
            asked.append(name)
            DispatchQueue.main.async {
                done([WinSocketAddress(family: .ipv6, host: "fe80:0:0:0:0:0:0:9", port: 1, interfaceIndex: 0),
                      WinSocketAddress(family: .ipv4, host: "127.0.0.1", port: port)])
            }
        })
        var bPeer: (TeamPeerID, Bool)?
        b.onPeerConnected = { bPeer = ($0, $1) }
        b.start(code: code)
        b.injectDiscovered("ptb-a", endpoint: .service("ptb-a"))
        let up = await contractWaitUntil(5) { bPeer != nil }
        XCTAssertTrue(up, "the IPv4 address (listed second) is tried first")
        XCTAssertEqual(asked, ["ptb-a"])
        XCTAssertEqual(bPeer?.1, true)
        let n = try XCTUnwrap(b.negotiated(try XCTUnwrap(bPeer).0))
        print("TEAMTRANSPORT-REPORT negotiated \(n)")
        XCTAssertEqual(n.version, "TLSv1.2")
        XCTAssertEqual(n.cipher, "PSK-AES128-GCM-SHA256")
        XCTAssertEqual(n.peer, "127.0.0.1:\(port)")
    }

    /// Windows repeats `.found` / `.lost` (four in a row on the runner) and reports this run's own service.
    func testRepeatedAndOwnDiscoveryEventsAreHarmless() async throws {
        var asked: [String] = []
        let t = make(resolve: { name, _ in asked.append(name) })
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        for _ in 0..<4 { t.handleDiscovery(.found("ptb-x")) }
        XCTAssertEqual(asked, ["ptb-x"], "one dial for four reports")
        XCTAssertEqual(t.linkCount, 1)
        for _ in 0..<4 { t.handleDiscovery(.lost("ptb-x")) }
        XCTAssertEqual(t.linkCount, 1, "a lost name does not end its running dial")
        for _ in 0..<4 { t.handleDiscovery(.found("ptb-x")) }
        XCTAssertEqual(asked, ["ptb-x"])
        let own = try XCTUnwrap(t.advertisedName)
        t.handleDiscovery(.found(own))
        t.handleDiscovery(.registered("ptb-renamed"))
        t.handleDiscovery(.found("ptb-renamed"))
        XCTAssertEqual(asked, ["ptb-x"], "this run's own service is never dialled, under either name")
        XCTAssertEqual(t.advertisedName, "ptb-renamed")
    }

    func testRegistrationAndBrowseFailuresRestartLikeAListenerFailure() async throws {
        harness.listenerRetryDelay = 0.5
        for failure in [WinDNSSD.Event.registerFailed(9002), .browseFailed(1460)] {
            let (a, _, aPeer, _) = try await contractConnectedPair(harness)
            var down: [TeamPeerID] = []
            a.onPeerDisconnected = { down.append($0) }
            a.handleDiscovery(failure)
            XCTAssertEqual(down, [aPeer], "\(failure)")
            XCTAssertNil(a.listenerPort)
            let back = await contractWaitUntil(3) { a.listenerPort != nil }
            XCTAssertTrue(back, "\(failure): back after the retry delay")
        }
    }

    func testABrokenListenerRestartsAfterTheRetryDelay() async throws {
        let t = make(retry: 0.5)
        var traced: [WindowsTeamTransport.Trace] = []
        t.trace = { traced.append($0) }
        t.start(code: Self.newCode())
        _ = await contractWaitUntil(5) { t.listenerPort != nil }
        let first = try XCTUnwrap(t.listenerPort)
        try XCTUnwrap(t.socketLoop).injectAcceptFailure(10050)   // WSAENETDOWN on the next accept
        let poke = await RawTCP.connections(1, port: first)
        defer { poke.forEach { RawTCP.close($0) } }
        let failed = await contractWaitUntil(3) { traced.contains(.listenFailed(10050)) }
        XCTAssertTrue(failed, "\(traced)")
        let back = await contractWaitUntil(3) { t.listenerPort != nil }
        XCTAssertTrue(back, "listening again after the retry delay")
    }

    /// The Mac restarts on a network reconnect; so does Windows (and, since Windows reports "connected" only with
    /// internet access, also on wake and on every DNS-SD or listener failure: the tests above).
    func testAReconnectRestartsTheTransport() async throws {
        let reach = QuietReachability()
        let code = Self.newCode()
        let a = make(reachability: reach), b = make()
        var aPeer: TeamPeerID?, down: [TeamPeerID] = []
        a.onPeerConnected = { id, _ in aPeer = id }
        a.onPeerDisconnected = { down.append($0) }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await harness.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil }
        XCTAssertTrue(up)
        reach.fire()
        let restarted = await contractWaitUntil(3) { aPeer.map { down == [$0] } == true && a.listenerPort != nil }
        XCTAssertTrue(restarted, "down=\(down) port=\(String(describing: a.listenerPort))")
        a.stop()
        reach.fire()   // after stop nobody listens to reachability
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(a.listenerPort)
    }

    /// The Mac's order: everything is closed and the listener port is gone before the owner hears of the first link.
    func testATeardownClearsEverythingBeforeReportingLinks() async throws {
        for step in ["sleep", "restart"] {
            let (a, _, aPeer, _) = try await contractConnectedPair(harness)
            var seen: [(TeamPeerID, UInt16?, Int)] = []
            a.onPeerDisconnected = { seen.append(($0, a.listenerPort, a.linkCount)) }
            if step == "sleep" { a.handleWillSleep() } else { a.restart() }
            XCTAssertEqual(seen.map { $0.0 }, [aPeer], step)
            let first = try XCTUnwrap(seen.first, step)
            XCTAssertNil(first.1, "\(step): the port is cleared first")
            XCTAssertEqual(first.2, 0, "\(step): the links are gone first")
        }
    }

    /// Every `.accepted` is answered in its handler, also over the limit: the loop never has to close one for us.
    func testEveryAcceptIsAnsweredInItsHandler() async throws {
        let t = make(linkLimit: 2)
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        let close = try await harness.plainTCP(toPortOf: t, count: 10)
        defer { close() }
        let full = await contractWaitUntil(5) { t.linkCount == 2 }
        XCTAssertTrue(full)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try XCTUnwrap(t.socketLoop).unansweredAccepts, 0)
        XCTAssertEqual(t.linkCount, 2)
    }

    /// Wake listens again and advertises the NEW port under a new name (real DNS-SD registration on the runner).
    func testWakeListensAgainAndAdvertisesTheNewPort() async throws {
        let t = make(advertise: true)
        var registering: [(String, UInt16)] = []
        t.trace = { if case .registering(let name, let port) = $0 { registering.append((name, port)) } }
        t.start(code: Self.newCode())
        let first = await contractWaitUntil(5) { !registering.isEmpty }
        XCTAssertTrue(first)
        XCTAssertEqual(registering.first?.1, t.listenerPort)
        t.handleWillSleep()
        XCTAssertNil(t.advertisedName)
        t.handleDidWake()
        let again = await contractWaitUntil(5) { registering.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(registering.last?.1, t.listenerPort, "the port registered is the new listener's")
        XCTAssertNotEqual(registering.first?.0, registering.last?.0, "a new run advertises a new name")
        let plain = make(advertise: false)
        var plainRegistered = false
        plain.trace = { if case .registering = $0 { plainRegistered = true } }
        plain.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: plain)
        XCTAssertFalse(plainRegistered, "a transport that does not advertise registers nothing")
    }
}
#endif
