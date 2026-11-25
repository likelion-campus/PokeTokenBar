#if os(Windows)
import CTeamTLS
import Foundation
import WinSDK

/// `Get-Clipboard | PokeTokenBar.exe --team-probe --code-stdin [--seconds 60] [--until-pass] [--selftest-out <file>]
/// [--host <address or name> --port <port>]`: what the PC check runs next to a Mac teammate. No tray, no window, no
/// single-instance lock (it may run next to the app). It joins the team with the real transport and a real
/// `TeamSession` as the member `WinProbe` with a Pikachu (Mac teammates see it appear; the first line says so), on
/// temporary settings that never reach the disk, and prints plain lines: the local addresses and interface indexes,
/// the listener port the firewall must let in, each service found (with its DNS-SD TTL), each dial and accept with
/// the TLS version and cipher, the handshake outcome, the first message, per-name results and `RESULT PASS|FAIL`.
/// Handshake failures of connections other teams' apps make to us are normal on a shared network: they are counted as
/// `other_teams` and never decide the result. The code comes from stdin (`--code-stdin`) or else from the app's saved
/// settings (`--set-team-code`); it is never printed, nor is the key: `key_fingerprint` is 8 hex digits of SHA-256 over
/// the key, which `scripts/team-interop-check.sh --fingerprint` computes on a Mac. Exit 0 = PASS, 1 = FAIL, 2 = no code.
@MainActor enum WindowsTeamProbe {
    static let nickname = "WinProbe"
    static let species = (id: 25, name: "Pikachu")

    static let usage = """
    PokeTokenBar team probe: joins your team on this network for a while and reports what happens.
      Get-Clipboard | .\\PokeTokenBar.exe --team-probe --code-stdin --seconds 60 --selftest-out probe.txt | Out-Host
      .\\PokeTokenBar.exe --team-probe --seconds 60 | Out-Host        (uses the code saved with --set-team-code)
      ... --host 192.168.0.12 --port 51234                           (dial one address, no DNS-SD)
      --until-pass ends 3 s after a teammate joined.
    Copy the team code to the clipboard first (never type it on the command line: PowerShell keeps a history).
    While it runs, Mac teammates see a member "\(nickname)" with a \(species.name). Exit 0 PASS, 1 FAIL, 2 no code.
    """

    static func main(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if arguments.contains("--help") {
            try? FileHandle.standardOutput.write(contentsOf: Data((usage + "\n").utf8))
            WindowsApp.exit(0, .helper)
        }
        let out = value("--selftest-out").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PokeTokenBar-team-probe.txt")
        let seconds = value("--seconds").flatMap { Int($0) } ?? 60
        let host = value("--host"), port = value("--port").flatMap { UInt16($0) }
        let code = arguments.contains("--code-stdin") ? readLine().flatMap { TeamCode(parsing: $0) } : savedCode()
        guard let code else {
            let log = ProbeLog(out)
            log.line("RESULT FAIL no team code: Get-Clipboard | PokeTokenBar.exe --team-probe --code-stdin, or save one with --set-team-code (--help)")
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
        log.line("IDENTITY nickname=\(nickname) species=\(species.name) (Mac teammates see this member while the probe runs)")
        for line in localAddressLines() { log.line(line) }

        // Temporary settings: a plain suite is never written to disk on Windows unless synchronized (F2), so the probe
        // leaves the user's settings and plist alone.
        let suite = "ptb.probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = nickname
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = WindowsTeamTransport(advertise: host == nil, events: Platform.current.events as? WindowsSystemEvents)
        let tap = ProbeTap(transport, log)
        transport.trace = { [weak tap] in tap?.trace($0) }
        WinDNSSD.answerObserver = { name, ttl in DispatchQueue.main.async { MainActor.assumeIsolated { tap.answer(name, ttl: ttl) } } }
        defer { WinDNSSD.answerObserver = nil }
        let memberID = settings.memberID
        let session = TeamSession(settings: settings, feed: feed, transport: tap, profileProvider: {
            TeamMemberProfile(memberID: memberID, nickname: nickname,
                              current: TeamMonSummary(speciesID: species.id, isShiny: false, form: nil, speciesName: species.name,
                                                      gender: nil),
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
        transport.shutdown()   // DNS-SD goodbye (waited for), close_notify to the teammates, the socket thread joined
        log.line("GOODBYE dns_sd=\(transport.lastGoodbye.map { $0 ? "sent" : "not confirmed in 500 ms" } ?? "nothing announced") "
            + "at_ms=\(ProbeLog.epochMs())")

        for line in tap.nameLines() { log.line(line) }
        let pass = passedAt != nil
        let summary = "teammates=\(teammates) links_ready=\(tap.readyCount) found=\(tap.foundOthers) "
            + "dials=\(tap.dials.values.reduce(0, +)) dials_per_name_max=\(tap.dials.values.max() ?? 0) "
            + "handshake_failures=\(tap.handshakeFailures) other_teams=\(tap.otherTeams) unreachable=\(tap.unreachable) "
            + "forgotten=\(tap.forgotten.count) messages=\(tap.messageCount) first_message=\(tap.firstMessage ?? "none")"
        if pass {
            log.line("RESULT PASS \(summary)")
        } else {
            log.line("RESULT FAIL \(summary): \(tap.diagnosis(incompatible: incompatible, direct: host != nil))")
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
    static func epochMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

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

    /// What happened to the dials of one DNS-SD name (or `host:port`).
    private struct NameResult {
        var dials = 0, ready = 0, tlsFailed = 0, unreachable = 0, noAddress = 0, timedOut = 0
        var forgotten = false
    }

    private let inner: WindowsTeamTransport
    private let log: ProbeLog
    private let started = Date()
    private(set) var found = Set<String>()
    private(set) var dials: [String: Int] = [:]
    private var results: [String: NameResult] = [:]
    private var dialTarget: [TeamPeerID: String] = [:]
    private var inbound = Set<TeamPeerID>()
    private(set) var readyCount = 0
    private(set) var handshakeFailures = 0
    private(set) var otherTeams = 0
    private(set) var unreachable = 0
    private(set) var forgotten = Set<String>()
    private(set) var messageCount = 0
    private(set) var firstMessage: String?
    private(set) var listened = false
    private var kindsSeen: [TeamPeerID: Set<String>] = [:]
    private var ttlPrinted: [String: UInt32] = [:]
    /// This probe's own DNS-SD names (kept after the transport stopped, for the summary).
    private var ownNames = Set<String>()

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

    var foundOthers: Int { found.filter { !ownNames.contains($0) && $0 != inner.advertisedName }.count }

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
        case .draw: "draw"
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

    /// Every DNS-SD answer (repeats included): the first, and each change of the TTL by 10 % or more, so a cached
    /// record counting down can be told from fresh announcements.
    func answer(_ name: String, ttl: UInt32) {
        let last = ttlPrinted[name]
        guard last == nil || ttl > (last ?? 0) || Double(ttl) < Double(last ?? 0) * 0.9 else { return }
        ttlPrinted[name] = ttl
        log.line("ANSWER name=\(name) ttl=\(ttl)\(ttl == 0 ? " (goodbye)" : "") at_ms=\(ProbeLog.epochMs())")
    }

    func trace(_ t: WindowsTeamTransport.Trace) {
        switch t {
        case .listening(let port):
            listened = true
            log.line("LISTEN port=\(port) (Windows Firewall must let inbound TCP \(port) reach PokeTokenBar.exe on this network)")
        case .listenFailed(let code):
            log.line("LISTEN-FAILED winsock=\(code)")
        case .registering(let name, let port):
            ownNames.insert(name)
            log.line("ADVERTISE name=\(name) port=\(port) type=\(TeamTransportRules.serviceType)")
        case .discovery(let event):
            switch event {
            case .registered(let name):
                ownNames.insert(name)
                log.line("REGISTERED name=\(name)")
            case .registerFailed(let code): log.line("REGISTER-FAILED dns_sd=\(code)")
            case .browseFailed(let code): log.line("BROWSE-FAILED dns_sd=\(code)")
            case .found(let name):
                if found.insert(name).inserted {
                    log.line("FOUND name=\(name)\(name == inner.advertisedName ? " (this probe)" : "")")
                }
            case .lost(let name):
                found.remove(name)
                log.line("LOST name=\(name) at_ms=\(ProbeLog.epochMs())")
            }
        case .resolved(let name, let addresses):
            let text = addresses.map { "\($0.host) port=\($0.port) if=\($0.interfaceIndex)" }.joined(separator: ", ")
            log.line("RESOLVED name=\(name) addresses=[\(text)]")
        case .dialing(let peer, let to):
            dials[to, default: 0] += 1
            results[to, default: NameResult()].dials += 1
            dialTarget[peer] = to
            log.line("DIAL peer=\(Self.short(peer)) to=\(to) attempt=\(dials[to] ?? 1)")
        case .accepted(let peer):
            inbound.insert(peer)
            log.line("ACCEPT peer=\(Self.short(peer))")
        case .refusedInbound:
            log.line("REFUSED an inbound connection (at the cap, or taken by an old listener)")
        case .ready(let peer, let mine):
            readyCount += 1
            if let to = dialTarget[peer] { results[to, default: NameResult()].ready += 1 }
            let n = inner.negotiated(peer)
            log.line("READY peer=\(Self.short(peer)) dir=\(mine ? "out" : "in") tls=\(n?.version ?? "?") "
                + "cipher=\(n?.cipher ?? "?") remote=\(n?.peer ?? "?")")
        case .closed(let peer, let reason):
            let tls = reason.hasPrefix("TLS handshake failed")
            if inbound.contains(peer) {
                // Someone dialled us and did not have our key: another team's app (normal on a shared network).
                if tls { otherTeams += 1 }
                log.line("CLOSED peer=\(Self.short(peer)) dir=in reason=\(reason)\(tls ? " (another team's app dialled in)" : "")")
            } else {
                if tls { handshakeFailures += 1 }
                if reason.hasPrefix("unreachable") || reason == "DNS-SD found no address" { unreachable += 1 }
                if let to = dialTarget[peer] {
                    if tls { results[to, default: NameResult()].tlsFailed += 1 }
                    if reason.hasPrefix("unreachable") { results[to, default: NameResult()].unreachable += 1 }
                    if reason == "DNS-SD found no address" { results[to, default: NameResult()].noAddress += 1 }
                    if reason.hasPrefix("handshake not finished") { results[to, default: NameResult()].timedOut += 1 }
                }
                log.line("CLOSED peer=\(Self.short(peer)) dir=out reason=\(reason)")
            }
            inbound.remove(peer)
            dialTarget[peer] = nil
        case .forgotten(let name):
            forgotten.insert(name)
            results[name, default: NameResult()].forgotten = true
            log.line("FORGOTTEN name=\(name) (\(WindowsTeamTransport.absentDialsBeforeForgetting) dials found no service and "
                + "DNS-SD heard nothing from it in between: no more resolves or dials until it announces itself again)")
        case .retrying(let what, let attempt, let delay):
            log.line("RETRY dns_sd=\(what) attempt=\(attempt) in=\(Int(delay)) s (the links stay)")
        }
    }

    /// One line per name this probe dialled: what each one did.
    func nameLines() -> [String] {
        results.keys.sorted().map { name in
            let r = results[name] ?? NameResult()
            let outcome: String
            if r.ready > 0 { outcome = "linked" }
            else if r.tlsFailed > 0 { outcome = "TLS refused: another team's code (or your teammate's code differs: compare key_fingerprint)" }
            else if r.forgotten { outcome = "gone: forgotten after \(r.dials) dials found no service" }
            else if r.unreachable + r.noAddress + r.timedOut > 0 { outcome = "not reachable (its firewall, another subnet, or a stale address)" }
            else { outcome = "no answer yet" }
            return "NAME \(name) dials=\(r.dials) ready=\(r.ready) tls_failed=\(r.tlsFailed) unreachable=\(r.unreachable) "
                + "no_address=\(r.noAddress) timed_out=\(r.timedOut): \(outcome)"
        }
    }

    func diagnosis(incompatible: Bool, direct: Bool) -> String {
        let noise = otherTeams > 0 ? " (\(otherTeams) connections from other teams' apps were refused: normal on a shared network)" : ""
        if !listened { return "the listener never started (see LISTEN-FAILED and the app log)" + noise }
        if incompatible { return "a teammate runs another protocol version: update both apps" + noise }
        if readyCount > 0 { return "linked, but no teammate said hello in time (another app version?)" + noise }
        let refused = results.filter { $0.value.tlsFailed > 0 }.keys.sorted()
        if !refused.isEmpty {
            return "every service found that answered uses another team code: \(refused.joined(separator: ", ")). "
                + "If one of them is your teammate, its code differs: compare key_fingerprint" + noise
        }
        if unreachable > 0 { return "a teammate was found but not reachable (its firewall, another subnet, or a stale address)" + noise }
        if direct { return "the direct dial did not link (address and port right? the Mac's firewall?)" + noise }
        if foundOthers == 0 {
            return "no teammate service found: same network? Windows network profile Private? the Mac app running with the team on?" + noise
        }
        return "teammates were found but never dialled (all in a cooldown)" + noise
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

/// `Get-Clipboard | PokeTokenBar.exe --set-team-code [--nickname <name>]` reads a team code on stdin and saves it,
/// with the team turned on, into the app's own settings (what the popover will do from stage 7); `--clear-team-code`
/// leaves the team. The code is never printed: only its `key_fingerprint`. Refuses while the app runs (the running app
/// would write its own copy of the settings back). Goes through the app's launch guard first (an unreadable settings
/// file is restored from its backup before anything is written) and leaves through `WindowsApp.exit`, which saves and
/// refreshes the verified backup, so after a clear the backup no longer holds the code either.
/// Exit 0 = saved, 2 = no or bad code or nickname, 3 = the app is running.
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
        // The app's launch step 8b, with the same domains (a code tool is never a selftest).
        let teamSuite = TeamSettings.suiteName(for: AppStatePaths.directory(), defaultDirectory: WindowsAppDelegate.defaultStateDirectory)
        WinDefaultsSync.guardAtLaunch(suites: [nil, teamSuite])
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
        WindowsApp.exit(0, .helper)   // saves the settings and refreshes the backup (WinDefaultsSync.flushNow)
    }
}
#endif
