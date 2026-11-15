#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// `--selftest-net-burst <out.json>`: what one HTTP fetch costs in wakeups, per thread and over time (the status-check
/// burst of the idle gate). Each case runs one fetch while a recorder thread reads every thread's context switches and
/// cycles every 20 ms (`IdleSampler.snapshot`, which does not wake the threads it reads), then 3 s of tail. Per case: the
/// hottest thread and its partner, the busy period (20 ms buckets where the hottest thread switched >= 500 times a
/// second) against the request time, wakeups per second inside it, whole-process switches, and the tail after completion.
/// Cases: a loopback HTTP server in this process (no network): URLSession on a new and on a reused connection, WinHTTP
/// waiting and stalled; the app's status-check path before and after the route (the status hosts the app contacts) and the
/// 30 s after it; each routed caller's request shape (its method, headers, body, timeout and session) before (URLSession,
/// new connection) and after (the seam); WinHTTP through the Windows proxy settings against a direct fetch, cold and warm.
/// Then stacks of the hot threads, sampled during a separate long loopback transfer (suspending a thread costs a context
/// switch, so never in a measured run). Diagnostics only: nothing here runs in the shipped app.
enum WindowsSelftestNetBurst {
    struct CaseResult: Codable {
        let name: String
        let outcome: String
        let requestMs: Int
        let busyMs: Int
        let busyStartMs: Int
        let busyEndMs: Int
        let hot: String
        let hotCs: Int
        let hotCycles: UInt64
        let hotWakesPerSec: Int
        let partner: String
        let partnerCs: Int
        let processCs: Int
        let processCycles: UInt64
        let tailCs: Int
        let top: String
    }

    struct Stacks: Codable { let name: String; let detail: String }
    struct Output: Codable { var results: [CaseResult] = []; var stacks: [Stacks] = []; var notes: [String] = [] }

    @MainActor static func run(_ args: [String]) -> Never {
        guard let out = args.first else { WindowsApp.exit(2, .helper) }
        _ = WinMainLoop.prepare()
        Task { @MainActor in
            var output = Output()
            func save() { if let data = try? JSONEncoder().encode(output) { try? data.write(to: URL(fileURLWithPath: out)) } }
            guard let server = LoopbackServer.start() else {
                output.notes.append("loopback server did not start: WSA \(WSAGetLastError())"); save(); WindowsApp.exit(1, .helper)
            }
            let lo = "http://127.0.0.1:\(server.port)"
            output.notes.append("loopback server on \(lo); route there: \(WinProxyRoute.route(for: URL(string: lo)!))")
            // Warm the dispatch threads, the shared session and WinHTTP once, so the cases see the steady state.
            // The first WinHTTP fetch of the process through the Windows proxy settings (cold: any detection happens here).
            let coldStart = WindowsSelftest.nowMs()
            let cold = (try? await WinHTTPFetch.data(for: URLRequest(url: URL(string: lo + "/delay/0")!, timeoutInterval: 10),
                                                    route: .systemProxy)) != nil
            output.notes.append(String(format: "cold system-proxy fetch: %.1f ms (ok=\(cold))", WindowsSelftest.nowMs() - coldStart))
            let warmSession = await get(URLSession.shared, lo + "/delay/0", timeout: 10)
            let warmWinHTTP = await winhttp(lo + "/delay/0", timeout: 10)
            output.notes.append("warm-up: \(warmSession); \(warmWinHTTP)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let claude = "https://status.claude.com/api/v2/summary.json"
            // URLSession cases on a "fresh" connection use a new ephemeral session each (curl connects); "reused" ones follow
            // a fetch to the same host on the same session within seconds (curl takes the cached connection). The app's
            // refresh comes every 120 s, past libcurl's 118 s connection age limit, so it connects afresh every time.
            var cases: [(String, @MainActor () async -> String)] = [
                ("lo-fresh-delay-2s", { await fresh(lo + "/delay/2000", timeout: 30) }),
                ("lo-shared-immediate", { await get(URLSession.shared, lo + "/delay/0", timeout: 10) }),
                ("lo-shared-reused-delay-2s", { await get(URLSession.shared, lo + "/delay/2000", timeout: 30) }),
                ("winhttp-lo-delay-2s", { await winhttp(lo + "/delay/2000", timeout: 30) }),
                ("winhttp-lo-hang-timeout-10s", { await winhttp(lo + "/hang", timeout: 10) }),
                // The first contact with the status hosts in this process: the old path connects afresh on URLSession.shared.
                ("status-check-old-path-urlsession", { await oldStatusPath() }),
                ("status-check-app-path", { await appStatusPath() }),
                // Does anything of WinHTTP keep waking after the fetch? (A process-wide session kept a pooled connection.)
                ("idle-30s-after-status-check", { try? await Task.sleep(nanoseconds: 30_000_000_000); return "slept" }),
            ]
            // Each routed caller's request (method, headers, body, timeout, its session) against the loopback server, which
            // answers after 200 ms (about a real fetch): URLSession on a new connection before, the seam after.
            for shape in callerShapes(lo) {
                cases.append(("\(shape.name)-before-urlsession", { await shapeBefore(shape) }))
                cases.append(("\(shape.name)-after-seam", { await shapeAfter(shape) }))
            }
            cases.append(("proxy-timing-loopback", { await proxyTiming(lo + "/delay/0", count: 10) }))
            cases.append(("proxy-timing-status-host", { await proxyTiming(claude, count: 5) }))
            cases.append(("idle-10s-after-all", { try? await Task.sleep(nanoseconds: 10_000_000_000); return "slept" }))
            for (name, body) in cases {
                let result = await measure(name, body)
                output.results.append(result)
                AppLog.write("net-burst \(name): \(result.outcome) req=\(result.requestMs) ms busy=\(result.busyMs) ms "
                             + "hot_cs=\(result.hotCs) (\(result.hotWakesPerSec)/s) partner_cs=\(result.partnerCs) proc_cs=\(result.processCs)")
                save()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let sessionStacks = await stacksDuring { await get(URLSession.shared, lo + "/delay/8000", timeout: 30) }
            output.stacks.append(Stacks(name: "urlsession-lo-delay-8s", detail: sessionStacks))
            save()
            let winhttpStacks = await stacksDuring { await winhttp(lo + "/delay/8000", timeout: 30) }
            output.stacks.append(Stacks(name: "winhttp-lo-delay-8s", detail: winhttpStacks))
            save()
            WindowsApp.exit(0, .helper)
        }
        WinMainLoop.run(.cfRunLoopWithMessages) { false }
        WindowsApp.exit(0, .helper)
    }

    // MARK: - fetches

    private static func get(_ session: URLSession, _ url: String, timeout: TimeInterval, close: Bool = false) async -> String {
        guard let u = URL(string: url) else { return "bad url" }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")
        if close { request.setValue("close", forHTTPHeaderField: "Connection") }
        let t0 = WindowsSelftest.nowMs()
        do {
            let (data, response) = try await session.data(for: request)
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(data.count) B in \(Int(WindowsSelftest.nowMs() - t0)) ms"
        } catch {
            return "failed after \(Int(WindowsSelftest.nowMs() - t0)) ms: \((error as? URLError)?.code.rawValue ?? 0) \(error.localizedDescription)"
        }
    }

    /// On a new ephemeral session, so libcurl opens a new connection.
    private static func fresh(_ url: String, timeout: TimeInterval, close: Bool = false) async -> String {
        let session = URLSession(configuration: .ephemeral)
        let outcome = await get(session, url, timeout: timeout, close: close)
        session.finishTasksAndInvalidate()
        return outcome
    }

    private static func winhttp(_ url: String, timeout: TimeInterval) async -> String {
        guard let u = URL(string: url) else { return "bad url" }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")
        let t0 = WindowsSelftest.nowMs()
        do {
            let (data, response) = try await WinHTTPFetch.data(for: request)
            let http = response as? HTTPURLResponse
            return "HTTP \(http?.statusCode ?? -1) \(data.count) B in \(Int(WindowsSelftest.nowMs() - t0)) ms "
                + "type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "-") url=\(response.url?.absoluteString ?? "-")"
        } catch {
            return "failed after \(Int(WindowsSelftest.nowMs() - t0)) ms: \((error as? URLError)?.code.rawValue ?? 0) \(error.localizedDescription)"
        }
    }

    /// `StatuspageStatusProvider.fetch()` as it was before the route: both endpoints at once on `URLSession.shared`, the
    /// same request (10 s, User-Agent), status 200 and component parse, so its statuses compare with the app path's.
    private static func oldStatusPath() async -> String {
        let t0 = WindowsSelftest.nowMs()
        let parts = await withTaskGroup(of: String.self) { group in
            for endpoint in StatuspageStatusProvider.endpoints {
                group.addTask {
                    var request = URLRequest(url: endpoint.url, timeoutInterval: 10)
                    request.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return endpoint.id + ": failed" }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let parsed = code == 200 ? StatuspageStatusProvider.parseComponent(data, named: endpoint.componentName) : nil
                    return endpoint.id + "=" + (parsed?.indicator.rawValue ?? "nil(HTTP \(code) \(data.count) B)")
                }
            }
            var parts: [String] = []
            for await part in group { parts.append(part) }
            return parts.sorted()
        }
        return "in \(Int(WindowsSelftest.nowMs() - t0)) ms: " + parts.joined(separator: " ")
    }

    /// The app's code path as built: `StatuspageStatusProvider.fetch()` (through `PlatformCompat.oneShotData`).
    private static func appStatusPath() async -> String {
        let t0 = WindowsSelftest.nowMs()
        let statuses = await StatuspageStatusProvider().fetch()
        return "\(statuses.count) statuses in \(Int(WindowsSelftest.nowMs() - t0)) ms: "
            + statuses.map { "\($0.key)=\($0.value.indicator.rawValue)" }.sorted().joined(separator: " ")
    }

    // MARK: - each routed caller's request shape

    struct Shape: @unchecked Sendable {
        let name: String
        let request: URLRequest
        /// nil: the caller uses `URLSession.shared`; else its own session's configuration.
        let configuration: URLSessionConfiguration?
        let fromURL: Bool
    }

    private static func callerShapes(_ lo: String) -> [Shape] {
        func request(_ path: String, _ timeout: TimeInterval, _ method: String = "GET", _ body: String? = nil,
                     headers: [String: String] = [:]) -> URLRequest {
            var r = URLRequest(url: URL(string: lo + path)!, timeoutInterval: timeout)
            r.httpMethod = method
            r.httpBody = body.map { Data($0.utf8) }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        func ephemeral(_ timeout: TimeInterval) -> URLSessionConfiguration {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            c.timeoutIntervalForRequest = timeout
            return c
        }
        let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return [
            Shape(name: "claude-usage-and-profile", request: request("/delay/200", 15, headers: [
                "Authorization": "Bearer fixture-token", "anthropic-beta": "oauth-2025-04-20"]), configuration: nil, fromURL: false),
            Shape(name: "claude-session-key", request: request("/delay/200", 15, headers: [
                "Cookie": "sessionKey=fixture", "Accept": "application/json", "User-Agent": browser,
                "Referer": "https://claude.ai", "Origin": "https://claude.ai"]), configuration: nil, fromURL: false),
            Shape(name: "cursor-token-refresh", request: request("/delay/200", 10, "POST", #"{"grant_type":"refresh_token"}"#,
                headers: ["Content-Type": "application/json"]), configuration: ephemeral(10), fromURL: false),
            Shape(name: "cursor-usage", request: request("/delay/200", 10, "POST", "{}", headers: [
                "Content-Type": "application/json", "User-Agent": "Mozilla/5.0", "Origin": "https://cursor.com",
                "Cookie": "WorkosCursorSessionToken=fixture"]), configuration: ephemeral(10), fromURL: false),
            Shape(name: "cursor-limits", request: request("/delay/200", 10, "POST", "{}", headers: [
                "Content-Type": "application/json", "Connect-Protocol-Version": "1", "Authorization": "Bearer fixture"]),
                configuration: ephemeral(10), fromURL: false),
            Shape(name: "grok-and-opencode-limits", request: request("/delay/200", 10, headers: [
                "Authorization": "Bearer fixture", "Accept": "application/json"]), configuration: ephemeral(10), fromURL: false),
            Shape(name: "update-feed", request: request("/delay/200", 15, headers: ["Accept": "application/vnd.github+json"]),
                  configuration: nil, fromURL: false),
            Shape(name: "pokeapi-rest-and-names", request: request("/delay/200", 15), configuration: nil, fromURL: false),
            Shape(name: "pokeapi-graphql", request: request("/delay/200", 15, "POST", #"{"query":"{ x }"}"#,
                headers: ["Content-Type": "application/json"]), configuration: nil, fromURL: false),
            Shape(name: "sprite-and-icon", request: URLRequest(url: URL(string: lo + "/big/40000")!), configuration: nil, fromURL: true),
        ]
    }

    /// URLSession as the caller used it, on a new connection (a fresh session with the caller's configuration).
    private static func shapeBefore(_ shape: Shape) async -> String {
        let session = URLSession(configuration: shape.configuration ?? .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return await describe { try await session.data(for: shape.request) }
    }

    /// The routed call as the caller makes it now.
    private static func shapeAfter(_ shape: Shape) async -> String {
        if shape.fromURL, let url = shape.request.url { return await describe { try await PlatformCompat.oneShotData(from: url) } }
        guard let configuration = shape.configuration else {
            return await describe { try await PlatformCompat.oneShotData(for: shape.request) }
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await describe { try await PlatformCompat.oneShotData(for: shape.request, session: session) }
    }

    private static func describe(_ fetch: () async throws -> (Data, URLResponse)) async -> String {
        let t0 = WindowsSelftest.nowMs()
        do {
            let (data, response) = try await fetch()
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(data.count) B in \(Int(WindowsSelftest.nowMs() - t0)) ms"
        } catch {
            return "failed after \(Int(WindowsSelftest.nowMs() - t0)) ms: \((error as? URLError)?.code.rawValue ?? 0)"
        }
    }

    /// WinHTTP through the Windows proxy settings against a direct fetch, `count` times each (warm: after the cold one).
    private static func proxyTiming(_ url: String, count: Int) async -> String {
        guard let u = URL(string: url) else { return "bad url" }
        func run(_ route: WinProxyRoute.Route) async -> [Double] {
            var ms: [Double] = []
            for _ in 0..<count {
                let t0 = WindowsSelftest.nowMs()
                _ = try? await WinHTTPFetch.data(for: URLRequest(url: u, timeoutInterval: 10), route: route)
                ms.append(WindowsSelftest.nowMs() - t0)
            }
            return ms
        }
        func summary(_ v: [Double]) -> String {
            let s = v.sorted()
            return String(format: "median %.1f max %.1f ms", s[s.count / 2], s.last ?? -1)
        }
        let system = await run(.systemProxy)
        let direct = await run(.direct)
        return "system proxy: \(summary(system)); direct: \(summary(direct)) (\(count) each)"
    }

    // MARK: - measurement

    @MainActor private static func measure(_ name: String, _ body: @MainActor () async -> String) async -> CaseResult {
        let recorder = Recorder()
        recorder.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let t0 = WindowsSelftest.nowMs()
        let outcome = await body()
        let t1 = WindowsSelftest.nowMs()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        recorder.requestStop()
        _ = await WindowsSelftest.waitUntil(timeout: 5) { recorder.isFinished }
        return analyse(name, outcome, recorder.taken(), t0: t0, t1: t1, recorder: recorder.threadID)
    }

    private static func analyse(_ name: String, _ outcome: String, _ points: [Recorder.Point], t0: Double, t1: Double,
                                recorder: UInt32) -> CaseResult {
        let empty = CaseResult(name: name, outcome: outcome, requestMs: Int(t1 - t0), busyMs: 0, busyStartMs: 0, busyEndMs: 0,
                               hot: "-", hotCs: 0, hotCycles: 0, hotWakesPerSec: 0, partner: "-", partnerCs: 0, processCs: 0,
                               processCycles: 0, tailCs: 0, top: "no samples")
        guard let startIndex = points.lastIndex(where: { $0.ms <= t0 }) ?? (points.isEmpty ? nil : 0),
              let doneIndex = points.firstIndex(where: { $0.ms >= t1 }) ?? (points.isEmpty ? nil : points.count - 1)
        else { return empty }
        let window = Array(points[startIndex...])
        guard window.count >= 2, let b = window.last else { return empty }
        let main = UInt32(WindowsApp.mainThreadID)
        // Per 20 ms bucket: a thread present at both edges counts its growth, a thread born inside counts from zero, a thread
        // that ended inside counts nothing for that bucket. Summed over the buckets, so short-lived threads are not lost
        // (the gate's edge-only reading loses a thread that ends inside its window).
        func delta(_ x: Recorder.Point, _ y: Recorder.Point, _ tid: UInt32) -> Int {
            guard let now = y.cs[tid] else { return 0 }
            return max(0, Int(now) - Int(x.cs[tid] ?? 0))
        }
        func cyclesDelta(_ x: Recorder.Point, _ y: Recorder.Point, _ tid: UInt32) -> UInt64 {
            guard let now = y.cycles[tid] else { return 0 }
            let before = x.cycles[tid] ?? 0
            return now >= before ? now - before : 0
        }
        var csByThread: [UInt32: Int] = [:]
        var cyclesByThread: [UInt32: UInt64] = [:]
        for i in 0..<(window.count - 1) {
            let x = window[i], y = window[i + 1]
            for tid in y.cs.keys where tid != recorder {
                csByThread[tid, default: 0] += delta(x, y, tid)
                cyclesByThread[tid, default: 0] &+= cyclesDelta(x, y, tid)
            }
        }
        var totals: [(tid: UInt32, cs: Int, cycles: UInt64)] = csByThread.compactMap { entry in
            let cycles = cyclesByThread[entry.key] ?? 0
            return entry.value > 0 || cycles > 0 ? (entry.key, entry.value, cycles) : nil
        }
        totals.sort { $0.cs != $1.cs ? $0.cs > $1.cs : $0.cycles > $1.cycles }
        func who(_ tid: UInt32) -> String { tid == main ? "main" : "\(tid) \(IdleSampler.label(tid))" }
        let hot = totals.first
        let partner = totals.dropFirst().first
        var busyStart: Double?, busyEnd = 0.0, busyMs = 0.0, busyCs = 0
        if let hot {
            for i in 0..<(window.count - 1) {
                let x = window[i], y = window[i + 1]
                let d = delta(x, y, hot.tid)
                let dt = y.ms - x.ms
                guard dt > 0, Double(d) / (dt / 1000) >= 500 else { continue }
                if busyStart == nil { busyStart = x.ms }
                busyEnd = y.ms
                busyMs += dt
                busyCs += d
            }
        }
        let done = points[doneIndex]
        var tail = 0
        for tid in Set(done.cs.keys).union(b.cs.keys) where tid != recorder { tail += max(0, delta(done, b, tid)) }
        return CaseResult(
            name: name, outcome: outcome, requestMs: Int(t1 - t0), busyMs: Int(busyMs),
            busyStartMs: busyStart.map { Int($0 - t0) } ?? 0, busyEndMs: busyStart == nil ? 0 : Int(busyEnd - t0),
            hot: hot.map { who($0.tid) } ?? "-", hotCs: hot?.cs ?? 0, hotCycles: hot?.cycles ?? 0,
            hotWakesPerSec: busyMs > 0 ? Int(Double(busyCs) / (busyMs / 1000)) : 0,
            partner: partner.map { who($0.tid) } ?? "-", partnerCs: partner?.cs ?? 0,
            processCs: totals.reduce(0) { $0 + max(0, $1.cs) }, processCycles: totals.reduce(UInt64(0)) { $0 &+ $1.cycles },
            tailCs: tail, top: totals.prefix(5).map { "\(who($0.tid)):cs=\($0.cs),cycles=\($0.cycles)" }.joined(separator: "; "))
    }

    /// Starts `body`, waits 1 s, picks the threads that switched more than 30 times in the next 300 ms, samples their stacks
    /// for 4 s while the transfer still runs, then waits for it.
    @MainActor private static func stacksDuring(_ body: @escaping @Sendable () async -> String) async -> String {
        let transfer = Task.detached { await body() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let a = IdleSampler.snapshot() else { return "snapshot failed" }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let b = IdleSampler.snapshot() else { return "snapshot failed" }
        let main = UInt32(WindowsApp.mainThreadID)
        let hot = b.contextSwitches.compactMap { entry -> (UInt32, Int)? in
            let d = Int(entry.value) - Int(a.contextSwitches[entry.key] ?? entry.value)
            return d > 30 && entry.key != main ? (entry.key, d) : nil
        }.sorted { $0.1 > $1.1 }
        let found = "hot threads (cs in 300 ms): " + (hot.isEmpty ? "none" : hot.map { "\($0.0) \(IdleSampler.label($0.0)) cs=\($0.1)" }.joined(separator: "; "))
        var detail = ""
        if !hot.isEmpty {
            let sampled = await StackSampler.sample(tids: hot.prefix(3).map { $0.0 }, seconds: 4)
            detail = "\n" + sampled
        }
        let outcome = await transfer.value
        return found + detail + "\ntransfer: " + outcome
    }
}

/// Reads every thread's switches and cycles every 20 ms on a thread of its own until stopped.
private final class Recorder: @unchecked Sendable {
    struct Point { let ms: Double; let cs: [UInt32: UInt32]; let cycles: [UInt32: UInt64] }
    private let lock = NSLock()
    private var points: [Point] = []
    private var stopRequested = false
    private var finished = false
    private var tid: UInt32 = 0

    func start() { Thread { self.loop() }.start() }
    func requestStop() { lock.lock(); stopRequested = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var threadID: UInt32 { lock.lock(); defer { lock.unlock() }; return tid }
    func taken() -> [Point] { lock.lock(); defer { lock.unlock() }; return points }

    private func loop() {
        lock.lock(); tid = UInt32(GetCurrentThreadId()); lock.unlock()
        while true {
            if let s = IdleSampler.snapshot() {
                let p = Point(ms: WindowsSelftest.nowMs(), cs: s.contextSwitches, cycles: s.cycles)
                lock.lock(); points.append(p); lock.unlock()
            }
            lock.lock(); let stop = stopRequested; lock.unlock()
            if stop { break }
            Sleep(20)
        }
        lock.lock(); finished = true; lock.unlock()
    }
}

/// A blocking HTTP/1.1 server on 127.0.0.1 (a thread per connection), for transfers of known shape without any network
/// (this helper and `WindowsHTTPFetchTests`). Routes:
/// `/delay/<ms>` answers after that long; `/big/<bytes>` sends that many bytes at once; `/hang` sends the headers and 10 of
/// 1000 body bytes, then nothing until the client closes; `/cut` sends the same 10 bytes and closes; `/silent` reads the
/// request and never answers; `/echo` answers with the method, the header block and the body it received;
/// `/redirect` is a 302 to `/delay/0`; `/redirect-to/<port>` a 302 to `http://localhost:<port>/echo` (another host);
/// `/see-other` a 303 to `/echo`; `/status/<code>` that status (204 and 304 without a body); `/gzip`, `/deflate` a fixed
/// body with that Content-Encoding; `/chunked` three chunks. A request in absolute form (`GET http://host/path`, the way a
/// client talks to a proxy) is answered `proxied <target>` plus the header block. Connections stay open (keep-alive)
/// unless the client asked for `Connection: close`; 20 s of silence closes them.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listener: SOCKET

    private init(listener: SOCKET, port: UInt16) { self.listener = listener; self.port = port }

    static func start() -> LoopbackServer? {
        var wsa = WSADATA()
        guard WSAStartup(0x0202, &wsa) == 0 else { return nil }
        let s = NB.open()
        guard s != SOCKET.max else { return nil }
        guard NB.bindTo(s, NB.loopback4(port: 0)), NB.startListening(s), let port = NB.localPort(s) else { NB.closeNow(s); return nil }
        let server = LoopbackServer(listener: s, port: port)
        Thread { server.acceptLoop() }.start()
        return server
    }

    /// A port with nothing listening (bound, then closed): a connection there is refused.
    static func closedPort() -> UInt16? {
        let s = NB.open()
        guard s != SOCKET.max else { return nil }
        defer { NB.closeNow(s) }
        guard NB.bindTo(s, NB.loopback4(port: 0)) else { return nil }
        return NB.localPort(s)
    }

    private func acceptLoop() {
        while true {
            let c = NB.acceptOne(listener)
            if c == SOCKET.max { return }
            Thread { Self.serve(c) }.start()
        }
    }

    static let gzipBody: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x4b, 0xaf, 0xca, 0x2c, 0x50, 0x48,
        0xca, 0x4f, 0xa9, 0xb4, 0x52, 0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0x2b, 0xca, 0xcf, 0x55, 0x28, 0xc9, 0x48, 0x55, 0xc8,
        0xc9, 0xcf, 0x2f, 0x48, 0x4a, 0x4c, 0xce, 0x56, 0x28, 0x4e, 0x2d, 0x2a, 0x4b, 0x2d, 0xe2, 0x02, 0x00, 0x26, 0x7a, 0xc9, 0x81,
        0x2a, 0x00, 0x00, 0x00]
    static let gzipText = "gzip body: hello from the loopback server\n"
    static let deflateBody: [UInt8] = [0x78, 0x9c, 0x4b, 0x49, 0x4d, 0xcb, 0x49, 0x2c, 0x49, 0x55, 0x48, 0xca, 0x4f, 0xa9, 0xb4, 0x52,
        0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0x2b, 0xca, 0xcf, 0x55, 0x28, 0xc9, 0x48, 0x55, 0xc8, 0xc9, 0xcf, 0x2f, 0x48, 0x4a,
        0x4c, 0xce, 0x56, 0x28, 0x4e, 0x2d, 0x2a, 0x4b, 0x2d, 0xe2, 0x02, 0x00, 0x7c, 0xf7, 0x10, 0x73]
    static let deflateText = "deflate body: hello from the loopback server\n"
    static let chunkedText = "first chunk, second chunk, third chunk\n"

    private static func serve(_ c: SOCKET) {
        defer { NB.closeNow(c) }
        NB.setReceiveTimeout(c, ms: 20_000)
        while let request = NB.readRequest(c) {
            let close = request.close
            if request.method == "TLS" {
                _ = NB.put(c, Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            if request.target.lowercased().hasPrefix("http://") {
                let body = Array("proxied \(request.target)\n\(request.header)".utf8)
                guard NB.put(c, NB.head(length: body.count, close: close) + body) else { return }
                if close { return }
                continue
            }
            let parts = request.target.split(separator: "/").map(String.init)
            let arg = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            switch parts.first ?? "" {
            case "delay":
                if arg > 0 { Sleep(DWORD(arg)) }
                let body = Array("ok \(arg)\n".utf8)
                guard NB.put(c, NB.head(length: body.count, close: close) + body) else { return }
            case "big":
                guard NB.put(c, NB.head(length: arg, close: close)) else { return }
                let chunk = [UInt8](repeating: 0x61, count: 65_536)
                var left = arg
                while left > 0 {
                    let k = min(left, chunk.count)
                    guard NB.put(c, Array(chunk[0..<k])) else { return }
                    left -= k
                }
            case "hang":
                _ = NB.put(c, NB.head(length: 1000, close: false) + Array("0123456789".utf8))
                NB.drain(c)
                return
            case "cut":
                _ = NB.put(c, NB.head(length: 1000, close: false) + Array("0123456789".utf8))
                return
            case "silent":
                NB.drain(c)
                return
            case "echo":
                let body = Array("\(request.method)\n\(request.header)\n\n".utf8) + request.body
                guard NB.put(c, NB.head(length: body.count, close: close) + body) else { return }
            case "redirect":
                guard NB.put(c, Array("HTTP/1.1 302 Found\r\nLocation: /delay/0\r\nContent-Length: 0\r\n\r\n".utf8)) else { return }
            case "redirect-to":
                let line = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(arg)/echo\r\nContent-Length: 0\r\n\r\n"
                guard NB.put(c, Array(line.utf8)) else { return }
            case "see-other":
                guard NB.put(c, Array("HTTP/1.1 303 See Other\r\nLocation: /echo\r\nContent-Length: 0\r\n\r\n".utf8)) else { return }
            case "status":
                if arg == 204 || arg == 304 {
                    guard NB.put(c, Array("HTTP/1.1 \(arg) Status\r\n\r\n".utf8)) else { return }
                } else {
                    let body = Array("status \(arg)\n".utf8)
                    let line = "HTTP/1.1 \(arg) Status\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\n\r\n"
                    guard NB.put(c, Array(line.utf8) + body) else { return }
                }
            case "gzip", "deflate":
                let gzip = parts.first == "gzip"
                let body = gzip ? gzipBody : deflateBody
                let line = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: \(gzip ? "gzip" : "deflate")\r\n"
                    + "Content-Length: \(body.count)\r\n\r\n"
                guard NB.put(c, Array(line.utf8) + body) else { return }
            case "chunked":
                var out = Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
                for piece in ["first chunk, ", "second chunk, ", "third chunk\n"] {
                    out += Array("\(String(piece.utf8.count, radix: 16))\r\n\(piece)\r\n".utf8)
                }
                out += Array("0\r\n\r\n".utf8)
                guard NB.put(c, out) else { return }
            default:
                _ = NB.put(c, Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            if close { return }
        }
    }
}

/// Thin Winsock calls under names that cannot collide with anything above.
private enum NB {
    struct Request { let method: String; let target: String; let close: Bool; let header: String; let body: [UInt8] }

    static func open() -> SOCKET { socket(2 /* AF_INET */, 1 /* SOCK_STREAM */, 6 /* IPPROTO_TCP */) }

    static func loopback4(port: UInt16) -> [UInt8] {
        [2, 0, UInt8(port >> 8), UInt8(port & 0xff), 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    static func bindTo(_ s: SOCKET, _ address: [UInt8]) -> Bool {
        address.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) } == 0
    }

    static func startListening(_ s: SOCKET) -> Bool { listen(s, 64) == 0 }

    static func acceptOne(_ s: SOCKET) -> SOCKET { accept(s, nil, nil) }

    static func localPort(_ s: SOCKET) -> UInt16? {
        var buffer = [UInt8](repeating: 0, count: 128)
        var length: Int32 = 128
        let r = buffer.withUnsafeMutableBytes { getsockname(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length) }
        guard r == 0 else { return nil }
        return UInt16(buffer[2]) << 8 | UInt16(buffer[3])
    }

    static func setReceiveTimeout(_ s: SOCKET, ms: UInt32) {
        var v = ms
        _ = withUnsafePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(s, 0xffff /* SOL_SOCKET */, 0x1006 /* SO_RCVTIMEO */, $0, 4) }
        }
    }

    static func head(length: Int, close: Bool) -> [UInt8] {
        Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(length)\r\n\(close ? "Connection: close\r\n" : "")\r\n".utf8)
    }

    /// One request: the header block, then a body of `Content-Length` bytes; nil when the client closed first.
    static func readRequest(_ s: SOCKET) -> Request? {
        var data: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        var headEnd: Int?
        while headEnd == nil {
            guard data.count < 65_536 else { return nil }
            let n = recv(s, &buffer, Int32(buffer.count), 0)
            if n <= 0 { return nil }
            data += buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
            // A TLS ClientHello (record type 0x16): this server speaks plain HTTP only; `serve` answers in plain text.
            if data.first == 0x16 { return Request(method: "TLS", target: "", close: true, header: "", body: []) }
            if data.count >= 4 {
                headEnd = (0...(data.count - 4)).first { data[$0] == 13 && data[$0 + 1] == 10 && data[$0 + 2] == 13 && data[$0 + 3] == 10 }
            }
        }
        guard let end = headEnd else { return nil }
        let head = String(decoding: data[0..<end], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var body = Array(data[(end + 4)...])
        while body.count < length {
            let n = recv(s, &buffer, Int32(min(buffer.count, length - body.count)), 0)
            if n <= 0 { return nil }
            body += buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
        }
        return Request(method: String(fields[0]), target: String(fields[1]), close: head.lowercased().contains("connection: close"),
                       header: head, body: Array(body.prefix(length)))
    }

    static func put(_ s: SOCKET, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                send(s, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), Int32(bytes.count - offset), 0)
            }
            if n <= 0 { return false }
            offset += Int(n)
        }
        return true
    }

    static func drain(_ s: SOCKET) {
        var buffer = [CChar](repeating: 0, count: 256)
        while recv(s, &buffer, 256, 0) > 0 {}
    }

    static func closeNow(_ s: SOCKET) { _ = closesocket(s) }
}
#endif
