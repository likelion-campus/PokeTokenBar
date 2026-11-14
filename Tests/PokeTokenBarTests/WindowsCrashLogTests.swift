#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// The file part of the crash log (`prepare`), in a temp folder with an injected log sink. The filter itself and the
/// real crashes are exercised by `--selftest` (`crash.*`), because a test process must not install a crash filter.
final class WindowsCrashLogTests: XCTestCase {
    private var dir: URL!
    private var lines: [String] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-crashlog-\(UUID().uuidString)", isDirectory: true)
        lines = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func prepare() {
        WindowsCrashLog.prepare(logsDirectory: dir) { self.lines.append($0) }
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }

    private func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testFirstInstallWritesTheMarkerOnly() {
        prepare()
        XCTAssertEqual(lines, [], "a first launch has nothing to report")
        XCTAssertEqual(names(), [WindowsCrashLog.markerName])
    }

    func testMarkerLeftBehindIsReportedOnce() {
        prepare()
        prepare()  // the first session never marked itself clean
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines[0].contains("did not end cleanly"), lines[0])
        XCTAssertTrue(exists(WindowsCrashLog.markerName), "the new session wrote its own marker")
    }

    func testMarkCleanRemovesTheMarker() {
        prepare()
        WindowsCrashLog.markClean(logsDirectory: dir)
        XCTAssertFalse(exists(WindowsCrashLog.markerName))
        prepare()
        XCTAssertEqual(lines, [], "a clean exit is not reported by the next launch")
    }

    func testMarkCleanLeavesAMarkerThisProcessDidNotWrite() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(WindowsCrashLog.markerName).path, contents: Data())
        WindowsCrashLog.markClean(logsDirectory: dir)  // a helper process exiting must not clear the running app's marker
        XCTAssertTrue(exists(WindowsCrashLog.markerName))
    }

    func testCrashLogIsDrainedThenRemoved() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = "[CRASH] exception 0xC0000005 at 0x00007FF600001234\n[CRASH] pid=1 tid=2\n"
        try Data(record.utf8).write(to: dir.appendingPathComponent(WindowsCrashLog.crashLogName))
        prepare()
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines[0].contains("previous session crash record: [CRASH] exception 0xC0000005 at 0x00007FF600001234"), lines[0])
        XCTAssertFalse(exists(WindowsCrashLog.crashLogName))
        lines = []
        prepare()
        XCTAssertFalse(lines.contains { $0.contains("crash record") }, "drained once")
    }

    func testOnlyThreeDumpsAreKept() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dumps = ["PokeTokenBar-20261114-100000-11.dmp", "PokeTokenBar-20261114-100500-12.dmp", "PokeTokenBar-20261114-101000-13.dmp",
                     "PokeTokenBar-20261114-101500-14.dmp", "PokeTokenBar-20261115-090000-15.dmp"]
        for name in dumps + ["unrelated.dmp"] { try Data("MDMP".utf8).write(to: dir.appendingPathComponent(name)) }
        prepare()
        XCTAssertEqual(names().filter { $0.hasPrefix("PokeTokenBar-") }, Array(dumps.suffix(WindowsCrashLog.keptDumps)))
        XCTAssertTrue(exists("unrelated.dmp"), "only our own dump names are pruned")
    }

    func testTheStderrLogIsCutToItsNewestBytes() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = WindowsCrashLog.stderrKeptBytes
        var data = Data(repeating: UInt8(ascii: "a"), count: 100_000)
        data.append(Data(repeating: UInt8(ascii: "b"), count: keep))
        try data.write(to: dir.appendingPathComponent(WindowsCrashLog.stderrName))
        prepare()
        let cut = try Data(contentsOf: dir.appendingPathComponent(WindowsCrashLog.stderrName))
        XCTAssertEqual(cut.count, keep)
        XCTAssertTrue(cut.allSatisfy { $0 == UInt8(ascii: "b") }, "the newest bytes are the ones kept")
    }
}
#endif
