#if os(Windows)
import Foundation
import WinSDK

/// The small window of an in-app update (stage 8 ruling 5: "silent install with a small progress window"): a line of text,
/// a progress bar and Cancel, opened only by the user's "Update". Plain Win32 controls (Static, msctls_progress32, Button) on
/// a window routed through `WinSinkWindow`: no modal loop of its own, so nothing here can hold the main thread; dragging it is
/// a size/move loop and keeps the main run loop served through `WinModalPump`. It ends with the app (Setup has started) or
/// closes on a failure or a cancel. Nothing in it runs on a timer: the bar moves when a download progress hop arrives.
@MainActor final class WinUpdateProgressWindow: WindowsUpdateProgress {
    static let className = "PokeTokenBarUpdateProgress"
    static let cancelID = 3

    private let l: L
    private var window: WinSinkWindow?
    private var label: HWND?
    private var bar: HWND?
    private var button: HWND?
    private var font: HFONT?
    private var cancel: (@MainActor () -> Void)?
    private var version = ""
    /// What the selftest and the CI e2e read.
    private(set) static var shown = 0
    private(set) var lastText = ""

    init(l: L) { self.l = l }

    func began(version: String, total: Int, cancel: @escaping @MainActor () -> Void) {
        self.version = version
        self.cancel = cancel
        guard window == nil else { return }
        open(total: total)
    }

    func received(_ bytes: Int, of total: Int) {
        guard window != nil else { return }
        let permille = total > 0 ? min(1000, bytes * 1000 / total) : 0
        if let bar { _ = SendMessageW(bar, 0x0402 /* PBM_SETPOS */, WPARAM(permille), 0) }
        setText(l.updateDownloading(version) + "\r\n" + Self.megabytes(bytes) + " / " + Self.megabytes(total) + " MB")
    }

    func checking() { setText(l.updateChecking) }

    func starting() {
        cancel = nil
        if let button { _ = EnableWindow(button, false) }
        setText(l.updateStartingSetup)
    }

    func close() {
        cancel = nil
        window?.destroy()
        window = nil
        label = nil
        bar = nil
        button = nil
        if let font { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        font = nil
    }

    /// "12.3": bytes in megabytes (10^6) with one decimal, independent of the region format.
    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_000_000) }

    // MARK: -

    private func setText(_ text: String) {
        lastText = text
        if let label { _ = SetWindowTextW(label, WinStr.w(text)) }
    }

    private func requestCancel() {
        guard let cancel else { return }
        self.cancel = nil
        AppLog.write("update: the user cancelled the download of v\(version)")
        cancel()
    }

    private func open(total: Int) {
        typealias DpiFn = @convention(c) () -> UINT
        let dpi = Int(WinDynamic.symbol("user32.dll", "GetDpiForSystem", as: DpiFn.self)?() ?? 96)
        func px(_ v: Int) -> Int32 { Int32((Double(v) * Double(dpi) / 96).rounded()) }
        var work = RECT()
        if !SystemParametersInfoW(0x0030 /* SPI_GETWORKAREA */, 0, &work, 0) {
            work = RECT(left: 0, top: 0, right: GetSystemMetrics(SM_CXSCREEN), bottom: GetSystemMetrics(SM_CYSCREEN))
        }
        // The client area is 400 x 120 DIP; the frame comes from the style.
        var frame = RECT(left: 0, top: 0, right: px(400), bottom: px(120))
        let style = DWORD(0x00C0_0000 | 0x0008_0000)  // WS_CAPTION | WS_SYSMENU (WS_OVERLAPPED is 0)
        _ = AdjustWindowRectEx(&frame, style, false, 0)
        let width = frame.right - frame.left, height = frame.bottom - frame.top
        let x = work.left + (work.right - work.left - width) / 2, y = work.top + (work.bottom - work.top - height) / 2
        guard let made = try? WinSinkWindow(className: Self.className, title: "PokeTokenBar", style: style, exStyle: 0,
                                            x: x, y: y, width: width, height: height) else {
            AppLog.write("update: the progress window could not be made (\(GetLastError())); the download goes on without it")
            return
        }
        window = made
        var icc = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: 0x0000_0020 | 0x0000_4000)
        _ = InitCommonControlsEx(&icc)  // ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES
        var lf = LOGFONTW()
        lf.lfHeight = -px(12)  // 9 pt
        lf.lfWeight = 400
        lf.lfCharSet = 1  // DEFAULT_CHARSET
        lf.lfQuality = 5  // CLEARTYPE_QUALITY
        let face = Array("Segoe UI".utf16) + [0]
        withUnsafeMutableBytes(of: &lf.lfFaceName) { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for (i, u) in face.enumerated() where i < p.count { p[i] = u }
        }
        font = CreateFontIndirectW(&lf)
        let module = GetModuleHandleW(nil)
        func child(_ cls: String, _ text: String, _ style: DWORD, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ id: Int) -> HWND? {
            let h = CreateWindowExW(0, WinStr.w(cls), WinStr.w(text), DWORD(0x4000_0000 | 0x1000_0000) /* WS_CHILD | WS_VISIBLE */ | style,
                                    px(x), px(y), px(w), px(h), made.hwnd, HMENU(bitPattern: id), module, nil)
            if let h, let font { _ = SendMessageW(h, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(font)))), 1) }
            return h
        }
        let first = l.updateDownloading(version) + "\r\n" + Self.megabytes(0) + " / " + Self.megabytes(total) + " MB"
        lastText = first
        label = child("Static", first, 0x0080 /* SS_NOPREFIX */, 16, 12, 368, 40, 1)
        bar = child("msctls_progress32", "", 0, 16, 56, 368, 16, 2)
        if let bar { _ = SendMessageW(bar, 0x0406 /* PBM_SETRANGE32 */, 0, 1000) }
        button = child("Button", l.cancel, 0x0001_0000 /* WS_TABSTOP */, 288, 82, 96, 28, Self.cancelID)

        made.on(UINT(WM_COMMAND)) { [weak self] wParam, _ in
            guard Int(wParam & 0xFFFF) == Self.cancelID, (wParam >> 16) & 0xFFFF == 0 /* BN_CLICKED */ else { return nil }
            self?.requestCancel()
            return 0
        }
        made.on(UINT(WM_CLOSE)) { [weak self] _, _ in self?.requestCancel(); return 0 }  // the close box cancels; `close` destroys
        let hwnd = made.hwnd
        made.on(0x0014 /* WM_ERASEBKGND */) { wParam, _ in
            var r = RECT()
            _ = GetClientRect(hwnd, &r)
            _ = FillRect(HDC(bitPattern: UInt(wParam)), &r, GetSysColorBrush(15 /* COLOR_BTNFACE */))
            return 1
        }
        made.on(0x0020 /* WM_SETCURSOR */) { _, lParam in
            guard Int(lParam) & 0xFFFF == 1 /* HTCLIENT */ else { return nil }
            _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDC_ARROW */)))
            return 1
        }
        made.on(WinModalPump.enterSizeMove) { _, _ in WinModalPump.begin("update window move"); return nil }
        made.on(WinModalPump.exitSizeMove) { _, _ in WinModalPump.end("update window move"); return nil }
        _ = ShowWindow(hwnd, 1 /* SW_SHOWNORMAL */)
        _ = UpdateWindow(hwnd)
        Self.shown += 1
        AppLog.write("update: progress window shown for v\(version)")
    }
}
#endif
