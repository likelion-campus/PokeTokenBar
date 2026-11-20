#if os(Windows)
import WinSDK
import XCTest
@testable import PokeTokenBar

final class WinAtomicWriteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-winatomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PlatformCompat.atomicWriteFaultForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private struct Injected: Error {}

    func testFailureBeforeTheRenameKeepsThePreviousFileAndLeavesNoTemp() throws {
        let url = dir.appendingPathComponent("state.json")
        try Data("previous".utf8).write(to: url)
        PlatformCompat.atomicWriteFaultForTesting = { throw Injected() }
        XCTAssertThrowsError(try PlatformCompat.atomicWrite(Data("new".utf8), to: url)) { XCTAssertTrue($0 is Injected) }
        XCTAssertEqual(try Data(contentsOf: url), Data("previous".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }

    func testFailureOnAFirstSaveLeavesNoDestination() throws {
        let url = dir.appendingPathComponent("first.json")
        PlatformCompat.atomicWriteFaultForTesting = { throw Injected() }
        XCTAssertThrowsError(try PlatformCompat.atomicWrite(Data("new".utf8), to: url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testTheFaultSeamSitsAfterTheTempIsComplete() throws {
        let url = dir.appendingPathComponent("state.json")
        nonisolated(unsafe) var tempSeen: [String] = []
        let folder = dir.path
        PlatformCompat.atomicWriteFaultForTesting = {
            tempSeen = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        }
        try PlatformCompat.atomicWrite(Data("new".utf8), to: url)
        XCTAssertEqual(tempSeen.count, 1, "one temp file next to the target while the rename is pending")
        XCTAssertTrue(tempSeen[0].hasSuffix(".tmp"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }

    func testAnOpenReaderWithoutShareDeleteFailsCleanly() throws {
        let url = dir.appendingPathComponent("held.json")
        try Data("previous".utf8).write(to: url)
        let held = WinPath.native(url).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        XCTAssertNotNil(held)
        XCTAssertThrowsError(try PlatformCompat.atomicWrite(Data("new".utf8), to: url))
        CloseHandle(held)
        XCTAssertEqual(try Data(contentsOf: url), Data("previous".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["held.json"])
    }
}
#endif
