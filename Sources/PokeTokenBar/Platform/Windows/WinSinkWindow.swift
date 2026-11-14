#if os(Windows)
import Foundation
import WinSDK

/// NUL-terminated UTF-16 for Win32 wide-string parameters.
enum WinStr {
    static func w(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }
}

struct WinError: Error, CustomStringConvertible {
    let call: String
    let code: DWORD
    var description: String { "\(call) failed: \(code)" }
}

/// The app's hidden top-level window: the target for posted messages (second instance, selftest) and for the
/// broadcasts that only reach top-level windows (`WM_POWERBROADCAST`, `WM_ENDSESSION`, `TaskbarCreated`), which is
/// why it is not an `HWND_MESSAGE` window. Created on the main thread after `RunLoop.main` was touched (F4).
/// Every window the app makes routes through here, so new windows add handlers, never a second loop.
@MainActor final class WinSinkWindow {
    nonisolated static let className = "PokeTokenBarSink"

    let hwnd: HWND
    typealias Handler = @MainActor (WPARAM, LPARAM) -> LRESULT?
    /// One registration; `off(_:)` removes exactly this one.
    struct Token: Hashable {
        let message: UINT
        fileprivate let id: Int
    }
    private var handlers: [UINT: [(id: Int, handler: Handler)]] = [:]
    private var nextID = 0
    private static var windows: [Int: WinSinkWindow] = [:]
    private static var registeredClasses: Set<String> = []

    /// The sink. `title` lets a second instance find the one that owns its mutex (`FindWindowW(className, title)`).
    convenience init(title: String = WinSinkWindow.className) throws {
        try self.init(className: Self.className, title: title, style: DWORD(WS_OVERLAPPED), exStyle: 0,
                      x: 0, y: 0, width: 0, height: 0)
    }

    /// Any other window of ours (the selftest's input window, `--ime-check`). Same routing as the sink.
    init(className: String, title: String, style: DWORD, exStyle: DWORD,
         x: Int32, y: Int32, width: Int32, height: Int32) throws {
        let instance = GetModuleHandleW(nil)
        try Self.register(className, instance)
        guard let h = CreateWindowExW(exStyle, WinStr.w(className), WinStr.w(title), style, x, y, width, height,
                                      nil, nil, instance, nil) else {
            throw WinError(call: "CreateWindowExW(\(className))", code: GetLastError())
        }
        hwnd = h
        Self.windows[Int(bitPattern: h)] = self
    }

    /// Adds a handler for a message. Every handler of a message runs, in registration order; the first non-nil
    /// result is returned to Windows, and nil from all falls through to `DefWindowProcW`. Several parties
    /// (tray, system events, the selftest) register for the same messages, so none replaces another.
    @discardableResult
    func on(_ message: UINT, _ handler: @escaping Handler) -> Token {
        nextID += 1
        handlers[message, default: []].append((nextID, handler))
        return Token(message: message, id: nextID)
    }

    /// Removes only the registration the token came from.
    func off(_ token: Token) {
        handlers[token.message]?.removeAll { $0.id == token.id }
        if handlers[token.message]?.isEmpty == true { handlers[token.message] = nil }
    }

    /// A message registered by name (`RegisterWindowMessageW`), e.g. the shell's `TaskbarCreated`.
    @discardableResult
    func onRegistered(_ name: String, _ handler: @escaping @MainActor () -> Void) -> Token? {
        let id = RegisterWindowMessageW(WinStr.w(name))
        guard id != 0 else { AppLog.write("RegisterWindowMessageW(\(name)) failed: \(GetLastError())"); return nil }
        return on(id) { _, _ in handler(); return 0 }
    }

    /// Whether `hwnd` is one of our windows or a child of one (the message hook re-dispatches characters for those only).
    static func owns(_ hwnd: HWND) -> Bool {
        windows[Int(bitPattern: hwnd)] != nil || GetAncestor(hwnd, UINT(GA_ROOT)).map { windows[Int(bitPattern: $0)] != nil } == true
    }

    func destroy() {
        Self.windows[Int(bitPattern: hwnd)] = nil
        _ = DestroyWindow(hwnd)
    }

    private static func register(_ name: String, _ instance: HINSTANCE?) throws {
        guard !registeredClasses.contains(name) else { return }
        let atom = WinStr.w(name).withUnsafeBufferPointer { p -> ATOM in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = { hwnd, message, wParam, lParam in winRoute(hwnd, message, wParam, lParam) }
            wc.hInstance = instance
            wc.lpszClassName = p.baseAddress
            return RegisterClassExW(&wc)
        }
        let error = GetLastError()
        if atom == 0, error != 1410 /* ERROR_CLASS_ALREADY_EXISTS */ {
            throw WinError(call: "RegisterClassExW(\(name))", code: error)
        }
        registeredClasses.insert(name)
    }

    fileprivate static func route(_ bits: Int, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let list = windows[bits]?.handlers[message] else { return nil }
        var result: LRESULT?
        for entry in list {  // a copy: a handler may add or remove registrations
            let r = entry.handler(wParam, lParam)
            if result == nil { result = r }
        }
        return result
    }
}

/// The window procedure of every class above. Windows calls it on the thread that made the window, the main thread,
/// so entering the main actor here is sound (F16). Messages that arrive inside `CreateWindowExW` (before the window
/// is in the table) go to `DefWindowProcW`.
private func winRoute(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    let bits = Int(bitPattern: hwnd)
    if let result = MainActor.assumeIsolated({ WinSinkWindow.route(bits, message, wParam, lParam) }) { return result }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}
#endif
