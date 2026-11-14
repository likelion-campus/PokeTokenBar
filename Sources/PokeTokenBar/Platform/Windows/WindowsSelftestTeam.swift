#if os(Windows)
import Foundation
import WinSDK

/// The team transport inside the shipped loop (Task 19). The app's own runtime has no team code here, so it must have
/// opened nothing. Then three in-process members on temporary settings (never written to disk) find each other by
/// real DNS-SD on this machine, link over TLS-PSK on the LAN addresses DNS-SD gives, and run through a restart, a
/// wrong-code member, 60 s of idle and a stop. Everything is shut down before the app's own idle window.
extension WindowsSelftest {
    @MainActor static func teamChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let own = app.teamTransport
        let ready = app.teamSettings.isReady
        r.add("team.offWithoutCode", !ready && own?.hasSocketLoop == false && own?.listenerPort == nil,
              "team ready=\(ready) code=\(app.teamSettings.code == nil ? "absent" : "present") "
                + "socket_loop=\(own?.hasSocketLoop == true ? "started" : "none") "
                + "listener=\(own?.listenerPort.map { String($0) } ?? "none") (no team: no thread, no socket, no firewall prompt)")

        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let a = SelftestMember("SelfA", code: code), b = SelftestMember("SelfB", code: code)
        defer { a.end(); b.end() }
        let t0 = Date()
        a.start(); b.start()
        let joined = await waitUntil(timeout: 30) {
            a.session.members.count == 1 && b.session.members.count == 1 && a.transport.linkCount == 1 && b.transport.linkCount == 1
        }
        let joinSeconds = Date().timeIntervalSince(t0)
        let tls = a.transport.peerIDs.first.flatMap { a.transport.negotiated($0) }
        var presence = false
        if joined {
            a.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .down, isWalking: false)
            presence = await waitUntil(timeout: 5) { b.session.members[a.settings.memberID]?.inPlaza == true }
        }
        let selfDials = a.dials(to: a.ownNames) + b.dials(to: b.ownNames)
        r.add("team.discoverAndExchange", joined && presence && selfDials == 0 && tls?.cipher == "PSK-AES128-GCM-SHA256",
              "joined=\(joined) after \(fmt2(joinSeconds)) s; a found=\(a.foundNames) b found=\(b.foundNames); "
                + "dials a=\(a.dialCount) b=\(b.dialCount) to_self=\(selfDials); links a=\(a.transport.linkCount) "
                + "b=\(b.transport.linkCount); duplicates dropped a=\(a.duplicatesDropped) b=\(b.duplicatesDropped); "
                + "tls=\(tls?.version ?? "-") \(tls?.cipher ?? "-") remote=\(tls?.peer ?? "-"); presence a->b=\(presence)")
        guard joined else { return }

        // A restart (as on a network change): b hears the link end, both find the new name and link again.
        // DNS-SD answers from its cache, so a relinks within milliseconds: watch b's disconnect, not an empty roster.
        let oldName = a.transport.advertisedName ?? "-"
        let t1 = Date()
        let downs = b.disconnects
        a.transport.restart()
        let dropped = await waitUntil(timeout: 5) { b.disconnects > downs }
        let relinked = await waitUntil(timeout: 30) { a.session.members.count == 1 && b.session.members.count == 1 }
        let newName = a.transport.advertisedName ?? "-"
        r.add("team.restartRelinks", dropped && relinked && newName != oldName,
              "b dropped a=\(dropped); relinked=\(relinked) after \(fmt2(Date().timeIntervalSince(t1))) s; name \(oldName) -> \(newName); "
                + "b saw lost(old)=\(b.lostNames.contains(oldName))")

        // A member with another code: no message ever reaches anyone, and it waits out the cooldown.
        let c = SelftestMember("SelfC", code: TeamCode.generate(using: &rng))
        c.start()
        let names = [a.transport.advertisedName, b.transport.advertisedName].compactMap { $0 }
        let failed = await waitUntil(timeout: 20) { names.allSatisfy { c.failedHandshakes(to: $0) > 0 } }
        let heldOff = names.allSatisfy { !c.transport.plannedDials(now: Date()).contains($0) }
            && names.allSatisfy { c.transport.plannedDials(now: Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)).contains($0) }
        let leaked = c.messages + c.session.members.count
        let others = a.session.members.count == 1 && b.session.members.count == 1
        c.end()
        r.add("team.wrongCodeRefused", failed && heldOff && leaked == 0 && others,
              "c failed handshakes with both=\(failed) (dials \(c.dialCount)); held off for the cooldown=\(heldOff); "
                + "messages or members from c=\(leaked); a and b still linked=\(others)")

        await teamIdleCheck(r, a, b)

        // Stop: the teammate hears the link end at once (close_notify), and DNS-SD's goodbye removes the service.
        let goneName = a.transport.advertisedName ?? "-"
        let t2 = Date()
        a.end()
        let down = await waitUntil(timeout: 5) { b.session.members.isEmpty }
        let downAfter = Date().timeIntervalSince(t2)
        let lost = await waitUntil(timeout: 10) { b.lostNames.contains(goneName) }
        r.add("team.stopIsSeen", down,
              "b dropped a after \(fmt2(downAfter)) s=\(down); b saw lost(\(goneName))=\(lost) (goodbye on deregister; informational)")
        b.end()
        // Let one-shot DNS-SD timeouts (8 s) and grace releases fire before the app's own idle window.
        try? await Task.sleep(nanoseconds: UInt64((WinDNSSD.resolveTimeout + 1) * 1_000_000_000))
    }

    /// Two linked transports, nothing to send: the socket threads must not wake at all, and the main thread only
    /// for the redial timers (15 s each, as on the Mac) and DNS-SD's own repeats.
    @MainActor private static func teamIdleCheck(_ r: Recorder, _ a: SelftestMember, _ b: SelftestMember) async {
        let seconds = WindowsSelftest.idleSeconds
        try? await Task.sleep(nanoseconds: 2_000_000_000)   // let the presence and the sync settle
        let w0 = (a.transport.socketLoop?.wakeups ?? 0, b.transport.socketLoop?.wakeups ?? 0)
        let e0 = (a.transport.redialFires + b.transport.redialFires, a.transport.discoveryEvents + b.transport.discoveryEvents)
        let threads = (a.transport.socketLoop?.ioThreadID ?? 0, b.transport.socketLoop?.ioThreadID ?? 0)
        let r0 = WinDNSSD.repeatsDropped
        let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID)
        let wakes = ((a.transport.socketLoop?.wakeups ?? 0) - w0.0, (b.transport.socketLoop?.wakeups ?? 0) - w0.1)
        let redials = a.transport.redialFires + b.transport.redialFires - e0.0
        let discovery = a.transport.discoveryEvents + b.transport.discoveryEvents - e0.1
        guard let sample else {
            r.add("team.idle", false, "measurement failed (NtQuerySystemInformation / QueryThreadCycleTime unavailable)")
            return
        }
        let budget = 3 + 3 * (redials + discovery)
        let linked = a.transport.linkCount == 1 && b.transport.linkCount == 1
        r.add("team.idle", linked && wakes.0 == 0 && wakes.1 == 0 && sample.mainContextSwitches <= budget,
              "\(Int(seconds)) s, two linked transports, no traffic: socket_thread_wakeups=[\(wakes.0), \(wakes.1)] "
                + "(threads \(threads.0), \(threads.1)) main_thread_cs=\(sample.mainContextSwitches) budget_cs=\(budget) "
                + "known_wakes={redial:\(redials), dnssd_events:\(discovery)} dnssd_repeats_dropped_off_main=\(WinDNSSD.repeatsDropped - r0) "
                + "main_cycles=\(sample.mainCycles) "
                + "still_linked=\(linked) busy_threads=[\(sample.busy)]")
    }

    private static func fmt2(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// One teammate in the selftest: its own settings (a plain suite, never synchronized, so never on disk), feed, session
/// and an advertising transport. The reachability is quiet: a runner network change must not restart it mid-check.
@MainActor private final class SelftestMember {
    let settings: TeamSettings
    let session: TeamSession
    let transport: WindowsTeamTransport
    private let defaults: UserDefaults
    private let suite: String
    private let dir: URL
    private var traces: [WindowsTeamTransport.Trace] = []
    private var ownNamesSeen = Set<String>()
    private(set) var messages = 0
    private(set) var disconnects = 0
    private var ended = false

    init(_ name: String, code: TeamCode) {
        suite = "ptb.selftest.team.\(name).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-selftest-team-\(UUID().uuidString)")
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        transport = WindowsTeamTransport(advertise: true, events: nil, reachability: SilentReachability())
        let memberID = settings.memberID
        session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: {
            TeamMemberProfile(memberID: memberID, nickname: name,
                              current: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil),
                              dex: [])
        })
        let inner = transport.onMessage   // the session's: count every message that reaches it
        transport.onMessage = { [weak self] id, m in
            self?.messages += 1
            inner?(id, m)
        }
        let innerDown = transport.onPeerDisconnected
        transport.onPeerDisconnected = { [weak self] id in
            self?.disconnects += 1
            innerDown?(id)
        }
        transport.trace = { [weak self] t in
            guard let self else { return }
            self.traces.append(t)
            if case .registering(let n, _) = t { self.ownNamesSeen.insert(n) }
            if case .discovery(.registered(let n)) = t { self.ownNamesSeen.insert(n) }
        }
    }

    func start() { session.applySettings() }

    func end() {
        guard !ended else { return }
        ended = true
        transport.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    var ownNames: Set<String> { ownNamesSeen }
    var foundNames: [String] {
        Array(Set(traces.compactMap { if case .discovery(.found(let n)) = $0, !ownNamesSeen.contains(n) { n } else { nil } })).sorted()
    }
    var lostNames: Set<String> { Set(traces.compactMap { if case .discovery(.lost(let n)) = $0 { n } else { nil } }) }
    var dialCount: Int { traces.filter { if case .dialing = $0 { true } else { false } }.count }
    var duplicatesDropped: Int {
        traces.filter { if case .closed(_, let reason) = $0, reason == "disconnected by the session" { true } else { false } }.count
    }

    func dials(to names: Set<String>) -> Int {
        traces.filter { if case .dialing(_, let to) = $0, names.contains(to) { true } else { false } }.count
    }

    /// Handshake failures of the dials this member made to `name`.
    func failedHandshakes(to name: String) -> Int {
        let peers = Set(traces.compactMap { if case .dialing(let p, let to) = $0, to == name { p } else { nil } })
        return traces.filter {
            if case .closed(let p, let reason) = $0, peers.contains(p), reason.hasPrefix("TLS handshake failed") { true } else { false }
        }.count
    }
}

/// Never reports a reconnect (the selftest's members restart only when a check says so).
private final class SilentReachability: ReachabilityMonitoring, @unchecked Sendable {
    var onReconnected: (@Sendable () -> Void)?
    func start() {}
    func stop() {}
}
#endif
