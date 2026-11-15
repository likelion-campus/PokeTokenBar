#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Win32 glue the popover kit shares: message parameters as `Int`, handles as parameters, window text, placement. Every
/// placement call passes `SWP_NOACTIVATE`: nothing in the kit activates a window (stage 7 "Focus"; Task 4's scan).
enum WinKit {
    static var module: HMODULE? { GetModuleHandleW(nil) }

    @discardableResult
    static func send(_ hwnd: HWND?, _ message: UINT, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(SendMessageW(hwnd, message, WPARAM(UInt(bitPattern: wParam)), LPARAM(lParam)))
    }

    /// A message whose `lParam` is a NUL-terminated wide string (valid for the call).
    @discardableResult
    static func send(_ hwnd: HWND?, _ message: UINT, _ wParam: Int = 0, text: String) -> Int {
        WinStr.w(text).withUnsafeBufferPointer { send(hwnd, message, wParam, Int(bitPattern: $0.baseAddress)) }
    }

    static func handle(_ pointer: UnsafeMutableRawPointer?) -> Int { Int(bitPattern: pointer) }
    static func loWord(_ v: WPARAM) -> Int { Int(v & 0xFFFF) }
    static func hiWord(_ v: WPARAM) -> Int { Int((v >> 16) & 0xFFFF) }
    static func signedHiWord(_ v: WPARAM) -> Int { Int(Int16(truncatingIfNeeded: (v >> 16) & 0xFFFF)) }
    static func point(_ l: LPARAM) -> POINT {
        POINT(x: Int32(Int16(truncatingIfNeeded: Int(l) & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (Int(l) >> 16) & 0xFFFF)))
    }

    static func text(of hwnd: HWND?) -> String {
        let n = GetWindowTextLengthW(hwnd)
        guard n > 0 else { return "" }
        var buffer = [UInt16](repeating: 0, count: Int(n) + 1)
        let got = GetWindowTextW(hwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(got)), as: UTF16.self)
    }

    /// `SetWindowTextW` only when the text differs (D10: only changed texts are set).
    static func setText(_ hwnd: HWND?, _ text: String) {
        guard Self.text(of: hwnd) != text else { return }
        _ = SetWindowTextW(hwnd, WinStr.w(text))
    }

    static func className(_ hwnd: HWND?) -> String {
        var buffer = [UInt16](repeating: 0, count: 128)
        let n = GetClassNameW(hwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(n)), as: UTF16.self)
    }

    static func move(_ hwnd: HWND?, _ r: RECT) {
        _ = SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// Shows or hides a child without activating it.
    static func setVisible(_ hwnd: HWND?, _ visible: Bool) {
        guard IsWindowVisible(hwnd) != visible else { return }
        let flag = visible ? UINT(SWP_SHOWWINDOW) : UINT(SWP_HIDEWINDOW)
        _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) | flag)
    }

    /// The window's rect in `parent`'s client coordinates.
    static func rect(_ hwnd: HWND?, in parent: HWND?) -> RECT {
        var r = RECT()
        _ = GetWindowRect(hwnd, &r)
        withUnsafeMutablePointer(to: &r) { p in
            p.withMemoryRebound(to: POINT.self, capacity: 2) { _ = MapWindowPoints(nil, parent, $0, 2) }
        }
        return r
    }

    static func create(_ className: String, _ text: String, style: DWORD, exStyle: DWORD = 0, parent: HWND, id: Int,
                       rect: RECT = RECT(left: 0, top: 0, right: 10, bottom: 10)) -> HWND? {
        let h = CreateWindowExW(exStyle, WinStr.w(className), WinStr.w(text), style, rect.left, rect.top, rect.right - rect.left,
                                rect.bottom - rect.top, parent, HMENU(bitPattern: id), module, nil)
        if h == nil { AppLog.write("popover kit: CreateWindowExW(\(className)) failed: \(GetLastError())") }
        return h
    }

    static func setFont(_ hwnd: HWND?, _ font: HFONT?) {
        send(hwnd, UINT(WM_SETFONT), Int(bitPattern: UnsafeMutableRawPointer(font)), 1)
    }

    /// The arrow over a client area of ours (the kit's window classes have no class cursor).
    static func arrowCursor(_ lParam: LPARAM) -> LRESULT? {
        guard Int(lParam) & 0xFFFF == 1 /* HTCLIENT */ else { return nil }
        _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDC_ARROW */)))
        return 1
    }

    static func rect(_ r: CGRect) -> RECT {
        RECT(left: Int32(r.minX.rounded()), top: Int32(r.minY.rounded()), right: Int32(r.maxX.rounded()), bottom: Int32(r.maxY.rounded()))
    }

    /// `GetSystemMetricsForDpi` (Windows 10 1607+), else the system DPI's metric scaled.
    static func metric(_ index: Int32, dpi: UINT) -> Int32 {
        typealias Fn = @convention(c) (Int32, UINT) -> Int32
        if let fn = WinDynamic.symbol("user32.dll", "GetSystemMetricsForDpi", as: Fn.self) { return fn(index, dpi) }
        return Int32((Double(GetSystemMetrics(index)) * Double(dpi) / 96).rounded())
    }
}

/// What every control and drawn part of one popover window shares (stage 7 D6, D15): the window's DPI and scale, the
/// fonts made for it, the colours, the tooltip window and the page metrics in device pixels. One context per window and
/// DPI: a DPI change (`WM_DPICHANGED`) makes a new one and the page is built again (comctl32 controls keep the font they
/// were given, R6). `destroy()` frees every GDI object, the tooltip window and the measuring DC.
@MainActor final class WinUIContext {
    let dpi: UINT
    /// Device pixels per DIP.
    let scale: CGFloat
    /// Windows' text size (Accessibility > Text size), applied to every font.
    let textScale: Double
    /// `SPI_GETHIGHCONTRAST`: controls and the page draw in the system colours (D15, "no colour is overridden").
    let highContrast: Bool
    let fonts: WinFonts
    let colors: WinUIColors
    let tooltips: WinTooltips
    /// The Settings page's numbers (`PopoverStackMetrics.settings`) in device pixels.
    let metrics: PopoverStackMetrics
    private var measureDC: HDC?
    private(set) var isDestroyed = false

    /// `owner` owns the tooltip window (the popover's top-level window). Text scale and high contrast are read from the
    /// system unless given (tests and the selftest's synthetic pages give them).
    init(dpi: UINT, owner: HWND?, textScale: Double? = nil, highContrast: Bool? = nil, accent: COLORREF? = nil) {
        let d = max(dpi, 48), ts = textScale ?? Self.systemTextScale(), hc = highContrast ?? Self.systemHighContrast()
        WinControls.initializeCommonControls()
        let madeFonts = WinFonts(dpi: d, textScale: ts)
        self.dpi = d
        scale = CGFloat(d) / 96
        self.textScale = ts
        self.highContrast = hc
        fonts = madeFonts
        colors = WinUIColors(highContrast: hc, accent: accent ?? Self.systemAccent())
        tooltips = WinTooltips(owner: owner, font: madeFonts.font(.callout), maxWidth: Int32((280 * CGFloat(d) / 96).rounded()))
        metrics = PopoverStackMetrics.settings.pixels(dpi: Int(d))
        measureDC = CreateCompatibleDC(nil)
    }

    func px(_ dip: CGFloat) -> Int32 { Int32(PopoverTextStyle.pixels(dip, dpi: Int(dpi))) }

    /// The size of `text` in `font`, in pixels: one line, or wrapped at `width` (`DrawTextW` `DT_WORDBREAK`, no `&` prefixes).
    /// An empty text is one line high and 0 wide.
    func measure(_ text: String, font: HFONT?, width: Int32? = nil) -> SIZE {
        guard let dc = measureDC else { return SIZE(cx: 0, cy: 0) }
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        defer { _ = SelectObject(dc, old) }
        var tm = TEXTMETRICW()
        _ = GetTextMetricsW(dc, &tm)
        guard !text.isEmpty else { return SIZE(cx: 0, cy: tm.tmHeight) }
        var r = RECT(left: 0, top: 0, right: width ?? 0x7FFF, bottom: 0)
        let format = UINT(DT_CALCRECT | DT_NOPREFIX | DT_EXPANDTABS) | (width == nil ? UINT(DT_SINGLELINE) : UINT(DT_WORDBREAK))
        _ = WinStr.w(text).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &r, format) }
        return SIZE(cx: r.right - r.left, cy: max(r.bottom - r.top, tm.tmHeight))
    }

    /// The font's line height in pixels (`tmHeight`).
    func lineHeight(_ font: HFONT?) -> Int32 { measure("", font: font).cy }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        tooltips.destroy()
        fonts.destroy()
        colors.destroy()
        if let dc = measureDC { _ = DeleteDC(dc) }
        measureDC = nil
    }

    // MARK: - system settings

    /// `HKCU\Software\Microsoft\Accessibility\TextScaleFactor` (100…225; missing = 100).
    static func systemTextScale() -> Double {
        if case .value(let bytes) = WinRegistry.bytes("Software\\Microsoft\\Accessibility", "TextScaleFactor"), bytes.count >= 4 {
            let v = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
            return PopoverTextStyle.textScale(registryPercent: v)
        }
        return 1
    }

    static func systemHighContrast() -> Bool {
        var hc = HIGHCONTRASTW()
        hc.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
        guard SystemParametersInfoW(0x0042 /* SPI_GETHIGHCONTRAST */, hc.cbSize, &hc, 0) else { return false }
        return hc.dwFlags & 0x1 /* HCF_HIGHCONTRASTON */ != 0
    }

    /// The user's accent (`HKCU\Software\Microsoft\Windows\DWM\AccentColor`, 0xAABBGGRR), nil when it is not set (D15).
    static func systemAccent() -> COLORREF? {
        guard case .value(let bytes) = WinRegistry.bytes("Software\\Microsoft\\Windows\\DWM", "AccentColor"), bytes.count >= 4 else { return nil }
        return COLORREF(bytes[0]) | COLORREF(bytes[1]) << 8 | COLORREF(bytes[2]) << 16
    }

    /// The window's DPI (`GetDpiForWindow`; 96 when unknown).
    static func dpi(of hwnd: HWND?) -> UINT { ptb_window_dpi(UnsafeMutableRawPointer(hwnd)) }
}
#endif
