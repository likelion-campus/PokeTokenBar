#if os(Windows)
import Foundation
import WinSDK

/// `--ime-check`, for the PC check (Task 13): a small window with an `EDIT` box under the shipped loop and hook.
/// Type Hangul (or anything) with the system IME. Each change logs the box's text as code points, and the window
/// title shows them; the hook logs every character and IME message the pump removes, so a `?` (0x3f) or a
/// missing character shows where text was lost (F15). Closing the window ends the process.
@MainActor enum WinImeCheck {
    static func run() -> Never {
        let strategy = WinMainLoop.prepare()
        let hooked = WinMessageHook.install()
        let window: WinSinkWindow
        do {
            window = try WinSinkWindow(className: "PokeTokenBarImeCheck", title: "PokeTokenBar IME check: type here",
                                       style: DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE), exStyle: 0,
                                       x: 120, y: 120, width: 520, height: 140)
        } catch {
            AppLog.writeAndFlush("ime-check: \(error)")
            WindowsApp.exit(1, .helper)
        }
        let style = DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_BORDER) | DWORD(ES_AUTOHSCROLL)
        guard let edit = CreateWindowExW(0, WinStr.w("EDIT"), WinStr.w(""), style, 12, 16, 480, 30,
                                         window.hwnd, nil, GetModuleHandleW(nil), nil) else {
            AppLog.writeAndFlush("ime-check: EDIT control failed: \(GetLastError())")
            WindowsApp.exit(1, .helper)
        }
        AppLog.write("ime-check start acp=\(GetACP()) hook=\(hooked) loop=\(strategy.rawValue) "
            + "editUnicode=\(IsWindowUnicode(edit))")
        WinMessageHook.observer = { message, wParam, redispatched in
            AppLog.write("ime-check pump msg=0x\(String(message, radix: 16)) wParam=0x\(String(wParam, radix: 16)) "
                + "redispatched=\(redispatched)")
        }
        window.on(UINT(WM_COMMAND)) { wParam, _ in
            guard (wParam >> 16) & 0xFFFF == 0x0300 else { return nil }  // EN_CHANGE
            let points = codePoints(of: edit)
            AppLog.write("ime-check text=\(points)")
            _ = SetWindowTextW(window.hwnd, WinStr.w("IME check: \(points)"))
            return 0
        }
        window.on(UINT(WM_CLOSE)) { _, _ in
            AppLog.writeAndFlush("ime-check closed text=\(codePoints(of: edit))")
            WindowsApp.exit(0, .helper)
        }
        _ = SetForegroundWindow(window.hwnd)
        _ = SetFocus(edit)
        WinMainLoop.run(strategy) { false }
        WindowsApp.exit(0, .helper)
    }

    private static func codePoints(of edit: HWND) -> String {
        var buffer = [UInt16](repeating: 0, count: 1024)
        let n = Int(GetWindowTextW(edit, &buffer, Int32(buffer.count)))
        let text = String(decoding: buffer.prefix(max(0, n)), as: UTF16.self)
        return text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }
}
#endif
