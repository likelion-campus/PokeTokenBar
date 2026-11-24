import XCTest
@testable import PokeTokenBar

// MARK: 기도로 부화하는 건 하루 한 번 — 기도 자체는 막지 않는다 (2026-11-24).

private struct LineFailsProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class EggPrayerCapTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let line = EvoLine(
        baseID: 1,
        tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [])]),
        rarity: .common,
        names: [1: ["en": "P1"], 2: ["en": "P2"]])

    private func key(_ date: Date) -> String { DayBoundary.dayKey(date, calendar: .current) }
    private var today: String { key(now) }
    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    /// An egg with `tokens` gathered, `record` (raw JSON) as its prayers and `usedOn` as the day of the last prayer hatch.
    private func egg(record: String? = nil, tokens: Int = 0, usedOn: String? = nil,
                     provider: PokeProviding? = nil) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prayer-cap-\(UUID().uuidString).json")
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":5000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"dex\":[],\"collectedFinals\":[],\"eggUsage\":\(tokens),\"pendingHatchID\":1"
            + (record.map { ",\"eggPrayers\":\($0)" } ?? "")
            + (usedOn.map { ",\"lastPrayerHatchDay\":\"\($0)\"" } ?? "") + "}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: provider ?? StubProvider(value: line), clock: { self.now }, fileURL: url,
                              rng: SeededRNG(seed: 7))
    }

    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        return condition()
    }

    private func refresh(_ store: CompanionStore) {
        store.update(todayTokensByProvider: [:], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: false)
    }

    func testTenPrayersInOneDayHatchTheEgg() async {
        XCTAssertEqual(PokemonBalance.prayerHatchesPerDay, 1)
        let store = egg()
        for _ in 0..<10 { store.pray() }
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 10))
        XCTAssertEqual(store.state.lastPrayerHatchDay, today, "the hatch used the day's prayer hatch")
    }

    /// Prayers are never refused: past the day's prayer hatch the count keeps rising and the egg stays an egg.
    func testThirtyPrayersAfterTheDaysPrayerHatchCountAndDoNotHatch() async {
        let store = egg(usedOn: today)
        for _ in 0..<30 { store.pray() }
        await store.hatchIfNeeded()
        XCTAssertNil(store.state.active)
        XCTAssertEqual(store.state.eggPrayers?.count, 30, "the 30-prayer quips stay reachable")
        XCTAssertTrue(store.isPrayerHatchUsedToday)
    }

    func testTheEggHatchesOnTheNextDayAfterARefreshWithoutAPrayer() async {
        let store = egg(record: "{\"count\":30}", usedOn: today)
        refresh(store)
        _ = await settled { store.state.active != nil }
        XCTAssertNil(store.state.active, "same day: still waiting")
        now = day(1)
        refresh(store)
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 30))
        XCTAssertEqual(store.state.lastPrayerHatchDay, key(now))
    }

    func testTheEggHatchesOnTheNextDaysPrayer() async {
        let store = egg(record: "{\"count\":12}", usedOn: today)
        now = day(1)
        store.pray()
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 13))
    }

    /// A date set back is another date key too: it starts the day again, like the plaza trees.
    func testADateSetBackAlsoStartsANewDay() async {
        let store = egg(record: "{\"count\":12}", usedOn: key(day(3)))
        XCTAssertTrue(store.isPrayerHatchUsedToday == false)
        await store.hatchIfNeeded()
        XCTAssertNotNil(store.state.active)
    }

    /// A hatch the tokens reached does not use the day's prayer hatch, even with ten prayers on the egg.
    func testATokenHatchDoesNotUseTheDaysPrayerHatch() async {
        let store = egg(record: "{\"count\":10}", tokens: PokemonBalance.eggHatchThreshold)
        await store.hatchIfNeeded()
        XCTAssertNotNil(store.state.active)
        XCTAssertNil(store.state.lastPrayerHatchDay)
        XCTAssertTrue(store.buyFreshEgg())
        for _ in 0..<10 { store.pray() }
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched, "a later egg still hatches by prayer the same day")
        XCTAssertEqual(store.state.lastPrayerHatchDay, today)
    }

    /// The day is only recorded when the hatch really happens: a failed hatch keeps it free.
    /// Hatch by prayer, buy an egg the same day: ten prayers leave it an egg; the next day's refresh hatches it, no tokens.
    func testABoughtEggWaitsForTheNextDayAfterThePrayerHatch() async {
        let store = egg()
        for _ in 0..<10 { store.pray() }
        _ = await settled { store.state.active != nil }
        XCTAssertNotNil(store.state.active)
        XCTAssertTrue(store.buyFreshEgg())
        for _ in 0..<10 { store.pray() }
        await store.hatchIfNeeded()
        XCTAssertNil(store.state.active)
        XCTAssertEqual(store.state.eggPrayers?.count, 10)
        now = day(1)
        refresh(store)
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 10))
    }

    func testAFailedHatchDoesNotBurnTheDay() async {
        let store = egg(provider: LineFailsProvider())
        for _ in 0..<10 { store.pray() }
        await store.hatchIfNeeded()
        XCTAssertNil(store.state.active)
        XCTAssertNil(store.state.lastPrayerHatchDay)
        XCTAssertFalse(store.isPrayerHatchUsedToday)
    }

    /// A save from v2.5.640 carries `day` and `today` on its prayers: it loads and `count` continues as the total.
    func testASaveFromV25640LoadsAndTakesPrayersFreely() async {
        let store = egg(record: "{\"count\":4,\"day\":\"\(today)\",\"today\":2}")
        XCTAssertEqual(store.state.eggPrayers, PrayerRecord(count: 4))
        for _ in 0..<5 { store.pray() }
        XCTAssertEqual(store.state.eggPrayers?.count, 9, "no daily cap on prayers")
        store.pray()
        let hatched = await settled { store.state.active != nil }
        XCTAssertTrue(hatched)
    }

    /// What this version writes must load in v2.5.640, which ignores unknown keys: the record keeps only `count`.
    func testThePrayerRecordWritesOnlyTheCount() async throws {
        let data = try JSONEncoder().encode(PrayerRecord(count: 3))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["count"])
    }

    func testTheDayOfThePrayerHatchSurvivesARestart() async throws {
        var state = CompanionState()
        state.lastPrayerHatchDay = "2026-11-24"
        let back = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.lastPrayerHatchDay, "2026-11-24")
        XCTAssertNil(try JSONDecoder().decode(CompanionState.self, from: Data("{}".utf8)).lastPrayerHatchDay, "an old save has none")
    }

    func testAHatchedPokemonHasNothingToPray() async {
        let store = egg(record: "{\"count\":10}", usedOn: today)
        now = day(1)
        await store.hatchIfNeeded()
        XCTAssertNotNil(store.state.active)
        store.pray()
        XCTAssertNil(store.state.eggPrayers)
        XCTAssertFalse(store.isPrayerHatchUsedToday, "a hatched Pokémon shows no prayer line at all")
    }

    func testTheUsedLineIsOnlyForAnEggWhoseDayIsUsed() async {
        XCTAssertFalse(egg().isPrayerHatchUsedToday)
        XCTAssertTrue(egg(usedOn: today).isPrayerHatchUsedToday)
        XCTAssertFalse(egg(usedOn: key(day(-1))).isPrayerHatchUsedToday)
        let l = L(.ko)
        XCTAssertEqual(l.plazaPrayHint(prayers: 4, hatchUsed: true),
                       "A를 눌러 기도하기 · 오늘은 기도로 이미 부화시켰어요 · 내일 다시 기도로 부화할 수 있어요 · 기도 4번")
        XCTAssertEqual(l.plazaPrayHint(prayers: 0, hatchUsed: true),
                       "A를 눌러 기도하기 · 오늘은 기도로 이미 부화시켰어요 · 내일 다시 기도로 부화할 수 있어요")
        XCTAssertEqual(l.plazaPrayedHint(prayers: 4, hatchUsed: false), "기도 4번")
        XCTAssertEqual(l.plazaPrayHint(prayers: 4), "A를 눌러 기도하기 · 기도 4번")
    }
}
