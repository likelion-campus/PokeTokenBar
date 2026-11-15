#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// A plain HTTP GET through WinHTTP, for the app's small one-shot fetches on Windows (`PlatformCompat.oneShotData`).
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
/// Same request as before: method GET, the request's headers, its `timeoutInterval` (for resolve, connect, send and each
/// receive, like curl's idle timer that every received chunk resets), TLS verified by Schannel against the Windows store with
/// revocation checked (curl's Schannel default, `schannel.c` 8.9.1 lines 493-495), gzip/deflate decoded, redirects followed
/// (WinHTTP's default policy: at most 10, never from HTTPS to HTTP), no size limit (URLSession had none), direct connection
/// (libcurl in corelibs does not read the Windows proxy settings either; see `handles` for the proxy variables).
enum WinHTTPFetch {
    /// libcurl's proxy variables. When one is set the request stays on URLSession, whose libcurl honours it (corelibs sets
    /// no proxy option of its own: `EasyHandle.swift` lines 305-307), so a proxy configured that way keeps working as before.
    /// Windows environment names are case-insensitive, so these also cover `HTTPS_PROXY` and `ALL_PROXY`.
    static let curlProxyVariables = ["http_proxy", "https_proxy", "all_proxy"]

    /// Whether this request goes through WinHTTP: a plain GET on http(s), WinHTTP loaded, no curl proxy variable set.
    static func handles(_ request: URLRequest) -> Bool {
        guard api != nil, (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let scheme = request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return false }
        return !curlProxyConfigured()
    }

    /// The way libcurl reads its proxy variables on Windows (the process environment; an empty value counts as unset).
    static func curlProxyConfigured() -> Bool {
        curlProxyVariables.contains { name in
            var buffer = [UInt16](repeating: 0, count: 2)
            return GetEnvironmentVariableW(WinStr.w(name), &buffer, DWORD(buffer.count)) > 0
        }
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let api else { throw URLError(.cannotLoadFromNetwork) }
        return try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try perform(request, api) }) }.start()
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

    /// Function pointers only. Each fetch opens its own WinHTTP session and closes it with the request, so nothing of WinHTTP
    /// stays open between fetches: a process-wide session kept the launch fetch's connection pooled and a thread-pool worker
    /// waking every 2-3 s (43-59 times in the gate's 120 s window without a refresh). A pooled connection would not be
    /// reused anyway: the next fetch comes 120 s later (libcurl reconnected every time too). No cookies carry over either.
    private struct API: @unchecked Sendable {
        let open: FnOpen, connect: FnConnect, openRequest: FnOpenRequest, setTimeouts: FnSetTimeouts, setOption: FnSetOption
        let queryOption: FnQueryOption, send: FnSendRequest, receive: FnReceiveResponse, queryHeaders: FnQueryHeaders
        let read: FnReadData, close: FnCloseHandle
    }

    private static let accessNoProxy: UInt32 = 1            // WINHTTP_ACCESS_TYPE_NO_PROXY
    private static let flagSecure: UInt32 = 0x0080_0000     // WINHTTP_FLAG_SECURE
    private static let queryStatusCode: UInt32 = 19 | 0x2000_0000  // WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
    private static let queryRawHeadersCRLF: UInt32 = 22    // WINHTTP_QUERY_RAW_HEADERS_CRLF
    private static let optionURL: UInt32 = 34               // WINHTTP_OPTION_URL
    private static let optionEnableFeature: UInt32 = 79     // WINHTTP_OPTION_ENABLE_FEATURE
    private static let enableSSLRevocation: UInt32 = 0x1    // WINHTTP_ENABLE_SSL_REVOCATION
    private static let optionDecompression: UInt32 = 118    // WINHTTP_OPTION_DECOMPRESSION (Windows 8.1+)
    private static let decompressGzipDeflate: UInt32 = 0x3  // WINHTTP_DECOMPRESSION_FLAG_GZIP | _DEFLATE

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

    /// Blocking: runs on a thread of its own.
    private static func perform(_ request: URLRequest, _ api: API) throws -> (Data, URLResponse) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty
        else { throw URLError(.unsupportedURL) }
        let secure = scheme == "https"
        let port = UInt16(truncatingIfNeeded: parts.port ?? (secure ? 443 : 80))
        var object = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { object += "?" + query }

        // No agent string: the request's own User-Agent header (or ours) is the only one sent.
        guard let session = api.open(nil, accessNoProxy, nil, nil, 0) else { throw failure("WinHttpOpen") }
        defer { _ = api.close(session) }  // last: closing the session also drops its connection
        guard let connection = api.connect(session, WinStr.w(host), port, 0) else { throw failure("WinHttpConnect") }
        defer { _ = api.close(connection) }
        guard let handle = api.openRequest(connection, WinStr.w("GET"), WinStr.w(object), nil, nil, nil, secure ? flagSecure : 0)
        else { throw failure("WinHttpOpenRequest") }
        defer { _ = api.close(handle) }

        let ms = Int32(clamping: Int((max(request.timeoutInterval, 0.001) * 1000).rounded()))
        guard api.setTimeouts(handle, ms, ms, ms, ms) != 0 else { throw failure("WinHttpSetTimeouts") }
        if secure {
            var revocation = enableSSLRevocation
            guard api.setOption(handle, optionEnableFeature, &revocation, 4) != 0 else { throw failure("WINHTTP_ENABLE_SSL_REVOCATION") }
        }
        var decompression = decompressGzipDeflate
        _ = api.setOption(handle, optionDecompression, &decompression, 4)  // without it the body arrives undecoded, as sent

        var fields = request.allHTTPHeaderFields ?? [:]
        if !fields.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) { fields["User-Agent"] = "PokeTokenBar" }
        let headers = WinStr.w(fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\r\n"))
        guard api.send(handle, headers, UInt32.max /* -1: zero-terminated */, nil, 0, 0, 0) != 0 else { throw failure("WinHttpSendRequest") }
        guard api.receive(handle, nil) != 0 else { throw failure("WinHttpReceiveResponse") }

        var status: UInt32 = 0
        var statusSize: UInt32 = 4
        guard api.queryHeaders(handle, queryStatusCode, nil, &status, &statusSize, nil) != 0 else { throw failure("WinHttpQueryHeaders") }

        var body = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            var got: UInt32 = 0
            let ok = chunk.withUnsafeMutableBytes { api.read(handle, $0.baseAddress, UInt32($0.count), &got) }
            guard ok != 0 else { throw failure("WinHttpReadData") }
            if got == 0 { break }
            body.append(contentsOf: chunk[0..<Int(got)])
        }

        let finalURL = wideOption(api, handle, optionURL).flatMap { URL(string: $0) } ?? url
        guard let response = HTTPURLResponse(url: finalURL, statusCode: Int(status), httpVersion: "HTTP/1.1",
                                             headerFields: headerFields(api, handle))
        else { throw URLError(.badServerResponse) }
        return (body, response)
    }

    private static func headerFields(_ api: API, _ handle: Handle) -> [String: String] {
        var length: UInt32 = 0
        _ = api.queryHeaders(handle, queryRawHeadersCRLF, nil, nil, &length, nil)  // ERROR_INSUFFICIENT_BUFFER: length in bytes
        guard length > 0 else { return [:] }
        var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
        guard buffer.withUnsafeMutableBytes({ api.queryHeaders(handle, queryRawHeadersCRLF, nil, $0.baseAddress, &length, nil) }) != 0
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

    private static func wideOption(_ api: API, _ handle: Handle, _ option: UInt32) -> String? {
        var length: UInt32 = 0
        _ = api.queryOption(handle, option, nil, &length)
        guard length > 0 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
        guard buffer.withUnsafeMutableBytes({ api.queryOption(handle, option, $0.baseAddress, &length) }) != 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    /// The URLError a caller of URLSession would have seen for the same failure, with the WinHTTP step and code kept.
    private static func failure(_ step: String) -> URLError {
        let code = GetLastError()
        let mapped: URLError.Code
        switch code {
        case 12002: mapped = .timedOut                    // ERROR_WINHTTP_TIMEOUT
        case 12007: mapped = .cannotFindHost              // ERROR_WINHTTP_NAME_NOT_RESOLVED
        case 12029: mapped = .cannotConnectToHost         // ERROR_WINHTTP_CANNOT_CONNECT
        case 12030: mapped = .networkConnectionLost       // ERROR_WINHTTP_CONNECTION_ERROR
        case 12156: mapped = .httpTooManyRedirects        // ERROR_WINHTTP_REDIRECT_FAILED
        case 12037, 12038, 12044, 12045, 12057, 12169, 12175, 12179: mapped = .secureConnectionFailed  // certificate / TLS
        default: mapped = .unknown
        }
        return URLError(mapped, userInfo: [NSLocalizedDescriptionKey: "\(step) failed: WinHTTP error \(code)"])
    }
}
#endif
