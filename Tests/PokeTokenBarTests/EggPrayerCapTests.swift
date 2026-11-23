import XCTest
@testable import PokeTokenBar

// MARK: 알 기도 하루 한도 — 하루에 `prayersPerDay`(2)번만 센다 (2026-11-23).

@MainActor
final class EggPrayerCapTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let line = EvoLine(
        baseID: 1,
        tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [])]),
        rarity: .common,
        names: [1: ["en": "P1"], 2: ["en": "P2"]])

    /// An egg with no tokens and `record` (raw JSON) as its prayers.
    private func egg(record: String? = nil) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prayer-cap-\(UUID().uuidString).json")
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":10000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"dex\":[],\"collectedFinals\":[],\"eggUsage\":0,\"pendingHatchID\":1"
            + (record.map { ",\"eggPrayers\":\($0)" } ?? "") + "}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: StubProvider(value: line), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
    }

    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        return condition()
    }

    func testOnlyTwoPrayersCountInOneDay() async {
        XCTAssertEqual(PokemonBalance.prayersPerDay, 2)
        let store = egg()
        XCTAssertEqual(store.prayersLeftToday, 2)
        XCTAssertTrue(store.pray())
        XCTAssertTrue(store.pray())
        XCTAssertTrue(store.isPrayerDoneToday)
        for _ in 0..<20 { XCTAssertFalse(store.pray()) }
        XCTAssertEqual(store.state.eggPrayers?.count, 2)
        now = now.addingTimeInterval(23 * 3600 + 59 * 60)   // still short of two local midnights, past one at most
        _ = store.pray(); _ = store.pray(); _ = store.pray()
        XCTAssertLessThanOrEqual(store.state.eggPrayers?.count ?? 0, 4)
    }

    func testTheNextDayCountsTwoMore() async {
        let store = egg()
        store.pray(); store.pray()
        now = now.addingTimeInterval(86_400)
        XCTAssertEqual(store.prayersLeftToday, 2)
        XCTAssertTrue(store.pray())
        XCTAssertTrue(store.pray())
        XCTAssertFalse(store.pray())
        XCTAssertEqual(store.state.eggPrayers?.count, 4)
    }

    /// Clicking as fast as you like no longer hatches an egg: ten clicks on one day leave it an egg.
    func testTenClicksInOneDayDoNotHatchTheEgg() async {
        let store = egg()
        for _ in 0..<10 { store.pray() }
        await store.hatchIfNeeded()
        XCTAssertNil(store.state.active)
    }

    func testTheTenthCountedPrayerOnTheFifthDayHatchesTheEgg() async {
        let store = egg()
        for day in 0..<5 {
            if day > 0 { now = now.addingTimeInterval(86_400) }
            store.pray(); store.pray(); store.pray()
            if day < 4 { XCTAssertNil(store.state.active, "day \(day + 1)") }
        }
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 10), "the hatchling keeps the count only")
    }

    /// A save from before the cap (a count with no day) still gets today's two.
    func testAnEggPrayedOverBeforeTheCapGetsTwoMoreToday() async {
        let store = egg(record: "{\"count\":7}")
        XCTAssertTrue(store.pray())
        XCTAssertTrue(store.pray())
        XCTAssertFalse(store.pray())
        XCTAssertEqual(store.state.eggPrayers?.count, 9)
    }

    /// The cap survives a restart: the day and its count are in the save.
    func testTheDaysCountIsSaved() async throws {
        let store = egg()
        store.pray(); store.pray()
        let data = try JSONEncoder().encode(store.state)
        let state = try JSONDecoder().decode(CompanionState.self, from: data)
        XCTAssertEqual(state.eggPrayers, store.state.eggPrayers)
        XCTAssertEqual(state.eggPrayers?.today, 2)
        XCTAssertEqual(state.eggPrayers?.counted(on: state.eggPrayers?.day ?? ""), 2)
        XCTAssertEqual(state.eggPrayers?.counted(on: "1999-01-01"), 0)
    }

    func testAHatchedPokemonHasNothingToPray() async {
        let store = egg(record: "{\"count\":10}")
        await store.hatchIfNeeded()
        XCTAssertNotNil(store.state.active)
        XCTAssertFalse(store.pray())
        XCTAssertEqual(store.prayersLeftToday, 0)
        XCTAssertFalse(store.isPrayerDoneToday, "a hatched Pokémon shows no prayer line at all")
    }
}
