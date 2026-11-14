#if os(Windows)
import Foundation
import WinSDK

/// Wake, screens sleep / wake, day change and (Windows extra) will-sleep, delivered on the main thread.
///
/// Sources, all through the sink window: `WM_POWERBROADCAST` (`PBT_APMSUSPEND`, `PBT_APMRESUMEAUTOMATIC`, and
/// `PBT_POWERSETTINGCHANGE` for `GUID_CONSOLE_DISPLAY_STATE`) and `WM_TIMECHANGE`. The day change is a one-shot
/// `Timer(fire:)` at the next local midnight, re-armed when it fires, on resume and on a time change. That timer is
/// the only thing this class ever wakes the process for, once per local day; there is no polling.
@MainActor final class WindowsSystemEvents: SystemEvents {
    static let pbtSuspend: UInt32 = 0x4                // PBT_APMSUSPEND
    static let pbtResumeAutomatic: UInt32 = 0x12       // PBT_APMRESUMEAUTOMATIC (PBT_APMRESUMESUSPEND 0x7 follows it on user input: ignored)
    static let pbtPowerSettingChange: UInt32 = 0x8013  // PBT_POWERSETTINGCHANGE

    private var willSleepHandlers: [@Sendable () -> Void] = []
    private var wakeHandlers: [@Sendable () -> Void] = []
    private var screensSleepHandlers: [@Sendable () -> Void] = []
    private var screensWakeHandlers: [@Sendable () -> Void] = []
    private var dayChangeHandlers: [@Sendable () -> Void] = []

    private let clock: @Sendable () -> Date
    private var calendar: Calendar
    private let followsSystemTimeZone: Bool
    private var lastDayKey: String
    private var dayTimer: Timer?
    private var closed = false
    private var screensAsleep = false
    private weak var window: WinSinkWindow?
    private var sinkTokens: [WinSinkWindow.Token] = []
    private(set) var timeChangeCount = 0
    private var suspendRegistration: UnsafeMutableRawPointer?
    private var displayRegistration: UnsafeMutableRawPointer?

    /// When the one-shot day timer will fire (nil after `shutdown()`).
    private(set) var armedFireDate: Date?
    /// How many times the day timer's fire handler ran (selftest idle accounting: the one known wake).
    private(set) var dayTimerFires = 0
    private(set) var suspendResumeRegistered = false
    private(set) var displayStateRegistered = false

    init(window: WinSinkWindow?, clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.window = window
        self.clock = clock
        self.calendar = calendar
        followsSystemTimeZone = calendar == Calendar.current
        lastDayKey = DayBoundary.dayKey(clock(), calendar: calendar)
        if let window { register(on: window) }
        armDayTimer()
    }

    // MARK: SystemEvents

    func onWake(_ f: @escaping @Sendable () -> Void) { wakeHandlers.append(f) }
    func onScreensSleep(_ f: @escaping @Sendable () -> Void) { screensSleepHandlers.append(f) }
    func onScreensWake(_ f: @escaping @Sendable () -> Void) { screensWakeHandlers.append(f) }
    func onDayChange(_ f: @escaping @Sendable () -> Void) { dayChangeHandlers.append(f) }
    var displaysAreAsleep: Bool { screensAsleep }

    /// Windows extra: called when the machine is about to suspend (the transport closes its sockets, Task 19).
    func onWillSleep(_ f: @escaping @Sendable () -> Void) { willSleepHandlers.append(f) }

    // MARK: messages

    /// `WM_POWERBROADCAST`. `displayState` is the parsed `GUID_CONSOLE_DISPLAY_STATE` payload (0 off, 1 on, 2 dimmed)
    /// for `PBT_POWERSETTINGCHANGE`, nil for every other event or another setting.
    func handlePowerBroadcast(event: UInt32, displayState: UInt32?) {
        guard !closed else { return }
        switch event {
        case Self.pbtSuspend:
            willSleepHandlers.forEach { $0() }
        case Self.pbtResumeAutomatic:
            // The timer's clock may not count the time asleep: look at the calendar, then arm again.
            checkDayChange()
            armDayTimer()
            wakeHandlers.forEach { $0() }
        case Self.pbtPowerSettingChange:
            guard let displayState else { return }
            let nowAsleep = displayState == 0  // 2 (dimmed) is still on
            guard nowAsleep != screensAsleep else { return }
            screensAsleep = nowAsleep
            (nowAsleep ? screensSleepHandlers : screensWakeHandlers).forEach { $0() }
        default:
            break
        }
    }

    /// `WM_TIMECHANGE`: the clock or the time zone changed.
    func handleTimeChange() {
        guard !closed else { return }
        timeChangeCount += 1
        if followsSystemTimeZone {
            NSTimeZone.resetSystemTimeZone()
            calendar = .current
        }
        checkDayChange()
        armDayTimer()
    }

    /// Unregisters, removes the handlers and stops the timer. Nothing is delivered afterwards.
    func shutdown() {
        guard !closed else { return }
        closed = true
        dayTimer?.invalidate()
        dayTimer = nil
        armedFireDate = nil
        if let window {
            for token in sinkTokens { window.off(token) }
        }
        if let r = suspendRegistration { _ = UnregisterSuspendResumeNotification(r) }
        if let r = displayRegistration { _ = UnregisterPowerSettingNotification(r) }
        suspendRegistration = nil
        displayRegistration = nil
        willSleepHandlers = []; wakeHandlers = []; screensSleepHandlers = []; screensWakeHandlers = []; dayChangeHandlers = []
    }

    // MARK: day change

    private func checkDayChange() {
        let key = DayBoundary.dayKey(clock(), calendar: calendar)
        guard key != lastDayKey else { return }
        lastDayKey = key
        dayChangeHandlers.forEach { $0() }
    }

    private func armDayTimer() {
        dayTimer?.invalidate()
        let fire = DayBoundary.nextLocalMidnight(after: clock(), calendar: calendar)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dayTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dayTimer = timer
        armedFireDate = fire
    }

    private func dayTimerFired() {
        guard !closed else { return }
        dayTimerFires += 1
        checkDayChange()  // an early fire (key unchanged) only re-arms
        armDayTimer()
    }

    // MARK: registration

    private func register(on window: WinSinkWindow) {
        sinkTokens.append(window.on(UINT(WM_POWERBROADCAST)) { [weak self] wParam, lParam in
            let event = UInt32(truncatingIfNeeded: wParam)
            let state = event == Self.pbtPowerSettingChange
                ? Self.displayState(fromPowerSetting: UnsafeRawPointer(bitPattern: Int(lParam))) : nil
            self?.handlePowerBroadcast(event: event, displayState: state)
            return 1  // TRUE: handled
        })
        sinkTokens.append(window.on(UINT(WM_TIMECHANGE)) { [weak self] _, _ in
            self?.handleTimeChange()
            return 0
        })
        suspendRegistration = RegisterSuspendResumeNotification(window.hwnd, 0 /* DEVICE_NOTIFY_WINDOW_HANDLE */)
        suspendResumeRegistered = suspendRegistration != nil
        if !suspendResumeRegistered {
            AppLog.write("system events: RegisterSuspendResumeNotification failed (\(GetLastError())); relying on the window's own power broadcasts")
        }
        var guid = Self.displayStateGUID
        displayRegistration = RegisterPowerSettingNotification(window.hwnd, &guid, 0)
        displayStateRegistered = displayRegistration != nil
        if !displayStateRegistered {
            AppLog.write("system events: RegisterPowerSettingNotification(display state) failed (\(GetLastError())); screens sleep/wake never fire and displaysAreAsleep stays false")
        }
    }

    /// GUID_CONSOLE_DISPLAY_STATE {6FE69556-704A-47A0-8F24-C28D936FDA47}, spelled out so the app does not link uuid.lib.
    static var displayStateGUID: GUID {
        GUID(Data1: 0x6FE69556, Data2: 0x704A, Data3: 0x47A0,
             Data4: (0x8F, 0x24, 0xC2, 0x8D, 0x93, 0x6F, 0xDA, 0x47))
    }

    /// Reads a `POWERBROADCAST_SETTING` (GUID, DWORD length, data) and returns its DWORD when it is the display state.
    static func displayState(fromPowerSetting pointer: UnsafeRawPointer?) -> UInt32? {
        guard let pointer else { return nil }
        let guid = pointer.loadUnaligned(as: GUID.self)
        var expected = displayStateGUID
        let same = withUnsafeBytes(of: guid) { a in withUnsafeBytes(of: &expected) { b in a.elementsEqual(b) } }
        guard same, pointer.loadUnaligned(fromByteOffset: 16, as: UInt32.self) >= 4 else { return nil }
        return pointer.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
    }
}
#endif
