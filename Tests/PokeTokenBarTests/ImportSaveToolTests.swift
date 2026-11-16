import XCTest
@testable import PokeTokenBar

/// `SaveImportTool` (`PokeTokenBar.exe --import-save`): applies a Mac save, backs up first, and a failure changes nothing.
@MainActor
final class ImportSaveToolTests: XCTestCase {
    private var dir: URL!
    private var stateFile: URL { dir.appendingPathComponent("companion-state.json") }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-import-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A PC's own progress: an egg with one dex entry.
        var mine = CompanionState()
        mine.usedSinceInstall = 1234
        mine.dex = [DexEntry(baseID: 10, finalID: 12, chainOrder: [10, 11, 12], rarity: .common, caughtAt: now)]
        try JSONEncoder().encode(mine).write(to: stateFile)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func saveFile(_ name: String = "mac.json") throws -> String {
        var s = CompanionState()
        s.usedSinceInstall = 8_000_000_000
        s.dex = [DexEntry(baseID: 1, finalID: 3, chainOrder: [1, 2, 3], rarity: .common, caughtAt: now,
                          names: [3: ["en": "Venusaur"]]),
                 DexEntry(baseID: 4, finalID: 6, chainOrder: [4, 5, 6], rarity: .common, caughtAt: now)]
        s.active = MonState(baseID: 3, pathIDs: [3], plannedPathIDs: [3], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        let url = dir.appendingPathComponent(name)
        try SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Old Mac", now: now).write(to: url)
        return url.path
    }

    private func run(_ path: String?, running: Bool = false) -> SaveImportTool.Result {
        return SaveImportTool.run(path: path, stateDirectory: dir, appIsRunning: { running },
                                  makeDefaults: { TestDefaults.make(suite: "ptb.importtool") }, now: { self.now })
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }
    }

    func testValidSaveIsAppliedAndThePreviousStateIsBackedUp() async throws {
        let before = try Data(contentsOf: stateFile)
        let result = run(try saveFile())
        XCTAssertEqual(result.exitCode, 0, result.line)
        let backupName = SaveTransfer.backupFileName(date: now)
        XCTAssertEqual(try backups(), [backupName])
        XCTAssertTrue(result.line.contains(dir.appendingPathComponent(backupName).path), result.line)
        XCTAssertTrue(result.line.contains("Venusaur"), result.line)
        XCTAssertTrue(result.line.contains("2 Pokedex entries"), result.line)
        let backup = try Data(contentsOf: dir.appendingPathComponent(backupName))
        XCTAssertEqual(try JSONDecoder().decode(CompanionState.self, from: backup).usedSinceInstall, 1234)
        let after = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: stateFile))
        XCTAssertNotEqual(try Data(contentsOf: stateFile), before)
        XCTAssertEqual(after.usedSinceInstall, 8_000_000_000)
        XCTAssertEqual(after.dex.count, 2)
        XCTAssertFalse(after.installBaselineSet, "no usage data is known: the app's first update seeds the baseline")
    }

    func testEggSaveSaysEgg() async throws {
        var s = CompanionState()
        s.dex = []
        let url = dir.appendingPathComponent("egg.json")
        try SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Old Mac", now: now).write(to: url)
        let result = run(url.path)
        XCTAssertEqual(result.exitCode, 0, result.line)
        XCTAssertTrue(result.line.contains("companion egg, 0 Pokedex"), result.line)
    }

    /// The minimal envelope the Windows CI step writes by hand (state decoding is lenient).
    func testMinimalHandWrittenEnvelope() async throws {
        let url = dir.appendingPathComponent("min.json")
        try Data(#"{"format":"poketokenbar.save","schema":2,"appVersion":"ci","exportedAt":"2026-01-01T00:00:00Z","sourceDevice":"CI","state":{}}"#.utf8).write(to: url)
        let result = run(url.path)
        XCTAssertEqual(result.exitCode, 0, result.line)
        XCTAssertTrue(result.line.hasPrefix("imported: companion egg, 0 Pokedex entries"), result.line)
    }

    private func assertRefused(_ result: SaveImportTool.Result, _ code: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.exitCode, code, result.line, file: file, line: line)
        XCTAssertFalse(result.line.contains("\n"), file: file, line: line)
        XCTAssertEqual(try backups(), [], "nothing is backed up when nothing is applied", file: file, line: line)
    }

    func testFailuresChangeNothing() async throws {
        let before = try Data(contentsOf: stateFile)
        let notASave = dir.appendingPathComponent("other.json")
        try Data("{\"hello\":1}".utf8).write(to: notASave)
        let newer = dir.appendingPathComponent("newer.json")
        try Data("{\"format\":\"\(SaveEnvelope.formatID)\",\"schema\":\(SaveEnvelope.schemaVersion + 1)}".utf8).write(to: newer)
        let big = dir.appendingPathComponent("big.json")
        try Data(count: SaveTransfer.maxFileBytes + 1).write(to: big)
        let valid = try saveFile()

        try assertRefused(run(nil), 2)
        try assertRefused(run("--selftest"), 2)
        try assertRefused(run(dir.appendingPathComponent("missing.json").path), 2)
        try assertRefused(run(notASave.path), 2)
        try assertRefused(run(newer.path), 2)
        try assertRefused(run(big.path), 2)
        try assertRefused(run(dir.path), 2)
        try assertRefused(run(valid, running: true), 3)
        XCTAssertEqual(try Data(contentsOf: stateFile), before)
    }

    func testNonASCIIPathWithSpaces() async throws {
        let sub = dir.appendingPathComponent("바탕 화면 dir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("내 세이브 file.json")
        try FileManager.default.moveItem(atPath: try saveFile(), toPath: moved.path)
        XCTAssertEqual(run(moved.path).exitCode, 0)
    }

    #if !os(Windows)
    func testBackupFailureChangesNothing() async throws {
        let before = try Data(contentsOf: stateFile)
        let file = try saveFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "running as a user who can write anyway")
        let result = run(file)
        XCTAssertEqual(result.exitCode, 4, result.line)
        XCTAssertEqual(try Data(contentsOf: stateFile), before)
    }
    #endif
}
