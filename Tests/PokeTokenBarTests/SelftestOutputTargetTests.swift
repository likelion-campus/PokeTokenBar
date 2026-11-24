import XCTest
@testable import PokeTokenBar

/// `--selftest-out <path>` clears the previous result before it writes; a folder given by mistake must survive (F3 of the 2026-11 audit).
final class SelftestOutputTargetTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-selftest-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAFolderIsRefusedAndKeepsItsContents() throws {
        let precious = dir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: precious)
        let why = try XCTUnwrap(SelftestOutputTarget.refusal(for: dir))
        XCTAssertTrue(why.contains("not a regular file"), why)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    func testAFolderAtTheProgressSiblingIsRefusedToo() throws {
        let out = dir.appendingPathComponent("r.json")
        try FileManager.default.createDirectory(at: SelftestOutputTarget.progressURL(out), withIntermediateDirectories: true)
        XCTAssertNotNil(SelftestOutputTarget.refusal(for: out))
    }

    func testAnAbsentPathAndARegularFileAreAccepted() throws {
        let out = dir.appendingPathComponent("r.json")
        XCTAssertNil(SelftestOutputTarget.refusal(for: out))
        try Data("old".utf8).write(to: out)
        try Data("old".utf8).write(to: SelftestOutputTarget.progressURL(out))
        XCTAssertNil(SelftestOutputTarget.refusal(for: out))
    }

    func testRemoveStaleRemovesRegularFilesOnly() throws {
        let out = dir.appendingPathComponent("r.json")
        try Data("old".utf8).write(to: out)
        try Data("old".utf8).write(to: SelftestOutputTarget.progressURL(out))
        SelftestOutputTarget.removeStale(out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SelftestOutputTarget.progressURL(out).path))

        let precious = dir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: precious)
        SelftestOutputTarget.removeStale(dir)   // what the run did before the fix
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path), "a folder is never removed")
    }
}
