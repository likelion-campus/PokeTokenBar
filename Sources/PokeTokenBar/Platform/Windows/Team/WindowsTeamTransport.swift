#if os(Windows)
import Foundation

/// Where a Windows transport dials: a DNS-SD instance (resolved when dialled) or a numeric host and port.
enum WinTeamEndpoint: Equatable, Sendable {
    case service(String)
    case hostPort(String, UInt16)
}

/// What the transport needs from DNS-SD (`WinDNSSD` in the app; a fake in the tests). Main thread.
@MainActor protocol WinTeamDiscovery: AnyObject {
    func register(instance: String, port: UInt16)
    func deregister()
    /// Deregisters and waits (bounded) for the goodbye to leave; nil when nothing was announced.
    func deregister(waitingUpTo seconds: TimeInterval) -> Bool?
    func browse()
    func stopBrowsing()
    func resolve(instance: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void)
    /// When the current browse last heard an answer for `name`, repeats included.
    func lastAnswer(_ name: String) -> Date?
    /// Its next announcement is reported as `.found` again.
    func forget(_ name: String)
}

extension WinDNSSD: WinTeamDiscovery {}

/// The Windows `TeamTransporting`: DNS-SD discovery (`WinDNSSD`), TLS-PSK links on one socket thread
/// (`WinSocketLoop`), and every decision the Mac's `BonjourTeamTransport` makes, taken from the shared rules
/// (`TeamTransportRules`, `TeamLinkReceiver`, `TeamDialPlanner`). It mirrors that class line by line: the same states
/// (`wanted`, `running`, `generation`), the same callback order, the same timers and hold-offs. Both pass the same
/// contract (`TeamTransportContract`). All state lives on the main actor; the loop and DNS-SD deliver on the main queue.
///
/// Nothing is opened until `start(code:)`: no thread, no socket, no DNS-SD request, so an app without a team code
/// never listens (no firewall prompt).
///
/// Where Windows needs more than the Mac, because Windows' DNS-SD behaves differently:
/// - A name is forgotten after `absentDialsBeforeForgetting` dials in a row that found no service (no address, the
///   address unreachable, or no TLS answer in time) with no DNS-SD answer for it in between. Windows drops a name only
///   on a goodbye packet; the Mac's mDNS cache also expires names whose announcements stop.
/// - A DNS-SD registration failure, and a browse failure after the first, do not tear the links down: only the failed
///   part is retried, with a backoff (`discoveryRetryDelay`), logged once per step. The first browse failure restarts
///   everything, as the Mac's `browserStateChanged(.failed)` does.
///
/// Timers (each states what arms it and what ends it):
/// - redial: `Timer` every `redialInterval` (15 s, tolerance 3 s) on the main run loop, from `begin()` to the next
///   teardown, exactly as the Mac's. The only periodic wake of a running transport.
/// - handshake: one task per unfinished link, `handshakeTimeout` (10 s) from the dial (DNS-SD resolve time included)
///   or the accept; cancelled when the link is ready or ends, and by every teardown.
/// - listener retry: one task `listenerRetryDelay` (5 s) after a listener failure or the first browse failure.
/// - DNS-SD retry: one task per failed part (registration, browse), 5 s doubling to 5 min, only after a failure.
@MainActor
final class WindowsTeamTransport: TeamTransporting {
    typealias Resolver = @MainActor (String, @escaping @MainActor ([WinSocketAddress]) -> Void) -> Void
    typealias DiscoveryFactory = @MainActor (@escaping @MainActor (WinDNSSD.Event) -> Void) -> any WinTeamDiscovery

    /// Dials in a row that found no service, with no DNS-SD answer for the name in between, before it is forgotten.
    static let absentDialsBeforeForgetting = 3
    /// The longest wait between DNS-SD retries.
    static let discoveryRetryCap: TimeInterval = 300
    /// How long an exit waits for the DNS-SD goodbye to leave.
    static let goodbyeWait: TimeInterval = 0.5

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
        case forgotten(name: String)
        case retrying(what: String, attempt: Int, delay: TimeInterval)
    }

    /// The production values, pinned against the shared rules by a test.
    struct Timing: Equatable {
        let handshakeTimeout: TimeInterval
        let listenerRetryDelay: TimeInterval
        let discoveryRetryBase: TimeInterval
        let discoveryRetryCap: TimeInterval
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
        var receiver: TeamLinkReceiver
        /// The remote host of an inbound link (no port, no scope), the key of the per-address limits; nil for a dial.
        let address: String?
        var isReady = false
        var handshakeTimer: Task<Void, Never>?
        init(initiatedByMe: Bool, address: String? = nil, startingTokens: Double? = nil) {
            self.initiatedByMe = initiatedByMe
            self.address = address
            receiver = TeamLinkReceiver(startingTokens: startingTokens)
        }
    }

    private enum DiscoveryPart: String { case registration, browse }

    private let advertise: Bool
    private let loopbackOnly: Bool
    private let linkLimit: Int
    let timing: Timing
    private let clock: @MainActor () -> Date
    private let log: @MainActor (String) -> Void
    /// True between the owner's `start(code:)` and `stop()`. Internal restarts only happen while set.
    private var wanted = false
    private var running = false
    private var code: TeamCode?
    /// Bumped on every teardown; timers, resolves and accepts from an older generation are dropped.
    private var generation = 0
    /// The loop's listener generation (`listen` return value) -> the transport generation that opened it: an accept
    /// by a listener of an older generation is refused, as the Mac's `newConnectionHandler` refuses one.
    private var listenGenerations: [Int: Int] = [:]
    private var instanceName = ""
    /// The name DNS-SD registered (Windows may rename on a conflict); filtered from discovery like `instanceName`.
    private var registeredName: String?
    private var redialTimer: Timer?
    private var links: [TeamPeerID: Link] = [:]
    private var peerForConn: [WinConnID: TeamPeerID] = [:]
    private var endpoints: [String: WinTeamEndpoint] = [:]
    private var planner = TeamDialPlanner()
    private var floods = TeamFloodMemory()
    /// The name each running dial came from, and each name's streak of dials that found no service.
    private var dialName: [TeamPeerID: String] = [:]
    private var absence: [String: (count: Int, since: Date)] = [:]
    private var foundAt: [String: Date] = [:]
    private var failures: [DiscoveryPart: Int] = [:]
    private var retryTasks: [DiscoveryPart: Task<Void, Never>] = [:]
    private var observing = false
    private var hookedSystemEvents = false
    private let events: WindowsSystemEvents?
    private let reachability: any ReachabilityMonitoring
    private let resolver: Resolver?
    private let makeDiscovery: DiscoveryFactory?
    private var loop: WinSocketLoop?
    private var dnssd: (any WinTeamDiscovery)?

    /// Nil until the listener reports its port (and again from every teardown).
    private(set) var listenerPort: UInt16?
    /// Test and selftest seams.
    private(set) var redialFires = 0
    private(set) var discoveryEvents = 0
    /// Whether the last `shutdown()` saw the DNS-SD goodbye leave (nil: nothing was announced).
    private(set) var lastGoodbye: Bool?
    var hasSocketLoop: Bool { loop != nil }
    var socketLoop: WinSocketLoop? { loop }
    var redialTimerInterval: TimeInterval? { redialTimer?.timeInterval }
    /// The DNS-SD name of this run while it is running.
    var advertisedName: String? { running ? (registeredName ?? instanceName) : nil }

    /// - Parameters:
    ///   - loopbackOnly: listen on `[::1]` only (the selftest on a person's PC); the caller dials with `connect(to:)`, so pair it with `advertise: false`.
    ///   - events: sleep and wake (the app passes the platform's; nil = the platform's if it is the Windows one).
    ///   - reachability: a reconnect restarts the transport, as on the Mac (nil = a `WindowsReachabilityMonitor`).
    ///   - resolve, discovery, clock, log: test seams (nil = `WinDNSSD`; the clock drives the dial planner and the
    ///     absence rule).
    init(advertise: Bool = true, loopbackOnly: Bool = false, linkLimit: Int = TeamTransportRules.maxLinks,
         events: WindowsSystemEvents? = nil, reachability: (any ReachabilityMonitoring)? = nil,
         resolve: Resolver? = nil, discovery: DiscoveryFactory? = nil,
         handshakeTimeout: TimeInterval = TeamTransportRules.handshakeTimeout,
         listenerRetryDelay: TimeInterval = TeamTransportRules.listenerRetryDelay,
         discoveryRetryBase: TimeInterval = TeamTransportRules.listenerRetryDelay,
         discoveryRetryCap: TimeInterval = WindowsTeamTransport.discoveryRetryCap,
         clock: @escaping @MainActor () -> Date = { Date() },
         log: @escaping @MainActor (String) -> Void = { AppLog.write($0) }) {
        self.advertise = advertise
        self.loopbackOnly = loopbackOnly
        self.linkLimit = linkLimit
        self.events = events ?? (Platform.current.events as? WindowsSystemEvents)
        self.reachability = reachability ?? WindowsReachabilityMonitor()
        self.resolver = resolve
        self.makeDiscovery = discovery
        timing = Timing(handshakeTimeout: handshakeTimeout, listenerRetryDelay: listenerRetryDelay,
                        discoveryRetryBase: discoveryRetryBase, discoveryRetryCap: discoveryRetryCap)
        self.clock = clock
        self.log = log
    }

    // MARK: TeamTransporting

    func start(code: TeamCode) {
        wanted = true
        self.code = code
        resetDiscoveryRetries()
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

    /// App exit: withdraws the advertisement and waits (at most `goodbyeWait`, and never past `seconds` in all) for the
    /// goodbye to leave, so Macs remove the service at once; then stops silently (peers get close_notify) and waits for
    /// the socket thread within what is left of `seconds` (`WinSocketLoop.shutdown(within:)`: a thread that does not come
    /// back is abandoned with one log line). A later `start` would make a new loop.
    func shutdown(within seconds: TimeInterval = WinSocketLoop.shutdownBound) {
        let started = Date()
        lastGoodbye = dnssd?.deregister(waitingUpTo: min(Self.goodbyeWait, max(0, seconds)))
        if let goodbye = lastGoodbye {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("team: DNS-SD goodbye \(goodbye ? "sent" : "not confirmed") after \(ms) ms")
            if !goodbye { log("exit: abandoned DNS-SD goodbye after \(ms) ms") }
        }
        stop()
        loop?.shutdown(within: max(0.25, seconds - Date().timeIntervalSince(started)))
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

    /// What the redial timer does, now (tests with a fake clock).
    func redialNow() { dialDue() }

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
        dialName = [:]
        absence = [:]
        foundAt = [:]
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
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
        resetDiscoveryRetries()   // a network change: DNS-SD gets a fresh start
        suspend()
        // The owner may have stopped or restarted us from inside `onPeerDisconnected`.
        guard wanted, !running else { return }
        begin()
    }

    func handleWillSleep() { suspend() }

    func handleDidWake() {
        guard wanted, !running else { return }
        resetDiscoveryRetries()
        begin()
    }

    private func scheduleListenerRestart() {
        suspend()
        let delay = timing.listenerRetryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.wanted, !self.running else { return }
            self.begin()
        }
    }

    /// The Mac reacts to `NSWorkspace` sleep / wake and to a network reconnect. Windows: the same, through the sink
    /// window's power broadcasts and the connectivity hint. Reachability alone is not enough on Windows (it reports
    /// "connected" only with internet access, which an office LAN may not have), so wake and every listener failure
    /// restart the transport as well, as on the Mac, and DNS-SD failures retry on their own.
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
        let loop = WinSocketLoop(deliver: { [weak self] event in self?.handle(event) }, loopbackOnly: loopbackOnly)
        guard loop.start() else { return nil }   // logged by the loop; the next begin() makes a new one
        self.loop = loop
        return loop
    }

    private func discovery() -> any WinTeamDiscovery {
        if let dnssd { return dnssd }
        let deliver: @MainActor (WinDNSSD.Event) -> Void = { [weak self] event in self?.handleDiscovery(event) }
        let d = makeDiscovery?(deliver) ?? WinDNSSD(deliver: deliver)
        dnssd = d
        return d
    }

    private func startListener(code: TeamCode) -> Bool {
        guard let loop = socketLoopStarted() else {
            AppLog.write("team: listener not created (the socket loop did not start)")
            scheduleListenerRestart()
            return false
        }
        let token = loop.listen(code: code)
        listenGenerations[token] = generation
        listenGenerations = listenGenerations.filter { $0.key > token - 8 }   // a few restarts' worth
        return true
    }

    /// DNS-SD events (`WinDNSSD` delivers on the main queue and never after `stopBrowsing`/`deregister`; it drops
    /// repeated answers before the main thread, and both kinds are idempotent here anyway). Internal: tests feed it.
    func handleDiscovery(_ event: WinDNSSD.Event) {
        guard running else { return }
        discoveryEvents += 1
        trace?(.discovery(event))
        switch event {
        case .registered(let name):
            registeredName = name
            recovered(.registration)
        case .registerFailed(let code):
            discoveryPartFailed(.registration, code: code)
        case .browseFailed(let code):
            discoveryFailed(code: code)
        case .found(let name):
            recovered(.browse)   // the browse works (it finds this run's own service too)
            guard !isMine(name) else { return }
            foundAt[name] = clock()
            endpoints[name] = .service(name)
            if let evicted = planner.discovered(name) { forgetName(evicted) }
            dialDue()
        case .lost(let name):
            guard !isMine(name) else { return }
            endpoints[name] = nil
            foundAt[name] = nil
            absence[name] = nil
            planner.lost(name, now: clock())
            dialDue()
        }
    }

    /// A failed browse. The first one (since the owner's start, a wake or a network change) is the Mac's browser
    /// `.failed` (`BonjourTeamTransport.browserStateChanged`): tear down and start again after the listener retry
    /// delay. If browsing fails again after that, only the browse is retried, with the DNS-SD backoff: the listener
    /// and the links stay (the Mac's browser waits in `.waiting` meanwhile and keeps its links too).
    func discoveryFailed(code: Int32) {
        let n = (failures[.browse] ?? 0) + 1
        failures[.browse] = n
        guard n > 1 else {
            log("team: browser failed (DNS-SD \(code))")
            scheduleListenerRestart()
            return
        }
        scheduleRetry(.browse, code: code, attempt: n - 1)
    }

    /// A failed registration: only the registration is retried, with the backoff; the links stay.
    private func discoveryPartFailed(_ part: DiscoveryPart, code: Int32) {
        let n = (failures[part] ?? 0) + 1
        failures[part] = n
        scheduleRetry(part, code: code, attempt: n)
    }

    /// The delay before retry `attempt` (1, 2, …): base, doubling, capped.
    static func backoff(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, attempt - 1))))
    }

    private func scheduleRetry(_ part: DiscoveryPart, code: Int32, attempt: Int) {
        let delay = Self.backoff(attempt: attempt, base: timing.discoveryRetryBase, cap: timing.discoveryRetryCap)
        let previous = attempt > 1 ? Self.backoff(attempt: attempt - 1, base: timing.discoveryRetryBase, cap: timing.discoveryRetryCap) : 0
        if delay != previous {   // once per backoff step: the first failure, each doubling, reaching the cap
            let atCap = delay >= timing.discoveryRetryCap
            log("team: DNS-SD \(part.rawValue) failed (\(code)); retrying in \(Int(delay)) s"
                + (atCap ? ", then every \(Int(delay)) s, not logged again until it works" : ""))
        }
        trace?(.retrying(what: part.rawValue, attempt: attempt, delay: delay))
        retryTasks[part]?.cancel()
        let generation = generation
        retryTasks[part] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == generation, self.running, self.advertise else { return }
            self.retryTasks[part] = nil
            switch part {
            case .registration:
                guard let port = self.listenerPort else { return }
                self.trace?(.registering(name: self.instanceName, port: port))
                self.discovery().register(instance: self.instanceName, port: port)
            case .browse:
                self.discovery().stopBrowsing()
                self.discovery().browse()
            }
        }
    }

    private func recovered(_ part: DiscoveryPart) {
        guard let n = failures[part], n > 0 else { return }
        failures[part] = 0
        if part == .registration || n > 1 { log("team: DNS-SD \(part.rawValue) works again") }
    }

    private func resetDiscoveryRetries() {
        failures = [:]
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
    }

    /// A name the planner made room by dropping: out of every table that holds it, and out of DNS-SD's repeat filter.
    private func forgetName(_ name: String) {
        endpoints[name] = nil
        foundAt[name] = nil
        absence[name] = nil
        dnssd?.forget(name)
    }

    private func isMine(_ name: String) -> Bool { name == instanceName || name == registeredName }

    private func dialDue() {
        var rng = SystemRandomNumberGenerator()
        // A service still being resolved is an unfinished dial too.
        let unfinished = links.values.filter { $0.initiatedByMe && !$0.isReady }.count
        let room = TeamTransportRules.dialRoom(unfinishedOutbound: unfinished, linkCount: links.count, linkLimit: linkLimit)
        guard room > 0 else { return }   // every new name lands here, and a flood of them must not cost a scan each
        for name in planner.dialPicks(now: clock(), limit: room, using: &rng) {
            guard let endpoint = endpoints[name], let peer = dial(endpoint) else { continue }
            planner.dialStarted(name, peer: peer)
            dialName[peer] = name
        }
    }

    /// A dial of `name` found no service. `absentDialsBeforeForgetting` of those in a row, with no DNS-SD answer for
    /// the name since the first of them, and the name is forgotten: out of the planner (no more resolves, no dial
    /// slot) and out of DNS-SD's repeat filter, so its next real announcement is found again. Costs nothing while
    /// nothing fails: no timer, only the dial outcomes.
    private func noteAbsent(_ name: String) {
        let now = clock()
        var streak = absence[name] ?? (count: 0, since: now)
        let answered = [foundAt[name], dnssd?.lastAnswer(name)].compactMap { $0 }.max()
        if let answered, answered > streak.since { streak = (count: 0, since: now) }   // it answered in between
        streak.count += 1
        guard streak.count >= Self.absentDialsBeforeForgetting else {
            absence[name] = streak
            return
        }
        absence[name] = nil
        foundAt[name] = nil
        endpoints[name] = nil
        planner.lost(name, now: .distantFuture)   // gone now, cooldown or not (no dial of it is running)
        dnssd?.forget(name)
        trace?(.forgotten(name: name))
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
                    self.finish(id, handshakeFailed: true, absent: true)
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

    /// Every `.accepted` is answered here, in every branch: `admit` (TLS starts) or `close` (refused, nothing
    /// allocated). One taken by a listener of an older generation (a stop and start in one turn, a new team code) is
    /// refused: it would run TLS with that listener's, the old code's, key.
    private func accept(_ conn: WinConnID) {
        guard let loop else { return }
        let current = loop.listenerGeneration(of: conn).flatMap { listenGenerations[$0] } == generation
        let address = loop.remoteHost(of: conn).map(TeamTransportRules.addressKey)
        let same = links.values.filter { !$0.initiatedByMe && address != nil && $0.address == address }
        guard running, current, TeamTransportRules.admitsInbound(
            linkCount: links.count,
            unfinishedInbound: links.values.filter({ !$0.initiatedByMe && !$0.isReady }).count,
            linkLimit: linkLimit,
            linksFromAddress: same.count,
            unfinishedFromAddress: same.filter { !$0.isReady }.count) else {
            loop.close(conn)
            trace?(.refusedInbound)
            return
        }
        let id = UUID().uuidString
        let link = Link(initiatedByMe: false, address: address,
                        startingTokens: address.flatMap { floods.startingTokens(for: $0, now: clock()) })
        link.conn = conn
        links[id] = link
        peerForConn[conn] = id
        armHandshakeTimer(id, link)
        loop.admit(conn)
        trace?(.accepted(peer: id))
    }

    private func armHandshakeTimer(_ id: TeamPeerID, _ link: Link) {
        let generation = generation
        let timeout = timing.handshakeTimeout
        link.handshakeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == generation, let current = self.links[id],
                  current === link, !link.isReady else { return }
            self.trace?(.closed(peer: id, reason: "handshake not finished in \(Int(timeout)) s"))
            self.finish(id, handshakeFailed: link.initiatedByMe, absent: link.initiatedByMe)
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
            if let name = dialName[id] { absence[name] = nil }   // the service is there
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
            case .handshakeFailed:   // something answered: alive, of another team or not ours
                finish(id, handshakeFailed: link.initiatedByMe && !link.isReady)
            case .unreachable:
                finish(id, handshakeFailed: link.initiatedByMe && !link.isReady, absent: link.initiatedByMe && !link.isReady)
            case .remoteClosed, .error:
                finish(id, handshakeFailed: false)
            }
        }
    }

    /// One chunk (at most `TeamTransportRules.maxReadChunk`), then the next is asked for: the Mac's `receive`.
    /// Each chunk is charged to the link's budget and decoded before any of its messages is delivered, in the order
    /// the loop delivers chunks (FIFO per link), so asking for the next chunk earlier could not reorder messages or
    /// let a chunk past the budget: it only lets one more chunk wait in the loop (dropped if the link ends).
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
            if let address = link.address { floods.noteFlood(from: address, now: clock()) }
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

    /// Ends one connection. `report` is false when the owner asked for it. `absent`: a dial that found no service.
    private func finish(_ id: TeamPeerID, handshakeFailed: Bool, refused: Bool = false, report: Bool = true,
                        absent: Bool = false) {
        guard let link = links.removeValue(forKey: id) else { return }
        link.handshakeTimer?.cancel(); link.handshakeTimer = nil
        if let conn = link.conn {
            peerForConn[conn] = nil
            loop?.close(conn)
        }
        planner.connectionEnded(peer: id, handshakeFailed: handshakeFailed, refused: refused, now: clock())
        if let name = dialName.removeValue(forKey: id), absent { noteAbsent(name) }
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
