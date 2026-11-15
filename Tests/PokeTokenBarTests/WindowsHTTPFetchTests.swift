#if os(Windows)
import XCTest
import FoundationNetworking
@testable import PokeTokenBar

/// `WinHTTPFetch` and the Windows branch of `PlatformCompat.oneShotData` against the in-process loopback server (no network).
final class WindowsHTTPFetchTests: XCTestCase {
    private static let server = LoopbackServer.start()

    private func base() throws -> String {
        let server = try XCTUnwrap(Self.server, "loopback server did not start")
        return "http://127.0.0.1:\(server.port)"
    }

    private func request(_ url: String, timeout: TimeInterval = 10) throws -> URLRequest {
        URLRequest(url: try XCTUnwrap(URL(string: url)), timeoutInterval: timeout)
    }

    func testGetReturnsStatusBodyAndHeaders() async throws {
        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/delay/0"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok 0\n")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testSendsTheRequestHeadersAndADefaultUserAgent() async throws {
        var given = try request(try base() + "/echo")
        given.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")
        given.setValue("1", forHTTPHeaderField: "X-Probe")
        let (echoed, _) = try await WinHTTPFetch.data(for: given)
        let text = String(decoding: echoed, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /echo HTTP/1.1"), text)
        XCTAssertEqual(text.components(separatedBy: "User-Agent:").count - 1, 1, "exactly one User-Agent: \(text)")
        XCTAssertTrue(text.contains("User-Agent: PokeTokenBar"), text)
        XCTAssertTrue(text.contains("X-Probe: 1"), text)

        let (plain, _) = try await WinHTTPFetch.data(for: try request(try base() + "/echo"))
        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("User-Agent: PokeTokenBar"))
    }

    func testFollowsARedirectAndReportsTheFinalURL() async throws {
        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/redirect"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok 0\n")
        XCTAssertEqual(response.url?.path, "/delay/0")
    }

    func testAnErrorStatusIsAResponseNotAThrow() async throws {
        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/status/503"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "status 503\n")
    }

    func testAStalledBodyEndsWithTimedOutAfterTheRequestTimeout() async throws {
        let t0 = Date()
        do {
            _ = try await WinHTTPFetch.data(for: try request(try base() + "/hang", timeout: 1))
            XCTFail("a body that never completes must time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut, "\(error)")
        }
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(elapsed, 0.8)
        XCTAssertLessThan(elapsed, 5)
    }

    func testOnlyPlainHTTPGetsGoThroughWinHTTP() throws {
        let get = try request(try base() + "/delay/0")
        XCTAssertTrue(WinHTTPFetch.handles(get))
        var post = get
        post.httpMethod = "POST"
        XCTAssertFalse(WinHTTPFetch.handles(post))
        var withBody = get
        withBody.httpBody = Data("x".utf8)
        XCTAssertFalse(WinHTTPFetch.handles(withBody))
        XCTAssertFalse(WinHTTPFetch.handles(try request("ftp://127.0.0.1/x")))
    }

    /// libcurl reads these variables and WinHTTP does not: with one set, the request keeps URLSession (as before).
    func testACurlProxyVariableKeepsTheRequestOnURLSession() throws {
        let get = try request(try base() + "/delay/0")
        for name in ["HTTPS_PROXY", "http_proxy", "ALL_PROXY"] {
            PlatformCompat.setEnvironment(name, "http://127.0.0.1:9")
            XCTAssertTrue(WinHTTPFetch.curlProxyConfigured(), name)
            XCTAssertFalse(WinHTTPFetch.handles(get), name)
            PlatformCompat.setEnvironment(name, nil)
        }
        PlatformCompat.setEnvironment("https_proxy", "")
        XCTAssertFalse(WinHTTPFetch.curlProxyConfigured(), "an empty value is unset, as for libcurl")
        PlatformCompat.setEnvironment("https_proxy", nil)
        XCTAssertTrue(WinHTTPFetch.handles(get))
    }

    /// The defect this route fixes (the status-check burst): URLSession on Windows keeps two dispatch threads waking each
    /// other for the whole transfer. Through `PlatformCompat.oneShotData` a 2 s loopback transfer must leave every thread
    /// nearly asleep. The same bound applied to URLSession is printed as the control (it fails it by thousands).
    func testAWaitingTransferThroughTheSeamDoesNotKeepAThreadAwake() async throws {
        let given = try request(try base() + "/delay/2000")
        let routed = try await busiestThreadSwitchesWhileWaiting { _ = try await PlatformCompat.oneShotData(for: given) }
        let control = try await busiestThreadSwitchesWhileWaiting { _ = try await URLSession.shared.data(for: given) }
        print("oneShotData, 1.5 s of a 2 s transfer: busiest thread cs=\(routed); control URLSession.shared: cs=\(control) (bound 150)")
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
