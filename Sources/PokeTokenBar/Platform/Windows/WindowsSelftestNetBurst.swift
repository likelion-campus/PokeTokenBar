#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// `--selftest-net-burst <out.json>`: what one HTTP fetch costs in wakeups, per thread and over time (the status-check
/// burst of the idle gate). Each case runs one fetch while a recorder thread reads every thread's context switches and
/// cycles every 20 ms (`IdleSampler.snapshot`, which does not wake the threads it reads), then 3 s of tail. Per case: the
/// hottest thread and its partner, the busy period (20 ms buckets where the hottest thread switched >= 500 times a
/// second) against the request time, wakeups per second inside it, whole-process switches, and the tail after completion.
/// Cases: a loopback HTTP server in this process (no network) answering at once, after 2 s and 10 s, never finishing
/// (the client's 10 s timeout ends it), and with 8 MB; the same through WinHTTP; the status endpoints the app already
/// contacts through URLSession and WinHTTP; the app's status-check code path before and after the route; one fetch of
/// each other URLSession user (update feed, sprite, PokeAPI, the limits host without credentials). Then stacks of the hot
/// threads, sampled during a separate long loopback transfer (suspending a thread costs a context switch, so never in a
/// measured run). Diagnostics only: nothing here runs in the shipped app.
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
            output.notes.append("loopback server on \(lo); curl proxy variable set: \(WinHTTPFetch.curlProxyConfigured())")
            // Warm the dispatch threads, the shared session and WinHTTP once, so the cases see the steady state.
            let warmSession = await get(URLSession.shared, lo + "/delay/0", timeout: 10)
            let warmWinHTTP = await winhttp(lo + "/delay/0", timeout: 10)
            output.notes.append("warm-up: \(warmSession); \(warmWinHTTP)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let claude = "https://status.claude.com/api/v2/summary.json"
            let openai = "https://status.openai.com/api/v2/summary.json"
            let cases: [(String, @MainActor () async -> String)] = [
                ("lo-immediate", { await get(URLSession.shared, lo + "/delay/0", timeout: 10) }),
                ("lo-delay-2s", { await get(URLSession.shared, lo + "/delay/2000", timeout: 30) }),
                ("lo-delay-10s", { await get(URLSession.shared, lo + "/delay/10000", timeout: 30) }),
                ("lo-hang-timeout-10s", { await get(URLSession.shared, lo + "/hang", timeout: 10) }),
                ("lo-8MB", { await get(URLSession.shared, lo + "/big/8388608", timeout: 30) }),
                ("lo-delay-2s-connection-close", { await get(URLSession.shared, lo + "/delay/2000", timeout: 30, close: true) }),
                ("lo-delay-2s-own-ephemeral-session", {
                    let session = URLSession(configuration: .ephemeral)
                    let r = await get(session, lo + "/delay/2000", timeout: 30)
                    session.finishTasksAndInvalidate()
                    return r
                }),
                ("winhttp-lo-immediate", { await winhttp(lo + "/delay/0", timeout: 10) }),
                ("winhttp-lo-delay-2s", { await winhttp(lo + "/delay/2000", timeout: 30) }),
                ("winhttp-lo-delay-10s", { await winhttp(lo + "/delay/10000", timeout: 30) }),
                ("winhttp-lo-hang-timeout-10s", { await winhttp(lo + "/hang", timeout: 10) }),
                ("winhttp-lo-8MB", { await winhttp(lo + "/big/8388608", timeout: 30) }),
                ("https-claude-urlsession", { await get(URLSession.shared, claude, timeout: 10) }),
                ("https-openai-urlsession", { await get(URLSession.shared, openai, timeout: 10) }),
                ("https-claude-winhttp", { await winhttp(claude, timeout: 10) }),
                ("https-openai-winhttp", { await winhttp(openai, timeout: 10) }),
                ("status-check-old-path-urlsession", { await oldStatusPath() }),
                ("status-check-app-path", { await appStatusPath() }),
                ("update-feed-urlsession", {
                    let t0 = WindowsSelftest.nowMs()
                    let outcome = await InstallerReleaseFeed.outcome()
                    return "\(outcome) in \(Int(WindowsSelftest.nowMs() - t0)) ms"
                }),
                ("sprite-urlsession", {
                    await get(URLSession.shared, "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/25.png", timeout: 15)
                }),
                ("pokeapi-urlsession", { await get(URLSession.shared, "https://pokeapi.co/api/v2/pokemon-species/25", timeout: 15) }),
                ("limits-host-urlsession-no-credentials", {
                    await get(URLSession.shared, "https://api.anthropic.com/api/oauth/usage", timeout: 15)
                }),
                ("idle-10s-after-all", { try? await Task.sleep(nanoseconds: 10_000_000_000); return "slept" }),
            ]
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

    /// `StatuspageStatusProvider.fetch()` as it was before the route: both endpoints at once on `URLSession.shared`.
    private static func oldStatusPath() async -> String {
        await withTaskGroup(of: String.self) { group in
            for endpoint in StatuspageStatusProvider.endpoints {
                group.addTask {
                    let outcome = await get(URLSession.shared, endpoint.url.absoluteString, timeout: 10)
                    return endpoint.id + ": " + outcome
                }
            }
            var parts: [String] = []
            for await part in group { parts.append(part) }
            return parts.sorted().joined(separator: "; ")
        }
    }

    /// The app's code path as built: `StatuspageStatusProvider.fetch()` (through `PlatformCompat.oneShotData`).
    private static func appStatusPath() async -> String {
        let t0 = WindowsSelftest.nowMs()
        let statuses = await StatuspageStatusProvider().fetch()
        return "\(statuses.count) statuses in \(Int(WindowsSelftest.nowMs() - t0)) ms: "
            + statuses.map { "\($0.key)=\($0.value.indicator.rawValue)" }.sorted().joined(separator: " ")
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
        guard let a = window.first, let b = window.last, window.count >= 2 else { return empty }
        let main = UInt32(WindowsApp.mainThreadID)
        func delta(_ x: Recorder.Point, _ y: Recorder.Point, _ tid: UInt32) -> Int { Int(y.cs[tid] ?? 0) - Int(x.cs[tid] ?? 0) }
        var totals: [(tid: UInt32, cs: Int, cycles: UInt64)] = []
        for tid in Set(a.cs.keys).union(b.cs.keys) where tid != recorder {
            let cs = delta(a, b, tid)
            let cycles = (b.cycles[tid] ?? 0) &- (a.cycles[tid] ?? 0)
            if cs > 0 || cycles > 0 { totals.append((tid, cs, cycles)) }
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
/// (this helper and `WindowsHTTPFetchTests`): `/delay/<ms>` answers after that long, `/big/<bytes>` sends that many bytes at
/// once, `/hang` sends the headers and 10 of 1000 body bytes and then nothing until the client closes, `/echo` answers with
/// the request's header block, `/redirect` is a 302 to `/delay/0`, `/status/<code>` answers with that status. Connections
/// stay open (keep-alive) unless the client asked for `Connection: close`; 20 s of silence closes them.
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

    private func acceptLoop() {
        while true {
            let c = NB.acceptOne(listener)
            if c == SOCKET.max { return }
            Thread { Self.serve(c) }.start()
        }
    }

    private static func serve(_ c: SOCKET) {
        defer { NB.closeNow(c) }
        NB.setReceiveTimeout(c, ms: 20_000)
        while let request = NB.readRequest(c) {
            let (path, close, header) = request
            let parts = path.split(separator: "/").map(String.init)
            let arg = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            switch parts.first ?? "" {
            case "delay":
                if arg > 0 { Sleep(DWORD(arg)) }
                let body = Array("ok \(arg)\n".utf8)
                guard NB.put(c, NB.head(length: body.count, close: close) + body) else { return }
            case "echo":
                let body = Array(header.utf8)
                guard NB.put(c, NB.head(length: body.count, close: close) + body) else { return }
            case "redirect":
                guard NB.put(c, Array("HTTP/1.1 302 Found\r\nLocation: /delay/0\r\nContent-Length: 0\r\n\r\n".utf8)) else { return }
            case "status":
                let body = Array("status \(arg)\n".utf8)
                let line = "HTTP/1.1 \(arg) Status\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\n\r\n"
                guard NB.put(c, Array(line.utf8) + body) else { return }
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

    /// The request target, whether the client asked to close, and the header block, once it has arrived; nil when it closed.
    static func readRequest(_ s: SOCKET) -> (String, Bool, String)? {
        var data: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let n = recv(s, &buffer, Int32(buffer.count), 0)
            if n <= 0 { return nil }
            data += buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
            guard data.count >= 4, let end = (0...(data.count - 4)).first(where: {
                data[$0] == 13 && data[$0 + 1] == 10 && data[$0 + 2] == 13 && data[$0 + 3] == 10
            }) else { continue }
            let head = String(decoding: data[0..<end], as: UTF8.self)
            let line = head.components(separatedBy: "\r\n").first ?? ""
            let fields = line.split(separator: " ")
            guard fields.count >= 2 else { return nil }
            return (String(fields[1]), head.lowercased().contains("connection: close"), head)
        }
        return nil
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
