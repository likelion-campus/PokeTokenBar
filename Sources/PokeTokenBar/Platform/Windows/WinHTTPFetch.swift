#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// One HTTP request through WinHTTP, for the app's one-shot fetches on Windows (`PlatformCompat.oneShotData`).
///
/// Why not URLSession: swift-corelibs-foundation drives libcurl through libdispatch read/write sources on the socket
/// (FoundationNetworking `MultiHandle.swift`, swift-6.3.2-RELEASE, lines 527-549). It creates a write source when curl first
/// asks for write readiness and cancels it only when curl removes the socket (`register`, lines 110-140: `.registerRead`
/// after `.registerReadAndWrite` leaves the write source alive). libdispatch on Windows emulates a level-triggered write
/// source with a zero-byte `send()` on every re-arm and posts "writable" at once when it succeeds (`event_windows.c`,
/// lines 487-505; re-armed through `_dispatch_unote_resume_muxed`, 581-588). A connected socket is always writable, so the
/// source fires, curl finds nothing to write, the source re-arms and fires again, between two dispatch threads, from the
/// connect until the transfer ends: 25,000-50,000 wakeups a second on the CI runner. A reused keep-alive connection is quiet
/// (curl never asks for write readiness), but a store refresh every 120 s is past libcurl's 118 s reuse limit (curl 8.9.1
/// `url.c` line 481), so it always connects afresh. WinHTTP's synchronous calls on a thread of our own block in the kernel.
///
/// The request is the caller's, with what URLSession would have added (`HTTPURLProtocol.swift` 330-436 and 664-700):
/// - method, headers and `httpBody` as given; the session's `httpAdditionalHeaders` under them; `User-Agent` and
///   `Accept-Language` when absent (corelibs' defaults, with "WinHTTP" where corelibs names its curl version); a POST body
///   without a `Content-Type` gets `application/x-www-form-urlencoded`, as corelibs does.
/// - the timeout: the request's `timeoutInterval`, or the session's `timeoutIntervalForRequest` when the request kept the
///   default 60 s, for resolve, connect, send, each receive and the response headers, plus a timer of our own that answers the
///   caller on time (WinHTTP checks its receive timeouts only when data arrives: `WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT`,
///   "Option flags"). The same timer keeps a whole-fetch deadline: the session's `timeoutIntervalForResource` when the caller
///   set one (Cursor usage: 120 s), else `defaultTotalDeadline`, so a server that drips bytes cannot hold a fetch forever.
/// - TLS by Schannel against the Windows store with revocation checked (curl's Schannel default, `schannel.c` 8.9.1 493-495),
///   TLS 1.2 or 1.3 only (Windows 10's WinHTTP default still allows SSL 3, TLS 1.0 and 1.1: "Option flags",
///   `WINHTTP_OPTION_SECURE_PROTOCOLS`). No certificate check is relaxed (`WINHTTP_OPTION_SECURITY_FLAGS` is never set).
/// - gzip decoded (curl asked for deflate, gzip and br; WinHTTP asks for gzip only, the one form it decodes as libcurl did:
///   its "deflate" decoder takes only raw deflate, not the zlib-wrapped form).
/// - redirects followed here, not by WinHTTP (`WINHTTP_OPTION_REDIRECT_POLICY_NEVER`), with corelibs' methods
///   (`HTTPURLProtocol.swift` 567-579) and limit (20, 459-466), never in a loop. The headers of each hop follow the Mac's
///   URLSession (`RedirectHeadersMacTests`): `Authorization` is dropped on every hop, the rest goes along; stricter than the
///   Mac, a request that carries a `Cookie` does not follow a redirect to another origin (the Mac sends it along; the 3xx comes
///   back to the caller, which treats it as a failure), and nothing follows from HTTPS to HTTP. `nextHop` has the rules.
/// - no cookies kept or sent by WinHTTP (`WINHTTP_DISABLE_COOKIES`); a `Cookie` header the caller sets is sent as given.
/// - the decoded body is limited to `maxBodyBytes` (`defaultMaxBodyBytes`, 32 MB: none of the callers had a limit; the
///   largest answers are under 1 MB), counted after decompression: `.dataLengthExceedsMaximum`.
/// - the route from `WinProxyRoute`: the Windows proxy settings, or libcurl's proxy variables when set.
/// - Windows logon credentials never go to a server. Every request starts with automatic authentication off
///   (`WINHTTP_DISABLE_AUTHENTICATION`) and the automatic logon policy at HIGH, so a 401 asking for NTLM or Negotiate comes back
///   to the caller as a status. WinHTTP's default, MEDIUM, sends the logon identity to "requests on the local intranet. The
///   local intranet is considered to be any server on the proxy bypass list in the current proxy configuration"
///   (`WinHttpRequestAutoLogonPolicy`); without a proxy that can be any host. Only a 407 from a proxy the request went through
///   (an environment proxy, or the proxy WinHTTP reports for a request on the Windows settings) is answered: once, on a new
///   request with authentication on and the policy at MEDIUM, and if the proxy asks again for NTLM or Negotiate, with
///   `WinHttpSetCredentials` and no name (the logon identity), as .NET's WinHttpHandler does (dotnet/runtime v9.0.0,
///   `WinHttpAuthHelper.cs` 288-300 and 335-346; `WinHttpHandler.cs` 1517-1528 starts every request at HIGH). Nothing of ours
///   (a token, a cookie) is ever offered to a proxy: those are request headers only.
/// - cancellation and the timer answer the caller at once and only signal the worker thread, which alone closes its handles,
///   after the WinHTTP call it is in returns: "An application should never call WinHttpCloseHandle on a synchronous request.
///   This can create a race condition" (`WinHttpCloseHandle`, Remarks). The WinHTTP timeouts above bound that wait; the
///   worker checks the signal after every call and never touches a handle after closing it.
/// - at most `maxConcurrentFetches` workers at once; a slot is held until the worker ends, also after its caller was
///   answered, so a hung network cannot pile up threads. Waiting for a slot ends on Task cancellation.
/// Nothing here logs a header, a body or a URL query. Each fetch opens its own session and closes it with the request, so
/// nothing of WinHTTP stays open between fetches (a process-wide session kept a pooled connection and a thread-pool worker
/// waking every 2-3 s); cross-session pooling is switched off where Windows offers the option.
enum WinHTTPFetch {
    static let maxConcurrentFetches = 8
    static let defaultMaxBodyBytes = 32 * 1024 * 1024
    static let defaultTotalDeadline: TimeInterval = 300
    static let maxRedirects = 20
    /// The credential headers the callers set: `Authorization` (Claude OAuth usage and profile, Cursor limits and usage, Grok,
    /// OpenCode Go) and `Cookie` (claude.ai session key, Cursor usage).
    static let credentialHeaders = ["Authorization", "Cookie"]
    static let fallbackNotice = "winhttp: proxy from environment not supported by WinHTTP; using URLSession (higher idle cost)"

    /// Whether this request goes through WinHTTP: http(s), WinHTTP loaded, no body stream, a route WinHTTP can take, and no
    /// protocol of the caller's own in its session (a `URLProtocol` subclass in `protocolClasses` that takes the request is the
    /// caller's chosen transport, e.g. a test stub; corelibs' built-in protocols do not count). A proxy variable WinHTTP
    /// cannot take is logged once (without its value).
    static func handles(_ request: URLRequest, session: URLSession? = nil) -> Bool {
        guard api != nil, request.httpBodyStream == nil, let url = request.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return false }
        if let classes = session?.configuration.protocolClasses, classes.contains(where: { candidate in
            guard let type = candidate as? URLProtocol.Type, !String(reflecting: type).hasPrefix("FoundationNetworking.") else { return false }
            return type.canInit(with: request)
        }) { return false }
        if case .urlSession = WinProxyRoute.route(for: url) {
            if stats.noteFallback() { AppLog.write(fallbackNotice) }
            return false
        }
        return true
    }

    /// `configuration`: the session the caller would have used (its timeouts and extra headers apply, as URLSession applied
    /// them). Diagnostics and tests only: `route` (the net-burst helper compares a direct fetch with the system proxy),
    /// `maxBodyBytes`, and `logonAsBefore`, which starts the request with WinHTTP's defaults (authentication on, logon policy
    /// MEDIUM), as this file did before the review, for the control in `WindowsHTTPFetchTests`. `progress` (the update
    /// download's window) gets the decoded body bytes so far after each read, on the fetch's own thread.
    static func data(for request: URLRequest, configuration: URLSessionConfiguration? = nil,
                     route: WinProxyRoute.Route? = nil, maxBodyBytes: Int = defaultMaxBodyBytes,
                     logonAsBefore: Bool = false, progress: (@Sendable (Int) -> Void)? = nil) async throws -> (Data, URLResponse) {
        try await data(for: request, configuration: configuration, route: route, maxBodyBytes: maxBodyBytes,
                       logonAsBefore: logonAsBefore, session: nil, progress: progress)
    }

    private static func data(for request: URLRequest, configuration: URLSessionConfiguration?, route: WinProxyRoute.Route?,
                             maxBodyBytes: Int, logonAsBefore: Bool, session: SharedSession?,
                             progress: (@Sendable (Int) -> Void)? = nil) async throws -> (Data, URLResponse) {
        guard let api, let url = request.url else { throw URLError(.cannotLoadFromNetwork) }
        try refuseRealNetworkOutsideTheApp(url)
        let plan = try Plan(request, configuration, route: route ?? WinProxyRoute.route(for: url), maxBodyBytes: maxBodyBytes,
                            logonAsBefore: logonAsBefore, progress: progress)
        try await WinHTTPFetch.gate.acquire()
        let fetch = Fetch(api: api, plan: plan, shared: session)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetch.start(continuation) { WinHTTPFetch.gate.release() }
            }
        } onCancel: {
            fetch.stop(.cancelled)
        }
    }

    /// The URLError a caller sees for a WinHTTP error code: the codes the shared code was written against on the Mac.
    static func urlErrorCode(_ winhttp: DWORD) -> URLError.Code {
        switch winhttp {
        case 12002: return .timedOut                       // ERROR_WINHTTP_TIMEOUT
        case 12005: return .badURL                         // INVALID_URL
        case 12006: return .unsupportedURL                 // UNRECOGNIZED_SCHEME
        case 12007: return .cannotFindHost                 // NAME_NOT_RESOLVED (also offline: no DNS answer)
        case 12017: return .cancelled                      // OPERATION_CANCELLED
        case 12029: return .cannotConnectToHost            // CANNOT_CONNECT (refused, unreachable)
        case 12030: return .networkConnectionLost          // CONNECTION_ERROR (reset, closed mid-body)
        case 12037: return .serverCertificateHasBadDate    // SECURE_CERT_DATE_INVALID
        case 12038, 12057, 12169, 12170, 12179: return .serverCertificateUntrusted  // CN, revocation, invalid, revoked, usage
        case 12045: return .serverCertificateHasUnknownRoot // SECURE_INVALID_CA
        case 12044: return .clientCertificateRequired      // CLIENT_AUTH_CERT_NEEDED
        case 12157, 12175: return .secureConnectionFailed  // SECURE_CHANNEL_ERROR, SECURE_FAILURE
        case 12152, 12182, 12183, 12184: return .badServerResponse  // invalid response, header/chunk/drain overflow
        case 12156: return .httpTooManyRedirects           // REDIRECT_FAILED
        case 12166, 12167, 12178, 12180: return .cannotConnectToHost  // PAC script / auto-proxy service / WPAD failed
        default: return .unknown
        }
    }

    // MARK: - redirects

    struct Field: Sendable, Equatable { let name: String; let value: String }

    /// One request on the way: a redirect makes the next one.
    struct Hop: Sendable, Equatable {
        var url: URL
        var method: String
        var fields: [Field]
        var sendsBody: Bool
    }

    /// The request a redirect leads to, or nil when the 3xx goes back to the caller as the answer. corelibs' methods
    /// (`HTTPURLProtocol.swift` 567-579): 301/302 after a POST and 303 continue as GET without the body; 301, 302 and 305-308
    /// keep the method and the body. `Authorization` is dropped on every hop, as the Mac's URLSession does. Not followed:
    /// no usable `Location`, a scheme other than http(s), HTTPS to HTTP, and another origin (scheme, host, port) while the
    /// request still carries a credential header (`Cookie`).
    static func nextHop(after status: Int, location: String?, from hop: Hop) -> Hop? {
        var method = hop.method
        var sendsBody = hop.sendsBody
        switch status {
        case 301...302 where hop.method == "POST", 303:
            method = "GET"
            sendsBody = false
        case 301...302, 305...308:
            break
        default:
            return nil
        }
        guard let location, let next = URL(string: location, relativeTo: hop.url)?.absoluteURL,
              let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https", next.host?.isEmpty == false
        else { return nil }
        if hop.url.scheme?.lowercased() == "https", scheme == "http" { return nil }
        let fields = hop.fields.filter { $0.name.caseInsensitiveCompare("Authorization") != .orderedSame }
        if origin(next) != origin(hop.url), fields.contains(where: { field in
            credentialHeaders.contains { $0.caseInsensitiveCompare(field.name) == .orderedSame }
        }) { return nil }
        return Hop(url: next, method: method, fields: fields, sendsBody: sendsBody)
    }

    private static func origin(_ url: URL) -> String? {
        guard let target = Target(url) else { return nil }
        return "\(target.secure ? "https" : "http")://\(target.host.lowercased()):\(target.port)"
    }

    // MARK: - outside the installed app

    /// Outside the installed app (`swift test`, a bare build) only loopback and the reserved test names (`.invalid`, `.test`:
    /// RFC 6761) may be fetched, so no test reaches a real server by accident: a test that needs the answer fails on its own,
    /// and a fetch nobody waits for (a store's status check, a sprite) just does not happen. The selftests run from the
    /// packaged bundle (`PokeTokenBar.version` next to the exe), where this does not apply. Each refused host is named once on
    /// stderr; the Windows test workflow lists them.
    static func refuseRealNetworkOutsideTheApp(_ url: URL) throws {
        guard !PlatformCompat.isBundledApp, let host = url.host, !isTestHost(host) else { return }
        let line = "WinHTTPFetch: refused real host \(host) outside the installed app"
        if stats.noteRefused(host) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: line])
    }

    static func isTestHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return host == "invalid" || host.hasSuffix(".invalid") || host == "test" || host.hasSuffix(".test")
    }

    // MARK: - what tests and diagnostics read

    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var fallbacks = 0
        private var protocols: UInt32 = 0
        private var proxyReports: [String] = []

        /// True the first time only: the notice is logged once per process.
        func noteFallback() -> Bool { lock.lock(); defer { lock.unlock() }; fallbacks += 1; return fallbacks == 1 }
        var fallbackCount: Int { lock.lock(); defer { lock.unlock() }; return fallbacks }
        func noteProtocols(_ mask: UInt32) { lock.lock(); protocols = mask; lock.unlock() }
        /// The `WINHTTP_OPTION_SECURE_PROTOCOLS` mask the last session took.
        var secureProtocols: UInt32 { lock.lock(); defer { lock.unlock() }; return protocols }
        func noteProxyReport(_ text: String) { lock.lock(); proxyReports.append(text); lock.unlock() }
        private var unanswered = 0
        private var refused: Set<String> = []
        /// True the first time a host is refused.
        func noteRefused(_ host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return refused.insert(host.lowercased()).inserted }
        /// True the first time only.
        func noteUnansweredProxyChallenge() -> Bool { lock.lock(); defer { lock.unlock() }; unanswered += 1; return unanswered == 1 }
        /// What `WINHTTP_OPTION_PROXY` said for each 407 on the Windows proxy settings (access type, whether a proxy was named).
        var proxyReportsSeen: [String] { lock.lock(); defer { lock.unlock() }; return proxyReports }
    }

    static let stats = Stats()

    /// At most `slots` fetches hold a worker; the rest wait in order. Waiting ends with `.cancelled` on Task cancellation.
    final class Gate: @unchecked Sendable {
        private enum Waiter { case pending, waiting(CheckedContinuation<Void, Error>), cancelled }
        private let lock = NSLock()
        private var free: Int
        private var waiters: [UInt64: Waiter] = [:]
        private var order: [UInt64] = []
        private var nextID: UInt64 = 0
        private var busy = 0
        private var peak = 0

        init(slots: Int) { free = slots }

        /// Workers running now, and the most at once since the last `resetPeak`.
        var load: (busy: Int, peak: Int) { lock.lock(); defer { lock.unlock() }; return (busy, peak) }
        func resetPeak() { lock.lock(); peak = busy; lock.unlock() }

        func acquire() async throws {
            let id = register()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    if case .cancelled? = self.waiters[id] {
                        self.waiters[id] = nil
                        self.lock.unlock()
                        continuation.resume(throwing: URLError(.cancelled))
                        return
                    }
                    if self.free > 0 {
                        self.free -= 1
                        self.waiters[id] = nil
                        self.grantLocked()
                        self.lock.unlock()
                        continuation.resume()
                        return
                    }
                    self.waiters[id] = .waiting(continuation)
                    self.order.append(id)
                    self.lock.unlock()
                }
            } onCancel: {
                self.lock.lock()
                switch self.waiters[id] {
                case .pending?:
                    self.waiters[id] = .cancelled
                    self.lock.unlock()
                case .waiting(let continuation)?:
                    self.waiters[id] = nil
                    self.order.removeAll { $0 == id }
                    self.lock.unlock()
                    continuation.resume(throwing: URLError(.cancelled))
                default:
                    self.lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            busy -= 1
            while !order.isEmpty {
                let id = order.removeFirst()
                if case .waiting(let continuation)? = waiters[id] {
                    waiters[id] = nil
                    grantLocked()
                    lock.unlock()
                    continuation.resume()
                    return
                }
            }
            free += 1
            lock.unlock()
        }

        private func grantLocked() { busy += 1; peak = max(peak, busy) }

        /// Synchronous: `NSLock` is unavailable from async code.
        private func register() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            nextID += 1
            waiters[nextID] = .pending
            return nextID
        }
    }

    static let gate = Gate(slots: maxConcurrentFetches)

    // MARK: - one session for a batch (diagnostics only)

    /// The net-burst selftest's comparison: `urls` fetched `concurrency` at a time, each on its own session (the app's way) or
    /// all on one session closed when the batch ends (connections kept alive within it). Time, failures, workers at once.
    static func batchDiagnostic(_ urls: [URL], concurrency: Int, oneSession: Bool) async -> String {
        guard let api else { return "WinHTTP unavailable" }
        let shared: SharedSession?
        if oneSession {
            guard let handle = Fetch.openSession(api, route: .systemProxy) else { return "WinHttpOpen failed" }
            shared = SharedSession(handle: handle)
        } else {
            shared = nil
        }
        defer { if let shared { _ = api.close(shared.handle) } }
        gate.resetPeak()
        let t0 = Date()
        var failures = 0
        var index = 0
        while index < urls.count {
            let round = urls[index..<min(index + concurrency, urls.count)]
            failures += await withTaskGroup(of: Int.self) { group in
                for url in round {
                    group.addTask {
                        // Unqualified: `WindowsSeamScanTests` reads a qualified `.data(for:` as a URLSession call.
                        let ok = try? await data(for: URLRequest(url: url, timeoutInterval: 15), configuration: nil,
                                                 route: .systemProxy, maxBodyBytes: WinHTTPFetch.defaultMaxBodyBytes,
                                                 logonAsBefore: false, session: shared)
                        return ok == nil ? 1 : 0
                    }
                }
                return await group.reduce(0, +)
            }
            index += concurrency
        }
        let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
        return "\(urls.count) fetches, \(concurrency) at a time, \(oneSession ? "one session" : "a session each"): \(ms) ms, "
            + "\(failures) failed, workers at once \(gate.load.peak)"
    }

    private struct SharedSession: @unchecked Sendable { let handle: Handle }

    // MARK: - the request as WinHTTP takes it

    private struct Target {
        let host: String, port: UInt16, secure: Bool, object: String

        init?(_ url: URL) {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = parts.host, !host.isEmpty
            else { return nil }
            let isSecure = scheme == "https"
            var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
            if let query = parts.percentEncodedQuery { path += "?" + query }
            self.host = host
            secure = isSecure
            port = UInt16(truncatingIfNeeded: parts.port ?? (isSecure ? 443 : 80))
            object = path
        }
    }

    private struct Plan: Sendable {
        let first: Hop
        let body: Data?
        let timeoutMs: Int32
        let deadline: TimeInterval
        let maxBodyBytes: Int
        let route: WinProxyRoute.Route
        let logonAsBefore: Bool
        let progress: (@Sendable (Int) -> Void)?

        init(_ request: URLRequest, _ configuration: URLSessionConfiguration?, route: WinProxyRoute.Route, maxBodyBytes: Int,
             logonAsBefore: Bool, progress: (@Sendable (Int) -> Void)? = nil) throws {
            guard let url = request.url, Target(url) != nil else { throw URLError(.unsupportedURL) }
            let verb = request.httpMethod ?? "GET"
            let payload = request.httpBody

            var fields: [Field] = []
            func set(_ name: String, _ value: String) {
                fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                fields.append(Field(name: name, value: value))
            }
            func has(_ name: String) -> Bool { fields.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            for (key, value) in configuration?.httpAdditionalHeaders ?? [:] {
                if let name = key as? String, let text = value as? String { set(name, text) }
            }
            for (name, value) in request.allHTTPHeaderFields ?? [:] { set(name, value) }
            if !has("User-Agent") { set("User-Agent", "\(ProcessInfo.processInfo.processName) (unknown version) WinHTTP") }
            if !has("Accept-Language"), let language = Locale.current.language.languageCode?.identifier {
                set("Accept-Language", language)
            }
            if verb == "POST", !(payload?.isEmpty ?? true), !has("Content-Type") {
                set("Content-Type", "application/x-www-form-urlencoded")
            }
            first = Hop(url: url, method: verb, fields: fields, sendsBody: !(payload?.isEmpty ?? true))
            body = payload

            var seconds = request.timeoutInterval
            if seconds == 60, let configuration { seconds = configuration.timeoutIntervalForRequest }
            timeoutMs = Int32(clamping: Int((max(seconds, 0.001) * 1000).rounded()))
            // URLSession's default resource timeout is 7 days: no deadline of the caller's own.
            let resource = configuration?.timeoutIntervalForResource ?? 0
            deadline = resource > 0 && resource < 7 * 24 * 3600 ? resource : WinHTTPFetch.defaultTotalDeadline
            self.maxBodyBytes = maxBodyBytes
            self.route = route
            self.logonAsBefore = logonAsBefore
            self.progress = progress
        }
    }

    private struct Answer {
        let status: Int
        let fields: [String: String]
        let body: Data
        /// A 407 from a proxy this request went through (only then is the logon identity offered, to that proxy).
        let fromProxy: Bool

        func field(_ name: String) -> String? { fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    /// One fetch on its own thread. `stop` (Task cancellation, the timer; any thread) answers the caller and signals the worker,
    /// which stops after the WinHTTP call it is in and closes its handles itself.
    private final class Fetch: @unchecked Sendable {
        private let api: API
        private let plan: Plan
        private let shared: SharedSession?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var answered = false
        private var stopped = false
        private var reason = URLError.Code.cancelled
        /// The silence timer and the whole-fetch deadline in one: it fires at the earlier of the next `timeoutMs` without
        /// data and `ends`. It exists only while the fetch runs.
        private var timer: DispatchSourceTimer?
        private var ends = DispatchTime.now()

        init(api: API, plan: Plan, shared: SharedSession?) { self.api = api; self.plan = plan; self.shared = shared }

        func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>, whenDone: @escaping @Sendable () -> Void) {
            lock.lock()
            if stopped {
                answered = true
                let code = reason
                lock.unlock()
                continuation.resume(throwing: URLError(code))
                whenDone()
                return
            }
            self.continuation = continuation
            ends = .now() + .milliseconds(Int(min(plan.deadline, 86_400) * 1000))
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.setEventHandler { [weak self] in self?.stop(.timedOut) }
            timer = t
            scheduleLocked()
            t.resume()
            lock.unlock()
            Thread { [self] in
                let result = Result { try self.run() }
                self.lock.lock()
                let waiting = self.answered ? nil : self.continuation
                self.answered = true
                self.continuation = nil
                self.timer?.cancel()
                self.timer = nil
                self.lock.unlock()
                waiting?.resume(with: result)
                whenDone()
            }.start()
        }

        /// Task cancellation (`.cancelled`) or the timer (`.timedOut`); the first reason wins.
        func stop(_ code: URLError.Code) {
            lock.lock()
            if !stopped { stopped = true; reason = code }
            let waiting = answered ? nil : continuation
            answered = true
            continuation = nil
            let why = reason
            lock.unlock()
            waiting?.resume(throwing: URLError(why))
        }

        private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        private var stopReason: URLError.Code { lock.lock(); defer { lock.unlock() }; return reason }

        /// After every WinHTTP call: a stopped fetch goes no further (its handles close on the way out).
        private func checkStopped() throws { if isStopped { throw URLError(stopReason) } }

        private func dataArrived() { lock.lock(); scheduleLocked(); lock.unlock() }

        private func scheduleLocked() {
            let silence = DispatchTime.now() + .milliseconds(Int(plan.timeoutMs))
            timer?.schedule(deadline: min(silence, ends))
        }

        static func openSession(_ api: API, route: WinProxyRoute.Route) -> Handle? {
            // No agent string: the request's own User-Agent header is the only one sent.
            let session: Handle?
            switch route {
            case .direct:
                session = api.open(nil, WinHTTPFetch.accessNoProxy, nil, nil, 0)
            case .systemProxy:
                session = api.open(nil, WinHTTPFetch.accessAutomaticProxy, nil, nil, 0) ?? api.open(nil, WinHTTPFetch.accessDefaultProxy, nil, nil, 0)
            case .namedProxy(let hostPort):
                session = api.open(nil, WinHTTPFetch.accessNamedProxy, WinStr.w(hostPort), nil, 0)
            case .urlSession:
                session = nil
            }
            guard let session else { return nil }
            var disablePooling: UInt32 = 1
            _ = api.setOption(session, WinHTTPFetch.optionDisableGlobalPooling, &disablePooling, 4)  // Windows versions without it refuse; fine
            // TLS 1.2 and 1.3; a WinHTTP without TLS 1.3 refuses that flag: TLS 1.2 alone.
            var protocols = WinHTTPFetch.protocolsTLS12And13
            if api.setOption(session, WinHTTPFetch.optionSecureProtocols, &protocols, 4) == 0 {
                protocols = WinHTTPFetch.protocolTLS12
                guard api.setOption(session, WinHTTPFetch.optionSecureProtocols, &protocols, 4) != 0 else {
                    _ = api.close(session)
                    return nil
                }
            }
            WinHTTPFetch.stats.noteProtocols(protocols)
            return session
        }

        func run() throws -> (Data, URLResponse) {
            try checkStopped()
            // WinHTTP may send the body again after `WinHttpSendRequest` returns (an authentication round): it must stay
            // valid "until the request handle is closed or the call to WinHttpReceiveResponse has completed"
            // (`WinHttpSendRequest`). Ours lives until every handle below is closed (this defer runs last).
            var owned: UnsafeMutableRawBufferPointer?
            if let body = plan.body, !body.isEmpty {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: body.count, alignment: 1)
                buffer.copyBytes(from: body)
                owned = buffer
            }
            defer { owned?.deallocate() }
            let session: Handle
            if let shared {
                session = shared.handle
            } else {
                guard let opened = Fetch.openSession(api, route: plan.route) else { throw failure("WinHttpOpen") }
                session = opened
            }
            defer { if shared == nil { _ = api.close(session) } }  // closing the session also drops its connection

            var hop = plan.first
            var visited: Set<String> = [hop.method + " " + hop.url.absoluteString]
            var redirects = 0
            var proxyLogon = plan.logonAsBefore
            while true {
                let answer = try exchange(session, hop, body: hop.sendsBody ? owned : nil, proxyLogon: proxyLogon)
                if answer.status == 407, answer.fromProxy, !proxyLogon {
                    proxyLogon = true
                    continue
                }
                if let next = WinHTTPFetch.nextHop(after: answer.status, location: answer.field("Location"), from: hop) {
                    redirects += 1
                    guard redirects <= WinHTTPFetch.maxRedirects, visited.insert(next.method + " " + next.url.absoluteString).inserted
                    else { throw URLError(.httpTooManyRedirects, userInfo: [NSLocalizedDescriptionKey: "too many HTTP redirects"]) }
                    hop = next
                    continue
                }
                guard let response = HTTPURLResponse(url: hop.url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                     headerFields: answer.fields)
                else { throw URLError(.badServerResponse) }
                return (answer.body, response)
            }
        }

        /// One request and its whole answer, on a connection and request handle of its own (closed on return).
        private func exchange(_ session: Handle, _ hop: Hop, body: UnsafeMutableRawBufferPointer?, proxyLogon: Bool) throws -> Answer {
            guard let target = Target(hop.url) else { throw URLError(.unsupportedURL) }
            guard let connection = api.connect(session, WinStr.w(target.host), target.port, 0) else { throw failure("WinHttpConnect") }
            defer { _ = api.close(connection) }
            guard let request = api.openRequest(connection, WinStr.w(hop.method), WinStr.w(target.object), nil, nil, nil,
                                                target.secure ? WinHTTPFetch.flagSecure : 0)
            else { throw failure("WinHttpOpenRequest") }
            defer { _ = api.close(request) }

            let ms = plan.timeoutMs
            guard api.setTimeouts(request, ms, ms, ms, ms) != 0 else { throw failure("WinHttpSetTimeouts") }
            try set(request, WinHTTPFetch.optionReceiveResponseTimeout, UInt32(ms), "WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT")
            if target.secure {
                try set(request, WinHTTPFetch.optionEnableFeature, WinHTTPFetch.enableSSLRevocation, "WINHTTP_ENABLE_SSL_REVOCATION")
            }
            try set(request, WinHTTPFetch.optionDisableFeature,
                    WinHTTPFetch.disableCookies | (proxyLogon ? 0 : WinHTTPFetch.disableAuthentication), "WINHTTP_OPTION_DISABLE_FEATURE")
            try set(request, WinHTTPFetch.optionRedirectPolicy, WinHTTPFetch.redirectPolicyNever, "WINHTTP_OPTION_REDIRECT_POLICY")
            try set(request, WinHTTPFetch.optionAutologonPolicy,
                    proxyLogon ? WinHTTPFetch.autologonMedium : WinHTTPFetch.autologonHigh, "WINHTTP_OPTION_AUTOLOGON_POLICY")
            var decompression = WinHTTPFetch.decompressGzip
            _ = api.setOption(request, WinHTTPFetch.optionDecompression, &decompression, 4)  // without it the body arrives undecoded, as sent

            let headers = WinStr.w(hop.fields.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n"))
            var status = try send(request, headers, body)
            if status == 407, proxyLogon, let scheme = proxyLogonScheme(request) {
                _ = try readBody(request)  // the previous answer is read before the request goes again (`WinHttpSendRequest`)
                guard api.setCredentials(request, WinHTTPFetch.authTargetProxy, scheme, nil, nil, nil) != 0
                else { throw failure("WinHttpSetCredentials") }
                status = try send(request, headers, body)
            }
            let fromProxy = status == 407 && !proxyLogon && wentThroughProxy(request)
            let data = try readBody(request)
            let fields = headerFields(request)
            func field(_ name: String) -> String? { fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
            // A body that ended early: libcurl failed the transfer (CURLE_PARTIAL_FILE); WinHTTP may just stop reading.
            if hop.method != "HEAD", status != 204, status != 304, field("Content-Encoding") == nil,
               let declared = field("Content-Length").flatMap({ Int($0) }),
               data.count < declared {
                throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "the body ended after \(data.count) of \(declared) bytes"])
            }
            return Answer(status: status, fields: fields, body: data, fromProxy: fromProxy)
        }

        private func set(_ handle: Handle, _ option: UInt32, _ value: UInt32, _ name: String) throws {
            var v = value
            guard api.setOption(handle, option, &v, 4) != 0 else { throw failure(name) }
        }

        /// Send and receive the headers; an authentication round may ask for the same request again (`ERROR_WINHTTP_RESEND_REQUEST`).
        private func send(_ request: Handle, _ headers: [UInt16], _ body: UnsafeMutableRawBufferPointer?) throws -> Int {
            let length = UInt32(body?.count ?? 0)
            for _ in 0..<3 {
                let sent = api.send(request, headers, UInt32.max /* -1: zero-terminated */, body?.baseAddress, length, length, 0)
                let sendError = sent == 0 ? GetLastError() : 0
                try checkStopped()
                guard sent != 0 else { throw failure("WinHttpSendRequest", sendError) }
                let received = api.receive(request, nil)
                let receiveError = received == 0 ? GetLastError() : 0
                try checkStopped()
                if received == 0, receiveError == WinHTTPFetch.errorResendRequest { continue }
                guard received != 0 else { throw failure("WinHttpReceiveResponse", receiveError) }
                var status: UInt32 = 0
                var size: UInt32 = 4
                guard api.queryHeaders(request, WinHTTPFetch.queryStatusCode, nil, &status, &size, nil) != 0
                else { throw failure("WinHttpQueryHeaders") }
                return Int(status)
            }
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "authentication kept asking for the request again"])
        }

        /// The decoded body, at most `maxBodyBytes`, read as it arrives: `WinHttpQueryDataAvailable` waits for the next bytes and
        /// says how many, then `WinHttpReadData` takes exactly those (the documented loop). A synchronous `WinHttpReadData`
        /// with a 64 KB buffer waited to fill it: a body arriving 1 KB every 500 ms tripped a 2 s idle timer on the runner.
        private func readBody(_ request: Handle) throws -> Data {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var available: UInt32 = 0
                let queried = api.queryDataAvailable(request, &available)
                let queryError = queried == 0 ? GetLastError() : 0
                try checkStopped()
                guard queried != 0 else { throw failure("WinHttpQueryDataAvailable", queryError) }
                if available == 0 { return data }  // the end of the response
                dataArrived()
                var got: UInt32 = 0
                let want = UInt32(min(Int(available), chunk.count))
                let ok = chunk.withUnsafeMutableBytes { api.read(request, $0.baseAddress, want, &got) }
                let code = ok == 0 ? GetLastError() : 0
                try checkStopped()
                guard ok != 0 else { throw failure("WinHttpReadData", code) }
                if got == 0 { return data }
                guard data.count + Int(got) <= plan.maxBodyBytes else {
                    throw URLError(.dataLengthExceedsMaximum, userInfo: [NSLocalizedDescriptionKey: "the body passed \(plan.maxBodyBytes) bytes"])
                }
                data.append(contentsOf: chunk[0..<Int(got)])
                plan.progress?(data.count)
            }
        }

        /// Whether a 407 came from a proxy this request used: an environment proxy always; on the Windows settings, the proxy
        /// WinHTTP reports for the request (`WINHTTP_OPTION_PROXY`); never on a direct route.
        private func wentThroughProxy(_ request: Handle) -> Bool {
            switch plan.route {
            case .direct, .urlSession: return false
            case .namedProxy, .systemProxy:
                var info = ProxyInfo()
                var size = UInt32(MemoryLayout<ProxyInfo>.size)
                guard api.queryOption(request, WinHTTPFetch.optionProxy, &info, &size) != 0 else {
                    WinHTTPFetch.stats.noteProxyReport("\(plan.route == .systemProxy ? "system" : "environment"): query failed \(GetLastError())")
                    return plan.route != .systemProxy
                }
                defer {
                    if let p = info.proxy { _ = GlobalFree(UnsafeMutableRawPointer(p)) }
                    if let b = info.bypass { _ = GlobalFree(UnsafeMutableRawPointer(b)) }
                }
                let named = info.proxy.map { !String(decodingCString: $0, as: UTF16.self).isEmpty } ?? false
                WinHTTPFetch.stats.noteProxyReport("\(plan.route == .systemProxy ? "system" : "environment"): access \(info.accessType), proxy named: \(named)")
                if plan.route == .systemProxy, !named, WinHTTPFetch.stats.noteUnansweredProxyChallenge() {
                    // Once per process, for the office-proxy check on a PC: the access type only, no host.
                    AppLog.write("winhttp: a 407 on the Windows proxy settings, but WinHTTP names no proxy for the request "
                                 + "(access type \(info.accessType)): not answered")
                }
                // An environment proxy is the route itself; the report is kept for the tests (does WinHTTP name it?).
                return plan.route == .systemProxy ? named : true
            }
        }

        /// NTLM or Negotiate offered by a proxy (Negotiate first, as .NET's WinHttpHandler chooses); nothing else is answered.
        private func proxyLogonScheme(_ request: Handle) -> UInt32? {
            var supported: UInt32 = 0, first: UInt32 = 0, target: UInt32 = 0
            guard api.queryAuthSchemes(request, &supported, &first, &target) != 0, target == WinHTTPFetch.authTargetProxy else { return nil }
            if supported & WinHTTPFetch.schemeNegotiate != 0 { return WinHTTPFetch.schemeNegotiate }
            if supported & WinHTTPFetch.schemeNTLM != 0 { return WinHTTPFetch.schemeNTLM }
            return nil
        }

        private func headerFields(_ handle: Handle) -> [String: String] {
            var length: UInt32 = 0
            _ = api.queryHeaders(handle, WinHTTPFetch.queryRawHeadersCRLF, nil, nil, &length, nil)  // ERROR_INSUFFICIENT_BUFFER: length in bytes
            guard length > 0 else { return [:] }
            var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
            guard buffer.withUnsafeMutableBytes({ api.queryHeaders(handle, WinHTTPFetch.queryRawHeadersCRLF, nil, $0.baseAddress, &length, nil) }) != 0
            else { return [:] }
            var fields: [String: String] = [:]
            for line in String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self).components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[name] = fields[name].map { $0 + ", " + value } ?? value
            }
            return fields
        }

        /// The step and the WinHTTP code stay in the description; no header, body or query.
        private func failure(_ step: String, _ code: DWORD) -> URLError {
            if isStopped { return URLError(stopReason) }
            if code == 12017 { return URLError(.cancelled) }
            return URLError(WinHTTPFetch.urlErrorCode(code), userInfo: [NSLocalizedDescriptionKey: "\(step) failed: WinHTTP error \(code)"])
        }

        private func failure(_ step: String) -> URLError { failure(step, GetLastError()) }
    }

    /// `WINHTTP_PROXY_INFO` (winhttp.h): the strings are the caller's to `GlobalFree`.
    private struct ProxyInfo {
        var accessType: UInt32 = 0
        var proxy: UnsafeMutablePointer<UInt16>? = nil
        var bypass: UnsafeMutablePointer<UInt16>? = nil
    }

    // MARK: - WinHTTP (winhttp.dll is not in the WinSDK module map: `WinDynamic.symbol` loads it by name, once per process;
    // an already loaded copy, else the application directory, then System32: `LoadLibraryExW` with
    // `LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32`, WinMainLoop.swift line 10)

    private typealias Handle = UnsafeMutableRawPointer
    private typealias FnOpen = @convention(c) (UnsafePointer<UInt16>?, UInt32, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UInt32) -> Handle?
    private typealias FnConnect = @convention(c) (Handle?, UnsafePointer<UInt16>?, UInt16, UInt32) -> Handle?
    private typealias FnOpenRequest = @convention(c) (Handle?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?,
                                                      UnsafePointer<UInt16>?, UnsafeMutableRawPointer?, UInt32) -> Handle?
    private typealias FnSetTimeouts = @convention(c) (Handle?, Int32, Int32, Int32, Int32) -> Int32
    private typealias FnSetOption = @convention(c) (Handle?, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32
    private typealias FnQueryOption = @convention(c) (Handle?, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias FnSendRequest = @convention(c) (Handle?, UnsafePointer<UInt16>?, UInt32, UnsafeMutableRawPointer?, UInt32, UInt32, UInt) -> Int32
    private typealias FnReceiveResponse = @convention(c) (Handle?, UnsafeMutableRawPointer?) -> Int32
    private typealias FnQueryHeaders = @convention(c) (Handle?, UInt32, UnsafePointer<UInt16>?, UnsafeMutableRawPointer?,
                                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias FnReadData = @convention(c) (Handle?, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias FnQueryDataAvailable = @convention(c) (Handle?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias FnCloseHandle = @convention(c) (Handle?) -> Int32
    private typealias FnQueryAuthSchemes = @convention(c) (Handle?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                                           UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias FnSetCredentials = @convention(c) (Handle?, UInt32, UInt32, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?,
                                                         UnsafeMutableRawPointer?) -> Int32

    /// Function pointers only (each fetch opens and closes its own session).
    private struct API: @unchecked Sendable {
        let open: FnOpen, connect: FnConnect, openRequest: FnOpenRequest, setTimeouts: FnSetTimeouts, setOption: FnSetOption
        let queryOption: FnQueryOption, send: FnSendRequest, receive: FnReceiveResponse, queryHeaders: FnQueryHeaders
        let read: FnReadData, queryDataAvailable: FnQueryDataAvailable, close: FnCloseHandle, queryAuthSchemes: FnQueryAuthSchemes
        let setCredentials: FnSetCredentials
    }

    // winhttp.h (Windows SDK 10.0.26100)
    private static let accessDefaultProxy: UInt32 = 0        // WINHTTP_ACCESS_TYPE_DEFAULT_PROXY
    private static let accessNoProxy: UInt32 = 1             // WINHTTP_ACCESS_TYPE_NO_PROXY
    private static let accessNamedProxy: UInt32 = 3          // WINHTTP_ACCESS_TYPE_NAMED_PROXY
    private static let accessAutomaticProxy: UInt32 = 4      // WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY (Windows 8.1+)
    private static let flagSecure: UInt32 = 0x0080_0000      // WINHTTP_FLAG_SECURE
    private static let queryStatusCode: UInt32 = 19 | 0x2000_0000  // WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
    private static let queryRawHeadersCRLF: UInt32 = 22     // WINHTTP_QUERY_RAW_HEADERS_CRLF
    private static let optionReceiveResponseTimeout: UInt32 = 7  // WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT (default 90 s)
    private static let optionProxy: UInt32 = 38              // WINHTTP_OPTION_PROXY
    private static let optionDisableFeature: UInt32 = 63     // WINHTTP_OPTION_DISABLE_FEATURE
    private static let disableCookies: UInt32 = 0x1          // WINHTTP_DISABLE_COOKIES
    private static let disableAuthentication: UInt32 = 0x4   // WINHTTP_DISABLE_AUTHENTICATION
    private static let optionAutologonPolicy: UInt32 = 77    // WINHTTP_OPTION_AUTOLOGON_POLICY
    private static let autologonMedium: UInt32 = 0           // WINHTTP_AUTOLOGON_SECURITY_LEVEL_MEDIUM (the default)
    private static let autologonHigh: UInt32 = 2             // WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH
    private static let optionEnableFeature: UInt32 = 79      // WINHTTP_OPTION_ENABLE_FEATURE
    private static let enableSSLRevocation: UInt32 = 0x1     // WINHTTP_ENABLE_SSL_REVOCATION
    private static let optionSecureProtocols: UInt32 = 84    // WINHTTP_OPTION_SECURE_PROTOCOLS (session handles only)
    static let protocolTLS12: UInt32 = 0x800                 // WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2
    static let protocolsTLS12And13: UInt32 = 0x800 | 0x2000  // ... | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
    private static let optionRedirectPolicy: UInt32 = 88     // WINHTTP_OPTION_REDIRECT_POLICY
    private static let redirectPolicyNever: UInt32 = 0       // WINHTTP_OPTION_REDIRECT_POLICY_NEVER: the 30x comes back to us
    private static let optionDecompression: UInt32 = 118     // WINHTTP_OPTION_DECOMPRESSION (Windows 8.1+)
    /// GZIP only: WinHTTP decodes "deflate" only as a raw stream, not the zlib-wrapped form RFC 9110 defines and libcurl decoded
    /// (it failed with E_ABORT on the loopback test), so deflate is not asked for.
    private static let decompressGzip: UInt32 = 0x1          // WINHTTP_DECOMPRESSION_FLAG_GZIP
    private static let optionDisableGlobalPooling: UInt32 = 195  // WINHTTP_OPTION_DISABLE_GLOBAL_POOLING
    private static let authTargetProxy: UInt32 = 1           // WINHTTP_AUTH_TARGET_PROXY
    private static let schemeNTLM: UInt32 = 0x2              // WINHTTP_AUTH_SCHEME_NTLM
    private static let schemeNegotiate: UInt32 = 0x10        // WINHTTP_AUTH_SCHEME_NEGOTIATE
    private static let errorResendRequest: DWORD = 12032     // ERROR_WINHTTP_RESEND_REQUEST

    private static let api: API? = load()

    private static func load() -> API? {
        func fn<T>(_ name: String, _ type: T.Type) -> T? { WinDynamic.symbol("winhttp.dll", name, as: type) }
        guard let open = fn("WinHttpOpen", FnOpen.self), let connect = fn("WinHttpConnect", FnConnect.self),
              let openRequest = fn("WinHttpOpenRequest", FnOpenRequest.self), let setTimeouts = fn("WinHttpSetTimeouts", FnSetTimeouts.self),
              let setOption = fn("WinHttpSetOption", FnSetOption.self), let queryOption = fn("WinHttpQueryOption", FnQueryOption.self),
              let send = fn("WinHttpSendRequest", FnSendRequest.self), let receive = fn("WinHttpReceiveResponse", FnReceiveResponse.self),
              let queryHeaders = fn("WinHttpQueryHeaders", FnQueryHeaders.self), let read = fn("WinHttpReadData", FnReadData.self),
              let queryDataAvailable = fn("WinHttpQueryDataAvailable", FnQueryDataAvailable.self),
              let close = fn("WinHttpCloseHandle", FnCloseHandle.self),
              let queryAuthSchemes = fn("WinHttpQueryAuthSchemes", FnQueryAuthSchemes.self),
              let setCredentials = fn("WinHttpSetCredentials", FnSetCredentials.self)
        else {
            AppLog.write("winhttp: unavailable (a WinHTTP function did not load); one-shot fetches stay on URLSession")
            return nil
        }
        return API(open: open, connect: connect, openRequest: openRequest, setTimeouts: setTimeouts, setOption: setOption,
                   queryOption: queryOption, send: send, receive: receive, queryHeaders: queryHeaders, read: read,
                   queryDataAvailable: queryDataAvailable, close: close, queryAuthSchemes: queryAuthSchemes, setCredentials: setCredentials)
    }
}
#endif
