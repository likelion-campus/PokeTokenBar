#if os(Windows)
import Foundation
import WinSDK

/// Counts what the handlers saw. Handlers are `@Sendable`; here they run on the main thread.
private final class SysTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var threads: [String: Bool] = [:]
    func hit(_ name: String) {
        lock.lock(); counts[name, default: 0] += 1; threads[name] = (GetCurrentThreadId() == WindowsApp.mainThreadID) && (threads[name] ?? true); lock.unlock()
    }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name] ?? 0 }
    func onMain(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return threads[name] ?? false }
}

private final class SysClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

extension WindowsSelftest {
    /// Task 7: system events, idle clock, reachability. One line per check.
    @MainActor static func systemServiceChecks(_ r: Recorder) async {
        liveCheck(r)
        messageCheck(r)
        await dayTimerCheck(r)
        idleValueCheck(r)
        await reachabilityChecks(r)
    }

    /// The app's own services were installed before any store read them (`static let` built on first access).
    @MainActor private static func liveCheck(_ r: Recorder) {
        let events = Platform.current.events as? WindowsSystemEvents
        let idle = Platform.current.idle is WindowsIdleClock
        let net = PlatformNetwork.current is WindowsNetworkWatching
        r.add("platform.liveBeforeStores", events != nil && idle && net,
              "events=\(events != nil ? "WindowsSystemEvents" : "stub") idle=\(idle ? "WindowsIdleClock" : "stub") network=\(net ? "WindowsNetworkWatching" : "stub")")
        let armed = events?.armedFireDate
        let ahead = armed.map { $0.timeIntervalSinceNow } ?? -1
        let isMidnight = armed.map { DayBoundary.dayKey($0, calendar: .current) != DayBoundary.dayKey($0.addingTimeInterval(-1), calendar: .current) } ?? false
        r.add("events.registered",
              events?.suspendResumeRegistered == true && events?.displayStateRegistered == true && ahead > 0 && ahead <= 90_000 && isMidnight,
              "suspendResume=\(events?.suspendResumeRegistered ?? false) displayState=\(events?.displayStateRegistered ?? false) "
                + "day_timer_in_s=\(Int(ahead)) at_local_midnight=\(isMidnight) one_shot=true")
    }

    /// Synthetic messages through the real window procedure of a scratch sink: each hook fires exactly as many times as expected.
    @MainActor private static func messageCheck(_ r: Recorder) {
        do {
            let window = try WinSinkWindow(title: "PokeTokenBar-selftest-events")
            defer { window.destroy() }
            let clock = SysClock()
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            let events = WindowsSystemEvents(window: window, clock: { clock.date }, calendar: utc)
            defer { events.shutdown() }
            let t = SysTally()
            events.onWillSleep { t.hit("willSleep") }
            events.onWake { t.hit("wake") }
            events.onScreensSleep { t.hit("screensSleep") }
            events.onScreensWake { t.hit("screensWake") }
            events.onDayChange { t.hit("day") }
            func power(_ event: UInt32) { _ = SendMessageW(window.hwnd, UINT(WM_POWERBROADCAST), WPARAM(event), 0) }
            func display(_ state: UInt32) {
                var bytes: [UInt8] = []
                withUnsafeBytes(of: WindowsSystemEvents.displayStateGUID) { bytes += $0 }
                withUnsafeBytes(of: UInt32(4)) { bytes += $0 }
                withUnsafeBytes(of: state) { bytes += $0 }
                bytes.withUnsafeBytes {
                    _ = SendMessageW(window.hwnd, UINT(WM_POWERBROADCAST), WPARAM(WindowsSystemEvents.pbtPowerSettingChange),
                                     LPARAM(Int(bitPattern: $0.baseAddress)))
                }
            }
            power(WindowsSystemEvents.pbtSuspend)
            power(WindowsSystemEvents.pbtResumeAutomatic)
            power(0x7)
            display(0); display(0)
            let asleep = events.displaysAreAsleep
            display(1)
            let awake = !events.displaysAreAsleep
            _ = SendMessageW(window.hwnd, UINT(WM_TIMECHANGE), 0, 0)
            let dayBefore = t.count("day"), armedBefore = events.armedFireDate
            clock.date = clock.date.addingTimeInterval(36 * 3600)
            _ = SendMessageW(window.hwnd, UINT(WM_TIMECHANGE), 0, 0)
            let rearmed = events.armedFireDate != armedBefore
            let ok = t.count("willSleep") == 1 && t.count("wake") == 1 && t.count("screensSleep") == 1 && t.count("screensWake") == 1
                && asleep && awake && dayBefore == 0 && t.count("day") == 1 && rearmed
                && ["willSleep", "wake", "screensSleep", "screensWake", "day"].allSatisfy { t.onMain($0) }
            r.add("events.messages", ok,
                  "WM_POWERBROADCAST suspend/resume/resume-suspend/display off x2/on, WM_TIMECHANGE x2 (+36 h): willSleep=\(t.count("willSleep")) "
                    + "wake=\(t.count("wake")) screensSleep=\(t.count("screensSleep")) screensWake=\(t.count("screensWake")) "
                    + "day=\(t.count("day")) displayReadBack=\(asleep)/\(awake) rearmed=\(rearmed)")
        } catch {
            r.add("events.messages", false, "\(error)")
        }
    }

    /// The real one-shot timer: a time zone whose local midnight is under a second away fires the day change once,
    /// then nothing more (the next arm is a day out).
    @MainActor private static func dayTimerCheck(_ r: Recorder) async {
        let secondOfDay = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        var offset = 86_399 - Int(secondOfDay)
        while offset > 43_200 { offset -= 86_400 }
        while offset < -43_200 { offset += 86_400 }
        var cal = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: offset) else { r.add("events.dayTimer", false, "no time zone for offset \(offset)"); return }
        cal.timeZone = zone
        let events = WindowsSystemEvents(window: nil, calendar: cal)
        defer { events.shutdown() }
        let t = SysTally()
        events.onDayChange { t.hit("day") }
        let armedIn = events.armedFireDate?.timeIntervalSinceNow ?? -1
        let start = nowMs()
        let fired = await waitUntil(timeout: 5) { t.count("day") == 1 }
        let firedMs = nowMs() - start
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let rearmedIn = events.armedFireDate?.timeIntervalSinceNow ?? -1
        r.add("events.dayTimer", fired && t.count("day") == 1 && t.onMain("day") && events.dayTimerFires >= 1 && rearmedIn > 3_600,
              "offset=\(offset) s armed_in_s=\(String(format: "%.2f", armedIn)) fired=\(fired) after_ms=\(Int(firedMs)) day_changes=\(t.count("day")) "
                + "timer_fires=\(events.dayTimerFires) rearmed_in_h=\(String(format: "%.1f", rearmedIn / 3600))")
    }

    @MainActor private static func idleValueCheck(_ r: Recorder) {
        let seconds = WindowsIdleClock().secondsSinceLastInput()
        var info = LASTINPUTINFO()
        info.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
        let read = GetLastInputInfo(&info)
        let uptime = TimeInterval(GetTickCount64()) / 1000
        r.add("idle.value", read && seconds.isFinite && seconds >= 0 && seconds <= uptime + 1,
              "GetLastInputInfo=\(read) idle_s=\(String(format: "%.1f", seconds)) uptime_s=\(String(format: "%.0f", uptime)) "
                + "wrap_ok=\(WindowsIdleClock.seconds(lastInputTick: 0xFFFF_FF00, nowTick: 0x100) == 0.512)")
    }

    @MainActor private static func reachabilityChecks(_ r: Recorder) async {
        let t = SysTally()
        let monitor = WindowsReachabilityMonitor(cooldown: 0)
        monitor.onReconnected = { t.hit("reconnected") }
        let start = nowMs()
        monitor.start()
        let got = await waitUntil(timeout: 5) { monitor.observations > 0 }
        r.add("reachability.initialCallback", monitor.isAvailable && got,
              "available=\(monitor.isAvailable) observations=\(monitor.observations) after_ms=\(Int(nowMs() - start)) "
                + "reconnects_on_cold_start=\(t.count("reconnected"))")
        guard let ctx = monitor.currentContext else {
            r.add("reachability.delivery", false, "no registration to deliver through")
            monitor.stop()
            return
        }
        let before = monitor.observations
        // From a pool thread, like Windows: offline then online is one reconnect, delivered on the main thread.
        Thread { ctx.receive(isSatisfied: false); ctx.receive(isSatisfied: true) }.start()
        let delivered = await waitUntil(timeout: 5) { t.count("reconnected") >= 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        monitor.stop()
        let afterStop = t.count("reconnected")
        Thread { ctx.receive(isSatisfied: false); ctx.receive(isSatisfied: true) }.start()
        try? await Task.sleep(nanoseconds: 400_000_000)
        r.add("reachability.delivery", delivered && afterStop == 1 && t.count("reconnected") == 1 && t.onMain("reconnected")
                && monitor.observations == before + 2,
              "injected offline->online: reconnects=\(afterStop) on_main=\(t.onMain("reconnected")); after stop() the same injection: "
                + "reconnects=\(t.count("reconnected")) observations=\(monitor.observations - before) (expected 2)")
    }
}
#endif
