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

@MainActor final class DNSSDSeen { var events: [WinDNSSD.Event] = [] }

/// DNS-SD for the failure tests: each registration and browse can be made to fail, with the codes WinDNSSD reports.
@MainActor final class FakeDiscovery: WinTeamDiscovery {
    let deliver: @MainActor (WinDNSSD.Event) -> Void
    var failRegister: Int32?
    var failBrowse: Int32?
    private(set) var registers: [Date] = []
    private(set) var browses: [Date] = []
    private var instance: String?

    init(_ deliver: @escaping @MainActor (WinDNSSD.Event) -> Void) { self.deliver = deliver }

    func register(instance: String, port: UInt16) {
        registers.append(Date())
        self.instance = instance
        let failure = failRegister
        DispatchQueue.main.async { self.deliver(failure.map { WinDNSSD.Event.registerFailed($0) } ?? .registered(instance)) }
    }
    func deregister() {}
    func deregister(waitingUpTo seconds: TimeInterval) -> Bool? { nil }
    /// A working browse finds this run's own service, as a real one does.
    func browse() {
        browses.append(Date())
        let failure = failBrowse, own = instance
        DispatchQueue.main.async {
            if let failure { self.deliver(.browseFailed(failure)) } else if let own { self.deliver(.found(own)) }
        }
    }
    func stopBrowsing() {}
    func resolve(instance: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void) {
        DispatchQueue.main.async { done([]) }
    }
    func lastAnswer(_ name: String) -> Date? { nil }
    func forget(_ name: String) {}
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

    // MARK: review round: DNS-SD failures, aging, old listeners, read order, production timing, goodbye

    /// Registration fails every time while a link is up: the link and the listener stay, only the registration is
    /// retried, after 1, 2, 4, 8 base delays capped (here 0.05 s doubling to 0.4 s), one log line per backoff step.
    func testRegistrationFailuresBackOffAndTheLinksStay() async throws {
        var fake: FakeDiscovery?
        var lines: [String] = []
        let code = Self.newCode()
        let a = WindowsTeamTransport(advertise: true, reachability: QuietReachability(),
                                     discovery: { deliver in let f = FakeDiscovery(deliver); f.failRegister = 9002; fake = f; return f },
                                     discoveryRetryBase: 0.05, discoveryRetryCap: 0.4, log: { lines.append($0) })
        harness.keep(a)
        let b = make()
        var aPeer: TeamPeerID?, aDown = 0
        a.onPeerConnected = { id, _ in aPeer = id }
        a.onPeerDisconnected = { _ in aDown += 1 }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await harness.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil }
        XCTAssertTrue(up)
        let tried = await contractWaitUntil(6) { (fake?.registers.count ?? 0) >= 8 }
        XCTAssertTrue(tried, "registrations: \(fake?.registers.count ?? 0)")
        XCTAssertEqual(aDown, 0, "a registration failure tears no link down")
        XCTAssertEqual(a.linkCount, 1)
        XCTAssertNotNil(a.listenerPort)
        let r = try XCTUnwrap(fake).registers
        let gaps = zip(r.dropFirst(), r).map { $0.timeIntervalSince($1) }
        print("TEAMTRANSPORT-REPORT registration retry gaps \(gaps.map { String(format: "%.2f", $0) })")
        for (gap, expected) in zip(gaps, [0.05, 0.1, 0.2, 0.4, 0.4, 0.4, 0.4]) {
            XCTAssertGreaterThanOrEqual(gap, expected * 0.8, "\(gaps)")
            XCTAssertLessThan(gap, expected + 0.35, "\(gaps)")
        }
        let failLines = lines.filter { $0.contains("DNS-SD registration failed") }
        XCTAssertEqual(failLines.count, 4, "one line per step (0.05, 0.1, 0.2, then the cap): \(lines)")
        XCTAssertTrue(failLines.last?.contains("not logged again until it works") == true, "\(failLines)")
        // Success resets: one more retry succeeds, nothing is retried after it, and the recovery is logged once.
        try XCTUnwrap(fake).failRegister = nil
        let works = await contractWaitUntil(2) { lines.contains { $0.contains("registration works again") } }
        XCTAssertTrue(works, "\(lines)")
        let settled = try XCTUnwrap(fake).registers.count
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(try XCTUnwrap(fake).registers.count, settled, "no retry after a success")
        XCTAssertEqual(aDown, 0)
    }

    /// The Mac restarts everything on a failed browser (`BonjourTeamTransport.browserStateChanged(.failed)`): so does the
    /// first failure here (the contract's `failedDiscoveryRestartsLikeAFailedListener`). If browsing fails again after
    /// that restart, only the browse is retried, with the backoff; the listener and the links stay.
    func testAFailedBrowseRestartsOnceThenOnlyTheBrowseRetries() async throws {
        var fake: FakeDiscovery?
        var lines: [String] = []
        let code = Self.newCode()
        let a = WindowsTeamTransport(advertise: true, reachability: QuietReachability(),
                                     discovery: { deliver in let f = FakeDiscovery(deliver); fake = f; return f },
                                     listenerRetryDelay: 0.3, discoveryRetryBase: 0.05, discoveryRetryCap: 0.4,
                                     log: { lines.append($0) })
        harness.keep(a)
        let b = make()
        var aPeers: [TeamPeerID] = [], aDown: [TeamPeerID] = []
        a.onPeerConnected = { id, _ in aPeers.append(id) }
        a.onPeerDisconnected = { aDown.append($0) }
        a.start(code: code); b.start(code: code)
        b.connect(to: try await harness.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeers.count == 1 }
        XCTAssertTrue(up)
        try XCTUnwrap(fake).failBrowse = 1460
        a.handleDiscovery(.browseFailed(1460))
        XCTAssertEqual(aDown, aPeers, "the first failure: the Mac's restart")
        XCTAssertNil(a.listenerPort)
        let back = await contractWaitUntil(3) { a.listenerPort != nil }
        XCTAssertTrue(back)
        b.connect(to: try await harness.loopbackEndpoint(of: a))
        let again = await contractWaitUntil(5) { aPeers.count == 2 }
        XCTAssertTrue(again)
        let browses0 = try XCTUnwrap(fake).browses.count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(aDown.count, 1, "repeated browse failures tear nothing down: \(lines)")
        XCTAssertEqual(a.linkCount, 1)
        let browses = try XCTUnwrap(fake).browses
        XCTAssertGreaterThanOrEqual(browses.count - browses0, 3, "the browse is retried")
        let gaps = zip(browses.dropFirst(), browses).map { $0.timeIntervalSince($1) }
        print("TEAMTRANSPORT-REPORT browse retry gaps \(gaps.map { String(format: "%.2f", $0) })")
        XCTAssertEqual(lines.filter { $0.contains("team: browser failed") }.count, 1, "\(lines)")
        XCTAssertEqual(lines.filter { $0.contains("DNS-SD browse failed") }.count, 4, "one per step: \(lines)")
        // Browsing works again (it finds this run's own service): the recovery is logged and the retries stop.
        try XCTUnwrap(fake).failBrowse = nil
        let works = await contractWaitUntil(2) { lines.contains { $0.contains("browse works again") } }
        XCTAssertTrue(works, "\(lines)")
    }

    /// A wake (and a network change) gives DNS-SD a fresh start: the next failure waits the base delay again.
    func testAWakeResetsTheBackoff() async throws {
        var fake: FakeDiscovery?
        var retries: [(String, Int)] = []
        let a = WindowsTeamTransport(advertise: true, reachability: QuietReachability(),
                                     discovery: { deliver in let f = FakeDiscovery(deliver); f.failRegister = 9002; fake = f; return f },
                                     discoveryRetryBase: 0.05, discoveryRetryCap: 0.4, log: { _ in })
        harness.keep(a)
        a.trace = { if case .retrying(let what, let attempt, _) = $0 { retries.append((what, attempt)) } }
        a.start(code: Self.newCode())
        let climbed = await contractWaitUntil(3) { retries.count >= 4 }
        XCTAssertTrue(climbed)
        a.handleWillSleep()
        a.handleDidWake()
        let n = retries.count
        let next = await contractWaitUntil(3) { retries.count > n }
        XCTAssertTrue(next)
        XCTAssertEqual(retries.dropFirst(n).first?.1, 1, "after a wake the backoff starts over: \(retries)")
        _ = fake
    }

    /// A name whose dials keep finding no service (Windows drops a name only on a goodbye packet, which Wi-Fi may
    /// lose) is forgotten after three in a row with no DNS-SD answer for it in between: no more resolves, no dial
    /// slot. Its next real announcement makes it new again.
    func testANameThatKeepsFindingNoServiceIsForgottenAndComesBackWhenItAnnounces() async throws {
        var now = Date()
        var asked = 0
        var forgotten: [String] = []
        let t = WindowsTeamTransport(advertise: false, reachability: QuietReachability(),
                                     resolve: { _, done in asked += 1; DispatchQueue.main.async { done([]) } },
                                     clock: { now })
        harness.keep(t)
        t.trace = { if case .forgotten(let n) = $0 { forgotten.append(n) } }
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        t.handleDiscovery(.found("ptb-gone"))
        for attempt in 1...3 {
            let ended = await contractWaitUntil(2) { asked == attempt && t.linkCount == 0 }
            XCTAssertTrue(ended, "attempt \(attempt)")
            guard attempt < 3 else { break }
            XCTAssertEqual(forgotten, [])
            XCTAssertEqual(t.plannedDials(now: now), [], "inside the cooldown")
            now = now.addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
            t.redialNow()
        }
        XCTAssertEqual(forgotten, ["ptb-gone"])
        // Forgotten: however long it waits, it costs no resolve (no mDNS query) and no dial slot.
        for _ in 0..<5 {
            now = now.addingTimeInterval(3600)
            t.redialNow()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(t.linkCount, 0)
        XCTAssertEqual(t.plannedDials(now: now), [])
        // Its next announcement is new: found and dialled again.
        t.handleDiscovery(.found("ptb-gone"))
        let back = await contractWaitUntil(2) { asked == 4 }
        XCTAssertTrue(back)
    }

    /// An answer for the name between two failed dials is a sign of life: the count starts over.
    func testAnAnswerBetweenFailedDialsKeepsTheName() async throws {
        var now = Date()
        var asked = 0
        var forgotten: [String] = []
        let t = WindowsTeamTransport(advertise: false, reachability: QuietReachability(),
                                     resolve: { _, done in asked += 1; DispatchQueue.main.async { done([]) } },
                                     clock: { now })
        harness.keep(t)
        t.trace = { if case .forgotten(let n) = $0 { forgotten.append(n) } }
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        t.handleDiscovery(.found("ptb-flaky"))
        for attempt in 1...4 {
            let ended = await contractWaitUntil(2) { asked == attempt && t.linkCount == 0 }
            XCTAssertTrue(ended, "attempt \(attempt)")
            if attempt == 1 {
                now = now.addingTimeInterval(1)
                t.handleDiscovery(.found("ptb-flaky"))   // DNS-SD heard it after the first failure
            }
            if attempt == 3 { XCTAssertEqual(forgotten, [], "three failures, but an answer after the first") }
            guard attempt < 4 else { break }
            now = now.addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
            t.redialNow()
        }
        XCTAssertEqual(forgotten, ["ptb-flaky"], "three in a row after the answer")
    }

    /// A TLS failure means something answered (another team): it never counts toward forgetting.
    func testAServiceOfAnotherTeamIsNeverForgotten() async throws {
        var now = Date()
        var forgotten: [String] = []
        let other = make()
        other.start(code: Self.newCode())
        let otherEndpoint = try await harness.loopbackEndpoint(of: other)
        let t = WindowsTeamTransport(advertise: false, reachability: QuietReachability(), clock: { now })
        harness.keep(t)
        t.trace = { if case .forgotten(let n) = $0 { forgotten.append(n) } }
        t.start(code: Self.newCode())
        _ = try await harness.loopbackEndpoint(of: t)
        t.injectDiscovered("ptb-other-team", endpoint: otherEndpoint)
        for attempt in 1...4 {
            let ended = await contractWaitUntil(5) { t.linkCount == 0 }
            XCTAssertTrue(ended, "attempt \(attempt)")
            now = now.addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
            t.redialNow()
        }
        XCTAssertEqual(forgotten, [])
    }

    /// A stop and a start with another code in one turn (a team-code change): a connection the OLD listener took before
    /// the loop saw the change is refused, never admitted with the old code's key. The wake for the stop is dropped, so
    /// the loop keeps polling the old listener while the transport already runs the new code.
    func testAConnectionTheOldListenerTookIsNeverAdmittedAfterACodeChange() async throws {
        let old = Self.newCode(), new = Self.newCode()
        let a = make()
        var connected = 0
        var refused = 0
        a.onPeerConnected = { _, _ in connected += 1 }
        a.trace = { if case .refusedInbound = $0 { refused += 1 } }
        a.start(code: old)
        _ = try await harness.loopbackEndpoint(of: a)
        let oldPort = try XCTUnwrap(a.listenerPort)
        let loop = try XCTUnwrap(a.socketLoop)
        loop.injectWakeFaults(drop: 1, fail: 0)
        a.stop()
        a.start(code: new)
        let peer = WindowsTransportHarness.RawPeer()
        let raw = WinSocketLoop(deliver: { peer.events.append($0) })
        XCTAssertTrue(raw.start())
        defer { raw.shutdown() }
        let id = raw.dial([WinSocketAddress(family: .ipv4, host: "127.0.0.1", port: oldPort)], code: old)
        let answered = await contractWaitUntil(3) { refused > 0 || connected > 0 || a.linkCount > 0 }
        XCTAssertTrue(answered, "the old listener's accept reached the transport")
        try await Task.sleep(nanoseconds: 300_000_000)
        loop.receiveNext(WinConnID(raw: .max))   // any later command sends the wake again: the queue runs
        try await Task.sleep(nanoseconds: 2_000_000_000)
        print("TEAMTRANSPORT-REPORT old-listener accept: refused=\(refused) connected=\(connected) raw=\(peer.events)")
        XCTAssertEqual(connected, 0, "a peer with the old code joined through the old listener")
        XCTAssertFalse(peer.events.contains(.ready(id)), "the old code's TLS finished")
        XCTAssertEqual(refused, 1)
    }

    /// Asking for the next chunk earlier (read-ahead) could not reorder messages or get past the receive budget:
    /// chunks of a link arrive in order, each is charged and decoded before its messages are delivered, and one taken
    /// over the budget ends the link. Here the receiving main thread is held while thousands of frames pile up.
    func testHeldBackChunksArriveInOrderAndTheBudgetStillCuts() async throws {
        let (receiver, sender, _, peer) = try await contractConnectedPair(harness)
        let linkedAt = Date()
        var got: [String] = [], cost = 0, bad = 0
        receiver.onMessage = { _, m in
            if case .chat(let c) = m { got.append(c.text) }
            cost += ((try? TeamWire.encode(m))?.count ?? 0) + TeamTransportRules.frameCost
        }
        receiver.onPeerBadFrame = { _ in bad += 1 }
        var pour = Data()
        for i in 0..<3000 { pour.append(try TeamWire.encode(.chat(TeamChat(text: String(format: "%05d", i), isLoud: nil)))) }
        harness.sendRaw(sender, pour, to: peer)
        Sleep(300)   // the main thread is held: the bytes wait in the socket and in OpenSSL
        let all = await contractWaitUntil(5) { got.count == 3000 || bad > 0 }
        XCTAssertTrue(all)
        XCTAssertEqual(got, (0..<3000).map { String(format: "%05d", $0) }, "order")
        var flood = Data()
        let tiny = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        for _ in 0..<6000 { flood.append(tiny) }
        harness.sendRaw(sender, flood, to: peer)
        Sleep(300)
        let cut = await contractWaitUntil(5) { bad == 1 }
        XCTAssertTrue(cut)
        let bound = TeamTransportRules.receiveBurst + TeamTransportRules.receivePerSecond * Date().timeIntervalSince(linkedAt)
        print("TEAMTRANSPORT-REPORT delivered cost \(cost) of a bound \(Int(bound))")
        XCTAssertLessThanOrEqual(Double(cost), bound, "messages past the budget were delivered")
    }

    /// The production values are the shared rules' (the contract only bounds them from above).
    func testProductionTimingIsTheSharedRules() async throws {
        let t = WindowsTeamTransport(advertise: false, reachability: QuietReachability())
        harness.keep(t)
        XCTAssertEqual(t.timing, .init(handshakeTimeout: TeamTransportRules.handshakeTimeout,
                                       listenerRetryDelay: TeamTransportRules.listenerRetryDelay,
                                       discoveryRetryBase: TeamTransportRules.listenerRetryDelay,
                                       discoveryRetryCap: 300))
        XCTAssertEqual(WindowsTeamTransport.absentDialsBeforeForgetting, 3)
        t.start(code: Self.newCode())
        XCTAssertEqual(t.redialTimerInterval, TeamTransportRules.redialInterval)
        XCTAssertEqual(WindowsTeamTransport.backoff(attempt: 1, base: 5, cap: 300), 5)
        XCTAssertEqual((1...8).map { WindowsTeamTransport.backoff(attempt: $0, base: 5, cap: 300) },
                       [5, 10, 20, 40, 80, 160, 300, 300])
    }

    /// A clean exit withdraws the advertisement and waits for the goodbye: another browser sees the service go at once.
    func testShutdownSendsTheGoodbyeBeforeItReturns() async throws {
        let seen = DNSSDSeen()
        let browser = WinDNSSD(deliver: { seen.events.append($0) })
        defer { browser.stopBrowsing() }
        browser.browse()
        let a = WindowsTeamTransport(advertise: true, reachability: QuietReachability())
        var completed = false
        a.trace = { if case .discovery(.registered) = $0 { completed = true } }
        a.start(code: Self.newCode())
        let name = try XCTUnwrap(a.advertisedName)
        let registered = await contractWaitUntil(30) { seen.events.contains(.found(name)) && completed }
        XCTAssertTrue(registered, "\(seen.events)")
        let t0 = Date()
        a.shutdown()
        let waited = Date().timeIntervalSince(t0)
        let gone = await contractWaitUntil(5) { seen.events.contains(.lost(name)) }
        let after = Date().timeIntervalSince(t0)
        print("TEAMTRANSPORT-REPORT goodbye confirmed=\(String(describing: a.lastGoodbye)) shutdown \(Int(waited * 1000)) ms, lost seen after \(Int(after * 1000)) ms")
        XCTAssertEqual(a.lastGoodbye, true, "the deregistration completed within the wait")
        XCTAssertLessThan(waited, WindowsTeamTransport.goodbyeWait + 0.4)
        XCTAssertTrue(gone)
        XCTAssertLessThan(after, 1.5, "the browser saw the removal within a second")
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
