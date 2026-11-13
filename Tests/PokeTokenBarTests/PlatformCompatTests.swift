import XCTest
@testable import PokeTokenBar

final class PlatformCompatTests: XCTestCase {
    func testTildeAbbreviatesTheHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertEqual(PlatformCompat.abbreviatingWithTilde(home + "/projects/x"), "~/projects/x")
        XCTAssertEqual(PlatformCompat.abbreviatingWithTilde("/opt/elsewhere"), "/opt/elsewhere")
    }

    func testZlibRoundTripsWhereAvailable() throws {
        let original = Data(String(repeating: "pokemon ", count: 500).utf8)
        guard let compressed = PlatformCompat.zlibCompressed(original) else {
            throw XCTSkip("zlib unavailable on this platform")
        }
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(PlatformCompat.zlibDecompressed(compressed), original)
        XCTAssertNil(PlatformCompat.zlibDecompressed(Data("not zlib".utf8)))
    }

    func testZlibIsUnavailableWhenDisabledForTesting() {
        PlatformCompat.zlibDisabledForTesting = true
        defer { PlatformCompat.zlibDisabledForTesting = false }
        XCTAssertNil(PlatformCompat.zlibCompressed(Data("x".utf8)))
        XCTAssertNil(PlatformCompat.zlibDecompressed(Data("x".utf8)))
    }

    func testForceKillEndsARunningChild() throws {
        #if os(Windows)
        throw XCTSkip("needs a POSIX sleep binary; Windows coverage arrives with the process tests")
        #endif
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        XCTAssertTrue(child.isRunning)
        PlatformCompat.forceKill(pid: child.processIdentifier)
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(child.isRunning)
    }

    func testActivityTokenRoundTrips() {
        let token = PlatformCompat.beginActivity(reason: "PlatformCompatTests")
        if PlatformCompat.holdsActivities {
            XCTAssertNotNil(token)
            XCTAssertTrue(token is NSObjectProtocol, "endActivity would drop this token and leave the activity open")
        } else {
            XCTAssertNil(token)
        }
        PlatformCompat.endActivity(token)
        PlatformCompat.endActivity(nil)
    }
}
