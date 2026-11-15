#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// One HTTP request through WinHTTP, for the app's one-shot fetches on Windows (`PlatformCompat.oneShotData`).
///
/// Why not URLSession: swift-corelibs-foundation drives libcurl through libdispatch read/write sources on the socket
/// (FoundationNetworking `MultiHandle.swift`, swift-6.3.2-RELEASE, lines 527-548). It creates a write source when curl first
/// asks for write readiness and cancels it only when curl removes the socket (`register`, lines 119-138: `.registerRead`
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
///   default 60 s, for resolve, connect, send and each receive (an idle timer, like corelibs'). `timeoutIntervalForResource`
///   is not enforced (corelibs does not either; the one caller that sets it keeps its own deadline).
/// - TLS by Schannel against the Windows store with revocation checked (curl's Schannel default, `schannel.c` 8.9.1 493-495).
/// - gzip and deflate decoded (curl decoded those and brotli; WinHTTP asks only for what it can decode).
/// - redirects followed up to 20 as corelibs did (`HTTPURLProtocol.swift` 459-466), also to another host; never from HTTPS to
///   HTTP (WinHTTP's default policy; corelibs followed those, and a bearer token would then travel in clear text).
/// - no cookies kept or sent by WinHTTP (`WINHTTP_DISABLE_COOKIES`); a `Cookie` header the caller sets is sent as given.
/// - no size limit (none of the callers had one). Task cancellation closes the request handle: `URLError(.cancelled)`.
/// - the route from `WinProxyRoute`: the Windows proxy settings, or libcurl's proxy variables when set.
/// - credentials: WinHTTP's default automatic logon policy (MEDIUM): Windows logon credentials are offered only to intranet
///   hosts and proxies, only for NTLM and Negotiate challenges, never with other schemes. This code never calls
///   `WinHttpSetCredentials`; a 401 or 407 comes back to the caller as a status, as it did from URLSession.
/// Nothing here logs a header, a body or a URL query. Each fetch opens its own session and closes it with the request, so
/// nothing of WinHTTP stays open between fetches (a process-wide session kept a pooled connection and a thread-pool worker
/// waking every 2-3 s); cross-session pooling is switched off where Windows offers the option.
enum WinHTTPFetch {
    /// Whether this request goes through WinHTTP: http(s), WinHTTP loaded, no body stream, a route WinHTTP can take.
    static func handles(_ request: URLRequest) -> Bool {
        guard api != nil, request.httpBodyStream == nil, let url = request.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return false }
        if case .urlSession = WinProxyRoute.route(for: url) { return false }
        return true
    }

    /// `configuration`: the session the caller would have used (its timeout and extra headers apply, as URLSession applied
    /// them). `route`: diagnostics only (the net-burst helper compares a direct fetch with the system proxy).
    static func data(for request: URLRequest, configuration: URLSessionConfiguration? = nil,
                     route: WinProxyRoute.Route? = nil) async throws -> (Data, URLResponse) {
        guard let api, let url = request.url else { throw URLError(.cannotLoadFromNetwork) }
        let plan = try Plan(request, configuration, route: route ?? WinProxyRoute.route(for: url))
        let fetch = Fetch(api: api, plan: plan)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread { continuation.resume(with: Result { try fetch.run() }) }.start()
            }
        } onCancel: {
            fetch.cancel()
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

    // MARK: - the request as WinHTTP takes it

    private struct Plan: Sendable {
        let url: URL, host: String, port: UInt16, secure: Bool, object: String
        let method: String, headers: String, body: Data?
        let timeoutMs: Int32
        let route: WinProxyRoute.Route

        init(_ request: URLRequest, _ configuration: URLSessionConfiguration?, route: WinProxyRoute.Route) throws {
            guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = parts.host, !host.isEmpty
            else { throw URLError(.unsupportedURL) }
            let isSecure = scheme == "https"
            let verb = request.httpMethod ?? "GET"
            let payload = request.httpBody
            self.url = url
            self.host = host
            secure = isSecure
            port = UInt16(truncatingIfNeeded: parts.port ?? (isSecure ? 443 : 80))
            var object = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
            if let query = parts.percentEncodedQuery { object += "?" + query }
            self.object = object
            method = verb
            body = payload

            var fields: [(name: String, value: String)] = []
            func set(_ name: String, _ value: String) {
                fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                fields.append((name, value))
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
            headers = fields.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")

            var seconds = request.timeoutInterval
            if seconds == 60, let configuration { seconds = configuration.timeoutIntervalForRequest }
            timeoutMs = Int32(clamping: Int((max(seconds, 0.001) * 1000).rounded()))
            self.route = route
        }
    }

    /// One fetch on its own thread. `cancel()` (Task cancellation, any thread) closes the request handle, which makes the
    /// blocked WinHTTP call return ERROR_WINHTTP_OPERATION_CANCELLED; the handle is closed exactly once.
    private final class Fetch: @unchecked Sendable {
        private let api: API
        private let plan: Plan
        private let lock = NSLock()
        private var request: Handle?
        private var cancelled = false

        init(api: API, plan: Plan) { self.api = api; self.plan = plan }

        func cancel() {
            lock.lock()
            cancelled = true
            let handle = request
            request = nil
            lock.unlock()
            if let handle { _ = api.close(handle) }
        }

        private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        private func adopt(_ handle: Handle) -> Bool {
            lock.lock()
            if cancelled { lock.unlock(); _ = api.close(handle); return false }
            request = handle
            lock.unlock()
            return true
        }

        private func release() {
            lock.lock()
            let handle = request
            request = nil
            lock.unlock()
            if let handle { _ = api.close(handle) }
        }

        func run() throws -> (Data, URLResponse) {
            if isCancelled { throw URLError(.cancelled) }
            guard let session = openSession() else { throw failure("WinHttpOpen") }
            defer { _ = api.close(session) }  // last: closing the session also drops its connection
            var disablePooling: UInt32 = 1
            _ = api.setOption(session, WinHTTPFetch.optionDisableGlobalPooling, &disablePooling, 4)  // Windows versions without it refuse; fine
            guard let connection = api.connect(session, WinStr.w(plan.host), plan.port, 0) else { throw failure("WinHttpConnect") }
            defer { _ = api.close(connection) }
            guard let handle = api.openRequest(connection, WinStr.w(plan.method), WinStr.w(plan.object), nil, nil, nil,
                                               plan.secure ? WinHTTPFetch.flagSecure : 0)
            else { throw failure("WinHttpOpenRequest") }
            guard adopt(handle) else { throw URLError(.cancelled) }
            defer { release() }

            let ms = plan.timeoutMs
            guard api.setTimeouts(handle, ms, ms, ms, ms) != 0 else { throw failure("WinHttpSetTimeouts") }
            if plan.secure {
                var revocation = WinHTTPFetch.enableSSLRevocation
                guard api.setOption(handle, WinHTTPFetch.optionEnableFeature, &revocation, 4) != 0 else { throw failure("WINHTTP_ENABLE_SSL_REVOCATION") }
            }
            var noCookies = WinHTTPFetch.disableCookies
            guard api.setOption(handle, WinHTTPFetch.optionDisableFeature, &noCookies, 4) != 0 else { throw failure("WINHTTP_DISABLE_COOKIES") }
            var redirects: UInt32 = 20
            _ = api.setOption(handle, WinHTTPFetch.optionMaxRedirects, &redirects, 4)
            var decompression = WinHTTPFetch.decompressGzipDeflate
            _ = api.setOption(handle, WinHTTPFetch.optionDecompression, &decompression, 4)  // without it the body arrives undecoded, as sent

            let headers = WinStr.w(plan.headers)
            let sent: Int32
            if let body = plan.body, !body.isEmpty {
                sent = body.withUnsafeBytes { raw in
                    api.send(handle, headers, UInt32.max, UnsafeMutableRawPointer(mutating: raw.baseAddress),
                             UInt32(raw.count), UInt32(raw.count), 0)
                }
            } else {
                sent = api.send(handle, headers, UInt32.max /* -1: zero-terminated */, nil, 0, 0, 0)
            }
            guard sent != 0 else { throw failure("WinHttpSendRequest") }
            guard api.receive(handle, nil) != 0 else { throw failure("WinHttpReceiveResponse") }

            var status: UInt32 = 0
            var statusSize: UInt32 = 4
            guard api.queryHeaders(handle, WinHTTPFetch.queryStatusCode, nil, &status, &statusSize, nil) != 0 else { throw failure("WinHttpQueryHeaders") }

            var body = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var got: UInt32 = 0
                let ok = chunk.withUnsafeMutableBytes { api.read(handle, $0.baseAddress, UInt32($0.count), &got) }
                guard ok != 0 else { throw failure("WinHttpReadData") }
                if got == 0 { break }
                body.append(contentsOf: chunk[0..<Int(got)])
            }

            let fields = headerFields(handle)
            func field(_ name: String) -> String? { fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
            // A body that ended early: libcurl failed the transfer (CURLE_PARTIAL_FILE); WinHTTP may just stop reading.
            if plan.method != "HEAD", status != 204, status != 304, field("Content-Encoding") == nil,
               let declared = field("Content-Length").flatMap({ Int($0) }),
               body.count < declared {
                throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "the body ended after \(body.count) of \(declared) bytes"])
            }
            let finalURL = wideOption(handle, WinHTTPFetch.optionURL).flatMap { URL(string: $0) } ?? plan.url
            guard let response = HTTPURLResponse(url: finalURL, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: fields)
            else { throw URLError(.badServerResponse) }
            return (body, response)
        }

        private func openSession() -> Handle? {
            // No agent string: the request's own User-Agent header is the only one sent.
            switch plan.route {
            case .direct:
                return api.open(nil, WinHTTPFetch.accessNoProxy, nil, nil, 0)
            case .systemProxy:
                return api.open(nil, WinHTTPFetch.accessAutomaticProxy, nil, nil, 0) ?? api.open(nil, WinHTTPFetch.accessDefaultProxy, nil, nil, 0)
            case .namedProxy(let hostPort):
                return api.open(nil, WinHTTPFetch.accessNamedProxy, WinStr.w(hostPort), nil, 0)
            case .urlSession:
                return nil
            }
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

        private func wideOption(_ handle: Handle, _ option: UInt32) -> String? {
            var length: UInt32 = 0
            _ = api.queryOption(handle, option, nil, &length)
            guard length > 0 else { return nil }
            var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
            guard buffer.withUnsafeMutableBytes({ api.queryOption(handle, option, $0.baseAddress, &length) }) != 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
        }

        /// The step and the WinHTTP code stay in the description; no header, body or query.
        private func failure(_ step: String) -> URLError {
            let code = GetLastError()
            if isCancelled || code == 12017 { return URLError(.cancelled) }
            return URLError(WinHTTPFetch.urlErrorCode(code), userInfo: [NSLocalizedDescriptionKey: "\(step) failed: WinHTTP error \(code)"])
        }
    }

    // MARK: - WinHTTP (winhttp.dll is not in the WinSDK module map; loaded once from System32)

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
    private typealias FnCloseHandle = @convention(c) (Handle?) -> Int32

    /// Function pointers only (each fetch opens and closes its own session).
    private struct API: @unchecked Sendable {
        let open: FnOpen, connect: FnConnect, openRequest: FnOpenRequest, setTimeouts: FnSetTimeouts, setOption: FnSetOption
        let queryOption: FnQueryOption, send: FnSendRequest, receive: FnReceiveResponse, queryHeaders: FnQueryHeaders
        let read: FnReadData, close: FnCloseHandle
    }

    // winhttp.h (Windows SDK 10.0.26100)
    private static let accessDefaultProxy: UInt32 = 0        // WINHTTP_ACCESS_TYPE_DEFAULT_PROXY
    private static let accessNoProxy: UInt32 = 1             // WINHTTP_ACCESS_TYPE_NO_PROXY
    private static let accessNamedProxy: UInt32 = 3          // WINHTTP_ACCESS_TYPE_NAMED_PROXY
    private static let accessAutomaticProxy: UInt32 = 4      // WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY (Windows 8.1+)
    private static let flagSecure: UInt32 = 0x0080_0000      // WINHTTP_FLAG_SECURE
    private static let queryStatusCode: UInt32 = 19 | 0x2000_0000  // WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
    private static let queryRawHeadersCRLF: UInt32 = 22     // WINHTTP_QUERY_RAW_HEADERS_CRLF
    private static let optionURL: UInt32 = 34                // WINHTTP_OPTION_URL
    private static let optionDisableFeature: UInt32 = 63     // WINHTTP_OPTION_DISABLE_FEATURE
    private static let disableCookies: UInt32 = 0x1          // WINHTTP_DISABLE_COOKIES
    private static let optionEnableFeature: UInt32 = 79      // WINHTTP_OPTION_ENABLE_FEATURE
    private static let enableSSLRevocation: UInt32 = 0x1     // WINHTTP_ENABLE_SSL_REVOCATION
    private static let optionMaxRedirects: UInt32 = 89       // WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS (default 10)
    private static let optionDecompression: UInt32 = 118     // WINHTTP_OPTION_DECOMPRESSION (Windows 8.1+)
    private static let decompressGzipDeflate: UInt32 = 0x3   // WINHTTP_DECOMPRESSION_FLAG_ALL = GZIP | DEFLATE
    private static let optionDisableGlobalPooling: UInt32 = 195  // WINHTTP_OPTION_DISABLE_GLOBAL_POOLING

    private static let api: API? = load()

    private static func load() -> API? {
        func fn<T>(_ name: String, _ type: T.Type) -> T? { WinDynamic.symbol("winhttp.dll", name, as: type) }
        guard let open = fn("WinHttpOpen", FnOpen.self), let connect = fn("WinHttpConnect", FnConnect.self),
              let openRequest = fn("WinHttpOpenRequest", FnOpenRequest.self), let setTimeouts = fn("WinHttpSetTimeouts", FnSetTimeouts.self),
              let setOption = fn("WinHttpSetOption", FnSetOption.self), let queryOption = fn("WinHttpQueryOption", FnQueryOption.self),
              let send = fn("WinHttpSendRequest", FnSendRequest.self), let receive = fn("WinHttpReceiveResponse", FnReceiveResponse.self),
              let queryHeaders = fn("WinHttpQueryHeaders", FnQueryHeaders.self), let read = fn("WinHttpReadData", FnReadData.self),
              let close = fn("WinHttpCloseHandle", FnCloseHandle.self)
        else {
            AppLog.write("winhttp: unavailable (a WinHTTP function did not load); one-shot fetches stay on URLSession")
            return nil
        }
        return API(open: open, connect: connect, openRequest: openRequest, setTimeouts: setTimeouts, setOption: setOption,
                   queryOption: queryOption, send: send, receive: receive, queryHeaders: queryHeaders, read: read, close: close)
    }
}
#endif
