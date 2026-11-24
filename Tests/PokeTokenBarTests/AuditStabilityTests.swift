import XCTest
import Observation
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

    // MARK: save format

    func testSaveRoundTripsTheMarkerAndOlderSavesAndUnknownKeysStillLoad() async throws {
        var state = CompanionState()
        state.usedSinceInstall = 5
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: data).formatVersion,
                       CompanionState.currentFormatVersion)

        // A save from before the marker, plus a key a future build might add: both load.
        let old = Data(#"{"usedSinceInstall":42,"someFutureKey":{"a":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(CompanionState.self, from: old)
        XCTAssertEqual(decoded.usedSinceInstall, 42)
        XCTAssertEqual(decoded.formatVersion, 0, "read as found; the store writes its own on the next save")
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
        use(s, ["codex": 100], date: "d0")   // the day key changed (a rollover credits the day, as before)
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

    // MARK: 8. a newer save is kept aside once, then saving goes on

    private func newerFile(_ url: URL, marker: Int) throws -> Data {
        var state = CompanionState()
        state.usedSinceInstall = 777
        state.formatVersion = marker
        let data = try JSONEncoder().encode(state)
        try data.write(to: url)
        return data
    }

    func testSaveFromANewerFormatIsCopiedAsideOnceAndSavingContinues() async throws {
        let url = tempURL()
        let newer = CompanionState.currentFormatVersion + 1
        let original = try newerFile(url, marker: newer)
        let copy = url.deletingLastPathComponent().appendingPathComponent("companion-state.newer-\(newer).json")

        let s = makeStore(url)
        XCTAssertFalse(s.persistenceBlocked, "a downgrade must keep earning and saving")
        XCTAssertEqual(s.state.usedSinceInstall, 777)
        XCTAssertEqual(try Data(contentsOf: copy), original, "the newer file, byte for byte")

        s.receivePlazaItem(.rareCandy)
        let saved = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.formatVersion, CompanionState.currentFormatVersion, "this build writes its own marker")
        XCTAssertNoThrow(try s.createManualSnapshot())

        // The next launch reads this build's own marker: no new copy, the first copy untouched.
        try FileManager.default.removeItem(at: copy)
        _ = makeStore(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "its own save is never judged newer")
    }

    func testAnExistingCopyIsNeverOverwritten() async throws {
        let url = tempURL()
        let newer = CompanionState.currentFormatVersion + 1
        _ = try newerFile(url, marker: newer)
        let copy = url.deletingLastPathComponent().appendingPathComponent("companion-state.newer-\(newer).json")
        try Data("the first copy".utf8).write(to: copy)
        _ = makeStore(url)
        XCTAssertEqual(try Data(contentsOf: copy), Data("the first copy".utf8))
    }

    func testOwnAndMarkerlessSavesMakeNoCopyAndGetTheMarker() async throws {
        let url = tempURL()
        try Data(#"{"usedSinceInstall":5}"#.utf8).write(to: url)   // before the marker existed
        let s = makeStore(url)
        XCTAssertFalse(s.persistenceBlocked)
        s.receivePlazaItem(.rareCandy)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, CompanionState.currentFormatVersion)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.contains("newer") })
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

    func testUniquelyKeyedNumbersCollidersWithoutAnIdentityByPosition() async {
        let ws = [("a", 100.0), ("a", 10.0), ("b", 5.0), ("a", 0.0)].map {
            CandyWindow(key: $0.0, name: "n", kind: .weekly, utilization: $0.1)
        }
        XCTAssertEqual(CandyWindow.uniquelyKeyed(ws).map(\.key), ["a", "a#2", "b", "a#3"])
        XCTAssertEqual(CandyWindow.uniquelyKeyed(ws).map(\.utilization), [100, 10, 5, 0])
    }

    /// The window that keeps the plain key is chosen by the provider's own id, not by the order it listed them in,
    /// so a saved tier on the plain key stays with the same window when the order changes.
    func testUniquelyKeyedKeysByIdentityWhateverTheOrder() async {
        func window(_ id: String, _ utilization: Double) -> CandyWindow {
            CandyWindow(key: "antigravity.gemini.5h", name: id, kind: .session, utilization: utilization, identity: id)
        }
        let a = CandyWindow.uniquelyKeyed([window("g-2", 100), window("g-1", 40)])
        let b = CandyWindow.uniquelyKeyed([window("g-1", 40), window("g-2", 100)])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: a.map { ($0.name, $0.key) }),
                       Dictionary(uniqueKeysWithValues: b.map { ($0.name, $0.key) }))
        XCTAssertEqual(a.first { $0.name == "g-1" }?.key, "antigravity.gemini.5h")
        XCTAssertEqual(a.first { $0.name == "g-2" }?.key, "antigravity.gemini.5h#g-2")
    }

    func testAPersistedPlainKeyKeepsItsTierWhenNothingCollides() async {
        let w = CandyWindow(key: "codex.pro.primary", name: "n", kind: .session, utilization: 100, identity: "pro")
        XCTAssertEqual(CandyWindow.uniquelyKeyed([w]).map(\.key), ["codex.pro.primary"])
        var tier = ["codex.pro.primary": 1], epoch: [String: String] = [:]
        XCTAssertTrue(CompanionStore.evaluateCandyGrants(windows: CandyWindow.uniquelyKeyed([w]),
                                                         grantTier: &tier, windowEpoch: &epoch).isEmpty,
                      "already granted before the upgrade: no second grant")
    }

    // MARK: update() does not fire observers for equal values

    func testAnUnchangedPollDoesNotFireTheStoreObservers() async {
        let s = makeStore(tempURL())
        use(s, ["codex": 0], date: "d1")
        use(s, ["codex": 100], date: "d1")
        final class Fired: @unchecked Sendable { var n = 0 }
        let fired = Fired()
        withObservationTracking({
            _ = s.state
            _ = s.displayState
            _ = s.sulkIdle
        }, onChange: { fired.n += 1 })
        use(s, ["codex": 100], date: "d1")
        XCTAssertEqual(fired.n, 0, "equal writes still fire @Observable and re-show the floating pet each poll")
    }
}
