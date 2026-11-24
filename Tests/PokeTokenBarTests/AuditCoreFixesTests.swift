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

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-audit-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            // Restore permissions a test may have removed so the cleanup can run.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    /// Symlink creation needs a privilege on Windows; skip there when it is missing.
    private func makeLink(_ link: URL, to target: URL) throws {
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) } catch {
            throw XCTSkip("no symbolic link privilege: \(error)")
        }
    }

    private func claudeLine(id: String, output: Int = 7) -> String {
        #"{"type":"assistant","requestId":"r-\#(id)","timestamp":"2026-07-02T01:00:00.000Z","message":{"id":"m-\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":\#(output),"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#
    }

    private func sampleState(tokens: Int) -> CompanionState {
        var s = CompanionState()
        s.installBaselineSet = true
        s.usedSinceInstall = tokens
        s.active = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1], stageIndex: 0, usedAtStage: 500, rarity: .common, totalForms: 1)
        return s
    }

    // MARK: 1. saturating token sums

    func testSaturatingAddClampsInsteadOfTrapping() async {
        XCTAssertEqual(Int.max.saturatingAdding(1), Int.max)
        XCTAssertEqual(Int.min.saturatingAdding(-1), Int.min)
        XCTAssertEqual([Int.max, Int.max, 5].saturatingSum(), Int.max)
        XCTAssertEqual([1, 2, 3].saturatingSum(), 6)
    }

    func testBucketAddAndTotalSaturate() async {
        var bucket = LocalUsageReader.Bucket()
        let entry = LocalUsageReader.Entry(id: "x", date: baseNow, localDay: "2023-11-14", model: "m",
                                           input: Int.max, output: Int.max, cacheWrite: Int.max, cacheRead: Int.max)
        bucket.add(entry)
        bucket.add(entry)   // second add of Int.max trapped before
        XCTAssertEqual(bucket.input, Int.max)
        XCTAssertEqual(bucket.total, Int.max)
    }

    func testPerEntryCeilingLeavesRoomForManyEntries() async {
        // 4 buckets x 1e8 entries must still fit in Int64 (the old 1e15 ceiling overflowed after 2,306 entries).
        XCTAssertLessThan(LocalUsageReader.maxParsedTokenValue, Int.max / 4 / 100_000_000)
    }

    // MARK: 2. numeric timestamps

    func testPlausibleDateRejectsValuesOutsideTheWindow() async {
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 1e300))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: .infinity))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: .nan))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 5))
        XCTAssertNil(LocalUsageReader.plausibleDate(epochSeconds: 1_700_000_000_000), "milliseconds read as seconds")
        XCTAssertEqual(LocalUsageReader.plausibleDate(epochSeconds: 1_700_000_000)?.timeIntervalSince1970, 1_700_000_000)
    }

    func testKimiRecordWithAbsurdTimeIsSkippedNotTrapped() async throws {
        let dir = tempDir("kimi")
        let file = dir.appendingPathComponent("wire.jsonl")
        let good = #"{"type":"usage.record","time":1700000000000,"usage":{"inputOther":5,"output":2},"usageScope":"turn"}"#
        let huge = #"{"type":"usage.record","time":1e300,"usage":{"inputOther":5,"output":2},"usageScope":"turn"}"#
        try (huge + "\n" + good + "\n").write(to: file, atomically: true, encoding: .utf8)
        let entries = try XCTUnwrap(LocalUsageReader.parseKimiWireFile(file, fmt: LocalUsageReader.localDayFormatter()))
        XCTAssertEqual(entries.count, 1, "the 1e300 record is dropped, the real one stays")
        XCTAssertEqual(entries.first?.input, 5)
    }

    func testActiveBlockIdDoesNotTrapOnAnExtremeDate() async {
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

    func testCorruptSaveThatCannotBeMovedAsideIsLeftAloneAsAPlaceholder() async throws {
        let dir = tempDir("corrupt-move")
        let url = dir.appendingPathComponent("companion-state.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        // A read-only directory: the original can be read but not renamed to `.corrupt`.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "permissions are not enforced here (root)")

        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertTrue(store.persistenceBlocked)
        XCTAssertTrue(store.statePlaceholder, "nothing was recovered, so the state is the empty placeholder")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original must be untouched")
        XCTAssertThrowsError(try store.createManualSnapshot(), "a snapshot of the placeholder would push out real ones")
    }

    func testCorruptSaveRecoveredFromASnapshotKeepsSnapshotting() async throws {
        let dir = tempDir("corrupt-move-recovered")
        let url = dir.appendingPathComponent("companion-state.json")
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 4_321), for: url, date: baseNow.addingTimeInterval(-3600))
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "permissions are not enforced here (root)")

        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertTrue(store.persistenceBlocked)
        XCTAssertFalse(store.statePlaceholder, "the state came from a real snapshot")
        XCTAssertEqual(store.state.usedSinceInstall, 4_321)
        XCTAssertEqual(try Data(contentsOf: url), garbage)
        XCTAssertNoThrow(try store.createManualSnapshot())   // `.snapshots` is its own writable folder
    }

    func testUnreadableSaveIsAdoptedOnceItBecomesReadable() async throws {
        let dir = tempDir("adopt")
        let url = dir.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(sampleState(tokens: 12_345)).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "permissions are not enforced here (root)")

        let store = CompanionStore(provider: AuditOfflineProvider(), clock: { self.baseNow }, fileURL: url)
        XCTAssertTrue(store.statePlaceholder)
        XCTAssertThrowsError(try store.createManualSnapshot())
        func refresh() {
            store.update(todayTokensByProvider: [:], todayDate: "2026-01-01", monthTotal: 0,
                         burnTier: .idle, limitWarning: false, hasUsageData: false)
        }
        refresh()   // still unreadable: nothing changes
        XCTAssertTrue(store.persistenceBlocked)
        XCTAssertEqual(store.state.usedSinceInstall, 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        refresh()
        XCTAssertFalse(store.persistenceBlocked)
        XCTAssertFalse(store.statePlaceholder)
        XCTAssertEqual(store.state.usedSinceInstall, 12_345, "the real save is adopted, not replaced")
    }

    // MARK: 5. inventory counts

    func testSanitizedClampsInventoryCounts() async {
        var s = CompanionState()
        s.inventory[ItemKind.rareCandy.rawValue] = Int.max
        s.inventory[ItemKind.mint.rawValue] = 3
        let clean = SaveTransfer.sanitized(s)
        XCTAssertEqual(clean.inventory[ItemKind.rareCandy.rawValue], SaveTransfer.maxTokenValue)
        XCTAssertEqual(clean.inventory[ItemKind.mint.rawValue], 3, "ordinary counts and entries are kept")
    }

    // MARK: 6. snapshot legacy fallback, recovery skips undecodable envelopes

    func testEnvelopeThatFailsDecodeIsNotReadAsAnEmptyLegacyState() async throws {
        let stateURL = tempDir("envelope").appendingPathComponent("companion-state.json")
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 777), for: stateURL, date: baseNow.addingTimeInterval(-3600))
        let dir = SaveSnapshotManager.snapshotsDirectory(for: stateURL)
        // Newer file claiming to be an envelope (has `format`) that `SaveTransfer.decode` rejects.
        // The real trigger: the right format id with a newer `schema` (a downgrade, or an older Windows build).
        let bad = dir.appendingPathComponent(SaveSnapshotManager.snapshotFileName(date: baseNow))
        let valid = try SaveTransfer.encode(state: sampleState(tokens: 9_999), appVersion: "9.9.9", deviceName: "x", now: baseNow)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schema"] = SaveEnvelope.schemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: bad)
        XCTAssertThrowsError(try SaveTransfer.decode(try Data(contentsOf: bad)), "premise: decode rejects it")
        // Older raw legacy state (no `format`) is still recognised.
        let legacy = dir.appendingPathComponent(SaveSnapshotManager.snapshotFileName(date: baseNow.addingTimeInterval(-7200)))
        try JSONEncoder().encode(sampleState(tokens: 555)).write(to: legacy)

        XCTAssertEqual(SaveSnapshotManager.listSnapshots(for: stateURL).count, 2, "the undecodable envelope is not listed")
        let recovered = SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)
        XCTAssertEqual(recovered?.usedSinceInstall, 777)
    }

    // MARK: 7. a snapshot dated in the future

    func testRecoveryPicksTheSnapshotWithTheLatestProgressAcrossAFutureDate() throws {
        let stateURL = tempDir("future-recover").appendingPathComponent("companion-state.json")
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 100), for: stateURL, date: baseNow.addingTimeInterval(-3600))
        let future = baseNow.addingTimeInterval(86_400 * 30)
        // A future-dated snapshot with LESS progress does not beat the newest real one...
        let low = try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 50), for: stateURL, date: future)
        XCTAssertEqual(SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)?.usedSinceInstall, 100)
        // ...and one with MORE progress does (written while the clock ran ahead, the latest play).
        try FileManager.default.removeItem(at: low.fileURL)
        try SaveSnapshotManager.createSnapshot(state: sampleState(tokens: 200), for: stateURL, date: future)
        XCTAssertEqual(SaveSnapshotManager.loadLatestValidSnapshot(for: stateURL, now: baseNow)?.usedSinceInstall, 200)
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

    func testJsonlScanSkipsSymlinksAndKeepsRegularFiles() async throws {
        let dir = tempDir("symlink")
        let regular = dir.appendingPathComponent("real.jsonl")
        try Data("{}\n".utf8).write(to: regular)
        try makeLink(dir.appendingPathComponent("y.jsonl"), to: URL(fileURLWithPath: "/dev/zero"))
        let files = LocalUsageReader.jsonlFiles(in: dir, modifiedSince: .distantPast).map(\.lastPathComponent)
        XCTAssertEqual(files, ["real.jsonl"])
    }

    /// Production reads through `LocalUsageCache.collect` and `codexRolloutFiles`, not `jsonlFiles`: link to a
    /// regular file that holds real usage lines (outside the root) and expect none of it counted.
    func testCacheCollectAndCodexEnumerationDoNotFollowLinkedFiles() async throws {
        let outside = tempDir("outside")
        let target = outside.appendingPathComponent("usage.jsonl")
        try (claudeLine(id: "a") + "\n").write(to: target, atomically: true, encoding: .utf8)
        let root = tempDir("linkroot")
        let cacheFile = tempDir("linkcache").appendingPathComponent("cache.json")
        try makeLink(root.appendingPathComponent("linked.jsonl"), to: target)
        try makeLink(root.appendingPathComponent("rollout-x.jsonl"), to: target)

        let cache = LocalUsageCache(claudeRoot: root, fileURL: cacheFile)
        XCTAssertTrue(cache.claudeEntries(modifiedSince: .distantPast).isEmpty)
        XCTAssertTrue(LocalUsageReader.codexRolloutFiles(in: root).isEmpty)

        // The same line in a regular file is counted (the guard is not just "return nothing").
        try (claudeLine(id: "b") + "\n").write(to: root.appendingPathComponent("plain.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalUsageCache(claudeRoot: root, fileURL: cacheFile).claudeEntries(modifiedSince: .distantPast).count, 1)
    }

    /// A Claude file larger than the read cap is still fully counted: each refresh resumes where the last stopped.
    func testClaudeFileLargerThanTheReadCapIsFullyCountedAcrossRefreshes() async throws {
        let root = tempDir("cap")
        let lines = (0..<40).map { claudeLine(id: "n\($0)") }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let saved = LocalUsageReader.maxLogReadBytes
        LocalUsageReader.maxLogReadBytes = 1_000   // a few lines per read
        defer { LocalUsageReader.maxLogReadBytes = saved }

        let cache = LocalUsageCache(claudeRoot: root, fileURL: tempDir("capcache").appendingPathComponent("c.json"))
        var counts: [Int] = []
        for _ in 0..<60 {
            counts.append(cache.claudeEntries(modifiedSince: .distantPast).count)
            if counts.last == 40 { break }
        }
        XCTAssertEqual(counts.last, 40, "every line is counted eventually: \(counts)")
        XCTAssertGreaterThan(counts.count, 1, "premise: the cap really split the read")
    }

    func testOpenLogHandleRefusesASymlinkEvenToARegularFile() async throws {
        #if !os(Windows)
        let dir = tempDir("nofollow")
        let target = dir.appendingPathComponent("target.jsonl")
        try Data("{}\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.jsonl")
        try makeLink(link, to: target)
        XCTAssertNoThrow(try LocalUsageReader.openLogHandle(target).close())
        XCTAssertThrowsError(try LocalUsageReader.openLogHandle(link))
        XCTAssertNil(LocalUsageReader.parseClaudeFile(link, fromOffset: 0, fmt: LocalUsageReader.localDayFormatter()))
        #endif
    }

    // MARK: 8. chunked readers

    func testKimiReaderHandlesLinesLargerThanOneChunk() async throws {
        let file = tempDir("chunk").appendingPathComponent("wire.jsonl")
        let pad = String(repeating: "x", count: 1_500_000)   // > the 1 MiB read chunk
        let big = #"{"type":"message","pad":"\#(pad)","note":"usage.record"}"#
        let a = #"{"type":"usage.record","time":1700000000000,"usage":{"inputOther":1,"output":1},"usageScope":"turn"}"#
        let b = #"{"type":"usage.record","time":1700000001000,"usage":{"inputOther":2,"output":2},"usageScope":"turn"}"#
        try (a + "\n" + big + "\n" + b).write(to: file, atomically: true, encoding: .utf8)   // no trailing newline
        let entries = try XCTUnwrap(LocalUsageReader.parseKimiWireFile(file, fmt: LocalUsageReader.localDayFormatter()))
        XCTAssertEqual(entries.map(\.input).sorted(), [1, 2])
    }

    func testStreamedReadersParseCRLFFilesLikeLFFiles() throws {
        let pi = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-07-03T01:00:00.000Z","cwd":"/x"}
        {"type":"message","id":"cc01","parentId":null,"timestamp":"2026-07-03T01:00:10.000Z","message":{"role":"assistant","content":[],"model":"m","usage":{"input":100,"output":10,"cacheRead":600,"cacheWrite":40,"totalTokens":750,"cost":{"total":0.005}}}}
        {"type":"message","id":"cc02","parentId":"cc01","timestamp":"2026-07-03T01:00:20.000Z","message":{"role":"assistant","content":[],"model":"m","usage":{"input":5,"output":7,"cacheRead":0,"cacheWrite":3,"totalTokens":15,"cost":{"total":0}}}}
        """
        let kimi = """
        {"type":"usage.record","time":1700000000000,"usage":{"inputOther":1,"output":1},"usageScope":"turn"}
        {"type":"usage.record","time":1700000001000,"usage":{"inputOther":2,"output":2},"usageScope":"turn"}
        """
        let fmt = LocalUsageReader.localDayFormatter()
        func shape(_ entries: [LocalUsageReader.Entry]?) throws -> [String] {
            try XCTUnwrap(entries).map { "\($0.input)/\($0.output)/\($0.cacheWrite)/\($0.cacheRead)" }.sorted()
        }
        let dir = tempDir("crlf")
        let parsers: [(String, String, (URL) -> [LocalUsageReader.Entry]?)] = [
            ("pi", pi, { LocalUsageReader.parsePiFile($0, fmt: fmt) }),
            ("omp", pi, { LocalUsageReader.parseOmpFile($0, fmt: fmt) }),
            ("omo", pi, { LocalUsageReader.parseOmoFile($0, fmt: fmt) }),
            ("kimi", kimi, { LocalUsageReader.parseKimiWireFile($0, fmt: fmt) }),
        ]
        for (name, text, parse) in parsers {
            let lf = dir.appendingPathComponent("\(name)-lf.jsonl"), crlf = dir.appendingPathComponent("\(name)-crlf.jsonl")
            try text.write(to: lf, atomically: true, encoding: .utf8)
            try text.replacingOccurrences(of: "\n", with: "\r\n").write(to: crlf, atomically: true, encoding: .utf8)
            let expected = try shape(parse(lf))
            XCTAssertEqual(expected.count, 2, name)
            XCTAssertEqual(try shape(parse(crlf)), expected, "\(name): CRLF must parse like LF")
        }
    }

    func testStoreLevelSumsSaturateAcrossManyHugeValues() {
        func day(_ n: Int) -> DailyUsage {
            DailyUsage(date: "2026-07-\(String(format: "%02d", n))", inputTokens: Int.max, outputTokens: Int.max,
                       cacheCreationTokens: Int.max, cacheReadTokens: Int.max, totalTokens: Int.max,
                       totalCost: 0, costCoverage: .empty)
        }
        XCTAssertEqual(PeriodUsage(period: "m", daily: (1...5).map(day)).totalTokens, Int.max)
        // Thousands of entries at the per-entry ceiling add up exactly (no premature clamp) in a bucket.
        var bucket = LocalUsageReader.Bucket()
        let cap = LocalUsageReader.maxParsedTokenValue
        let entry = LocalUsageReader.Entry(id: "x", date: baseNow, localDay: "d", model: "m",
                                           input: cap, output: cap, cacheWrite: cap, cacheRead: cap)
        for _ in 0..<3_000 { bucket.add(entry) }
        XCTAssertEqual(bucket.total, 3_000 * 4 * cap)
    }

    // MARK: 10. refresh interval

    func testRefreshIntervalIsClamped() async {
        XCTAssertEqual(UsageStore.clampedRefreshInterval(nil), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(0), 0, "manual stays manual")
        XCTAssertEqual(UsageStore.clampedRefreshInterval(0.01), 30)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(300), 300)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(1e9), 3600)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(-5), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(.nan), 120)
        XCTAssertEqual(UsageStore.clampedRefreshInterval(.infinity), 120)
    }

    func testStoredTinyRefreshIntervalIsClampedAtLoad() async {
        let defaults = TestDefaults.make(suite: "ptb.test.audit.interval.\(UUID().uuidString)")
        defaults.set(0.01, forKey: "refreshInterval")
        let store = makeHermeticUsageStore(providers: [], defaults: defaults)
        XCTAssertEqual(store.refreshInterval, UsageStore.minimumRefreshInterval)
    }
}
