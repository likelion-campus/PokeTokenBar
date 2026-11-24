import XCTest
@testable import PokeTokenBar

/// A person's Windows `--selftest` must neither read their credentials nor send a request for them: it closes the live gate for the whole
/// run (`AppEnv.liveFetchForbidden`). Every provider whose fetch reads a token or sends a request checks it first.
/// Nothing here can reach a real credential file, the Keychain or the network: the providers get fake sources that count calls, and
/// `allowsLiveLimitsFetch` is closed under `swift test` anyway.
final class LiveFetchForbiddenTests: XCTestCase {
    override func tearDown() {
        AppEnv.liveFetchForbidden = false
        AppEnv.allowLiveFetchForTesting = false
        super.tearDown()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func tick() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testForbiddingClosesTheGateWhateverOpensIt() {
        AppEnv.allowLiveFetchForTesting = true
        XCTAssertTrue(AppEnv.allowsLiveLimitsFetch, "the test switch opens the gate")
        AppEnv.liveFetchForbidden = true
        XCTAssertFalse(AppEnv.allowsLiveLimitsFetch, "forbidden wins over every opener")
    }

    /// The token source is asked for nothing, and nothing is returned, when the run is forbidden (a fake source: never a real token).
    func testForbiddenProvidersDoNotEvenAskForTheirToken() async throws {
        AppEnv.liveFetchForbidden = true
        let keyCalls = Counter(), tokenCalls = Counter()
        let openCode = OpenCodeGoRateLimitsProvider(apiKey: { keyCalls.tick(); return "fake-key" })
        let grok = GrokRateLimitsProvider(accessToken: { tokenCalls.tick(); return "fake-token" })
        let a = try await openCode.fetch()
        let b = try await grok.fetch()
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(keyCalls.count, 0, "the OpenCode Go key source was not asked")
        XCTAssertEqual(tokenCalls.count, 0, "the Grok token source was not asked")
        let status = await StatuspageStatusProvider().fetch()
        XCTAssertTrue(status.isEmpty, "no status page request")
    }

    /// The providers that cannot take a fake source (Cursor's login store, the Codex CLI, the session key file) carry the check too.
    func testEveryProviderThatReadsATokenOrSendsARequestChecksTheFlag() throws {
        for file in ["CursorRateLimitsProvider", "OpenCodeGoRateLimitsProvider", "GrokRateLimitsProvider", "CodexRateLimitsProvider",
                     "ProviderStatusChecker", "SessionKeyLimitsProvider", "CursorUsageAPI", "CursorAuthentication", "ClaudeOAuthLimitsProvider",
                     "LocalAdditionalUsageProvider", "ProcessRunner"] {
            let url = SharedSources.sourcesRoot.appendingPathComponent("Core/\(file).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("AppEnv.liveFetchForbidden"), "\(file) does not check AppEnv.liveFetchForbidden")
        }
    }

    /// Every selftest process of a person's run closes the gate (before the state-folder decision, so a caller-set PTB_STATE_DIR does not skip it).
    func testTheSelftestClosesTheGateForEveryFlag() throws {
        let selftest = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows/WindowsSelftest.swift"), encoding: .utf8)
        let hasPrefix = try XCTUnwrap(selftest.range(of: "$0.hasPrefix(\"--selftest\")"))
        let closes = try XCTUnwrap(selftest.range(of: "AppEnv.liveFetchForbidden = true"))
        let stateGuard = try XCTUnwrap(selftest.range(of: "PTB_STATE_DIR\"] ?? \"\").trimmingCharacters"))
        XCTAssertLessThan(hasPrefix.lowerBound, closes.lowerBound)
        XCTAssertLessThan(closes.lowerBound, stateGuard.lowerBound)
    }

    // MARK: - the choke points, with fakes only

    /// Answers every request itself and counts it: a request that gets past the gate lands here, never on the network.
    private final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var count = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.count += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func countingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The request layer: a real host is refused before any session sees it; loopback and an exempted host pass.
    func testTheRequestLayerRefusesEveryRealHostAndNothingReachesTheSession() async throws {
        AppEnv.liveFetchForbidden = true
        CountingProtocol.count = 0
        let session = countingSession()
        for raw in ["https://api.anthropic.com/v1/x", "https://status.claude.com/x", "https://graphql.pokeapi.co/v1beta2",
                    "https://raw.githubusercontent.com/PokeAPI/sprites/x.png", "https://api.cursor.sh/x", "https://opencode.ai/x"] {
            let url = try XCTUnwrap(URL(string: raw))
            do { _ = try await PlatformCompat.oneShotData(for: URLRequest(url: url), session: session); XCTFail("\(raw) was sent") } catch {
                XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, raw)
            }
            do { _ = try await PlatformCompat.oneShotData(from: url); XCTFail("\(raw) was sent") } catch {
                XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, raw)
            }
        }
        XCTAssertEqual(CountingProtocol.count, 0, "no request reached the session")
        _ = try await PlatformCompat.oneShotData(for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:9/x"))), session: session)
        XCTAssertEqual(CountingProtocol.count, 1, "loopback passes")
        AppEnv.beginExemption(hosts: ["script.google.com"])
        _ = try await PlatformCompat.oneShotData(for: URLRequest(url: try XCTUnwrap(URL(string: "https://script.google.com/x"))), session: session)
        AppEnv.endExemption(hosts: ["script.google.com"])
        XCTAssertEqual(CountingProtocol.count, 2, "an exempted host passes inside the block")
        do { _ = try await PlatformCompat.oneShotData(for: URLRequest(url: try XCTUnwrap(URL(string: "https://script.google.com/x"))), session: session); XCTFail("exemption outlived its block") } catch {}
        XCTAssertEqual(CountingProtocol.count, 2)
    }

    /// The credential readers hand back nothing, from a fake file that would otherwise be read (a temp folder; never a real path).
    func testTheCredentialReadersReturnNothingFromFakeFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-fetch-forbidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.bin")
        try Data("fake".utf8).write(to: secret)
        XCTAssertNotNil(PlatformCompat.readSecret(at: secret), "control: the fake file is readable while the gate is open")
        AppEnv.liveFetchForbidden = true
        XCTAssertNil(PlatformCompat.readSecret(at: secret))
        let opencode = dir.appendingPathComponent("auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"fake"}}"#.utf8).write(to: opencode)
        XCTAssertNil(LocalAdditionalUsageReader.openCodeAPIKey(integrationID: "opencode-go", roots: [dir]))
    }

    /// No CLI is started (Codex app-server, `security`): the fake binary is never run.
    func testNoCommandIsStarted() async throws {
        AppEnv.liveFetchForbidden = true
        do { _ = try await ProcessRunner.runCapturingStdout(binary: "/usr/bin/true", arguments: [], timeout: 5); XCTFail("a command ran") } catch {
            XCTAssertEqual("\(error)", RunnerError.forbidden.description)
        }
        do { _ = try await ProcessRunner.runJSONRPC(binary: "/usr/bin/true", arguments: [], inputLines: [], responseID: 1, timeout: 5); XCTFail("a command ran") } catch {
            XCTAssertEqual("\(error)", RunnerError.forbidden.description)
        }
    }

    /// Completeness: every file that can send a request or start a program is known here. A new one fails this test until someone
    /// decides how a person's selftest is kept out of it (add the check, or give the reason). Files under UI/, Team/UI/ and the
    /// selftests themselves are left out (they are the Mac's UI and the selftest's own loopback / documented requests).
    func testEveryRequestOrLaunchSiteIsAccountedFor() throws {
        let known: [String: String] = [
            "Platform/PlatformCompat.swift": "the choke point: oneShotData/oneShotDownload check AppEnv.fetchBlock",
            "Core/ProcessRunner.swift": "the one place that runs a CLI: both entry points check the flag",
            "Core/AntigravityRateLimitsProvider.swift": "behind AppEnv.allowsLiveLimitsFetch (closed by the flag) and a stub on a person's PC",
            "Core/BinaryLocator.swift": "looks for a tool's path (local); reads no login and sends nothing",
            "Core/UpdateChecker.swift": "Mac-only Homebrew launch; Windows asks no update in a selftest (checkNow false)",
            "Platform/Windows/WinAgentLink.swift": "starts this app for a link (local)",
            "Platform/Windows/WinProcess.swift": "starts this app / helpers (local)",
            "Platform/Windows/WindowsUpdateInstaller.swift": "the update download: oneShotDownload (checked) and a loopback feed only with CI=true",
        ]
        let patterns = ["URLSession.shared.data", "ession.data(", "= Process()", "URLSession.shared.download", ".dataTask(", "WinHTTPFetch.data(", "CreateProcessW"]
        var unknown: [String] = []
        for url in SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot) {
            let rel = SharedSources.relativePath(url, root: SharedSources.sourcesRoot)
            if rel.hasPrefix("UI/") || rel.hasPrefix("Team/UI/") || rel.contains("Selftest") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if patterns.contains(where: { code.contains($0) }), known[rel] == nil { unknown.append(rel) }
        }
        XCTAssertEqual(unknown, [], "a file that sends a request or starts a program is not accounted for in LiveFetchForbiddenTests.known")
    }
}
