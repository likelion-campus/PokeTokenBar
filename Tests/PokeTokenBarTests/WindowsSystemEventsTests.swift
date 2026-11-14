#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Counts calls made from `@Sendable` handlers (they run synchronously on the main actor here).
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ s: String) -> Int { all.filter { $0 == s }.count }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ d: Date) { now = d }
    var date: Date { get { lock.lock(); defer { lock.unlock() }; return now } set { lock.lock(); now = newValue; lock.unlock() } }
}

/// The message handling of `WindowsSystemEvents` without a window (XCTest drives the run loop its own way); the
/// registrations and the real message path are checked by `--selftest` (`events.*`).
@MainActor
final class WindowsSystemEventsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private func date(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso), iso) }

    private func make(_ clock: FakeClock, _ log: Log) -> WindowsSystemEvents {
        let e = WindowsSystemEvents(window: nil, clock: { clock.date }, calendar: utc)
        e.onWillSleep { log.add("willSleep") }
        e.onWake { log.add("wake") }
        e.onScreensSleep { log.add("screensSleep") }
        e.onScreensWake { log.add("screensWake") }
        e.onDayChange { log.add("day") }
        return e
    }

    func testSuspendCallsWillSleepThenResumeCallsWake() async throws {
        let log = Log()
        let e = make(FakeClock(try date("2026-03-10T12:00:00Z")), log)
        defer { e.shutdown() }
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtSuspend, displayState: nil)
        XCTAssertEqual(log.all, ["willSleep"])
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtResumeAutomatic, displayState: nil)
        XCTAssertEqual(log.all, ["willSleep", "wake"])
        e.handlePowerBroadcast(event: 0x7 /* PBT_APMRESUMESUSPEND follows the automatic one */, displayState: nil)
        e.handlePowerBroadcast(event: 0x0A /* PBT_APMPOWERSTATUSCHANGE */, displayState: nil)
        XCTAssertEqual(log.all, ["willSleep", "wake"], "other events do nothing")
    }

    func testDisplayOffAndOnMapToScreensSleepAndWake() async throws {
        let log = Log()
        let e = make(FakeClock(try date("2026-03-10T12:00:00Z")), log)
        defer { e.shutdown() }
        let change = WindowsSystemEvents.pbtPowerSettingChange
        e.handlePowerBroadcast(event: change, displayState: 1)
        XCTAssertEqual(log.all, [], "the initial notification (on) is not a wake")
        e.handlePowerBroadcast(event: change, displayState: 0)
        e.handlePowerBroadcast(event: change, displayState: 0)
        XCTAssertEqual(log.all, ["screensSleep"], "off twice is one sleep")
        e.handlePowerBroadcast(event: change, displayState: 2)
        XCTAssertEqual(log.all, ["screensSleep", "screensWake"], "dimmed is on")
        e.handlePowerBroadcast(event: change, displayState: 1)
        e.handlePowerBroadcast(event: change, displayState: nil)
        XCTAssertEqual(log.all, ["screensSleep", "screensWake"])
    }

    func testDisplayStateIsReadBack() async throws {
        let e = make(FakeClock(try date("2026-03-10T12:00:00Z")), Log())
        defer { e.shutdown() }
        XCTAssertFalse(e.displaysAreAsleep)
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtPowerSettingChange, displayState: 0)
        XCTAssertTrue(e.displaysAreAsleep)
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtPowerSettingChange, displayState: 1)
        XCTAssertFalse(e.displaysAreAsleep)
    }

    func testPowerSettingPayloadIsParsed() async {
        func buffer(guid: GUID, length: UInt32, value: UInt32) -> [UInt8] {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: guid) { bytes += $0 }
            withUnsafeBytes(of: length) { bytes += $0 }
            withUnsafeBytes(of: value) { bytes += $0 }
            return bytes
        }
        let good = buffer(guid: WindowsSystemEvents.displayStateGUID, length: 4, value: 2)
        XCTAssertEqual(good.withUnsafeBytes { WindowsSystemEvents.displayState(fromPowerSetting: $0.baseAddress) }, 2)
        var other = WindowsSystemEvents.displayStateGUID
        other.Data1 ^= 1
        let wrong = buffer(guid: other, length: 4, value: 2)
        XCTAssertNil(wrong.withUnsafeBytes { WindowsSystemEvents.displayState(fromPowerSetting: $0.baseAddress) })
        let short = buffer(guid: WindowsSystemEvents.displayStateGUID, length: 0, value: 2)
        XCTAssertNil(short.withUnsafeBytes { WindowsSystemEvents.displayState(fromPowerSetting: $0.baseAddress) })
        XCTAssertNil(WindowsSystemEvents.displayState(fromPowerSetting: nil))
    }

    func testTimeChangeReArmsTheDayTimer() async throws {
        let log = Log()
        let clock = FakeClock(try date("2026-03-10T12:00:00Z"))
        let e = make(clock, log)
        defer { e.shutdown() }
        XCTAssertEqual(e.armedFireDate, try date("2026-03-11T00:00:00Z"))
        clock.date = try date("2026-03-12T05:00:00Z")
        e.handleTimeChange()
        XCTAssertEqual(e.armedFireDate, try date("2026-03-13T00:00:00Z"))
        XCTAssertEqual(log.count("day"), 1, "the clock jumped over midnights: one day change")
        e.handleTimeChange()
        XCTAssertEqual(log.count("day"), 1, "same day again: nothing")
        clock.date = try date("2026-03-12T01:00:00Z")  // back within the same day
        e.handleTimeChange()
        XCTAssertEqual(log.count("day"), 1)
        XCTAssertEqual(e.armedFireDate, try date("2026-03-13T00:00:00Z"))
    }

    func testResumeAfterMidnightFiresDayChangeOnce() async throws {
        let log = Log()
        let clock = FakeClock(try date("2026-03-10T23:50:00Z"))
        let e = make(clock, log)
        defer { e.shutdown() }
        clock.date = try date("2026-03-11T00:10:00Z")
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtResumeAutomatic, displayState: nil)
        XCTAssertEqual(log.count("day"), 1)
        XCTAssertEqual(log.count("wake"), 1)
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtResumeAutomatic, displayState: nil)
        XCTAssertEqual(log.count("day"), 1, "a second resume on the same day")
        XCTAssertEqual(e.armedFireDate, try date("2026-03-12T00:00:00Z"))
    }

    func testNothingIsDeliveredAfterShutdown() async throws {
        let log = Log()
        let e = make(FakeClock(try date("2026-03-10T12:00:00Z")), log)
        e.shutdown()
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtSuspend, displayState: nil)
        e.handlePowerBroadcast(event: WindowsSystemEvents.pbtResumeAutomatic, displayState: nil)
        e.handleTimeChange()
        XCTAssertEqual(log.all, [])
        XCTAssertNil(e.armedFireDate)
    }

    func testIdleSecondsAreFiniteAndNonNegative() async {
        let s = WindowsIdleClock().secondsSinceLastInput()
        XCTAssertTrue(s.isFinite)
        XCTAssertGreaterThanOrEqual(s, 0)
    }

    func testIdleArithmeticSurvivesTheTickWrap() async {
        XCTAssertEqual(WindowsIdleClock.seconds(lastInputTick: 1_000, nowTick: 4_500), 3.5)
        // 49.7 days of uptime: now wrapped past zero, the last input did not.
        XCTAssertEqual(WindowsIdleClock.seconds(lastInputTick: 0xFFFF_FF00, nowTick: 0x100), 0.512, accuracy: 1e-9)
        XCTAssertEqual(WindowsIdleClock.seconds(lastInputTick: 0xFFFF_FFFF, nowTick: 0), 0.001, accuracy: 1e-9)
        // The last-input tick a little ahead of now (non-atomic reads): just now, not 49 days.
        XCTAssertEqual(WindowsIdleClock.seconds(lastInputTick: 105, nowTick: 100), 0)
        XCTAssertEqual(WindowsIdleClock.seconds(lastInputTick: 0, nowTick: 0), 0)
    }

    func testConnectivityLevelsMapToSatisfied() async {
        XCTAssertEqual((0...5).map(winConnectivityIsSatisfied), [false, false, false, true, true, false])
    }

    func testNoDeliveryAfterTheReachabilityContextIsClosed() async {
        let calls = Log()
        let ctx = WinReachabilityContext { _ in calls.add("change") }
        ctx.close()
        ctx.receive(isSatisfied: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls.all, [])
    }
}
#endif
