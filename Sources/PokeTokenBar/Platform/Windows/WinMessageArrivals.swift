#if os(Windows)
import Foundation
import WinSDK

/// What reaches the main thread during one of the selftest's idle windows (`modalPump.idle`; judged by `IdleBurstAttribution`):
/// messages SENT from another thread or process (WH_CALLWNDPROC with wParam 0: a broadcast arrives as one per top-level window, handled
/// inside the pump without a loop iteration) and messages POSTED to the thread that the pump removes (WH_GETMESSAGE, PM_REMOVE). Thread
/// hooks on the main thread, only between `begin` and `end`; the hooks append to a plain array (they run on the main thread only).
enum WinMessageArrivals {
    nonisolated(unsafe) private static var started = Date()
    nonisolated(unsafe) private static var list: [IdleBurstAttribution.Arrival] = []
    nonisolated(unsafe) private static var hooks: [HHOOK] = []
    static let capacity = 4096

    @MainActor static func begin() {
        _ = end()
        list.reserveCapacity(256)
        started = Date()
        let thread = GetCurrentThreadId()
        if let h = SetWindowsHookExW(WH_CALLWNDPROC, { code, wParam, lParam in winArrivalSent(code, wParam, lParam) }, nil, thread) { hooks.append(h) }
        if let h = SetWindowsHookExW(WH_GETMESSAGE, { code, wParam, lParam in winArrivalPosted(code, wParam, lParam) }, nil, thread) { hooks.append(h) }
    }

    /// Removes the hooks and hands over what arrived (seconds from `begin`).
    @MainActor static func end() -> [IdleBurstAttribution.Arrival] {
        for h in hooks { _ = UnhookWindowsHookEx(h) }
        hooks = []
        let out = list
        list = []
        return out
    }

    fileprivate static func record(_ message: UInt32, _ hwnd: HWND?, posted: Bool) {
        guard list.count < capacity else { return }
        let root = hwnd.flatMap { GetAncestor($0, UINT(GA_ROOT)) }
        list.append(IdleBurstAttribution.Arrival(t: Date().timeIntervalSince(started), message: message, root: Int(bitPattern: root),
                                                 rootClass: root == nil ? "-" : WinKit.className(root), posted: posted))
    }
}

private func winArrivalSent(_ code: Int32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    // wParam: "nonzero if the message was sent by the current thread" (CallWndProc): only the others' sends wake the thread.
    if code == HC_ACTION, wParam == 0, let p = UnsafePointer<CWPSTRUCT>(bitPattern: Int(lParam)) {
        WinMessageArrivals.record(p.pointee.message, p.pointee.hwnd, posted: false)
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}

private func winArrivalPosted(_ code: Int32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if code == HC_ACTION, wParam & WPARAM(PM_REMOVE) != 0, let m = UnsafePointer<MSG>(bitPattern: Int(lParam)) {
        WinMessageArrivals.record(m.pointee.message, m.pointee.hwnd, posted: true)
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}
#endif
