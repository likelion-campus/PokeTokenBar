import XCTest
@testable import PokeTokenBar

/// A person's Windows `--selftest` must neither read their credentials nor send a request for them (audit F4/F5 follow-up): it closes
/// `AppEnv.allowsLiveLimitsFetch` for the whole run. Nothing here touches a credentials file, the Keychain or the network.
final class LiveFetchForbiddenTests: XCTestCase {
    override func tearDown() {
        AppEnv.liveFetchForbidden = false
        AppEnv.allowLiveFetchForTesting = false
        super.tearDown()
    }

    func testForbiddingClosesTheGateWhateverOpensIt() {
        AppEnv.allowLiveFetchForTesting = true
        XCTAssertTrue(AppEnv.allowsLiveLimitsFetch, "the test switch opens the gate")
        AppEnv.liveFetchForbidden = true
        XCTAssertFalse(AppEnv.allowsLiveLimitsFetch, "forbidden wins over every opener")
    }

    /// The selftest's start-up code keeps its promises: the gate is closed before the state-folder decision, and the Windows limits
    /// providers (which read the credentials file) are installed only outside a person's selftest.
    func testThePersonRunClosesTheGateAndKeepsTheStubProviders() throws {
        let root = SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows")
        let selftest = try String(contentsOf: root.appendingPathComponent("WindowsSelftest.swift"), encoding: .utf8)
        let closes = try XCTUnwrap(selftest.range(of: "AppEnv.liveFetchForbidden = true"))
        let stateGuard = try XCTUnwrap(selftest.range(of: "PTB_STATE_DIR\"] ?? \"\").trimmingCharacters"))
        XCTAssertLessThan(closes.lowerBound, stateGuard.lowerBound, "closed even when the person set PTB_STATE_DIR")
        let app = try String(contentsOf: root.appendingPathComponent("WindowsApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("if !(WinDefaultsSync.selftestOwnsSettings && !WindowsSelftest.onCI) { WindowsPlatform.limitsFactory = WindowsLimitsProviders() }"))
    }
}
