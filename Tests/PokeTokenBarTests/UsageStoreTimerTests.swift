import XCTest
@testable import PokeTokenBar

private final class CountingProvider: UsageProvider, @unchecked Sendable {
    let id = "timer-stub"
    let displayName = "Timer stub"
    let reportsCost = false
    private let lock = NSLock()
    private var n = 0
    var fetches: Int { lock.withLock { n } }
    func fetchDaily() async throws -> DailyUsage? { lock.withLock { n += 1 }; return nil }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
}

/// corelibs `Timer(timeInterval:repeats:block:)` fires at once on Windows, the Mac first fires after the interval.
/// Runs on both; see the Windows-Foundation entry in `docs/reference/defect-log.md`.
@MainActor
final class UsageStoreTimerTests: XCTestCase {
    /// Pumps the main run loop and the main actor together until `seconds` pass.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    private func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPollingTimerFirstFiresAfterTheInterval() async {
        let defaults = TestDefaults.make(suite: "ptb.test.timer.first.\(UUID().uuidString)")
        defaults.set(0.5, forKey: "refreshInterval")
        let provider = CountingProvider()
        let store = makeHermeticUsageStore(providers: [provider], defaults: defaults)
        XCTAssertTrue(store.isPollingTimerScheduled)
        await pump(0.2)
        XCTAssertEqual(provider.fetches, 0, "the polling timer fired before its interval")
        await pump(1.3)
        XCTAssertGreaterThanOrEqual(provider.fetches, 1, "the polling timer never fired")
        withExtendedLifetime(store) {}
    }
}
