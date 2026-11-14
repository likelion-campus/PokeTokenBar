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

    /// `GUI_INMOVESIZE | GUI_INMENUMODE | GUI_SYSTEMMENUMODE | GUI_POPUPMENUMODE` for this thread.
    private static func inMenuOrMoveLoop() -> Bool {
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        guard GetGUIThreadInfo(GetCurrentThreadId(), &info) else { return false }
        return info.flags & 0x1E != 0
    }

    fileprivate static func removed(_ messageBits: Int) {
        guard let m = UnsafeMutablePointer<MSG>(bitPattern: messageBits) else { return }
        let message = m.pointee.message
        if !dialogs.isEmpty, let target = m.pointee.hwnd {
            for bits in dialogs {
                guard let dialog = HWND(bitPattern: bits), dialog == target || IsChild(dialog, target) else { continue }
                var copy = m.pointee
                if IsDialogMessageW(dialog, &copy) {
                    m.pointee.message = UINT(WM_NULL)
                    return
                }
            }
        }
        switch message {
        case UINT(WM_CHAR), UINT(WM_SYSCHAR), UINT(WM_DEADCHAR), UINT(WM_SYSDEADCHAR):
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
