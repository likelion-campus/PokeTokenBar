#if os(Windows)
import XCTest
import FoundationNetworking
@testable import PokeTokenBar

/// `WinHTTPFetch` and the Windows branch of `PlatformCompat.oneShotData` against the in-process loopback server (no network).
/// Where URLSession's answer is the reference, the same request goes through a fresh ephemeral URLSession as the control.
final class WindowsHTTPFetchTests: XCTestCase {
    private static let server = LoopbackServer.start()
    private static let other = LoopbackServer.start()

    private func base(_ which: LoopbackServer? = WindowsHTTPFetchTests.server) throws -> String {
        let server = try XCTUnwrap(which, "loopback server did not start")
        return "http://127.0.0.1:\(server.port)"
    }

    private func request(_ url: String, timeout: TimeInterval = 10) throws -> URLRequest {
        URLRequest(url: try XCTUnwrap(URL(string: url)), timeoutInterval: timeout)
    }

    private struct Answer: Equatable { let status: Int; let body: Data }

    private func seam(_ r: URLRequest, session: URLSession = .shared) async throws -> Answer {
        let (data, response) = try await PlatformCompat.oneShotData(for: r, session: session)
        return Answer(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    /// URLSession as it ran before the route (a fresh session: a new connection, no shared state).
    private func control(_ r: URLRequest) async throws -> Answer {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: r)
        return Answer(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    private func text(_ a: Answer) -> String { String(decoding: a.body, as: UTF8.self) }

    // MARK: requests and responses

    func testGetReturnsStatusBodyAndHeaders() async throws {
        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/delay/0"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok 0\n")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testHeadersAndDefaultHeadersAsURLSessionSentThem() async throws {
        var given = try request(try base() + "/echo")
        given.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")
        given.setValue("1", forHTTPHeaderField: "X-Probe")
        let routed = text(try await seam(given))
        XCTAssertTrue(routed.hasPrefix("GET\nGET /echo HTTP/1.1"), routed)
        XCTAssertEqual(routed.components(separatedBy: "User-Agent:").count - 1, 1, "exactly one User-Agent: \(routed)")
        XCTAssertTrue(routed.contains("User-Agent: PokeTokenBar"), routed)
        XCTAssertTrue(routed.contains("X-Probe: 1"), routed)

        // No User-Agent given: both send one (corelibs: "<process> (unknown version) curl/x.y.z"), and Accept-Language.
        let plain = try request(try base() + "/echo")
        let mine = text(try await seam(plain)), theirs = text(try await control(plain))
        print("default headers, seam:\n\(mine)\ncontrol (URLSession):\n\(theirs)")
        XCTAssertTrue(mine.contains("User-Agent: "), mine)
        XCTAssertTrue(mine.contains("Accept-Encoding: gzip"), mine)
        XCTAssertFalse(mine.lowercased().contains("deflate"), "deflate is not asked for: \(mine)")
        XCTAssertEqual(mine.contains("Accept-Language: "), theirs.contains("Accept-Language: "), "Accept-Language as URLSession sent it")
    }

    func testTheSessionsHeadersAndTimeoutApply() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-Session": "s", "X-Both": "session"]
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var given = try request(try base() + "/echo", timeout: 60)  // the default: the session's 1 s applies
        given.setValue("request", forHTTPHeaderField: "X-Both")
        let echoed = text(try await seam(given, session: session))
        XCTAssertTrue(echoed.contains("X-Session: s"), echoed)
        XCTAssertTrue(echoed.contains("X-Both: request"), echoed)
        XCTAssertFalse(echoed.contains("X-Both: session"), echoed)

        let t0 = Date()
        do {
            _ = try await seam(try request(try base() + "/silent", timeout: 60), session: session)
            XCTFail("no answer within the session's 1 s must time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "the idle timer ends a silent server on time")
    }

    func testABodyIsSentAsGivenAndAPostWithoutContentTypeGetsURLSessionsDefault() async throws {
        var post = try request(try base() + "/echo")
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"grant_type":"refresh_token"}"#.utf8)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let echoed = text(try await seam(post))
        XCTAssertTrue(echoed.hasPrefix("POST\n"), echoed)
        XCTAssertTrue(echoed.hasSuffix("\n\n" + #"{"grant_type":"refresh_token"}"#), echoed)
        XCTAssertTrue(echoed.contains("Content-Type: application/json"), echoed)

        var bare = try request(try base() + "/echo")
        bare.httpMethod = "POST"
        bare.httpBody = Data("a=1".utf8)
        let mine = text(try await seam(bare)), theirs = text(try await control(bare))
        XCTAssertTrue(mine.contains("Content-Type: application/x-www-form-urlencoded"), mine)
        // corelibs writes it without the space ("Content-Type:application/..."): compare the field, not the spacing.
        XCTAssertTrue(theirs.lowercased().replacingOccurrences(of: " ", with: "").contains("content-type:application/x-www-form-urlencoded"), theirs)
    }

    func testRedirectsAreFollowedLikeURLSessionIncludingToAnotherHost() async throws {
        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/redirect"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok 0\n")
        XCTAssertEqual(response.url?.path, "/delay/0")

        let otherPort = try XCTUnwrap(Self.other).port
        var cross = try request(try base() + "/redirect-to/\(otherPort)")
        cross.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let mine = try await seam(cross), theirs = try await control(cross)
        XCTAssertEqual(mine.status, 200)
        XCTAssertEqual(theirs.status, 200)
        XCTAssertTrue(text(mine).contains("Host: localhost:\(otherPort)"), text(mine))
        print("cross-host redirect forwards Authorization: seam \(text(mine).contains("Authorization:")), URLSession \(text(theirs).contains("Authorization:"))")

        var post = try request(try base() + "/see-other")
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        let after = try await seam(post)
        XCTAssertTrue(text(after).hasPrefix("GET\n"), "a 303 continues as GET, as in URLSession: \(text(after))")
        let controlAfter = try await control(post)
        XCTAssertTrue(text(controlAfter).hasPrefix("GET\n"))
    }

    /// Every encoded form on its own: what WinHTTP decodes and what URLSession (libcurl) decoded, printed as a table.
    func testBodiesDecodeAsURLSessionDecodedThem() async throws {
        let forms: [(String, String, Bool)] = [  // path, text, must decode (what real servers send)
            ("/chunked", LoopbackServer.chunkedText, true), ("/gzip-unix", LoopbackServer.gzipText, true),
            ("/gzip-chunked", LoopbackServer.gzipText, true), ("/gzip", LoopbackServer.gzipText, true),
            // deflate is no longer asked for (Accept-Encoding: gzip); a server that sends it anyway: printed, not required.
            ("/deflate", LoopbackServer.deflateText, false), ("/deflate-raw", LoopbackServer.deflateText, false),
        ]
        for (path, expected, required) in forms {
            let r = try request(try base() + path)
            var mine = "", theirs = ""
            do { mine = text(try await seam(r)) } catch { mine = "error \((error as NSError).code) \(error.localizedDescription)" }
            do { theirs = text(try await control(r)) } catch { theirs = "error \((error as NSError).code)" }
            // Only printable text goes to the log: an undecoded body would put NUL bytes in test.log (grep then calls it binary
            // and the workflow's test count reads 0).
            let shown = mine == expected ? "decoded" : mine.hasPrefix("error ") ? mine : "\(mine.utf8.count) B not decoded: "
                + mine.utf8.prefix(8).map { String(format: "%02x", $0) }.joined()
            print("DECODE \(path): seam ok=\(mine == expected) urlsession ok=\(theirs == expected) | seam: \(shown)")
            if required { XCTAssertEqual(mine, expected, path) }
        }
    }

    func testTenMegabytesArriveWhole() async throws {
        let size = 10 * 1024 * 1024
        let answer = try await seam(try request(try base() + "/big/\(size)", timeout: 30))
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.body.count, size)
        XCTAssertTrue(answer.body.allSatisfy { $0 == 0x61 })
    }

    func testStatusesAreResponsesAsInURLSession() async throws {
        for code in [204, 304, 404, 503] {
            let r = try request(try base() + "/status/\(code)")
            let mine = try await seam(r), theirs = try await control(r)
            XCTAssertEqual(mine.status, code)
            XCTAssertEqual(mine, theirs, "status \(code)")
        }
    }

    // MARK: errors: the URLError codes a caller sees (shared code checks only the domain; see the report's table)

    private func failure(_ r: URLRequest, through path: (URLRequest) async throws -> Answer) async -> URLError? {
        do { _ = try await path(r); return nil } catch let e as URLError { return e } catch { return URLError(.unknown) }
    }

    func testErrorsMapToTheURLErrorCodes() async throws {
        let closed = try XCTUnwrap(LoopbackServer.closedPort())
        let port = try XCTUnwrap(Self.server).port
        let cases: [(String, URLRequest, [URLError.Code], Bool)] = [
            ("timeout, no answer", try request(try base() + "/silent", timeout: 1), [.timedOut], false),
            ("timeout, body stalls", try request(try base() + "/hang", timeout: 1), [.timedOut], false),
            ("closed mid-body", try request(try base() + "/cut"), [.networkConnectionLost], true),
            ("refused", try request("http://127.0.0.1:\(closed)/x"), [.cannotConnectToHost], true),
            ("no such host", try request("http://ptb-nowhere.invalid/x"), [.cannotFindHost], true),
            ("TLS handshake answered in plain text", try request("https://127.0.0.1:\(port)/delay/0", timeout: 5),
             [.secureConnectionFailed, .networkConnectionLost, .badServerResponse], true),
        ]
        for (name, r, expected, runControl) in cases {
            let mine = await failure(r) { try await self.seam($0) }
            var theirs: URLError?
            if runControl { theirs = await failure(r) { try await self.control($0) } }
            print("ERRORMAP \(name): seam=\(mine.map { "\($0.code.rawValue)" } ?? "none") urlsession=\(theirs.map { "\($0.code.rawValue)" } ?? (runControl ? "none" : "not run (corelibs does not end it: 20 s)"))")
            XCTAssertTrue(mine.map { expected.contains($0.code) } ?? false, "\(name): \(String(describing: mine))")
            XCTAssertEqual(mine.map { ($0 as NSError).domain }, NSURLErrorDomain, name)
        }
    }

    func testCancellingTheTaskEndsTheFetchWithCancelled() async throws {
        let r = try request(try base() + "/delay/5000")
        let t0 = Date()
        let task = Task { try await PlatformCompat.oneShotData(for: r) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch must not finish")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    // MARK: proxies

    private func withEnvironment(_ values: [String: String?], _ body: () async throws -> Void) async rethrows {
        let names = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        for n in names { PlatformCompat.setEnvironment(n, nil) }
        for (n, v) in values { PlatformCompat.setEnvironment(n, v) }
        defer { for n in names { PlatformCompat.setEnvironment(n, nil) } }
        try await body()
    }

    func testAProxyVariableSendsTheRequestThroughThatProxyAsLibcurlDid() async throws {
        let proxy = try base()
        let port = try XCTUnwrap(Self.server).port
        let target = try request("http://ptb-target.invalid/echo")
        let targetURL = try XCTUnwrap(target.url)
        try await withEnvironment(["HTTP_PROXY": proxy]) {
            XCTAssertEqual(WinProxyRoute.route(for: targetURL), .namedProxy("127.0.0.1:\(port)"))
            let mine = text(try await seam(target)), theirs = text(try await control(target))
            XCTAssertTrue(mine.hasPrefix("proxied http://ptb-target.invalid/echo"), mine)
            XCTAssertTrue(theirs.hasPrefix("proxied http://ptb-target.invalid/echo"), theirs)
        }
        try await withEnvironment(["ALL_PROXY": proxy]) {
            let viaAll = try await seam(target)
            XCTAssertTrue(text(viaAll).hasPrefix("proxied "), "all_proxy when the scheme has none")
        }
        for bypass in ["ptb-target.invalid", ".invalid", "a.example, invalid"] {
            try await withEnvironment(["HTTP_PROXY": proxy, "NO_PROXY": bypass]) {
                XCTAssertEqual(WinProxyRoute.route(for: targetURL), .direct, bypass)
                let mine = await failure(target) { try await self.seam($0) }
                XCTAssertEqual(mine?.code, .cannotFindHost, "NO_PROXY=\(bypass) goes direct")
            }
        }
    }

    func testAProxyFormWinHTTPCannotTakeStaysOnURLSession() async throws {
        let target = try request("https://ptb-target.invalid/x")
        for value in ["socks5://127.0.0.1:1080", "https://127.0.0.1:8443", "http://user:pass@127.0.0.1:8080"] {
            try await withEnvironment(["HTTPS_PROXY": value]) {
                XCTAssertFalse(WinHTTPFetch.handles(target), value)
            }
        }
        try await withEnvironment(["https_proxy": ""]) {
            XCTAssertEqual(WinProxyRoute.route(for: try XCTUnwrap(target.url)), .systemProxy, "an empty value is unset, as for libcurl")
        }
    }

    func testWithoutProxyVariablesTheSystemProxyRouteStillReachesTheServer() async throws {
        try await withEnvironment([:]) {
            let r = try request(try base() + "/delay/0")
            XCTAssertEqual(WinProxyRoute.route(for: try XCTUnwrap(r.url)), .systemProxy)
            let answer = try await seam(r)
            XCTAssertEqual(text(answer), "ok 0\n")
        }
    }

    /// A `URLProtocol` of the caller's own in its session (a test stub, as `InstallerReleaseFeedTests` uses) is its chosen
    /// transport: the request stays on URLSession. corelibs' built-in protocols do not count.
    func testACallersOwnURLProtocolKeepsURLSession() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnProtocol.self]
        let own = URLSession(configuration: configuration)
        let plain = URLSession(configuration: .ephemeral)
        defer { own.invalidateAndCancel(); plain.invalidateAndCancel() }
        let mine = try request("https://ptb-own.invalid/x")
        XCTAssertFalse(WinHTTPFetch.handles(mine, session: own))
        XCTAssertTrue(WinHTTPFetch.handles(mine, session: plain), "corelibs' own protocols do not count")
        XCTAssertTrue(WinHTTPFetch.handles(try request("https://other.invalid/x"), session: own), "only a protocol that takes the request")
    }

    private final class OwnProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ptb-own.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
        override func stopLoading() {}
    }

    // MARK: cost

    /// The defect this route fixes (the status-check burst): URLSession on Windows keeps two dispatch threads waking each
    /// other for the whole transfer. Through `PlatformCompat.oneShotData` a 2 s loopback transfer must leave every thread
    /// nearly asleep. The same bound applied to URLSession is printed as the control (it fails it by thousands).
    func testAWaitingTransferThroughTheSeamDoesNotKeepAThreadAwake() async throws {
        let given = try request(try base() + "/delay/2000")
        let routed = try await busiestThreadSwitchesWhileWaiting { _ = try await PlatformCompat.oneShotData(for: given) }
        let control = try await busiestThreadSwitchesWhileWaiting {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            _ = try await session.data(for: given)
        }
        print("oneShotData, 1.5 s of a 2 s transfer: busiest thread cs=\(routed); control URLSession (new connection): cs=\(control) (bound 150)")
        XCTAssertLessThan(routed, 150, "busiest thread woke \(routed) times in 1.5 s of waiting (URLSession control: \(control))")
    }

    /// Context switches of the busiest thread of this process over the first 1.5 s of `body` (the server answers after 2 s,
    /// so this is the waiting). A thread born meanwhile counts from zero.
    private func busiestThreadSwitchesWhileWaiting(_ body: @escaping @Sendable () async throws -> Void) async throws -> Int {
        let a = try XCTUnwrap(IdleSampler.snapshot())
        let transfer = Task { try await body() }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let b = try XCTUnwrap(IdleSampler.snapshot())
        try await transfer.value
        return b.contextSwitches.map { Int($0.value) - Int(a.contextSwitches[$0.key] ?? 0) }.max() ?? 0
    }
}
#endif
