#if os(Windows)
import Foundation

/// Where a Windows transport dials: a DNS-SD instance (resolved when dialled) or a numeric host and port.
enum WinTeamEndpoint: Equatable, Sendable {
    case service(String)
    case hostPort(String, UInt16)
}

/// The Windows `TeamTransporting`: DNS-SD discovery (`WinDNSSD`), TLS-PSK links on one socket thread
/// (`WinSocketLoop`), and every decision the Mac's `BonjourTeamTransport` makes, taken from the shared rules
/// (`TeamTransportRules`, `TeamLinkReceiver`, `TeamDialPlanner`). It mirrors that class line by line: the same states
/// (`wanted`, `running`, `generation`), the same callback order, the same timers and hold-offs. Both pass the same
/// contract (`TeamTransportContract`). All state lives on the main actor; the loop and DNS-SD deliver on the main queue.
///
/// Nothing is opened until `start(code:)`: no thread, no socket, no DNS-SD request, so an app without a team code
/// never listens (no firewall prompt).
///
/// Timers (each states what arms it and what ends it):
/// - redial: `Timer` every `redialInterval` (15 s, tolerance 3 s) on the main run loop, from `begin()` to the next
///   teardown, exactly as the Mac's. The only periodic wake of a running transport.
/// - handshake: one task per unfinished link, `handshakeTimeout` (10 s) from the dial (DNS-SD resolve time included)
///   or the accept; cancelled when the link is ready or ends, and by every teardown.
/// - listener retry: one task `listenerRetryDelay` (5 s) after a listener, DNS-SD registration or browse failure.
@MainActor
final class WindowsTeamTransport: TeamTransporting {
    typealias Resolver = @MainActor (String, @escaping @MainActor ([WinSocketAddress]) -> Void) -> Void

    /// What the team probe and the selftest watch. The app sets no observer.
    enum Trace: Equatable, Sendable {
        case listening(UInt16), listenFailed(Int32)
        case registering(name: String, port: UInt16)
        case discovery(WinDNSSD.Event)
        case resolved(name: String, addresses: [WinSocketAddress])
        case dialing(peer: TeamPeerID, to: String)
        case accepted(peer: TeamPeerID), refusedInbound
        case ready(peer: TeamPeerID, initiatedByMe: Bool)
        case closed(peer: TeamPeerID, reason: String)
    }

    var onPeerConnected: ((TeamPeerID, Bool) -> Void)?
    var onPeerDisconnected: ((TeamPeerID) -> Void)?
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)?
    var onPeerBadFrame: ((TeamPeerID) -> Void)?
    var trace: ((Trace) -> Void)?

    @MainActor private final class Link {
        let initiatedByMe: Bool
        /// nil while a service name is being resolved (the link already counts as an unfinished dial).
        var conn: WinConnID?
        var receiver = TeamLinkReceiver()
        var isReady = false
        var handshakeTimer: Task<Void, Never>?
        init(initiatedByMe: Bool) { self.initiatedByMe = initiatedByMe }
    }

    private let advertise: Bool
    private let linkLimit: Int
    private let handshakeTimeout: TimeInterval
    private let retryDelay: TimeInterval
    /// True between the owner's `start(code:)` and `stop()`. Internal restarts only happen while set.
    private var wanted = false
    private var running = false
    private var code: TeamCode?
    /// Bumped on every teardown; timers and resolves from an older generation are dropped.
    private var generation = 0
    private var instanceName = ""
    /// The name DNS-SD registered (Windows may rename on a conflict); filtered from discovery like `instanceName`.
    private var registeredName: String?
    private var redialTimer: Timer?
    private var links: [TeamPeerID: Link] = [:]
    private var peerForConn: [WinConnID: TeamPeerID] = [:]
    private var endpoints: [String: WinTeamEndpoint] = [:]
    private var planner = TeamDialPlanner()
    private var observing = false
    private var hookedSystemEvents = false
    private let events: WindowsSystemEvents?
    private let reachability: any ReachabilityMonitoring
    private let resolver: Resolver?
    private var loop: WinSocketLoop?
    private var dnssd: WinDNSSD?

    /// Nil until the listener reports its port (and again from every teardown).
    private(set) var listenerPort: UInt16?
    /// Test and selftest seams.
    private(set) var redialFires = 0
    private(set) var discoveryEvents = 0
    var hasSocketLoop: Bool { loop != nil }
    var socketLoop: WinSocketLoop? { loop }
    /// The DNS-SD name of this run while it is running.
    var advertisedName: String? { running ? (registeredName ?? instanceName) : nil }

    /// - Parameters:
    ///   - events: sleep and wake (the app passes the platform's; nil = the platform's if it is the Windows one).
    ///   - reachability: a reconnect restarts the transport, as on the Mac (nil = a `WindowsReachabilityMonitor`).
    ///   - resolve: test seam for DNS-SD resolve (nil = `WinDNSSD.resolve`).
    init(advertise: Bool = true, linkLimit: Int = TeamTransportRules.maxLinks,
         events: WindowsSystemEvents? = nil, reachability: (any ReachabilityMonitoring)? = nil,
         resolve: Resolver? = nil,
         handshakeTimeout: TimeInterval = TeamTransportRules.handshakeTimeout,
         listenerRetryDelay: TimeInterval = TeamTransportRules.listenerRetryDelay) {
        self.advertise = advertise
        self.linkLimit = linkLimit
        self.events = events ?? (Platform.current.events as? WindowsSystemEvents)
        self.reachability = reachability ?? WindowsReachabilityMonitor()
        self.resolver = resolve
        self.handshakeTimeout = handshakeTimeout
        self.retryDelay = listenerRetryDelay
    }

    // MARK: TeamTransporting

    func start(code: TeamCode) {
        wanted = true
        self.code = code
        if running { teardown() }
        begin()
        observeSystem()
    }

    func stop() {
        wanted = false
        teardown()
        removeObservers()
    }

    func send(_ m: TeamMessage, to peer: TeamPeerID) {
        guard let link = links[peer], link.isReady, let conn = link.conn else { return }
        let frame: Data
        do { frame = try TeamWire.encode(m) } catch {
            AppLog.write("team: frame not sent (\(error))")
            return
        }
        loop?.send(frame, on: conn)   // a failed write comes back as `.closed(.error)`, which ends the link
    }

    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?) {
        guard links[peer] != nil else { return }
        if let kept, links[kept] != nil { planner.cover(peer: peer, by: kept) }
        trace?(.closed(peer: peer, reason: "disconnected by the session"))
        finish(peer, handshakeFailed: false, report: false)
    }

    func refuse(_ peer: TeamPeerID) {
        guard links[peer] != nil else { return }
        trace?(.closed(peer: peer, reason: "refused by the session"))
        finish(peer, handshakeFailed: false, refused: true, report: false)
    }

    /// Dials an endpoint directly (tests, the probe, and the DNS-SD dial path).
    func connect(to endpoint: WinTeamEndpoint) {
        _ = dial(endpoint)
    }

    /// App exit: stops silently, then joins the socket thread (`WinSocketLoop.shutdown`, once). Peers get close_notify
    /// and DNS-SD its goodbye. A later `start` would make a new loop.
    func shutdown() {
        stop()
        loop?.shutdown()
        loop = nil
        dnssd = nil
    }

    // MARK: test seams

    var linkCount: Int { links.count }
    var peerIDs: [TeamPeerID] { Array(links.keys) }

    /// Writes bytes as they are, so a test can send what `TeamWire.encode` never would.
    func sendRaw(_ data: Data, to peer: TeamPeerID) {
        guard let conn = links[peer]?.conn else { return }
        loop?.send(data, on: conn)
    }

    /// Feeds a discovery result to the dial planner as the DNS-SD browser would.
    func injectDiscovered(_ name: String, endpoint: WinTeamEndpoint) {
        endpoints[name] = endpoint
        planner.discovered(name)
        dialDue()
    }

    func plannedDials(now: Date) -> [String] { planner.dueDials(now: now) }

    /// The TLS version, cipher and remote address of a ready link (the probe prints them).
    func negotiated(_ peer: TeamPeerID) -> WinSocketLoop.Negotiated? {
        guard let conn = links[peer]?.conn else { return nil }
        return loop?.negotiated(conn)
    }

    // MARK: lifecycle

    private func begin() {
        guard let code else { return }
        running = true
        instanceName = TeamTransportRules.newInstanceName()
        registeredName = nil
        planner = TeamDialPlanner()
        endpoints = [:]
        let generation = generation
        guard startListener(code: code) else { return }
        if advertise { discovery().browse() }
        let interval = TeamTransportRules.redialInterval
        // A redial check can wait a few seconds (tolerance); let the system coalesce it.
        redialTimer = WinMainThread.repeatingTimer(every: interval, tolerance: interval / 5) { [weak self] in
            self?.redialTick(generation)
        }
    }

    private func redialTick(_ generation: Int) {
        guard self.generation == generation else { return }
        redialFires += 1
        dialDue()
    }

    /// Cancels everything without telling the owner.
    private func teardown() {
        generation += 1
        running = false
        redialTimer?.invalidate(); redialTimer = nil
        loop?.stopListening()
        listenerPort = nil
        dnssd?.stopBrowsing()
        dnssd?.deregister()
        registeredName = nil
        for link in links.values { link.handshakeTimer?.cancel() }
        loop?.closeAll()
        links = [:]
        peerForConn = [:]
        endpoints = [:]
    }

    /// Internal restart: the owner hears about every live connection first, so it never keeps a dead peer.
    private func suspend() {
        guard running else { return }
        let live = links.filter { $0.value.isReady }.keys
        teardown()
        for peer in live { onPeerDisconnected?(peer) }
    }

    func restart() {
        guard wanted, running else { return }
        suspend()
        // The owner may have stopped or restarted us from inside `onPeerDisconnected`.
        guard wanted, !running else { return }
        begin()
    }

    func handleWillSleep() { suspend() }

    func handleDidWake() {
        guard wanted, !running else { return }
        begin()
    }

    private func scheduleListenerRestart() {
        suspend()
        let delay = retryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.wanted, !self.running else { return }
            self.begin()
        }
    }

    /// The Mac reacts to `NSWorkspace` sleep / wake and to a network reconnect. Windows: the same, through the sink
    /// window's power broadcasts and the connectivity hint. Reachability alone is not enough on Windows (it reports
    /// "connected" only with internet access, which an office LAN may not have), so wake and every listener, DNS-SD
    /// registration or browse failure restart the transport as well, as on the Mac.
    private func observeSystem() {
        guard !observing else { return }
        observing = true
        if !hookedSystemEvents, let events {
            // `WindowsSystemEvents` keeps its handlers for its life, so they are added once and ask `observing`.
            hookedSystemEvents = true
            events.onWillSleepOnMain { [weak self] in
                guard let self, self.observing else { return }
                self.handleWillSleep()
            }
            events.onWakeOnMain { [weak self] in
                guard let self, self.observing else { return }
                self.handleDidWake()
            }
        }
        reachability.onReconnected = { [weak self] in
            Task { @MainActor in self?.restart() }
        }
        reachability.start()
    }

    private func removeObservers() {
        observing = false
        reachability.onReconnected = nil
        reachability.stop()
    }

    // MARK: listener and discovery

    private func socketLoopStarted() -> WinSocketLoop? {
        if let loop { return loop }
        let loop = WinSocketLoop(deliver: { [weak self] event in self?.handle(event) })
        guard loop.start() else { return nil }   // logged by the loop; the next begin() makes a new one
        self.loop = loop
        return loop
    }

    private func discovery() -> WinDNSSD {
        if let dnssd { return dnssd }
        let d = WinDNSSD(deliver: { [weak self] event in self?.handleDiscovery(event) })
        dnssd = d
        return d
    }

    private func startListener(code: TeamCode) -> Bool {
        guard let loop = socketLoopStarted() else {
            AppLog.write("team: listener not created (the socket loop did not start)")
            scheduleListenerRestart()
            return false
        }
        loop.listen(code: code)
        return true
    }

    /// DNS-SD events (`WinDNSSD` delivers on the main queue and never after `stopBrowsing`/`deregister`). Windows
    /// repeats `.found` and `.lost` (seen 4 times in a row), so both are idempotent here. Internal: tests feed it.
    func handleDiscovery(_ event: WinDNSSD.Event) {
        guard running else { return }
        discoveryEvents += 1
        trace?(.discovery(event))
        switch event {
        case .registered(let name):
            registeredName = name
        case .registerFailed(let code):
            AppLog.write("team: service registration failed (DNS-SD \(code))")
            scheduleListenerRestart()
        case .browseFailed(let code):
            discoveryFailed(code: code)
        case .found(let name):
            guard !isMine(name) else { return }
            endpoints[name] = .service(name)
            planner.discovered(name)
            dialDue()
        case .lost(let name):
            guard !isMine(name) else { return }
            endpoints[name] = nil
            planner.lost(name, now: Date())
            dialDue()
        }
    }

    /// A failed browse is handled like a failed listener: tear down and start again after a pause.
    func discoveryFailed(code: Int32) {
        AppLog.write("team: browser failed (DNS-SD \(code))")
        scheduleListenerRestart()
    }

    private func isMine(_ name: String) -> Bool { name == instanceName || name == registeredName }

    private func dialDue() {
        var rng = SystemRandomNumberGenerator()
        // A service still being resolved is an unfinished dial too.
        let unfinished = links.values.filter { $0.initiatedByMe && !$0.isReady }.count
        let room = TeamTransportRules.dialRoom(unfinishedOutbound: unfinished, linkCount: links.count, linkLimit: linkLimit)
        guard room > 0 else { return }   // every new name lands here, and a flood of them must not cost a scan each
        for name in planner.dialPicks(now: Date(), limit: room, using: &rng) {
            guard let endpoint = endpoints[name], let peer = dial(endpoint) else { continue }
            planner.dialStarted(name, peer: peer)
        }
    }

    // MARK: connections

    /// IPv4 first (no scope needed, and what the Mac answers on first), then IPv6, a link-local one with
    /// `%<interface index>` from DNS-SD: Windows cannot route `fe80::` without it.
    static func dialOrder(_ resolved: [WinSocketAddress]) -> [WinSocketAddress] {
        let v4 = resolved.filter { $0.family == .ipv4 }
        let v6 = resolved.filter { $0.family == .ipv6 }.map { a -> WinSocketAddress in
            guard isLinkLocal(a.host), !a.host.contains("%"), a.interfaceIndex != 0 else { return a }
            return WinSocketAddress(family: .ipv6, host: "\(a.host)%\(a.interfaceIndex)", port: a.port,
                                    interfaceIndex: a.interfaceIndex)
        }
        return v4 + v6
    }

    /// `fe80::/10`, from the first group of IPv6 text.
    static func isLinkLocal(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") ? String(host.dropFirst()) : host
        guard let first = bare.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
              let group = UInt16(first, radix: 16) else { return false }
        return group & 0xffc0 == 0xfe80
    }

    private func dial(_ endpoint: WinTeamEndpoint) -> TeamPeerID? {
        guard running, let code, loop != nil else { return nil }
        let id = UUID().uuidString
        let link = Link(initiatedByMe: true)
        links[id] = link
        armHandshakeTimer(id, link)
        switch endpoint {
        case .hostPort(let host, let port):
            trace?(.dialing(peer: id, to: "\(host):\(port)"))
            open(link, id: id, to: [WinSocketAddress(family: host.contains(":") ? .ipv6 : .ipv4, host: host, port: port)],
                 code: code)
        case .service(let name):
            trace?(.dialing(peer: id, to: name))
            let generation = generation
            resolve(name) { [weak self] addresses in
                guard let self, self.generation == generation, let link = self.links[id], link.conn == nil,
                      let code = self.code else { return }
                self.trace?(.resolved(name: name, addresses: addresses))
                let ordered = Self.dialOrder(addresses)
                guard !ordered.isEmpty else {
                    self.trace?(.closed(peer: id, reason: "DNS-SD found no address"))
                    self.finish(id, handshakeFailed: true)
                    return
                }
                self.open(link, id: id, to: ordered, code: code)
            }
        }
        return id
    }

    private func resolve(_ name: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void) {
        if let resolver { resolver(name, done) } else { discovery().resolve(instance: name, done) }
    }

    private func open(_ link: Link, id: TeamPeerID, to addresses: [WinSocketAddress], code: TeamCode) {
        guard let loop else { return }
        let conn = loop.dial(addresses, code: code)
        link.conn = conn
        peerForConn[conn] = id
    }

    /// Every `.accepted` is answered here, in every branch: `admit` (TLS starts) or `close` (refused, nothing allocated).
    private func accept(_ conn: WinConnID) {
        guard let loop else { return }
        guard running, TeamTransportRules.admitsInbound(
            linkCount: links.count,
            unfinishedInbound: links.values.filter({ !$0.initiatedByMe && !$0.isReady }).count,
            linkLimit: linkLimit) else {
            loop.close(conn)
            trace?(.refusedInbound)
            return
        }
        let id = UUID().uuidString
        let link = Link(initiatedByMe: false)
        link.conn = conn
        links[id] = link
        peerForConn[conn] = id
        armHandshakeTimer(id, link)
        loop.admit(conn)
        trace?(.accepted(peer: id))
    }

    private func armHandshakeTimer(_ id: TeamPeerID, _ link: Link) {
        let generation = generation
        let nanoseconds = UInt64(handshakeTimeout * 1_000_000_000)
        link.handshakeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.generation == generation, let current = self.links[id],
                  current === link, !link.isReady else { return }
            self.trace?(.closed(peer: id, reason: "handshake not finished in \(Int(self.handshakeTimeout)) s"))
            self.finish(id, handshakeFailed: link.initiatedByMe)
        }
    }

    /// Socket events, one per call, in order (`WinSocketLoop` holds back anything for an id after `close`).
    private func handle(_ event: WinSocketEvent) {
        switch event {
        case .listening(let port):
            guard running else { return }
            listenerPort = port
            trace?(.listening(port))
            if advertise {
                trace?(.registering(name: instanceName, port: port))
                discovery().register(instance: instanceName, port: port)
            }
        case .listenFailed(let code):
            guard running else { return }
            AppLog.write("team: listener failed (Winsock \(code))")
            trace?(.listenFailed(code))
            scheduleListenerRestart()
        case .accepted(let conn):
            accept(conn)
        case .ready(let conn):
            guard let id = peerForConn[conn], let link = links[id], !link.isReady else { return }
            link.isReady = true
            link.handshakeTimer?.cancel(); link.handshakeTimer = nil
            trace?(.ready(peer: id, initiatedByMe: link.initiatedByMe))
            onPeerConnected?(id, link.initiatedByMe)
            guard links[id] != nil else { return }   // the owner may have dropped it inside the callback
            loop?.receiveNext(conn)
        case .data(let conn, let data):
            guard let id = peerForConn[conn], let link = links[id] else { return }
            receive(data, id: id, link: link, conn: conn)
        case .closed(let conn, let reason):
            guard let id = peerForConn[conn], let link = links[id] else { return }
            trace?(.closed(peer: id, reason: Self.describe(reason)))
            switch reason {
            case .handshakeFailed, .unreachable:
                finish(id, handshakeFailed: link.initiatedByMe && !link.isReady)
            case .remoteClosed, .error:
                finish(id, handshakeFailed: false)
            }
        }
    }

    /// One chunk (at most `TeamTransportRules.maxReadChunk`), then the next is asked for: the Mac's `receive`.
    private func receive(_ data: Data, id: TeamPeerID, link: Link, conn: WinConnID) {
        let messages: [TeamMessage]
        switch link.receiver.receive(data, now: Date()) {
        case .messages(let decoded):
            messages = decoded
        case .badFrame(let error):
            AppLog.write("team: dropped a connection after a bad frame (\(error))")
            trace?(.closed(peer: id, reason: "bad frame"))
            onPeerBadFrame?(id)
            finish(id, handshakeFailed: false, refused: true)
            return
        case .flood:
            AppLog.write("team: dropped a connection that sent too much")
            trace?(.closed(peer: id, reason: "flood"))
            onPeerBadFrame?(id)
            finish(id, handshakeFailed: false, refused: true)
            return
        }
        for message in messages {
            guard links[id] != nil else { return }
            onMessage?(id, message)
        }
        guard links[id] != nil else { return }
        loop?.receiveNext(conn)
    }

    /// Ends one connection. `report` is false when the owner asked for it.
    private func finish(_ id: TeamPeerID, handshakeFailed: Bool, refused: Bool = false, report: Bool = true) {
        guard let link = links.removeValue(forKey: id) else { return }
        link.handshakeTimer?.cancel(); link.handshakeTimer = nil
        if let conn = link.conn {
            peerForConn[conn] = nil
            loop?.close(conn)
        }
        planner.connectionEnded(peer: id, handshakeFailed: handshakeFailed, refused: refused, now: Date())
        if report, link.isReady { onPeerDisconnected?(id) }
    }

    private static func describe(_ reason: WinCloseReason) -> String {
        switch reason {
        case .handshakeFailed(let why): return "TLS handshake failed (\(why))"
        case .unreachable(let code): return "unreachable (Winsock \(code))"
        case .remoteClosed: return "closed by the peer"
        case .error(let code): return "socket error (Winsock \(code))"
        }
    }
}
#endif
