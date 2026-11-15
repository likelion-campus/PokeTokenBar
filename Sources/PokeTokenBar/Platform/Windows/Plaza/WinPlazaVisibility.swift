#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Whether a person can see the plaza window (D5), reported to the controller only when it changes — the Mac's
/// `windowDidMiniaturize` / `windowDidChangeOcclusionState`:
///
/// `visible = shown ∧ ¬minimized ∧ ¬cloaked ∧ session unlocked and connected ∧ displays on ∧ ¬covered`
///
/// | Signal | Source | Wakes |
/// |---|---|---|
/// | minimized / restored | the window's `WM_SIZE` (`SIZE_MINIMIZED`, else restored) | event |
/// | other virtual desktop, the shell hiding it | `EVENT_OBJECT_CLOAKED` / `UNCLOAKED` (our process) + `DWMWA_CLOAKED` | event |
/// | session locked / unlocked, console or remote session disconnected / connected | `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE` | event |
/// | displays asleep / awake | `WindowsSystemEvents` (`GUID_CONSOLE_DISPLAY_STATE`) | event |
/// | covered by other windows | the cover check (`ptb_window_covered`): our client area minus the visible top-level windows above it | 1 Hz while the window is shown and not minimized, cloaked, locked or the displays off; at once on a foreground change, a move/size end or a minimize anywhere (WinEvent), and on our own `WM_WINDOWPOSCHANGED` / `WM_ACTIVATE` |
///
/// Why a 1 Hz check while shown: DXGI reports no occlusion for flip-model swap chains, and the only event that sees every
/// window move (`EVENT_OBJECT_LOCATIONCHANGE`) also fires for every mouse move anywhere. So a window moved away by a program
/// (no move/size loop, no activation) is seen within a second; everything else at once. Nothing polls while the window is
/// minimized, cloaked, locked, disconnected or the displays are off: those end only by an event.
@MainActor final class WinPlazaVisibility {
    static let coverTimerID: UINT_PTR = 0x5054_4310
    static let coverInterval: UINT = 1000
    /// Windows may delay the 1 Hz check by this much to share a wakeup with other timers.
    static let coverTolerance: ULONG = 100

    var onChange: ((Bool) -> Void)?
    private(set) var visible = false
    private(set) var shown = false, minimized = false, cloaked = false, locked = false, disconnected = false
    private(set) var displaysOff = false, covered = false
    /// Counted for the selftest and the cost line.
    private(set) var coverChecks = 0, changesReported = 0, hookEvents = 0, sessionEvents = 0
    private(set) var coverMicros: Double = 0, lastCoverMicros: Double = 0, lastAbove: UInt32 = 0
    private(set) var isPolling = false
    private(set) var hooksInstalled = 0
    private(set) var sessionRegistered = false
    private var hwnd: HWND?
    /// What the controller was last told; nil until the window is first shown (the controller starts out "visible").
    private var reported: Bool?

    let hookMessage: UINT

    init(hookMessage: UINT) { self.hookMessage = hookMessage }

    /// Registers the event sources for `window` (no polling until it is shown).
    func start(window: HWND, displaysAsleep: Bool) {
        hwnd = window
        displaysOff = displaysAsleep
        hooksInstalled = Int(ptb_window_hooks_install(UnsafeMutableRawPointer(window), hookMessage))
        sessionRegistered = ptb_window_session_notify(UnsafeMutableRawPointer(window), 1) != 0
        if hooksInstalled < 4 { AppLog.write("plaza window: \(hooksInstalled) of 4 WinEvent hooks installed; cloaking or covering may be seen late") }
        if !sessionRegistered { AppLog.write("plaza window: no session notifications (WTSRegisterSessionNotification failed); a locked screen keeps drawing") }
    }

    /// Removes every hook, the session registration and the timer. Nothing is reported afterwards.
    func stop() {
        guard let hwnd else { return }
        setPolling(false)
        ptb_window_hooks_remove()
        hooksInstalled = 0
        if sessionRegistered { _ = ptb_window_session_notify(UnsafeMutableRawPointer(hwnd), 0) }
        sessionRegistered = false
        self.hwnd = nil
        onChange = nil
    }

    // MARK: inputs

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on, reported == nil { reported = true }
        refresh(checkCover: true)
    }

    func setMinimized(_ on: Bool) {
        guard on != minimized else { return }
        minimized = on
        refresh(checkCover: !on)
    }

    /// `WM_WTSSESSION_CHANGE`: 7 lock, 8 unlock, 2 / 4 console / remote disconnect, 1 / 3 connect.
    func sessionChanged(_ code: Int) {
        sessionEvents += 1
        switch code {
        case 7: locked = true
        case 8: locked = false
        case 2, 4: disconnected = true
        case 1, 3: disconnected = false
        default: return
        }
        refresh(checkCover: !locked && !disconnected)
    }

    func displaysChanged(asleep: Bool) {
        guard asleep != displaysOff else { return }
        displaysOff = asleep
        refresh(checkCover: !asleep)
    }

    /// A WinEvent the hooks posted (`wParam` = the event).
    func hookEvent(_ event: UInt32) {
        hookEvents += 1
        if event == 0x8017 || event == 0x8018 {  // EVENT_OBJECT_CLOAKED / UNCLOAKED: read the attribute itself
            let now = hwnd.map { ptb_window_cloaked(UnsafeMutableRawPointer($0)) != 0 } ?? false
            if now != cloaked {
                cloaked = now
                refresh(checkCover: !now)
            }
            return
        }
        ptb_window_hooks_ack()
        checkCoverNow()
    }

    /// Our own `WM_WINDOWPOSCHANGED` / `WM_ACTIVATE`, and the 1 Hz timer.
    func checkCoverNow() {
        guard isPolling else { return }
        refresh(checkCover: true)
    }

    // MARK: -

    private var canBeSeen: Bool { shown && !minimized && !cloaked && !locked && !disconnected && !displaysOff }

    private func refresh(checkCover: Bool) {
        setPolling(canBeSeen)
        if checkCover, canBeSeen, let hwnd {
            let t0 = WinPlazaClock.seconds()
            var above: UInt32 = 0
            covered = ptb_window_covered(UnsafeMutableRawPointer(hwnd), &above) != 0
            lastCoverMicros = (WinPlazaClock.seconds() - t0) * 1e6
            coverMicros += lastCoverMicros
            lastAbove = above
            coverChecks += 1
        }
        let now = canBeSeen && !covered
        visible = now
        guard let last = reported, now != last else { return }
        reported = now
        changesReported += 1
        onChange?(now)
    }

    private typealias CoalescableFn = @convention(c) (HWND?, UINT_PTR, UINT, UnsafeMutableRawPointer?, ULONG) -> UINT_PTR

    private func setPolling(_ on: Bool) {
        guard on != isPolling, let hwnd else { return }
        isPolling = on
        if on {
            if let coalescable = WinDynamic.symbol("user32.dll", "SetCoalescableTimer", as: CoalescableFn.self) {
                _ = coalescable(hwnd, Self.coverTimerID, Self.coverInterval, nil, Self.coverTolerance)
            } else {
                _ = SetTimer(hwnd, Self.coverTimerID, Self.coverInterval, nil)
            }
        } else {
            _ = KillTimer(hwnd, Self.coverTimerID)
        }
    }
}

/// Monotonic seconds for the frame clock and the cost lines (`QueryPerformanceCounter`; process-relative origin).
enum WinPlazaClock {
    private static let frequency: Double = {
        var f = LARGE_INTEGER()
        _ = QueryPerformanceFrequency(&f)
        return Double(f.QuadPart)
    }()

    static func seconds() -> Double {
        var c = LARGE_INTEGER()
        _ = QueryPerformanceCounter(&c)
        return Double(c.QuadPart) / frequency
    }
}
#endif
