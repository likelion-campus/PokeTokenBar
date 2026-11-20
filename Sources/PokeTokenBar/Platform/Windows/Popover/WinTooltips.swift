#if os(Windows)
import Foundation
import WinSDK

/// The popover's hover texts (SwiftUI's `.help`, stage 7 D7): one `tooltips_class32` window per popover, owned by it,
/// showing after 600 ms as the Mac app registers `NSInitialToolTipDelay` (inventory A5t). Tools are a control
/// (`TTF_IDISHWND`) or a rectangle of a window (a drawn part's tooltip). `TTF_SUBCLASS` lets the tooltip watch the mouse
/// itself: no timer of ours, and the tooltip's own timer runs only while the mouse rests on a tool.
@MainActor final class WinTooltips {
    /// The Mac app's `NSInitialToolTipDelay`.
    static let initialDelayMs = 600

    private enum Msg {
        static let activate: UINT = 0x0401, setDelayTime: UINT = 0x0403, getToolCount: UINT = 0x040D, getDelayTime: UINT = 0x0415
        static let setMaxTipWidth: UINT = 0x0418, addTool: UINT = 0x0432, delTool: UINT = 0x0433, newToolRect: UINT = 0x0434
        static let updateTipText: UINT = 0x0439
    }
    private static let idIsHwnd: UINT = 0x0001, subclass: UINT = 0x0010

    private(set) var hwnd: HWND?
    /// (window bits, id) of every tool added, so a window's tools can be removed together.
    private var tools: [(window: Int, id: UInt)] = []

    init(owner: HWND?, font: HFONT?, maxWidth: Int32) {
        let style: DWORD = 0x8000_0000 | 0x01 | 0x02  // WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX
        let cw = Int32.min  // CW_USEDEFAULT
        hwnd = CreateWindowExW(0x0000_0008 /* WS_EX_TOPMOST */, WinStr.w("tooltips_class32"), nil, style, cw, cw, cw, cw, owner, nil,
                               WinKit.module, nil)
        guard let hwnd else {
            AppLog.write("popover kit: no tooltip window (\(GetLastError())); hover texts stay off")
            return
        }
        WinKit.setFont(hwnd, font)
        WinKit.send(hwnd, Msg.setDelayTime, 3 /* TTDT_INITIAL */, Self.initialDelayMs)
        WinKit.send(hwnd, Msg.setDelayTime, 2 /* TTDT_AUTOPOP */, 20_000)
        WinKit.send(hwnd, Msg.setMaxTipWidth, 0, Int(maxWidth))
    }

    /// Dark mode (Task 16): the tooltip window's own colours. Visual styles would override them, so the window is taken off
    /// its theme first (the Mac's dark help tags are plain dark gray too).
    func dress(background: COLORREF, text: COLORREF) {
        guard let hwnd else { return }
        WinDarkMode.setTheme(hwnd, "")
        WinKit.send(hwnd, 0x0413 /* TTM_SETTIPBKCOLOR */, Int(background))
        WinKit.send(hwnd, 0x0414 /* TTM_SETTIPTEXTCOLOR */, Int(text))
    }

    /// Adds or updates the hover text of a control; nil removes it.
    func set(_ text: String?, for control: HWND, in parent: HWND?) {
        let id = UInt(bitPattern: Int(bitPattern: control))
        guard let text, !text.isEmpty else { remove(window: parent ?? control, id: id, flags: Self.idIsHwnd); return }
        tool(text, window: parent ?? control, id: id, flags: Self.idIsHwnd | Self.subclass, rect: RECT())
    }

    /// A rectangle of `window` (client pixels) with its own id.
    func setRect(_ text: String, id: Int, rect: RECT, in window: HWND) {
        tool(text, window: window, id: UInt(id), flags: Self.subclass, rect: rect)
    }

    /// Every tool that was added for `window` (as the tool's window: rect tools and the controls added with it as parent).
    func removeAll(in window: HWND) {
        let bits = Int(bitPattern: window)
        for t in tools where t.window == bits {
            var info = Self.info(window: window, id: t.id, flags: 0, rect: RECT())
            _ = withUnsafeMutablePointer(to: &info) { WinKit.send(hwnd, Msg.delTool, 0, Int(bitPattern: $0)) }
        }
        tools.removeAll { $0.window == bits }
    }

    var count: Int { hwnd.map { WinKit.send($0, Msg.getToolCount) } ?? 0 }
    var initialDelay: Int { hwnd.map { WinKit.send($0, Msg.getDelayTime, 3) } ?? -1 }

    func destroy() {
        if let hwnd { _ = DestroyWindow(hwnd) }
        hwnd = nil
        tools = []
    }

    private func tool(_ text: String, window: HWND, id: UInt, flags: UINT, rect: RECT) {
        guard let hwnd else { return }
        let bits = Int(bitPattern: window)
        var wide = WinStr.w(text)
        let known = tools.contains { $0.window == bits && $0.id == id }
        wide.withUnsafeMutableBufferPointer { buffer in
            var info = Self.info(window: window, id: id, flags: flags, rect: rect)
            info.lpszText = buffer.baseAddress
            withUnsafeMutablePointer(to: &info) { p in
                if known {
                    WinKit.send(hwnd, Msg.updateTipText, 0, Int(bitPattern: p))
                    if flags & Self.idIsHwnd == 0 { WinKit.send(hwnd, Msg.newToolRect, 0, Int(bitPattern: p)) }
                } else if WinKit.send(hwnd, Msg.addTool, 0, Int(bitPattern: p)) == 0 {
                    AppLog.write("popover kit: TTM_ADDTOOLW failed")
                }
            }
        }
        if !known { tools.append((bits, id)) }
    }

    private func remove(window: HWND, id: UInt, flags: UINT) {
        let bits = Int(bitPattern: window)
        guard tools.contains(where: { $0.window == bits && $0.id == id }) else { return }
        var info = Self.info(window: window, id: id, flags: flags, rect: RECT())
        _ = withUnsafeMutablePointer(to: &info) { WinKit.send(hwnd, Msg.delTool, 0, Int(bitPattern: $0)) }
        tools.removeAll { $0.window == bits && $0.id == id }
    }

    private static func info(window: HWND, id: UInt, flags: UINT, rect: RECT) -> TTTOOLINFOW {
        var info = TTTOOLINFOW()
        info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
        info.uFlags = flags
        info.hwnd = window
        info.uId = UINT_PTR(id)
        info.rect = rect
        info.hinst = WinKit.module
        return info
    }
}
#endif
