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
                     "ProviderStatusChecker", "SessionKeyLimitsProvider"] {
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
}
