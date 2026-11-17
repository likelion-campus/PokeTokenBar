#if os(Windows)
import XCTest
import FoundationNetworking
import WinSDK
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

    // MARK: redirects (the Mac's header rules: RedirectHeadersMacTests)

    func testASameOriginRedirectKeepsTheCookieAndDropsAuthorizationAsOnTheMac() async throws {
        var given = try request(try base() + "/redirect-307")
        given.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        given.setValue("sessionKey=fixture", forHTTPHeaderField: "Cookie")
        given.setValue("1", forHTTPHeaderField: "X-Probe")
        let hop = text(try await seam(given))
        XCTAssertTrue(hop.hasPrefix("GET\nGET /echo HTTP/1.1"), hop)
        XCTAssertFalse(hop.contains("Authorization:"), "dropped on every hop, as the Mac does: \(hop)")
        XCTAssertTrue(hop.contains("Cookie: sessionKey=fixture"), hop)
        XCTAssertTrue(hop.contains("X-Probe: 1"), hop)

        let (data, response) = try await WinHTTPFetch.data(for: try request(try base() + "/redirect"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok 0\n")
        XCTAssertEqual(response.url?.path, "/delay/0")
    }

    func testACrossOriginRedirectCarriesNoCredential() async throws {
        let other = try XCTUnwrap(Self.other)
        // Authorization only: followed, without it (the Mac does the same).
        var bearer = try request(try base() + "/redirect-to/\(other.port)")
        bearer.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        bearer.setValue("1", forHTTPHeaderField: "X-Probe")
        let crossed = try await seam(bearer)
        XCTAssertEqual(crossed.status, 200)
        XCTAssertTrue(text(crossed).contains("Host: localhost:\(other.port)"), text(crossed))
        XCTAssertFalse(text(crossed).contains("Authorization:"), text(crossed))
        XCTAssertTrue(text(crossed).contains("X-Probe: 1"), text(crossed))

        // A Cookie: not followed (the Mac would send it along); the 302 comes back and the other origin is never contacted.
        let before = other.accepted
        var cookie = try request(try base() + "/redirect-to/\(other.port)")
        cookie.setValue("sessionKey=fixture", forHTTPHeaderField: "Cookie")
        cookie.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (_, response) = try await PlatformCompat.oneShotData(for: cookie)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Location"), "http://localhost:\(other.port)/echo")
        XCTAssertEqual(other.accepted, before, "the other origin saw no connection")

        // The control: URLSession on Windows (corelibs keeps every header on a redirect, HTTPURLProtocol.swift 564).
        let theirs = text(try await control(cookie))
        print("REDIRECT cross-host, URLSession on Windows forwards: Authorization \(theirs.contains("Authorization:")), "
              + "Cookie \(theirs.contains("Cookie:"))")
    }

    /// The redirect rules on their own, where the loopback server cannot go (it speaks no TLS).
    func testTheRedirectRules() throws {
        let fields = [WinHTTPFetch.Field(name: "Authorization", value: "Bearer x"), WinHTTPFetch.Field(name: "X-Probe", value: "1")]
        let withCookie = fields + [WinHTTPFetch.Field(name: "cookie", value: "sessionKey=x")]
        func hop(_ url: String, _ method: String, _ f: [WinHTTPFetch.Field], body: Bool = false) throws -> WinHTTPFetch.Hop {
            WinHTTPFetch.Hop(url: try XCTUnwrap(URL(string: url)), method: method, fields: f, sendsBody: body)
        }
        let from = try hop("https://api.example.invalid/a", "POST", fields, body: true)
        XCTAssertNil(WinHTTPFetch.nextHop(after: 302, location: "http://api.example.invalid/b", from: from), "never HTTPS to HTTP")
        XCTAssertNil(WinHTTPFetch.nextHop(after: 302, location: "ftp://api.example.invalid/b", from: from))
        XCTAssertNil(WinHTTPFetch.nextHop(after: 302, location: nil, from: from))
        XCTAssertNil(WinHTTPFetch.nextHop(after: 304, location: "/b", from: from))
        XCTAssertNil(WinHTTPFetch.nextHop(after: 200, location: "/b", from: from))

        let get = try XCTUnwrap(WinHTTPFetch.nextHop(after: 302, location: "/b", from: from))
        XCTAssertEqual(get.url.absoluteString, "https://api.example.invalid/b")
        XCTAssertEqual(get.method, "GET")
        XCTAssertFalse(get.sendsBody)
        XCTAssertEqual(get.fields.map(\.name), ["X-Probe"], "Authorization is dropped on every hop")
        for status in [307, 308] {
            let kept = try XCTUnwrap(WinHTTPFetch.nextHop(after: status, location: "https://other.example.invalid/b", from: from))
            XCTAssertEqual(kept.method, "POST", "\(status)")
            XCTAssertTrue(kept.sendsBody, "\(status)")
        }
        let put = try hop("https://a.invalid/", "PUT", fields)
        XCTAssertEqual(WinHTTPFetch.nextHop(after: 303, location: "/b", from: put)?.method, "GET")
        XCTAssertEqual(WinHTTPFetch.nextHop(after: 301, location: "/b", from: put)?.method, "PUT")

        let cookie = try hop("https://a.invalid/x", "GET", withCookie)
        XCTAssertNotNil(WinHTTPFetch.nextHop(after: 302, location: "https://A.invalid:443/y", from: cookie), "same origin")
        for elsewhere in ["https://b.invalid/y", "https://a.invalid:8443/y", "http://a.invalid/y"] {
            XCTAssertNil(WinHTTPFetch.nextHop(after: 302, location: elsewhere, from: cookie), elsewhere)
        }
        let bearerOnly = try hop("http://a.invalid/x", "GET", fields)
        XCTAssertNotNil(WinHTTPFetch.nextHop(after: 302, location: "http://b.invalid/y", from: bearerOnly),
                        "no credential left once Authorization is dropped: another origin is fine")
    }

    func testRedirectChainsStopAfterTwentyHopsAndLoopsAtOnce() async throws {
        let chain = text(try await seam(try request(try base() + "/redirect-chain/20")))
        XCTAssertEqual(chain, "chain end\n")
        for path in ["/redirect-chain/21", "/redirect-loop"] {
            let error = await failure(try request(try base() + path)) { try await self.seam($0) }
            XCTAssertEqual(error?.code, .httpTooManyRedirects, path)
        }
    }

    func testA303TurnsAPostIntoAGetAsInURLSession() async throws {
        var post = try request(try base() + "/see-other")
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        let after = try await seam(post)
        XCTAssertTrue(text(after).hasPrefix("GET\n"), "a 303 continues as GET, as in URLSession: \(text(after))")
        let controlAfter = try await control(post)
        XCTAssertTrue(text(controlAfter).hasPrefix("GET\n"))
    }

    // MARK: the request body (WinHTTP may send it again after WinHttpSendRequest returns)

    func testABodyArrivesWholeAfterA307AndOnEveryRequestAProxyAsksFor() async throws {
        let payload = #"{"grant_type":"refresh_token","refresh_token":"fixture"}"#
        var post = try request(try base() + "/redirect-307")
        post.httpMethod = "POST"
        post.httpBody = Data(payload.utf8)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let echoed = text(try await seam(post))
        XCTAssertTrue(echoed.hasPrefix("POST\nPOST /echo HTTP/1.1"), echoed)
        XCTAssertTrue(echoed.hasSuffix("\n\n" + payload), echoed)

        let token = "body-\(UUID().uuidString.prefix(8))"
        var proxied = try request("http://ptb-target.invalid/proxy-auth/\(token)")
        proxied.httpMethod = "POST"
        proxied.httpBody = Data(payload.utf8)
        try await withEnvironment(["HTTP_PROXY": try base()]) {
            let status = try await seam(proxied).status
            XCTAssertEqual(status, 407)
        }
        // Our sends (the first and the retry) carry the whole body; WinHTTP's own NTLM/Negotiate legs go with Content-Length 0
        // (the body follows once the proxy completes the handshake, which this fake never does).
        let seen = LoopbackServer.recorded(token)
        print("PROXY407 POST requests the proxy saw: \(seen.map { $0.components(separatedBy: " body=").first ?? $0 })")
        let plain = seen.filter { $0.hasPrefix("proxy-authorization=none ") }
        let legs = seen.filter { !$0.hasPrefix("proxy-authorization=none ") }
        XCTAssertEqual(plain.count, 2, "the first request and the retry: \(seen)")
        XCTAssertTrue(plain.allSatisfy { $0.hasSuffix("length=\(payload.utf8.count) body=" + payload) }, "the exact body each time: \(seen)")
        XCTAssertTrue(legs.allSatisfy { $0.hasSuffix("length=0 body=") }, "handshake legs carry no body: \(seen)")
    }

    // MARK: Windows logon credentials

    /// A server asking for NTLM or Negotiate gets one request and nothing of the Windows logon; the 401 goes to the caller.
    /// The control is WinHTTP's own default (authentication on, policy MEDIUM), as this file ran before the review.
    func testA401AskingForTheWindowsLogonIsNeverAnswered() async throws {
        let port = try XCTUnwrap(Self.server).port
        for host in ["127.0.0.1", "localhost"] {
            let token = "server-\(host)-\(UUID().uuidString.prefix(8))"
            let answer = try await seam(try request("http://\(host):\(port)/auth/\(token)"))
            XCTAssertEqual(answer.status, 401, host)
            XCTAssertEqual(LoopbackServer.recorded(token), ["authorization=none"], host)

            let before = "before-\(token)"
            let (_, old) = try await WinHTTPFetch.data(for: try request("http://\(host):\(port)/auth/\(before)"), logonAsBefore: true)
            print("AUTOLOGON control \(host), WinHTTP default MEDIUM: status \((old as? HTTPURLResponse)?.statusCode ?? -1), "
                  + "requests \(LoopbackServer.recorded(before))")
        }
    }

    func testA407FromTheProxyIsAnsweredOnceWithTheLogonAllowed() async throws {
        let token = "proxy-\(UUID().uuidString.prefix(8))"
        try await withEnvironment(["HTTP_PROXY": try base()]) {
            let status = try await seam(try request("http://ptb-target.invalid/proxy-auth/\(token)")).status
            XCTAssertEqual(status, 407, "the fake proxy never completes the handshake: its last 407 goes back")
        }
        let seen = LoopbackServer.recorded(token).map { ($0.components(separatedBy: " length=").first ?? $0) }
        print("PROXY407 GET requests the proxy saw: \(seen); WINHTTP_OPTION_PROXY: \(WinHTTPFetch.stats.proxyReportsSeen)")
        XCTAssertEqual(seen.first, "proxy-authorization=none", "the first request offers nothing")
        XCTAssertGreaterThanOrEqual(seen.count, 2, "a 407 from the proxy is answered")
        XCTAssertTrue(seen.dropFirst().contains { $0 == "proxy-authorization=NTLM" || $0 == "proxy-authorization=Negotiate" },
                      "the retry offers the logon identity to the proxy: \(seen)")
    }

    func testA407FromAServerOnADirectRouteIsNotAnswered() async throws {
        try await withEnvironment([:]) {
            let token = "direct-\(UUID().uuidString.prefix(8))"
            let given = try request(try base() + "/proxy-407/\(token)")
            XCTAssertEqual(WinProxyRoute.route(for: try XCTUnwrap(given.url)), .systemProxy)
            let status = try await seam(given).status
            XCTAssertEqual(status, 407)
            print("PROXY407 direct: \(LoopbackServer.recorded(token)); WINHTTP_OPTION_PROXY: \(WinHTTPFetch.stats.proxyReportsSeen)")
            XCTAssertEqual(LoopbackServer.recorded(token), ["proxy-authorization=none"])
        }
    }

    // MARK: TLS, size, deadlines, concurrency

    func testSessionsTakeTLS12AndUpOnly() async throws {
        let port = try XCTUnwrap(Self.server).port
        _ = await failure(try request("https://127.0.0.1:\(port)/delay/0", timeout: 5)) { try await self.seam($0) }
        let mask = WinHTTPFetch.stats.secureProtocols
        print("SECURE_PROTOCOLS mask 0x\(String(mask, radix: 16))")
        XCTAssertTrue(mask == WinHTTPFetch.protocolsTLS12And13 || mask == WinHTTPFetch.protocolTLS12, "0x\(String(mask, radix: 16))")
        XCTAssertEqual(mask & (0x8 | 0x20 | 0x80 | 0x200), 0, "no SSL 2, SSL 3, TLS 1.0 or 1.1")
    }

    func testTheBodyLimitCountsDecodedBytes() async throws {
        let bomb = try request(try base() + "/gzip-bomb")
        XCTAssertLessThan(LoopbackServer.gzipBombBody.count, 64 * 1024)
        do {
            _ = try await WinHTTPFetch.data(for: bomb, maxBodyBytes: 64 * 1024)
            XCTFail("230 B of gzip decode to 200,000 B, past a 64 KB limit")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        let (whole, _) = try await WinHTTPFetch.data(for: bomb)
        XCTAssertEqual(whole.count, LoopbackServer.gzipBombSize, "the default limit lets it through")
    }

    func testASlowBodyArrivesPieceByPieceWithoutTheIdleTimerFiring() async throws {
        let t0 = Date()
        let answer = try await seam(try request(try base() + "/drip/20480/1024/500", timeout: 2))
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "DRIP 20 KB at 1 KB every 500 ms, 2 s timeout: %d B in %.1f s", answer.body.count, elapsed))
        XCTAssertEqual(answer.body.count, 20480)
        XCTAssertGreaterThan(elapsed, 8)
    }

    func testTheSessionsResourceTimeoutEndsADrippingFetch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let t0 = Date()
        let error = await failure(try request(try base() + "/drip/20480/1024/500", timeout: 60)) { try await self.seam($0, session: session) }
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "DEADLINE 3 s on a 10 s drip: code %d after %.1f s", error?.code.rawValue ?? 0, elapsed))
        XCTAssertEqual(error?.code, .timedOut)
        XCTAssertGreaterThan(elapsed, 2.5)
        XCTAssertLessThan(elapsed, 4.5)
    }

    func testAtMostEightFetchesRunAtOnceAndAWaitingOneEndsOnCancellation() async throws {
        WinHTTPFetch.gate.resetPeak()
        let slow = try request(try base() + "/delay/2000")
        let batch = Task { () -> [Int] in
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<12 {
                    group.addTask { ((try await PlatformCompat.oneShotData(for: slow)).1 as? HTTPURLResponse)?.statusCode ?? -1 }
                }
                var statuses: [Int] = []
                for try await status in group { statuses.append(status) }
                return statuses
            }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let busy = WinHTTPFetch.gate.load.busy
        let waiting = Task { try await PlatformCompat.oneShotData(for: slow) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t0 = Date()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled fetch must not finish")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let cancelledIn = Date().timeIntervalSince(t0)
        let statuses = try await batch.value
        let peak = WinHTTPFetch.gate.load.peak
        print(String(format: "GATE busy %d while 13 were asked, peak %d, a waiting fetch cancelled in %.3f s", busy, peak, cancelledIn))
        XCTAssertEqual(busy, WinHTTPFetch.maxConcurrentFetches, "the 13th waits for a slot")
        XCTAssertLessThanOrEqual(peak, WinHTTPFetch.maxConcurrentFetches)
        XCTAssertLessThan(cancelledIn, 0.5)
        XCTAssertEqual(statuses, Array(repeating: 200, count: 12))
    }

    // MARK: handles (run 44143290510: the base index's 649 REST fetches kept about 600)

    private func handleCount() -> Int {
        var count: DWORD = 0
        XCTAssertTrue(GetProcessHandleCount(GetCurrentProcess(), &count))
        return Int(count)
    }

    private func settledHandleCount() async throws -> Int {
        try await Task.sleep(nanoseconds: 500_000_000)
        return handleCount()
    }

    /// 100 bodies, each on a thread `start` makes, all returned.
    private func hundredThreads(_ start: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { await withCheckedContinuation { c in start { c.resume() } } } }
        }
    }

    /// Every fetch runs on a thread of its own. `Foundation.Thread` on Windows never closes its thread's handle (the control: 100
    /// threads that only return keep about 100 handles). 100 fetches on one session take the whole fetch path (gate, worker
    /// thread, timer, connection, request) except opening and closing a session: they must keep none (with `Foundation.Thread`
    /// workers, 100). What a session per fetch costs on top is `testWhatASessionPerFetchKeepsOverTime`.
    func testTheFetchWorkersKeepNoHandleWhereFoundationThreadsKeepOneEach() async throws {
        let url = try XCTUnwrap(URL(string: try base() + "/delay/0"))
        _ = await WinHTTPFetch.batchDiagnostic(Array(repeating: url, count: 5), concurrency: 1, oneSession: true)  // one-time handles
        let before = try await settledHandleCount()
        let batch = await WinHTTPFetch.batchDiagnostic(Array(repeating: url, count: 100), concurrency: 1, oneSession: true)
        let afterBatch = try await settledHandleCount()
        await hundredThreads { body in Thread { body() }.start() }
        let afterThreads = try await settledHandleCount()
        await hundredThreads { body in XCTAssertTrue(WinDetachedThread.start(body)) }
        let afterDetached = try await settledHandleCount()
        print("HANDLES before \(before), after 100 fetches on one session \(afterBatch) (\(batch)), "
              + "after 100 Foundation threads \(afterThreads), after 100 detached threads \(afterDetached)")
        XCTAssertTrue(batch.contains(", 0 failed,"), batch)
        XCTAssertLessThan(afterBatch - before, 20, "the fetches' workers kept handles")
        XCTAssertGreaterThanOrEqual(afterThreads - afterBatch, 90,
                                    "control: Foundation.Thread kept no handle; if corelibs closes it now, WinDetachedThread can go")
        XCTAssertLessThan(afterDetached - afterThreads, 10, "WinDetachedThread kept handles")
    }

    /// Information, not a bound: 100 fetches each on a session of its own (the app's way), through the Windows proxy settings
    /// and directly, and the handle count over the next 75 s (run 44166157252: +196 still after 20 s on the proxy route; the
    /// same 100 on one session kept +7).
    func testWhatASessionPerFetchKeepsOverTime() async throws {
        let url = try base() + "/delay/0"
        for route in [WinProxyRoute.Route.systemProxy, .direct] {
            for _ in 0..<5 { _ = try await WinHTTPFetch.data(for: try request(url), route: route) }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let before = handleCount()
            for _ in 0..<100 { _ = try await WinHTTPFetch.data(for: try request(url), route: route) }
            var trail: [String] = []
            let t0 = Date()
            for mark in [0.5, 5, 15, 30, 45, 60, 75] {
                let wait = mark - Date().timeIntervalSince(t0)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                trail.append(String(format: "%.0fs:%+d", mark, handleCount() - before))
            }
            print("SESSION HANDLES \(route): 100 fetches, a session each: \(trail.joined(separator: " "))")
        }
    }

    /// Item 9 of the review: per-fetch sessions against one session for a batch (time, connections). Printed, not a bound.
    func testABatchOnOneSessionAgainstASessionEach() async throws {
        let server = try XCTUnwrap(Self.server)
        let urls = Array(repeating: try XCTUnwrap(URL(string: try base() + "/delay/0")), count: 60)
        let a = server.accepted
        let each = await WinHTTPFetch.batchDiagnostic(urls, concurrency: 6, oneSession: false)
        let b = server.accepted
        let one = await WinHTTPFetch.batchDiagnostic(urls, concurrency: 6, oneSession: true)
        let c = server.accepted
        print("BATCH \(each), \(b - a) connections | \(one), \(c - b) connections")
        XCTAssertTrue(each.contains(", 0 failed,") && one.contains(", 0 failed,"), "\(each) | \(one)")
    }

    // MARK: outside the installed app, the proxy notice

    func testOutsideTheAppOnlyLoopbackAndTestNamesAreFetched() async throws {
        XCTAssertFalse(PlatformCompat.isBundledApp)
        for host in ["127.0.0.1", "127.5.6.7", "localhost", "::1", "[::1]", "a.invalid", "ptb.test"] {
            XCTAssertTrue(WinHTTPFetch.isTestHost(host), host)
        }
        for host in ["status.claude.com", "127.evil.com", "example.com", "invalid.example"] {
            XCTAssertFalse(WinHTTPFetch.isTestHost(host), host)
        }
        for _ in 0..<2 {
            let error = await failure(try request("https://ptb-guard.example/x")) { try await self.seam($0) }
            XCTAssertEqual(error?.code, .notConnectedToInternet)
        }
        XCTAssertFalse(WinHTTPFetch.stats.noteRefused("PTB-guard.example"), "named on stderr once per host")
    }

    func testAProxyVariableWinHTTPCannotTakeIsNotedOnceWithoutItsValue() async throws {
        let target = try request("https://ptb-target.invalid/x")
        let before = WinHTTPFetch.stats.fallbackCount
        try await withEnvironment(["HTTPS_PROXY": "socks5://user:secret@127.0.0.1:1080"]) {
            XCTAssertFalse(WinHTTPFetch.handles(target))
            XCTAssertFalse(WinHTTPFetch.handles(target))
        }
        XCTAssertEqual(WinHTTPFetch.stats.fallbackCount, before + 2)
        XCTAssertFalse(WinHTTPFetch.stats.noteFallback(), "logged the first time only")
        XCTAssertFalse(WinHTTPFetch.fallbackNotice.contains("secret") || WinHTTPFetch.fallbackNotice.contains("127.0.0.1"))
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
