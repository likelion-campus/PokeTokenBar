import XCTest
@testable import PokeTokenBar

/// A usage source whose today total the test moves.
private final class WiringProvider: UsageProvider, @unchecked Sendable {
    let id = "wiring"
    let displayName = "Wiring"
    private let lock = NSLock()
    private var value = 0
    var tokens: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    func fetchDaily() async throws -> DailyUsage? {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: 0, outputTokens: 0,
                   cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: tokens, totalCost: 0)
    }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
}

private final class WiringClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

/// `AppWiring` feeds the companion the way the Mac's `AppDelegate` does (both OSes).
@MainActor
final class AppWiringTests: XCTestCase {
    func testAppWiringPassesEveryUsageInput() async throws {
        let provider = WiringProvider()
        provider.tokens = 1_000
        let store = makeHermeticUsageStore(providers: [provider], defaults: TestDefaults.make(suite: "app-wiring-store"))
        store.alwaysFacesBack = true
        let clock = WiringClock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-wiring-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let line = EvoLine(baseID: 1,
                           tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [])]),
                           rarity: .common, names: [1: ["en": "P1"], 2: ["en": "P2"]])
        let companion = CompanionStore(provider: StubProvider(value: line), clock: { clock.now }, fileURL: file,
                                       dittoDisguiseRollingEnabled: false,
                                       defaults: TestDefaults.make(suite: "app-wiring-companion"))
        let today = LocalUsageReader.todayKey()

        // First refresh with data: the install baseline (usage before the app counts for nothing).
        await refreshed(store, total: 1_000)
        AppWiring.storeRefreshed(companion, store)
        XCTAssertTrue(companion.alwaysFacesBack, "alwaysFacesBack is mirrored")
        XCTAssertTrue(companion.state.installBaselineSet, "hasUsageData and the per-provider map reached update")
        XCTAssertEqual(companion.state.claimedTodayTokensByProvider, ["wiring": 1_000])
        XCTAssertEqual(companion.state.lastDate, today, "todayDate reached update")

        // More usage today: the egg is credited with the increase only.
        provider.tokens = 1_500
        await refreshed(store, total: 1_500)
        AppWiring.storeRefreshed(companion, store)
        XCTAssertEqual(companion.state.usedSinceInstall, 500)
        XCTAssertEqual(companion.state.eggUsage, 500)
        XCTAssertEqual(companion.state.claimedTodayTokensByProvider, ["wiring": 1_500])

        // Hatched and past the hatch animation, the mood follows the store's burn tier and limit warning.
        await companion.hatch(baseID: 1)
        clock.now = clock.now.addingTimeInterval(60)
        provider.tokens = 1_600
        await refreshed(store, total: 1_600)
        AppWiring.updateCompanion(companion, from: store)
        XCTAssertNotNil(companion.state.active)
        XCTAssertFalse(store.isLimitWarning)
        let expected: CompanionStateKind
        switch store.burnTier {
        case .idle: expected = .idle
        case .normal: expected = .working
        case .fast, .blazing: expected = .focus
        }
        XCTAssertEqual(companion.displayState, expected, "burnTier \(store.burnTier), hasUsageData and today's tokens")
    }

    /// `refresh` can return before its result lands (defect log): wait for the total.
    private func refreshed(_ store: UsageStore, total: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await store.refresh()
        for _ in 0..<2000 where store.todayTotalTokens != total { await Task.yield() }
        XCTAssertEqual(store.todayTotalTokens, total, file: file, line: line)
        XCTAssertTrue(store.hasUsageData, file: file, line: line)
    }
}
