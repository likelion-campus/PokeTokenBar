import XCTest
@testable import PokeTokenBar

private struct StabilityOfflineProvider: PokeProviding {
    struct Unavailable: Error {}
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw Unavailable() }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw Unavailable() }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw Unavailable() }
}

/// The stability audit batch (shared logic): the token ledger across day keys, save volume, a newer save format,
/// candy window keys. Every test runs on temp directories and a private defaults suite.
@MainActor
final class AuditStabilityTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_700_000_000) }
    private let clock = Clock()

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-stability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("companion-state.json")
    }

    private func makeStore(_ url: URL) -> CompanionStore {
        let clock = self.clock
        return CompanionStore(provider: StabilityOfflineProvider(), clock: { clock.now }, fileURL: url,
                              defaults: TestDefaults.make(suite: "stability-\(UUID().uuidString)"))
    }

    private func use(_ s: CompanionStore, _ map: [String: Int], date: String) {
        s.update(todayTokensByProvider: map, todayDate: date, monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
    }

    // MARK: 4. the ledger credits a day once

    func testGoingBackToAnUnseenDayCreditsNothingAndComingBackCreditsOnlyTheDifference() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "2026-11-25")
        use(s, ["codex": 400], date: "2026-11-25")
        XCTAssertEqual(s.state.usedSinceInstall, 400)

        // Time zone travel: the same usage now sits under the previous day key.
        use(s, ["codex": 900], date: "2026-11-24")
        XCTAssertEqual(s.state.usedSinceInstall, 400, "a day key that moves backwards is not a new day")
        // Back home: 150 more tokens since the first visit.
        use(s, ["codex": 550], date: "2026-11-25")
        XCTAssertEqual(s.state.usedSinceInstall, 550, "only the 150 that are new on that day")
    }

    func testFlippingTheClockBackAndForthDoesNotMintTokens() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "d2")
        use(s, ["codex": 300], date: "d2")
        use(s, ["codex": 100], date: "d3")   // a real rollover: credited in full once
        XCTAssertEqual(s.state.usedSinceInstall, 400)
        for _ in 0..<5 {
            use(s, ["codex": 300], date: "d2")
            use(s, ["codex": 100], date: "d3")
        }
        XCTAssertEqual(s.state.usedSinceInstall, 400, "each flip used to credit a whole day again")
    }

    func testReturningToAKnownDayCreditsTheUsageThatCameInBetween() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        use(s, ["codex": 30], date: "d2")
        XCTAssertEqual(s.state.usedSinceInstall, 130)
        use(s, ["codex": 130], date: "d1")   // 30 more were used on d1 (say, in another time zone's evening)
        XCTAssertEqual(s.state.usedSinceInstall, 160)
    }

    func testForwardRolloverStillCreditsTheWholeNewDay() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 200], date: "d1")
        use(s, ["codex": 100], date: "d2")
        XCTAssertEqual(s.state.usedSinceInstall, 300)
    }

    func testDayLedgersKeepOnlyTheLastFewDays() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "d00")
        for day in 1...12 { use(s, ["codex": 10], date: String(format: "d%02d", day)) }
        XCTAssertLessThanOrEqual(s.state.dayLedgers?.count ?? 0, 7)
    }

    func testSaveWithDayLedgersRoundTripsAndOlderSavesAndUnknownKeysStillLoad() async throws {
        var state = CompanionState()
        state.dayLedgers = ["d1": ["codex": 5]]
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: data).dayLedgers, ["d1": ["codex": 5]])

        // A save from before this field: no dayLedgers, no formatVersion, plus a key a future build might add.
        let old = Data(#"{"usedSinceInstall":42,"someFutureKey":{"a":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(CompanionState.self, from: old)
        XCTAssertEqual(decoded.usedSinceInstall, 42)
        XCTAssertNil(decoded.dayLedgers)
        XCTAssertEqual(decoded.formatVersion, CompanionState.currentFormatVersion)
    }

    // MARK: 2. update() writes only what changed

    func testUpdateWithNothingNewDoesNotRewriteTheSave() async throws {
        let url = tempURL()
        let s = makeStore(url)
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: url)

        use(s, ["codex": 100], date: "d1")   // the next poll: same numbers
        XCTAssertEqual(try Data(contentsOf: url), sentinel, "an unchanged poll rewrote the whole save")

        use(s, ["codex": 150], date: "d1")   // tokens moved: must be written
        XCTAssertNotEqual(try Data(contentsOf: url), sentinel)
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url)).usedSinceInstall, 150)
    }

    func testAChangedDayKeyIsWritten() async throws {
        let url = tempURL()
        let s = makeStore(url)
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        try Data("sentinel".utf8).write(to: url)
        use(s, ["codex": 100], date: "d0")   // backwards, nothing credited, but the key and the archive changed
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url)).lastDate, "d0")
    }

    func testAnIdleSaveStillHappensAfterTheInterval() async throws {
        let url = tempURL()
        let s = makeStore(url)
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: url)
        clock.now.addTimeInterval(601)
        use(s, ["codex": 100], date: "d1")
        XCTAssertNotEqual(try Data(contentsOf: url), sentinel, "a forgotten save path may lose minutes, not everything")
    }

    func testFlushWritesTheCurrentState() async throws {
        let url = tempURL()
        let s = makeStore(url)
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        try Data("sentinel".utf8).write(to: url)
        s.flush()
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url)).usedSinceInstall, 100)
    }

    // MARK: 8. a newer save is not overwritten

    func testSaveFromANewerFormatIsLeftAloneAndNotSnapshotted() async throws {
        let url = tempURL()
        var state = CompanionState()
        state.usedSinceInstall = 777
        state.formatVersion = CompanionState.currentFormatVersion + 1
        let original = try JSONEncoder().encode(state)
        try original.write(to: url)

        let s = makeStore(url)
        XCTAssertTrue(s.persistenceBlocked)
        XCTAssertEqual(s.state.usedSinceInstall, 777, "the in-memory state still runs")
        s.receivePlazaItem(.rareCandy)
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        s.flush()
        XCTAssertEqual(try Data(contentsOf: url), original, "a downgraded build must not rewrite the newer file")
        XCTAssertThrowsError(try s.createManualSnapshot(), "a lossy snapshot would push out the newer build's own")
    }

    func testCurrentAndMarkerlessSavesLoadAndWriteTheMarker() async throws {
        let url = tempURL()
        try Data(#"{"usedSinceInstall":5}"#.utf8).write(to: url)   // before the marker existed
        let s = makeStore(url)
        XCTAssertFalse(s.persistenceBlocked)
        s.receivePlazaItem(.rareCandy)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, CompanionState.currentFormatVersion)
    }

    // MARK: 7. a window key names one window

    func testWindowsSharingAKeyNeverGrantAndNeverTouchTheTier() async {
        let a = CandyWindow(key: "antigravity.gemini.5h", name: "A", kind: .session, utilization: 100)
        let b = CandyWindow(key: "antigravity.gemini.5h", name: "B", kind: .session, utilization: 40)
        var tier: [String: Int] = [:], epoch: [String: String] = [:]
        for _ in 0..<3 {
            XCTAssertTrue(CompanionStore.evaluateCandyGrants(windows: [a, b], grantTier: &tier, windowEpoch: &epoch).isEmpty)
        }
        XCTAssertTrue(tier.isEmpty)
        // Distinct keys still grant exactly once.
        let c = CandyWindow(key: "antigravity.gemini.5h#2", name: "B", kind: .session, utilization: 40)
        XCTAssertEqual(CompanionStore.evaluateCandyGrants(windows: [a, c], grantTier: &tier, windowEpoch: &epoch).count, 1)
        XCTAssertTrue(CompanionStore.evaluateCandyGrants(windows: [a, c], grantTier: &tier, windowEpoch: &epoch).isEmpty)
    }

    func testUniquelyKeyedKeepsTheFirstKeyAndNumbersTheRest() async {
        let ws = [("a", 100.0), ("a", 10.0), ("b", 5.0), ("a", 0.0)].map {
            CandyWindow(key: $0.0, name: "n", kind: .weekly, utilization: $0.1)
        }
        XCTAssertEqual(CandyWindow.uniquelyKeyed(ws).map(\.key), ["a", "a#2", "b", "a#3"])
        XCTAssertEqual(CandyWindow.uniquelyKeyed(ws).map(\.utilization), [100, 10, 5, 0])
    }
}
