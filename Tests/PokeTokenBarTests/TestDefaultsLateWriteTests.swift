import XCTest
@testable import PokeTokenBar

/// End-to-end regression for the late write (see `TestDefaults` and the defect log): a store that outlives
/// its test and saves its ledger after the test ended must not be able to put that into the defaults of the
/// next test. Methods of one class run in name order, so `testA…` ends before `testB…` starts, through the
/// shared pool and the real `UsageStore` save path.
@MainActor
final class TestDefaultsLateWriteTests: XCTestCase {
    private static var writerRan = false
    private static var keepAlive: [UsageStore] = []

    private final class SlowLedgerProvider: UsageProvider, @unchecked Sendable {
        let id = "claude_code", displayName = "Claude Code", reportsCost = true
        private func day(_ date: String) -> DailyUsage {
            DailyUsage(date: date, inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0,
                       cacheReadTokens: 0, totalTokens: 7_777_777, totalCost: 1)
        }
        func fetchDaily() async throws -> DailyUsage? {
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // outlives the test that started it
            return day("2026-11-01")
        }
        func fetchEnrichment() async -> ProviderEnrichment {
            var enrichment = ProviderEnrichment()
            enrichment.periodsOK = true
            enrichment.monthDaily = [day("2026-11-01")]
            return enrichment
        }
    }

    /// Returns at once. The setter starts an un-awaited refresh that saves the ledger ~1.5 s from now.
    func testA_endsWhileARefreshIsStillRunning() {
        let defaults = TestDefaults.make(suite: "late-writer-\(UUID().uuidString)")
        let store = makeHermeticUsageStore(providers: [SlowLedgerProvider()], defaults: defaults)
        store.setCustomScanRoots("~/late-write-root", for: "codex")
        Self.keepAlive.append(store)
        Self.writerRan = true
    }

    func testB_aLaterTestNeverSeesTheEarlierTestsLateWrite() async throws {
        try XCTSkipUnless(Self.writerRan, "the writer test did not run before this one")
        let defaults = TestDefaults.make(suite: "late-reader-\(UUID().uuidString)")
        XCTAssertNil(defaults.dictionary(forKey: UsageLedger.defaultsKey), "a fresh suite starts empty")
        try await Task.sleep(nanoseconds: 3_000_000_000)   // the writer's refresh finishes in here
        XCTAssertNil(defaults.dictionary(forKey: UsageLedger.defaultsKey),
                     "the previous test's late save landed in this test's defaults")
    }
}
