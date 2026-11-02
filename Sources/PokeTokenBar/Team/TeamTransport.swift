import AppKit
import Foundation
import Network
import Security

@MainActor
protocol TeamTransporting: AnyObject {
    var onPeerConnected: ((TeamPeerID, _ initiatedByMe: Bool) -> Void)? { get set }
    var onPeerDisconnected: ((TeamPeerID) -> Void)? { get set }
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)? { get set }
    /// A frame could not be decoded. The transport drops the link and holds off dialing its endpoint.
    var onPeerBadFrame: ((TeamPeerID) -> Void)? { get set }

    func start(code: TeamCode)
    /// Silent: no callbacks after this returns.
    func stop()
    func send(_ m: TeamMessage, to peer: TeamPeerID)
    /// Owner-initiated and silent (no `onPeerDisconnected`). With `kept`, the endpoint of `peer` is not
    /// dialed again while `kept` stays alive. Unknown peers are ignored.
    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?)
    /// Like `disconnect`, but the owner does not want this peer: its endpoint is not dialed again for 5 minutes.
    func refuse(_ peer: TeamPeerID)
}

/// Bonjour discovery plus TCP/TLS-PSK connections keyed by the team code. All state lives on the main
/// actor; Network.framework runs on `.main` and hops in through `MainActor.assumeIsolated`.
@MainActor
final class BonjourTeamTransport: TeamTransporting {
    static let serviceType = "_ptbteam._tcp"
    private static let handshakeTimeout: TimeInterval = 10
    private static let redialInterval: TimeInterval = 15
    private static let listenerRetryDelay: TimeInterval = 5
    /// Inbound links that have not finished their handshake. Anyone on the network can open these without
    /// the team code, so the rest are cancelled.
    static let maxUnfinishedInbound = 32

    var onPeerConnected: ((TeamPeerID, Bool) -> Void)?
    var onPeerDisconnected: ((TeamPeerID) -> Void)?
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)?
    var onPeerBadFrame: ((TeamPeerID) -> Void)?

    private final class Link {
        let connection: NWConnection
        let initiatedByMe: Bool
        var decoder = TeamWire.FrameDecoder()
        var isReady = false
        var handshakeTimer: DispatchWorkItem?
        init(connection: NWConnection, initiatedByMe: Bool) {
            self.connection = connection
            self.initiatedByMe = initiatedByMe
        }
    }

    private let advertise: Bool
    /// True between the owner's `start(code:)` and `stop()`. Internal restarts only happen while set.
    private var wanted = false
    private var running = false
    private var code: TeamCode?
    /// Bumped on every teardown; callbacks from an older generation are dropped.
    private var generation = 0
    private var instanceName = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var redialTimer: Timer?
    private var links: [TeamPeerID: Link] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var planner = TeamDialPlanner()
    private var observers: [NSObjectProtocol] = []
    private let reachability = NetworkReachabilityMonitor()

    private var listenerIsReady = false

    /// Nil until the listener is ready (before that the framework reports port 0).
    var listenerPort: NWEndpoint.Port? { listenerIsReady ? listener?.port : nil }

    init(advertise: Bool = true) {
        self.advertise = advertise
    }

    static func parameters(code: TeamCode) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = code.pskKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = TeamCode.pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        return parameters
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
        guard let link = links[peer], link.isReady else { return }
        let frame: Data
        do { frame = try TeamWire.encode(m) } catch {
            AppLog.write("team: frame not sent (\(error))")
            return
        }
        let generation = generation
        link.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.finish(peer, handshakeFailed: false)
            }
        })
    }

    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?) {
        guard links[peer] != nil else { return }
        if let kept, links[kept] != nil { planner.cover(peer: peer, by: kept) }
        finish(peer, handshakeFailed: false, report: false)
    }

    func refuse(_ peer: TeamPeerID) {
        guard links[peer] != nil else { return }
        finish(peer, handshakeFailed: false, refused: true, report: false)
    }

    /// Dials an endpoint directly (tests, and the Bonjour dial path).
    func connect(to endpoint: NWEndpoint) {
        _ = dial(endpoint)
    }

    // MARK: test seams

    var linkCount: Int { links.count }
    var peerIDs: [TeamPeerID] { Array(links.keys) }

    /// Writes bytes as they are, so a test can send what `TeamWire.encode` never would.
    func sendRaw(_ data: Data, to peer: TeamPeerID) {
        links[peer]?.connection.send(content: data, completion: .idempotent)
    }

    /// Feeds a discovery result to the dial planner as the Bonjour browser would.
    func injectDiscovered(_ name: String, endpoint: NWEndpoint) {
        endpoints[name] = endpoint
        planner.discovered(name)
        dialDue()
    }

    func plannedDials(now: Date) -> [String] { planner.dueDials(now: now) }

    // MARK: lifecycle

    private func begin() {
        guard let code else { return }
        running = true
        instanceName = "ptb-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        planner = TeamDialPlanner()
        endpoints = [:]
        let generation = generation
        guard startListener(code: code, generation: generation) else { return }
        if advertise { startBrowser(generation: generation) }
        let timer = Timer(timeInterval: Self.redialInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.dialDue()
            }
        }
        timer.tolerance = Self.redialInterval / 5   // a redial check can wait a few seconds; let the system coalesce it
        RunLoop.main.add(timer, forMode: .common)
        redialTimer = timer
    }

    /// Cancels everything without telling the owner.
    private func teardown() {
        generation += 1
        running = false
        redialTimer?.invalidate(); redialTimer = nil
        listener?.cancel(); listener = nil
        listenerIsReady = false
        browser?.cancel(); browser = nil
        for link in links.values {
            link.handshakeTimer?.cancel()
            link.connection.cancel()
        }
        links = [:]
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
        let delay = Self.listenerRetryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.wanted, !self.running else { return }
            self.begin()
        }
    }

    private func observeSystem() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })
        reachability.onReconnected = { [weak self] in
            Task { @MainActor in self?.restart() }
        }
        reachability.start()
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        observers = []
        reachability.onReconnected = nil
        reachability.stop()
    }

    // MARK: listener and browser

    private func startListener(code: TeamCode, generation: Int) -> Bool {
        let listener: NWListener
        do { listener = try NWListener(using: Self.parameters(code: code)) } catch {
            AppLog.write("team: listener not created (\(error))")
            scheduleListenerRestart()
            return false
        }
        if advertise { listener.service = NWListener.Service(name: instanceName, type: Self.serviceType) }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.listenerIsReady = true
                case .failed(let error):
                    AppLog.write("team: listener failed (\(error))")
                    self.scheduleListenerRestart()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { connection.cancel(); return }
                self.adopt(connection, initiatedByMe: false, generation: generation)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        return true
    }

    private func startBrowser(generation: Int) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                for change in changes {
                    switch change {
                    case .added(let result): self.found(result)
                    case .removed(let result): self.lost(result)
                    case .changed(_, let new, _): self.found(new)
                    default: break
                    }
                }
                self.dialDue()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.browserStateChanged(state)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// A failed browser is handled like a failed listener: tear down and start again after a pause.
    func browserStateChanged(_ state: NWBrowser.State) {
        guard case .failed(let error) = state else { return }
        AppLog.write("team: browser failed (\(error))")
        scheduleListenerRestart()
    }

    private func serviceName(_ result: NWBrowser.Result) -> String? {
        guard case .service(let name, _, _, _) = result.endpoint, name != instanceName else { return nil }
        return name
    }

    private func found(_ result: NWBrowser.Result) {
        guard let name = serviceName(result) else { return }
        endpoints[name] = result.endpoint
        planner.discovered(name)
    }

    private func lost(_ result: NWBrowser.Result) {
        guard let name = serviceName(result) else { return }
        endpoints[name] = nil
        planner.lost(name)
    }

    private func dialDue() {
        for name in planner.dueDials(now: Date()) {
            guard let endpoint = endpoints[name], let peer = dial(endpoint) else { continue }
            planner.dialStarted(name, peer: peer)
        }
    }

    // MARK: connections

    private func dial(_ endpoint: NWEndpoint) -> TeamPeerID? {
        guard running, let code else { return nil }
        let connection = NWConnection(to: endpoint, using: Self.parameters(code: code))
        return adopt(connection, initiatedByMe: true, generation: generation)
    }

    @discardableResult
    private func adopt(_ connection: NWConnection, initiatedByMe: Bool, generation: Int) -> TeamPeerID {
        let id = UUID().uuidString
        if !initiatedByMe, links.values.filter({ !$0.initiatedByMe && !$0.isReady }).count >= Self.maxUnfinishedInbound {
            connection.cancel()
            return id
        }
        let link = Link(connection: connection, initiatedByMe: initiatedByMe)
        links[id] = link
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.handle(state, of: id)
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.links[id]?.isReady == false else { return }
                self.finish(id, handshakeFailed: initiatedByMe)
            }
        }
        link.handshakeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: timer)
        connection.start(queue: .main)
        return id
    }

    private func handle(_ state: NWConnection.State, of id: TeamPeerID) {
        guard let link = links[id] else { return }
        switch state {
        case .ready:
            guard !link.isReady else { return }
            link.isReady = true
            link.handshakeTimer?.cancel()
            onPeerConnected?(id, link.initiatedByMe)
            receive(id, generation: generation)
        case .waiting:
            // A dialed connection that cannot complete (typically a different team code) is a failure, not a retry.
            if link.initiatedByMe, !link.isReady { finish(id, handshakeFailed: true) }
        case .failed:
            finish(id, handshakeFailed: link.initiatedByMe && !link.isReady)
        case .cancelled:
            finish(id, handshakeFailed: false)
        default:
            break
        }
    }

    private func receive(_ id: TeamPeerID, generation: Int) {
        guard let link = links[id] else { return }
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, let link = self.links[id] else { return }
                if let data, !data.isEmpty {
                    let messages: [TeamMessage]
                    do { messages = try link.decoder.append(data) } catch {
                        AppLog.write("team: dropped a connection after a bad frame (\(error))")
                        self.onPeerBadFrame?(id)
                        self.finish(id, handshakeFailed: false, refused: true)
                        return
                    }
                    for message in messages {
                        guard self.links[id] != nil else { return }
                        self.onMessage?(id, message)
                    }
                }
                if error != nil || isComplete {
                    self.finish(id, handshakeFailed: false)
                } else if self.links[id] != nil {
                    self.receive(id, generation: generation)
                }
            }
        }
    }

    /// Ends one connection. `report` is false when the owner asked for it.
    private func finish(_ id: TeamPeerID, handshakeFailed: Bool, refused: Bool = false, report: Bool = true) {
        guard let link = links.removeValue(forKey: id) else { return }
        link.handshakeTimer?.cancel()
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        planner.connectionEnded(peer: id, handshakeFailed: handshakeFailed, refused: refused, now: Date())
        if report, link.isReady { onPeerDisconnected?(id) }
    }
}
