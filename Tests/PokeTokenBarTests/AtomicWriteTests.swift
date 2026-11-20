import XCTest
@testable import PokeTokenBar

/// `PlatformCompat.atomicWrite` on both systems. The failure-injection tests are Windows-only (`WinAtomicWriteTests`):
/// the Mac branch is the old `Data.write(options: .atomic)` call, which this file pins.
final class AtomicWriteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testRoundTripAndNoTemporaryFileLeft() throws {
        let url = dir.appendingPathComponent("state.json")
        let data = Data("{\"a\":1}".utf8)
        try PlatformCompat.atomicWrite(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try names(), ["state.json"])
    }

    func testEmptyDataWritesAnEmptyFile() throws {
        let url = dir.appendingPathComponent("empty")
        try PlatformCompat.atomicWrite(Data(), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testReplacesAnExistingFile() throws {
        let url = dir.appendingPathComponent("state.json")
        try Data(String(repeating: "old", count: 1000).utf8).write(to: url)
        try PlatformCompat.atomicWrite(Data("new".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(try names(), ["state.json"])
    }

    func testLargePayloadIsComplete() throws {
        let url = dir.appendingPathComponent("big")
        let data = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try PlatformCompat.atomicWrite(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    /// Mac pin: the bytes on disk are the ones the old call wrote.
    func testSameBytesAsTheOldDirectCall() throws {
        let data = Data("pin \u{D55C}".utf8)
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try PlatformCompat.atomicWrite(data, to: a)
        try data.write(to: b, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }

    func testMissingFolderThrowsAndLeavesNothing() throws {
        let url = dir.appendingPathComponent("nope").appendingPathComponent("x.json")
        XCTAssertThrowsError(try PlatformCompat.atomicWrite(Data("x".utf8), to: url))
        XCTAssertEqual(try names(), [])
    }

    func testConcurrentWritersLeaveOneCompleteFile() throws {
        let url = dir.appendingPathComponent("shared.json")
        let payloads = (0..<8).map { i in Data(String(repeating: Character(UnicodeScalar(UInt8(65 + i))), count: 200_000).utf8) }
        let failures = NSLock()
        nonisolated(unsafe) var errors = 0
        DispatchQueue.concurrentPerform(iterations: 8 * 6) { n in
            do { try PlatformCompat.atomicWrite(payloads[n % 8], to: url) } catch { failures.lock(); errors += 1; failures.unlock() }
        }
        XCTAssertEqual(errors, 0)
        let final = try Data(contentsOf: url)
        XCTAssertTrue(payloads.contains(final), "the file must be exactly one writer's payload, not a mix")
        XCTAssertEqual(try names(), ["shared.json"])
    }
}
