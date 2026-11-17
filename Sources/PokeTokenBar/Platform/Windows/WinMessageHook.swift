#if os(Windows)
import Foundation
import WinSDK

/// CoreFoundation's message pump is the ANSI one (`PeekMessage`/`DispatchMessage` without `UNICODE`) and cannot be
/// replaced, so a character outside the code page (U+D55C on code page 1252) reaches a Unicode window as `?` (F15).
/// A thread-local `WH_GETMESSAGE` hook sees each message the pump removes in its Unicode form first: for a Unicode
/// window it dispatches the character itself with `DispatchMessageW` and hands the pump a `WM_NULL`. Everything
/// else passes untouched. Installed once, on the main thread.
@MainActor enum WinMessageHook {
    private static var hook: HHOOK?
    /// Characters the hook delivered itself (the selftest reads it).
    private(set) static var redispatchedChars = 0
    private static var dialogs: [Int] = []
    /// Diagnostics for `--ime-check`: each character or IME message the pump removes, and whether it was re-dispatched.
    static var observer: ((UINT, WPARAM, Bool) -> Void)?

    static func install() -> Bool {
        if hook != nil { return true }
        hook = SetWindowsHookExW(WH_GETMESSAGE, { code, wParam, lParam in winGetMessageHook(code, wParam, lParam) },
                                 nil, GetCurrentThreadId())
        if hook == nil { AppLog.write("SetWindowsHookExW(WH_GETMESSAGE) failed: \(GetLastError())") }
        return hook != nil
    }

    /// Stage 7: messages for this window or its children go through `IsDialogMessageW` (keyboard navigation).
    static func registerDialogWindow(_ hwnd: HWND) {
        let bits = Int(bitPattern: hwnd)
        if !dialogs.contains(bits) { dialogs.append(bits) }
    }

    /// Stage 7 Task 3: the window is being destroyed; its messages take the normal path again. A handle left here would
    /// send a later window that reuses the value through `IsDialogMessageW` of a window that no longer exists.
    static func unregisterDialogWindow(_ hwnd: HWND) {
        let bits = Int(bitPattern: hwnd)
        dialogs.removeAll { $0 == bits }
    }

    /// What the selftest reads: registered dialog windows, messages `IsDialogMessageW` took, and the ones left to a modal
    /// loop (a menu, a scroll bar's thumb drag, a dialog) instead.
    static var dialogWindowCount: Int { dialogs.count }
    private(set) static var dialogMessages = 0
    private(set) static var dialogMessagesLeftToModalLoop = 0

    /// `GUI_INMOVESIZE | GUI_INMENUMODE | GUI_SYSTEMMENUMODE | GUI_POPUPMENUMODE` for this thread.
    private static func inMenuOrMoveLoop() -> Bool {
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        guard GetGUIThreadInfo(GetCurrentThreadId(), &info) else { return false }
        return info.flags & 0x1E != 0
    }

    // --- stage 7 Task 22: a selftest tap on every message the pump removes (pet.idle's waker report) (begin) ---
    /// Set (empty) only by a selftest window that names what woke the main thread: messages removed, counted by
    /// `0x<message>@<window class>`; nil otherwise (nothing is counted).
    static var tapCounts: [String: Int]?
    // --- stage 7 Task 22 (end) ---

    fileprivate static func removed(_ messageBits: Int) {
        guard let m = UnsafeMutablePointer<MSG>(bitPattern: messageBits) else { return }
        let message = m.pointee.message
        // stage 7 Task 22: pet.idle's waker report (counts only, no closure: #272's note on a main-actor closure in this hook).
        if tapCounts != nil { tapCounts?["0x\(String(message, radix: 16))@\(m.pointee.hwnd.map { WinKit.className($0) } ?? "thread")", default: 0] += 1 }
        // A wParam can use all 64 bits (the shell's file dialog posts one at or above 2^63): `WakeTrace.message` takes it unsigned
        // (`Int(_:)` trapped on it — the transfer dialogs' checks died with exit 0xC000041D, #270).
        if WakeTrace.enabled {   // the class name is asked only while counting (the closure form trapped: a main-actor closure called from a nonisolated function)
            WakeTrace.message(message, wParam: UInt(m.pointee.wParam), target: m.pointee.hwnd.map { WinKit.className($0) } ?? "-")
        }   // idle gate attribution (off unless PTB_WAKE_TRACE=1)
        // Mouse messages (client 0x0200–0x020E, non-client 0x00A0–0x00AD) never take the dialog path: IsDialogMessageW only
        // dispatches them, and a tracking loop that DefWindowProc runs on a non-client click (a scroll bar's arrow or thumb,
        // even without WinModalPump.begin) must read its own button-up. Handing it WM_NULL left the loop holding the capture
        // (post-merge review of the kit; defect log, the modal-loop entry).
        let isMouse = (0x0200...0x020E).contains(message) || (0x00A0...0x00AD).contains(message)
        if !dialogs.isEmpty, !isMouse, let target = m.pointee.hwnd {
            for bits in dialogs {
                guard let dialog = HWND(bitPattern: bits), dialog == target || IsChild(dialog, target) else { continue }
                // The hook runs inside every message removal of the thread, also the ones a modal loop makes for itself
                // (a menu's, a scroll bar thumb drag's, a dialog's; all of ours run between WinModalPump.begin/end). Those
                // loops read their own keys and mouse messages: dispatching them here would take the loop's input away.
                if WinModalPump.depth > 0 || inMenuOrMoveLoop() {
                    dialogMessagesLeftToModalLoop += 1
                    break
                }
                var copy = m.pointee
                if IsDialogMessageW(dialog, &copy) {
                    m.pointee.message = UINT(WM_NULL)
                    dialogMessages += 1
                    return
                }
            }
        }
        switch message {
        case UINT(WM_CHAR), UINT(WM_SYSCHAR), UINT(WM_DEADCHAR), UINT(WM_SYSDEADCHAR), 0x0286 /* WM_IME_CHAR: Hangul from the IME (D13) */:
            // Only our own windows (and their children, e.g. an edit control), and never while the thread is in a menu or
            // move/size loop: that loop reads the WM_CHAR itself (menu mnemonics, type-to-select) and must not get a
            // WM_NULL instead. Other modal loops (MessageBoxW) own their windows, which are not ours.
            guard let target = m.pointee.hwnd, IsWindowUnicode(target), WinSinkWindow.owns(target),
                  !inMenuOrMoveLoop() else { return }
            var copy = m.pointee
            m.pointee.message = UINT(WM_NULL)
            redispatchedChars += 1
            observer?(message, copy.wParam, true)
            _ = DispatchMessageW(&copy)
        case 0x010D...0x010F, 0x0281...0x0291:  // WM_IME_STARTCOMPOSITION…WM_IME_COMPOSITION, WM_IME_SETCONTEXT…WM_IME_KEYUP
            observer?(message, m.pointee.wParam, false)
        default:
            break
        }
    }
}

/// Runs on the thread whose queue is read, which is the main thread (the hook is thread-local), so entering the main
/// actor is sound (F16). CF removes with `PM_REMOVE | PM_NOYIELD`: test the bit, not equality.
private func winGetMessageHook(_ code: Int32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if code == HC_ACTION, wParam & WPARAM(PM_REMOVE) != 0 {
        let bits = Int(lParam)
        MainActor.assumeIsolated { WinMessageHook.removed(bits) }
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}
#endif
