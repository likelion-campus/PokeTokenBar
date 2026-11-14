#if os(Windows)
import CTeamTLS
import Foundation
import WinSDK

/// `PokeTokenBar.exe --team-probe [--code-stdin] [--host <address or name> --port <port>] [--seconds 60]
/// [--until-pass] [--selftest-out <file>]`: what the PC check runs next to a Mac teammate. No tray, no window, no
/// single-instance lock (it may run next to the app). It joins the team with the real transport and a real
/// `TeamSession` under the nickname `WinProbe` (a Mac teammate sees it appear), on temporary settings that never
/// reach the disk, and prints plain lines: the local addresses and interface indexes, the listener port the firewall
/// must let in, each service found, each dial and accept with the TLS version and cipher, the handshake outcome, the
/// first message, and `RESULT PASS|FAIL`. The code comes from stdin (`--code-stdin`) or else from the app's saved
/// settings (`--set-team-code`); it is never printed, nor is the key: `key_fingerprint` is 8 hex digits of SHA-256 over
/// the key, which `scripts/team-interop-check.sh --fingerprint` computes on a Mac. Exit 0 = PASS, 1 = FAIL, 2 = no code.
@MainActor enum WindowsTeamProbe {
    static func main(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let out = value("--selftest-out").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PokeTokenBar-team-probe.txt")
        let seconds = value("--seconds").flatMap { Int($0) } ?? 60
        let host = value("--host"), port = value("--port").flatMap { UInt16($0) }
        let code = arguments.contains("--code-stdin") ? readLine().flatMap { TeamCode(parsing: $0) } : savedCode()
        guard let code else {
            let log = ProbeLog(out)
            log.line("RESULT FAIL no team code: pipe one in with --code-stdin, or save one with --set-team-code")
            WindowsApp.exit(2, .helper)
        }
        let strategy = WinMainLoop.prepare()
        Task { @MainActor in
            let status = await WindowsTeamProbe.run(code: code, host: host, port: port, seconds: seconds, out: out,
                                   untilPass: arguments.contains("--until-pass"))
            WindowsApp.exit(status, .helper)
        }
        WinMainLoop.run(strategy) { false }
        WindowsApp.exit(1, .helper)
    }

    /// The code the app would use, read without writing anything (a running app keeps its own copy of the settings).
    private static func savedCode() -> TeamCode? {
        let suite = TeamSettings.suiteName(for: AppStatePaths.directory(), defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
        let defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        return defaults.string(forKey: "team.code").flatMap { TeamCode(parsing: $0) }
    }

    static func run(code: TeamCode, host: String?, port: UInt16?, seconds: Int, out: URL, untilPass: Bool = false) async -> Int32 {
        let log = ProbeLog(out)
        log.line("PROBE version=\(WindowsInstall.version ?? "dev") openssl=\(String(cString: ptb_tls_openssl_version())) "
            + "key_fingerprint=\(code.keyFingerprint) tls=TLSv1.2 suite=PSK-AES128-GCM-SHA256 identity=ptb-team-v1 "
            + "service=\(TeamTransportRules.serviceType) mode=\(host == nil ? "dns-sd" : "direct") seconds=\(seconds)")
        for line in localAddressLines() { log.line(line) }

        // Temporary settings: a plain suite is never written to disk on Windows unless synchronized (F2), so the probe
        // leaves the user's settings and plist alone.
        let suite = "ptb.probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = "WinProbe"
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = WindowsTeamTransport(advertise: host == nil, events: Platform.current.events as? WindowsSystemEvents)
        let tap = ProbeTap(transport, log)
        transport.trace = { [weak tap] in tap?.trace($0) }
        let memberID = settings.memberID
        let session = TeamSession(settings: settings, feed: feed, transport: tap, profileProvider: {
            TeamMemberProfile(memberID: memberID, nickname: "WinProbe",
                              current: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil),
                              dex: [])
        })
        session.applySettings()   // starts the transport, as the app's session does

        if let host, let port {
            let deadline = Date().addingTimeInterval(5)
            while transport.listenerPort == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            let numeric = await numericHost(host, port: port)
            log.line("HOST \(host) -> \(numeric.map { "\($0.host):\($0.port)" } ?? "no address")")
            if let numeric { transport.connect(to: .hostPort(numeric.host, port)) }
        }

        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(seconds))
        var passedAt: Date?
        var nextTick = started.addingTimeInterval(TeamRuntime.tickInterval)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Date() >= nextTick {   // heartbeats, as TeamRuntime ticks: a Mac drops a link silent for 30 s
                session.tick()
                nextTick = Date().addingTimeInterval(TeamRuntime.tickInterval)
            }
            if passedAt == nil, !session.members.isEmpty {
                passedAt = Date()
                log.line("JOINED teammates=\(session.members.count) after \(ProbeLog.seconds(Date().timeIntervalSince(started))) s")
            }
            if untilPass, let passedAt, Date().timeIntervalSince(passedAt) >= 3 { break }
        }
        let teammates = session.members.count
        let incompatible = session.hasIncompatiblePeer
        transport.shutdown()   // close_notify to the teammates, DNS-SD goodbye, the socket thread joined

        let pass = passedAt != nil
        let summary = "teammates=\(teammates) links_ready=\(tap.readyCount) found=\(tap.found.count) "
            + "dials=\(tap.dials.values.reduce(0, +)) dials_per_name_max=\(tap.dials.values.max() ?? 0) "
            + "handshake_failures=\(tap.handshakeFailures) unreachable=\(tap.unreachable) messages=\(tap.messageCount) "
            + "first_message=\(tap.firstMessage ?? "none")"
        if pass {
            log.line("RESULT PASS \(summary)")
        } else {
            log.line("RESULT FAIL \(summary): \(tap.diagnosis(listening: tap.listened, incompatible: incompatible, direct: host != nil))")
        }
        return pass ? 0 : 1
    }

    private static func numericHost(_ host: String, port: UInt16) async -> WinSocketAddress? {
        if host.contains(":") { return WinSocketAddress(family: .ipv6, host: host, port: port) }
        if host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) {
            return WinSocketAddress(family: .ipv4, host: host, port: port)
        }
        return await withCheckedContinuation { (c: CheckedContinuation<WinSocketAddress?, Never>) in
            DispatchQueue.global().async { c.resume(returning: WinDNSSD.hostAddresses(host, port: port).first) }
        }
    }

    /// `ADDR if=<index> name=<adapter> <IPv4 or IPv6>` for every address of every adapter that is up.
    static func localAddressLines() -> [String] {
        var size: ULONG = 32 * 1024
        for _ in 0..<4 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            let first = buffer.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES_LH.self)
            // GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER
            let status = GetAdaptersAddresses(ULONG(0), ULONG(0x0002 | 0x0004 | 0x0008), nil, first, &size)
            if status == 111 { continue }   // ERROR_BUFFER_OVERFLOW: `size` now says how much
            guard status == 0 else { return ["ADDR unavailable (GetAdaptersAddresses \(status))"] }
            var lines: [String] = []
            var node: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES_LH>? = first
            while let adapter = node {
                defer { node = adapter.pointee.Next }
                guard adapter.pointee.OperStatus.rawValue == 1 else { continue }   // IfOperStatusUp
                let name = adapter.pointee.FriendlyName.map { String(decodingCString: UnsafePointer($0), as: UTF16.self) } ?? "?"
                var unicast = adapter.pointee.FirstUnicastAddress
                while let u = unicast {
                    defer { unicast = u.pointee.Next }
                    guard let sa = u.pointee.Address.lpSockaddr,
                          let a = WinSocketAddress(sockaddr: UnsafeRawPointer(sa), length: Int(u.pointee.Address.iSockaddrLength), port: 0)
                    else { continue }
                    let index = a.family == .ipv4 ? adapter.pointee.IfIndex : adapter.pointee.Ipv6IfIndex
                    let linkLocal = a.family == .ipv6 && WindowsTeamTransport.isLinkLocal(a.host) ? " link-local" : ""
                    lines.append("ADDR if=\(index) name=\"\(name)\" \(a.family == .ipv4 ? "ipv4" : "ipv6") \(a.host)\(linkLocal)")
                }
            }
            return lines.isEmpty ? ["ADDR none (no adapter is up)"] : lines
        }
        return ["ADDR unavailable (the adapter list kept growing)"]
    }
}

/// Lines to stdout (when the caller redirected it), to the `--selftest-out` file, and to the app log.
@MainActor final class ProbeLog {
    private let url: URL
    private let start = Date()

    init(_ url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    static func seconds(_ t: TimeInterval) -> String { String(format: "%.2f", t) }

    func line(_ text: String) {
        let stamped = "[+\(Self.seconds(Date().timeIntervalSince(start)))s] \(text)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(stamped.utf8))
        AppLog.write("team probe: \(text)")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}

/// Sits between the probe's `TeamSession` and the transport: prints what happens and counts it.
@MainActor private final class ProbeTap: TeamTransporting {
    var onPeerConnected: ((TeamPeerID, Bool) -> Void)?
    var onPeerDisconnected: ((TeamPeerID) -> Void)?
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)?
    var onPeerBadFrame: ((TeamPeerID) -> Void)?

    private let inner: WindowsTeamTransport
    private let log: ProbeLog
    private let started = Date()
    private(set) var found = Set<String>()
    private var foundRepeats = 0
    private(set) var dials: [String: Int] = [:]
    private(set) var readyCount = 0
    private(set) var handshakeFailures = 0
    private(set) var unreachable = 0
    private(set) var messageCount = 0
    private(set) var firstMessage: String?
    private(set) var listened = false
    private var kindsSeen: [TeamPeerID: Set<String>] = [:]

    init(_ inner: WindowsTeamTransport, _ log: ProbeLog) {
        self.inner = inner
        self.log = log
        inner.onPeerConnected = { [weak self] id, mine in self?.onPeerConnected?(id, mine) }
        inner.onPeerDisconnected = { [weak self] id in
            self?.log.line("DOWN peer=\(Self.short(id))")
            self?.onPeerDisconnected?(id)
        }
        inner.onMessage = { [weak self] id, m in self?.message(m, from: id) }
        inner.onPeerBadFrame = { [weak self] id in
            self?.log.line("BADFRAME peer=\(Self.short(id)) (another version, or not a PokeTokenBar peer)")
            self?.onPeerBadFrame?(id)
        }
    }

    static func short(_ id: TeamPeerID) -> String { String(id.prefix(8)) }

    private static func kind(_ m: TeamMessage) -> String {
        switch m {
        case .hello: "hello"
        case .inventory: "inventory"
        case .events: "events"
        case .reactions: "reactions"
        case .profileRequest: "profileRequest"
        case .profile: "profile"
        case .presence: "presence"
        case .emote: "emote"
        case .chat: "chat"
        }
    }

    /// The kind only: never the contents of a frame. The first of each kind per link is printed.
    private func message(_ m: TeamMessage, from id: TeamPeerID) {
        messageCount += 1
        let kind = Self.kind(m)
        if firstMessage == nil { firstMessage = "\(kind)@\(ProbeLog.seconds(Date().timeIntervalSince(started)))s" }
        if kindsSeen[id, default: []].insert(kind).inserted {
            var extra = ""
            if case .hello(let hello) = m { extra = " protocol=\(hello.protocolVersion) (ours \(TeamWire.protocolVersion))" }
            log.line("MSG peer=\(Self.short(id)) kind=\(kind)\(extra)")
        }
        onMessage?(id, m)
    }

    func trace(_ t: WindowsTeamTransport.Trace) {
        switch t {
        case .listening(let port):
            listened = true
            log.line("LISTEN port=\(port) (Windows Firewall must let inbound TCP \(port) reach PokeTokenBar.exe on this network)")
        case .listenFailed(let code):
            log.line("LISTEN-FAILED winsock=\(code)")
        case .registering(let name, let port):
            log.line("ADVERTISE name=\(name) port=\(port) type=\(TeamTransportRules.serviceType)")
        case .discovery(let event):
            switch event {
            case .registered(let name): log.line("REGISTERED name=\(name)")
            case .registerFailed(let code): log.line("REGISTER-FAILED dns_sd=\(code)")
            case .browseFailed(let code): log.line("BROWSE-FAILED dns_sd=\(code)")
            case .found(let name):
                if found.insert(name).inserted {
                    log.line("FOUND name=\(name)\(name == inner.advertisedName ? " (this probe)" : "")")
                } else {
                    foundRepeats += 1
                }
            case .lost(let name):
                found.remove(name)
                log.line("LOST name=\(name)")
            }
        case .resolved(let name, let addresses):
            let text = addresses.map { "\($0.host) port=\($0.port) if=\($0.interfaceIndex)" }.joined(separator: ", ")
            log.line("RESOLVED name=\(name) addresses=[\(text)]")
        case .dialing(let peer, let to):
            dials[to, default: 0] += 1
            log.line("DIAL peer=\(Self.short(peer)) to=\(to) attempt=\(dials[to] ?? 1)")
        case .accepted(let peer):
            log.line("ACCEPT peer=\(Self.short(peer))")
        case .refusedInbound:
            log.line("REFUSED an inbound connection (at the cap)")
        case .ready(let peer, let mine):
            readyCount += 1
            let n = inner.negotiated(peer)
            log.line("READY peer=\(Self.short(peer)) dir=\(mine ? "out" : "in") tls=\(n?.version ?? "?") "
                + "cipher=\(n?.cipher ?? "?") remote=\(n?.peer ?? "?")")
        case .closed(let peer, let reason):
            if reason.hasPrefix("TLS handshake failed") { handshakeFailures += 1 }
            if reason.hasPrefix("unreachable") || reason == "DNS-SD found no address" { unreachable += 1 }
            log.line("CLOSED peer=\(Self.short(peer)) reason=\(reason)")
        }
    }

    func diagnosis(listening: Bool, incompatible: Bool, direct: Bool) -> String {
        let others = found.filter { $0 != inner.advertisedName }
        if !listening { return "the listener never started (see LISTEN-FAILED and the app log)" }
        if incompatible { return "a teammate runs another protocol version: update both apps" }
        if readyCount > 0 { return "linked, but no teammate said hello in time (another app version?)" }
        if handshakeFailures > 0 {
            return "TLS handshake failed \(handshakeFailures)x: a different team code (compare key_fingerprint on both machines)"
        }
        if unreachable > 0 { return "a teammate was found but not reachable (its firewall, another subnet, or a stale address)" }
        if direct { return "the direct dial did not link (address and port right? the Mac's firewall?)" }
        if others.isEmpty {
            return "no teammate service found: same network? Windows network profile Private? the Mac app running with the team on?"
        }
        return "teammates were found but never dialled (all in a cooldown)"
    }

    func start(code: TeamCode) { inner.start(code: code) }
    func stop() { inner.stop() }
    func send(_ m: TeamMessage, to peer: TeamPeerID) {
        if case .hello = m { log.line("SEND peer=\(Self.short(peer)) kind=hello protocol=\(TeamWire.protocolVersion)") }
        inner.send(m, to: peer)
    }
    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?) {
        log.line("DUPLICATE peer=\(Self.short(peer)) dropped, kept=\(kept.map { Self.short($0) } ?? "none")")
        inner.disconnect(peer, coveredBy: kept)
    }
    func refuse(_ peer: TeamPeerID) {
        log.line("REFUSE peer=\(Self.short(peer)) (the session refused it: same member, other version or bad hello)")
        inner.refuse(peer)
    }
}

/// `PokeTokenBar.exe --set-team-code [--nickname <name>]` reads a team code on stdin and saves it, with the team turned
/// on, into the app's own settings (what the popover will do from stage 7); `--clear-team-code` leaves the team. The
/// code is never printed: only its `key_fingerprint`. Refuses while the app runs (the running app would write its own
/// copy of the settings back). Exit 0 = saved, 2 = no or bad code or nickname, 3 = the app is running.
@MainActor enum WindowsTeamCodeTool {
    static func run(_ arguments: [String]) -> Never {
        func say(_ text: String) {
            try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
            AppLog.write("team code tool: \(text)")
        }
        let mutex = WinSingleInstance.mutexName(stateDirectory: AppStatePaths.directory(),
                                                defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
        guard WinSingleInstance.acquire(name: mutex) == .acquired else {
            say("PokeTokenBar is running: quit it from the tray menu first, then run this again")
            WindowsApp.exit(3, .helper)
        }
        let settings = TeamSettings(defaults: WindowsAppDelegate.teamDefaults(fallback: WinDefaultsSync.makeAppDefaults()))
        if arguments.contains("--clear-team-code") {
            settings.leaveTeam()
            say("team code cleared; the team is off")
            WindowsApp.exit(0, .helper)
        }
        guard let line = readLine(), let code = TeamCode(parsing: line) else {
            say("no team code on stdin (for example: Get-Clipboard | .\\PokeTokenBar.exe --set-team-code)")
            WindowsApp.exit(2, .helper)
        }
        if let i = arguments.firstIndex(of: "--nickname") {
            guard i + 1 < arguments.count, settings.commitNickname(arguments[i + 1]) else {
                say("the nickname must be 1 to 12 characters")
                WindowsApp.exit(2, .helper)
            }
        } else if TeamSettings.validNickname(settings.nickname) == nil {
            settings.nickname = "Windows"
        }
        settings.code = code
        settings.isEnabled = true
        say("team code saved (key_fingerprint=\(code.keyFingerprint)); the team is on; nickname=\(settings.nickname)")
        WindowsApp.exit(0, .helper)   // saves the settings first (WinDefaultsSync.flushNow)
    }
}
#endif
