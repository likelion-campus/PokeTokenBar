#if os(Windows)
import Foundation
import WinSDK

/// Keeps the main run loop served while a Win32 modal loop owns the main thread (`TrackPopupMenu`, `MessageBoxW`,
/// the window move/size loop of any window of ours). Those loops run their own message loop and dispatch only
/// window messages, so without this the main dispatch queue, `RunLoop` timers and `@MainActor` tasks stand still
/// for as long as they last: no store refresh, no team heartbeats (a teammate drops a member after 30 s). The Mac
/// keeps serving its main queue while a menu is open.
///
/// While at least one modal loop is active there is one `WM_TIMER` (every `interval` ms) on the sink window; the
/// modal loop dispatches it, and the handler runs the main run loop for zero time. The timer exists only between
/// the first `begin` and the last `end`: nothing wakes the process when no modal loop is active.
///
/// Any code that starts a modal loop calls `begin(_:)` before and `end(_:)` after it (`defer`), on the main thread.
@MainActor enum WinModalPump {
    /// The tick period in milliseconds.
    static let interval: UINT = 50
    private static let timerID: UINT_PTR = 0x5054_4201
    /// WM_ENTERMENULOOP / WM_EXITMENULOOP / WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE.
    static let enterMenuLoop: UINT = 0x0211, exitMenuLoop: UINT = 0x0212
    static let enterSizeMove: UINT = 0x0231, exitSizeMove: UINT = 0x0232

    private static var window: WinSinkWindow?
    private static var inTick = false

    /// Nesting of active modal loops (a menu inside a size/move loop is two).
    private(set) static var depth = 0
    private(set) static var timerLive = false
    // What the selftest reads.
    private(set) static var timersSet = 0
    private(set) static var timersKilled = 0
    private(set) static var killFailures = 0
    private(set) static var ticks = 0
    private(set) static var reentrantTicksSkipped = 0
    /// Notifications that reached the sink, by message (the selftest reports which a tray menu delivers).
    private(set) static var delivered: [UINT: Int] = [:]
    private(set) static var beginsWithoutWindow = 0
    /// How a tick keeps CoreFoundation away from the thread's input queue (the selftest prints it).
    private(set) static var maskStrategy = "unresolved"

    /// CoreFoundation's per-mode Win32 message-queue mask (`_CFRunLoopSetWindowsMessageQueueMask`). With the mask 0 a
    /// run loop pass services timers, sources and the main dispatch queue but never calls `PeekMessage`, so it cannot
    /// pull the menu's keystrokes out of the thread queue. Foundation sets the default mode's mask to `QS_ALLINPUT`
    /// when `RunLoop.main` is first touched; the tick sets it to 0 for its own pass and puts the old value back.
    private struct MaskSPI {
        typealias GetMain = @convention(c) () -> UnsafeMutableRawPointer?
        typealias GetMask = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> UInt32
        typealias SetMask = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeRawPointer?) -> Void
        let getMain: GetMain, getMask: GetMask, setMask: SetMask
        let defaultMode: UnsafeRawPointer

        /// What the lookup found, for the log and the selftest line.
        nonisolated(unsafe) static var report = ""

        init?() {
            var seen: [String] = []
            func find<T>(_ name: String, as type: T.Type) -> T? {
                for module in ["CoreFoundation.dll", "Foundation.dll"] {
                    if let found = WinDynamic.symbol(module, name, as: type) { seen.append("\(name)@\(module)"); return found }
                }
                seen.append("\(name)=missing")
                return nil
            }
            let getMain = find("CFRunLoopGetMain", as: GetMain.self)
            let getMask = find("_CFRunLoopGetWindowsMessageQueueMask", as: GetMask.self)
            let setMask = find("_CFRunLoopSetWindowsMessageQueueMask", as: SetMask.self)
            let modeVar = find("kCFRunLoopDefaultMode", as: UnsafePointer<UnsafeRawPointer?>.self)
            Self.report = seen.joined(separator: " ")
            guard let getMain, let getMask, let setMask, let mode = modeVar?.pointee else { return nil }
            self.getMain = getMain
            self.getMask = getMask
            self.setMask = setMask
            defaultMode = mode
        }
    }

    private static var maskSPI: MaskSPI?
    private static func resolveMaskSPI() {
        maskSPI = MaskSPI()
        maskStrategy = (maskSPI == nil ? "fallback: tick skipped while input is pending (CoreFoundation SPI not found)"
            : "CoreFoundation message-queue mask 0 for the tick") + " [\(MaskSPI.report)]"
        if maskSPI == nil { AppLog.write("modal pump: \(maskStrategy)") }
    }

    /// Verified on the runner: a tray menu opened with `TPM_NONOTIFY` delivers neither WM_ENTERMENULOOP nor
    /// WM_EXITMENULOOP to the owner, so `WinPopupMenu.run` calls `begin`/`end` itself. The size/move pair is the
    /// generic hook for windows of ours.
    /// Registers the timer and the size/move notifications on the window that owns the modal loops (the sink).
    static func install(on sink: WinSinkWindow) {
        window = sink
        resolveMaskSPI()  // resolve now, on the main thread, never inside a modal loop
        sink.on(UINT(WM_TIMER)) { wParam, _ in
            guard wParam == WPARAM(timerID) else { return nil }
            tick()
            return 0
        }
        sink.on(enterMenuLoop) { _, _ in delivered[enterMenuLoop, default: 0] += 1; return nil }
        sink.on(exitMenuLoop) { _, _ in delivered[exitMenuLoop, default: 0] += 1; return nil }
        sink.on(enterSizeMove) { _, _ in delivered[enterSizeMove, default: 0] += 1; begin("sizemove"); return nil }
        sink.on(exitSizeMove) { _, _ in delivered[exitSizeMove, default: 0] += 1; end("sizemove"); return nil }
    }

    static func begin(_ reason: String) {
        depth += 1
        guard depth == 1 else { return }
        guard let hwnd = window?.hwnd else { beginsWithoutWindow += 1; return }
        guard SetTimer(hwnd, timerID, interval, nil) != 0 else {
            AppLog.write("modal pump: SetTimer failed (\(reason)): \(GetLastError())")
            return
        }
        timerLive = true
        timersSet += 1
    }

    static func end(_ reason: String) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, timerLive, let hwnd = window?.hwnd else { return }
        timerLive = false
        if KillTimer(hwnd, timerID) { timersKilled += 1 } else {
            killFailures += 1
            AppLog.write("modal pump: KillTimer failed (\(reason)): \(GetLastError())")
        }
    }

    /// Asks every open modal menu to close (the exit path calls it before leaving the process).
    static func cancelModalLoops() {
        if depth > 0 { _ = EndMenu() }
    }

    /// Selftest probe: whether the pump's timer still exists (it is killed by this call when it does).
    static func probeTimerExists() -> Bool {
        guard let hwnd = window?.hwnd else { return false }
        return KillTimer(hwnd, timerID)
    }

    /// One zero-time pass of the main run loop. Not re-entrant: a nested modal loop started by the work it runs
    /// (or a `WM_TIMER` the nested pass dispatches) must not recurse into `RunLoop.run`.
    private static func tick() {
        guard !inTick else { reentrantTicksSkipped += 1; return }
        inTick = true
        defer { inTick = false }
        ticks += 1
        guard let spi = maskSPI else {
            // No SPI: never run a pass while input waits for the modal loop (a remaining race, logged at startup).
            if GetQueueStatus(0x0407 /* QS_INPUT */) >> 16 != 0 { return }
            _ = RunLoop.main.run(mode: .default, before: Date())
            return
        }
        let main = spi.getMain()
        let saved = spi.getMask(main, spi.defaultMode)
        spi.setMask(main, 0, spi.defaultMode)
        defer { spi.setMask(main, saved, spi.defaultMode) }
        _ = RunLoop.main.run(mode: .default, before: Date())
    }
}
#endif
