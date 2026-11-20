import XCTest
@testable import PokeTokenBar

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class PlatformTests: XCTestCase {
    func testWindowsStubsReportUnavailable() async {
        let sink = LogLines()
        let platform = StubPlatform.make(log: { sink.add($0) })

        let authorized = await platform.notifications.requestAuthorization()
        XCTAssertFalse(authorized)
        XCTAssertFalse(platform.notifications.isAvailable)
        platform.notifications.post(id: "a", title: "t", body: "b", sound: true)

        XCTAssertEqual(platform.secrets.read(service: "s", account: nil), .failure(.unavailable))
        XCTAssertEqual(platform.secrets.read(service: "s", account: "acct"), .failure(.unavailable))

        let fired = Counter()
        platform.events.onWake { fired.bump() }
        platform.events.onScreensSleep { fired.bump() }
        platform.events.onScreensWake { fired.bump() }
        platform.events.onDayChange { fired.bump() }
        XCTAssertEqual(fired.value, 0)
        XCTAssertFalse(platform.events.displaysAreAsleep)

        XCTAssertEqual(platform.idle.secondsSinceLastInput(), 0)
    }

    func testEachStubLogsExactlyOnceAcrossRepeatedCalls() async {
        let sink = LogLines()
        let platform = StubPlatform.make(log: { sink.add($0) })

        for _ in 0..<3 {
            _ = await platform.notifications.requestAuthorization()
            platform.notifications.post(id: "a", title: "t", body: "b", sound: false)
            _ = platform.secrets.read(service: "s", account: nil)
            platform.events.onWake {}
            platform.events.onScreensSleep {}
            platform.events.onScreensWake {}
            platform.events.onDayChange {}
            _ = platform.notifications.isAvailable
            _ = platform.events.displaysAreAsleep
            _ = platform.idle.secondsSinceLastInput()
        }
        XCTAssertEqual(sink.lines.count, 4, "one line per stub: \(sink.lines)")
        XCTAssertEqual(Set(sink.lines).count, 4)
    }
}
