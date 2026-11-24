import XCTest
@testable import PokeTokenBar

private enum AuditStubError: Error { case unavailable }

private struct AuditOfflineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw AuditStubError.unavailable }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw AuditStubError.unavailable }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw AuditStubError.unavailable }
}

/// Regression tests for the local-file audit batch (core). Every test runs on temp directories only.
@MainActor
final class AuditCoreFixesTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs {
            // Restore permissions a test may have removed so the cleanup can run.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path)
            try? FileManager.default.removeItem(at: d)
        }
        dirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-audit-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func sampleState(tokens: Int) -> CompanionState {
        var s = CompanionState()
        s.installBaselineSet = true
        s.usedSinceInstall = tokens
        s.active = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1], stageIndex: 0, usedAtStage: 500, rarity: .common, totalForms: 1)
        return s
    }

    // MARK: 1. saturating token sums

    func testSaturatingAddClampsInsteadOfTrapping() {
        XCTAssertEqual(Int.max.saturatingAdding(1), Int.max)
        XCTAssertEqual(Int.min.saturatingAdding(-1), Int.min)
        XCTAssertEqual([Int.max, Int.max, 5].saturatingSum(), Int.max)
        XCTAssertEqual([1, 2, 3].saturatingSum(), 6)
    }

    func testBucketAddAndTotalSaturate() {
        var bucket = LocalUsageReader.Bucket()
        let entry = LocalUsageReader.Entry(id: "x", date: baseNow, localDay: "2023-11-14", model: "m",
                                           input: Int.max, output: Int.max, cacheWrite: Int.max, cacheRead: Int.max)
        bucket.add(entry)
        bucket.add(entry)   // second add of Int.max trapped before
        XCTAssertEqual(bucket.input, Int.max)
        XCTAssertEqual(bucket.total, Int.max)
    }

    func testPerEntryCeilingLeavesRoomForManyEntries() {
        // 4 buckets x 1e8 entries must still fit in Int64 (the old 1e15 ceiling overflowed after 2,306 entries).
        XCTAssertLessThan(LocalUsageReader.maxParsedTokenValue, Int.max / 4 / 100_000_000)
    }

    // MARK: 2. numeric timestamps

    func testPlausibleDateRejectsValuesOutsideTheWindow() {
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 1e300))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: .infinity))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: .nan))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 5))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 1_700_000_000_000), "milliseconds read as seconds")
        XCTAssertEqual(LocalUsageReader.plausibleDate(epochSeconds: 1_700_000_000)?.timeIntervalSince1970, 1_700_000_000)
    }

    func testKimiRecordWithAbsurdTimeIsSkippedNotTrapped() throws {
        let dir = tempDir("kimi")
        let file = dir.appendingPathComponent("wire.jsonl")
        let good = #"{"type":"usage.record","time":1700000000000,"usage":{"inputOther":5,"output":2},"usageScope":"turn"}"#
        let huge = #"{"type":"usage.record","time":1e300,"usage":{"inputOther":5,"output":2},"usageScope":"turn"}"#
        try (huge + "\n" + good + "\n").write(to: file, atomically: true, encoding: .utf8)
        let entries = try XCTUnwrap(LocalUsageReader.parseKimiWireFile(file, fmt: LocalUsageReader.localDayFormatter()))
        XCTAssertEqual(entries.count, 1, "the 1e300 record is dropped, the real one stays")
        XCTAssertEqual(entries.first?.input, 5)
    }

    func testActiveBlockIdDoesNotTrapOnAnExtremeDate() {
        let far = Date(timeIntervalSince1970: 1e300)
        let entry = LocalUsageReader.Entry(id: "x", date: far, localDay: "x", model: "m",
                                           input: 1, output: 1, cacheWrite: 0, cacheRead: 0)
        let block = LocalUsageReader.activeBlock(entries: [entry], now: far)
        XCTAssertEqual(block?.id, "block-0")
    }

    // MARK: 3. a save that exists but cannot be read is not replaced

    func testUnreadableSaveBlocksPersistenceAndIsLeftAlone() async throws {
        let dir = tempDir("unreadable")
        let url = dir.appendingPathComponent("companion-state.json")
        let original = try JSONEncoder().encode(sampleState(tokens: 12_345))
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "permissions are not enforced here (root)")

        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertTrue(store.persistenceBlocked)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        store.receivePlazaItem(.rareCandy)   // would save() over the real file
        XCTAssertEqual(try Data(contentsOf: url), original, "the unreadable save must survive the session untouched")
    }

    func testMissingSaveIsAFreshInstallAndStillSaves() async throws {
        let url = tempDir("missing").appendingPathComponent("companion-state.json")
        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertFalse(store.persistenceBlocked)
        store.receivePlazaItem(.rareCandy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptSaveThatCannotBeMovedAsideBlocksPersistence() async throws {
        let dir = tempDir("corrupt-move")
        let url = dir.appendingPathComponent("companion-state.json")
        try Data("{ not json".utf8).write(to: url)
        // A read-only directory: the original can be read but not renamed to `.corrupt`.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "permissions are not enforced here (root)")

        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertTrue(store.persistenceBlocked)
    }

    // MARK: 5. inventory counts

    func testSanitizedClampsInventoryCounts() {
        var s = CompanionState()
        s.inventory[ItemKind.rareCandy.rawValue] = Int.max
        s.inventory[ItemKind.mint.rawValue] = 3
        let clean = SaveTransfer.sanitized(s)
        XCTAssertEqual(clean.inventory[ItemKind.rareCandy.rawValue], SaveTransfer.maxTokenValue)
        XCTAssertEqual(clean.inventory[ItemKind.mint.rawValue], 3, "ordinary counts and entries are kept")
    }

    // MARK: 6. snapshot legacy fallback, recovery skips undecodable envelopes

    func testEnvelopeThatFailsDecodeIsNotReadAsAnEmptyLegacyState() throws {
        let stateURL = tempDir("envelope").appendingPathComponent("companion-state.json")
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 777), for: stateURL, date: baseNow.addingTimeInterval(-3600))
        let dir = SaveSnapshotManager.snapshotsDirectory(for: stateURL)
        // Newer file claiming to be an envelope (has `format`) that `SaveTransfer.decode` rejects.
        let bad = dir.appendingPathComponent(SaveSnapshotManager.snapshotFileName(date: baseNow))
        try Data(#"{"format":"ptb-save-from-the-future","schemaVersion":99}"#.utf8).write(to: bad)
        // Older raw legacy state (no `format`) is still recognised.
        let legacy = dir.appendingPathComponent(SaveSnapshotManager.snapshotFileName(date: baseNow.addingTimeInterval(-7200)))
        try JSONEncoder().encode(sampleState(tokens: 555)).write(to: legacy)

        XCTAssertEqual(SaveSnapshotManager.listSnapshots(for: stateURL).count, 2, "the undecodable envelope is not listed")
        let recovered = SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)
        XCTAssertEqual(recovered?.usedSinceInstall, 777)
    }

    // MARK: 7. a snapshot dated in the future

    func testRecoveryDoesNotPreferAFutureDatedSnapshot() throws {
        let stateURL = tempDir("future-recover").appendingPathComponent("companion-state.json")
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 100), for: stateURL, date: baseNow.addingTimeInterval(-3600))
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 200), for: stateURL, date: baseNow.addingTimeInterval(86_400 * 30))
        XCTAssertEqual(SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)?.usedSinceInstall, 100)
        // Only a future one left: still better than nothing.
        for s in SaveSnapshotManager.listSnapshots(for: stateURL) where s.date <= baseNow {
            try FileManager.default.removeItem(at: s.fileURL)
        }
        XCTAssertEqual(SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)?.usedSinceInstall, 200)
    }

    func testFutureDatedNewestSnapshotDoesNotStopAutomaticSnapshots() async throws {
        let url = tempDir("future-auto").appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(sampleState(tokens: 5)).write(to: url)
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 5), for: url, date: baseNow.addingTimeInterval(86_400 * 30))
        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertEqual(store.availableSnapshots.count, 1)
        store.autoSnapshotIfNeeded()
        XCTAssertEqual(store.availableSnapshots.count, 2, "no real-dated snapshot exists, so one is taken now")
    }

    // MARK: 4. only plain log files are read

    func testJsonlScanSkipsSymlinksAndKeepsRegularFiles() throws {
        let dir = tempDir("symlink")
        let regular = dir.appendingPathComponent("real.jsonl")
        try Data("{}\n".utf8).write(to: regular)
        let link = dir.appendingPathComponent("y.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let files = LocalUsageReader.jsonlFiles(in: dir, modifiedSince: .distantPast).map(\.lastPathComponent)
        XCTAssertEqual(files, ["real.jsonl"])
    }

    func testOpenLogHandleRefusesASymlinkEvenToARegularFile() throws {
        #if !os(Windows)
        let dir = tempDir("nofollow")
        let target = dir.appendingPathComponent("target.jsonl")
        try Data("{}\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNoThrow(try LocalUsageReader.openLogHandle(target).close())
        XCTAssertThrowsError(try LocalUsageReader.openLogHandle(link))
        XCTAssertNil(LocalUsageReader.parseClaudeFile(link, fromOffset: 0, fmt: LocalUsageReader.localDayFormatter()))
        #endif
    }

    // MARK: 8. chunked readers

    func testKimiReaderHandlesLinesLargerThanOneChunk() throws {
        let file = tempDir("chunk").appendingPathComponent("wire.jsonl")
        let pad = String(repeating: "x", count: 1_500_000)   // > the 1 MiB read chunk
        let big = #"{"type":"message","pad":"\#(pad)","note":"usage.record"}"#
        let a = #"{"type":"usage.record","time":1700000000000,"usage":{"inputOther":1,"output":1},"usageScope":"turn"}"#
        let b = #"{"type":"usage.record","time":1700000001000,"usage":{"inputOther":2,"output":2},"usageScope":"turn"}"#
        try (a + "\n" + big + "\n" + b).write(to: file, atomically: true, encoding: .utf8)   // no trailing newline
        let entries = try XCTUnwrap(LocalUsageReader.parseKimiWireFile(file, fmt: LocalUsageReader.localDayFormatter()))
        XCTAssertEqual(entries.map(\.input).sorted(), [1, 2])
    }

    // MARK: 10. refresh interval

    func testRefreshIntervalIsClamped() {
        XCTAssertEqual(UsageStore.clampedRefreshInterval(nil), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(0), 0, "manual stays manual")
        XCTAssertEqual(UsageStore.clampedRefreshInterval(0.01), 30)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(300), 300)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(1e9), 3600)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(-5), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(.nan), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(.infinity), 120)
    }

    func testStoredTinyRefreshIntervalIsClampedAtLoad() {
        let defaults = TestDefaults.make(suite: "ptb.test.audit.interval.\(UUID().uuidString)")
        defaults.set(0.01, forKey: "refreshInterval")
        let store = makeHermeticUsageStore(providers: [], defaults: defaults)
        XCTAssertEqual(store.refreshInterval, UsageStore.minimumRefreshInterval)
    }
}
