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

    /// A title for a control that reads `&` as an access-key prefix (buttons, check boxes, radio buttons, tab items, and
    /// their accessible names): every `&` doubled, as the tray menu does. Strings like "About & Support" stay whole.
    static func title(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&&") }

    /// The text again from such a title.
    static func plainTitle(_ title: String) -> String { title.replacingOccurrences(of: "&&", with: "&") }
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

    /// Shows or hides a child without activating it. Its own `WS_VISIBLE` bit decides, not `IsWindowVisible`, which is
    /// false for every child of a window not shown yet: a page laid out before the popover appears hides its rows too.
    static func setVisible(_ hwnd: HWND?, _ visible: Bool) {
        let own = GetWindowLongW(hwnd, -16 /* GWL_STYLE */) & 0x1000_0000 /* WS_VISIBLE */ != 0
        guard own != visible else { return }
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
        MainActor.assumeIsolated { WinOpenTrace.note(.window) }
        return h
    }

    /// The font of a control being made, without a redraw: with redraw on, a static paints itself at once where it was just
    /// made (the pane's top-left corner, before the layout moves it). A new window paints on its first `WM_PAINT` anyway.
    static func setFont(_ hwnd: HWND?, _ font: HFONT?) {
        send(hwnd, UINT(WM_SETFONT), Int(bitPattern: UnsafeMutableRawPointer(font)), 0)
    }

    // --- settings-open fix (field report 2026-11-17): a page built in a window on screen is drawn once, finished (begin) ---
    @MainActor private static var frozen: Set<Int> = []
    /// Times `drawingOnce` drew a window again (the selftest reads it).
    @MainActor private(set) static var drawnOnce = 0

    /// Runs `body` with `hwnd` and its children not drawing (`WM_SETREDRAW`), then draws them once, now. A page built or rebuilt
    /// in a window that is on screen (Home -> Settings, Back, the recap, a DPI change, a new language) shows only its finished
    /// state, not each control as it is made at the pane's corner and moved by every layout pass. A window not shown yet is left
    /// alone (`WM_SETREDRAW` TRUE would show it); a nested call only runs `body`.
    @MainActor static func drawingOnce(_ hwnd: HWND, _ body: () -> Void) {
        let key = Int(bitPattern: hwnd)
        guard GetWindowLongW(hwnd, -16 /* GWL_STYLE */) & 0x1000_0000 /* WS_VISIBLE */ != 0, !frozen.contains(key) else {
            body()
            return
        }
        frozen.insert(key)
        send(hwnd, 0x000B /* WM_SETREDRAW */, 0)
        body()
        frozen.remove(key)
        guard IsWindow(hwnd) else { return }
        send(hwnd, 0x000B /* WM_SETREDRAW */, 1)
        drawnOnce += 1
        _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100 | 0x0400))  // INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW | FRAME
    }
    // --- settings-open fix (end) ---

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
    /// Dark mode: `AppsUseLightTheme` is 0 and no high-contrast theme is on (that theme is the system's own colours).
    let dark: Bool
    let fonts: WinFonts
    let colors: WinUIColors
    let tooltips: WinTooltips
    /// The Settings page's numbers (`PopoverStackMetrics.settings`) in device pixels.
    let metrics: PopoverStackMetrics
    private var measureDC: HDC?
    private(set) var isDestroyed = false
    /// What was read from the system (not given by the caller): `needsRebuild` compares those only.
    private let followsTextScale: Bool, followsHighContrast: Bool, followsDark: Bool, givenAccent: COLORREF?, followsAccent: Bool

    /// `owner` owns the tooltip window (the popover's top-level window). Text scale and high contrast are read from the
    /// system unless given (tests and the selftest's synthetic pages give them).
    init(dpi: UINT, owner: HWND?, textScale: Double? = nil, highContrast: Bool? = nil, dark: Bool? = nil, accent: COLORREF? = nil) {
        followsTextScale = textScale == nil
        followsHighContrast = highContrast == nil
        followsDark = dark == nil
        followsAccent = accent == nil
        givenAccent = accent
        let d = max(dpi, 48), ts = textScale ?? Self.systemTextScale(), hc = highContrast ?? Self.systemHighContrast()
        WinControls.initializeCommonControls()
        let madeFonts = WinFonts(dpi: d, textScale: ts)
        self.dpi = d
        scale = CGFloat(d) / 96
        self.textScale = ts
        self.highContrast = hc
        let isDark = !hc && (dark ?? WinDarkMode.systemPrefersDark())
        self.dark = isDark
        fonts = madeFonts
        colors = WinUIColors(highContrast: hc, dark: isDark, accent: accent ?? Self.systemAccent())
        tooltips = WinTooltips(owner: owner, font: madeFonts.font(.callout), maxWidth: Int32((280 * CGFloat(d) / 96).rounded()))
        metrics = PopoverStackMetrics.settings.pixels(dpi: Int(d))
        measureDC = CreateCompatibleDC(nil)
        // The shared drawn parts read the appearance from here (PopoverAppearanceState); set before any part draws.
        PopoverAppearanceState.appearance = isDark ? .dark : .light
        PopoverAppearanceState.highContrast = hc ? Self.systemHighContrastColors() : nil
        if isDark { tooltips.dress(background: colors.palette.card, text: colors.palette.text) }
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

    /// Whether the page must be built again: a new DPI, or a system setting this context was made from changed (Windows'
    /// text size, high contrast, the accent, the system colours). `WM_SETTINGCHANGE`, `WM_SYSCOLORCHANGE` and
    /// `WM_THEMECHANGED` arrive for many other reasons (a wallpaper, the clock, a policy): rebuilding on each would lose the
    /// focus, the scroll position and an IME composition for nothing.
    func needsRebuild(dpi newDPI: UINT? = nil) -> Bool {
        if let newDPI, newDPI != dpi { return true }
        if followsTextScale, Self.systemTextScale() != textScale { return true }
        if followsHighContrast, Self.systemHighContrast() != highContrast { return true }
        if followsDark, (!highContrast && WinDarkMode.systemPrefersDark()) != dark { return true }
        let accent = followsAccent ? Self.systemAccent() : givenAccent
        return WinUIColors.resolve(highContrast: highContrast, dark: dark, accent: accent) { COLORREF(GetSysColor($0)) } != colors.palette
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

    /// The active high-contrast theme's colours for the shared drawn parts (`GetSysColor`).
    static func systemHighContrastColors() -> PopoverHighContrast {
        func c(_ i: Int32) -> UInt32 { WinUIColors.rgb(of: COLORREF(GetSysColor(i))) }
        return PopoverHighContrast(window: c(5 /* COLOR_WINDOW */), text: c(8 /* COLOR_WINDOWTEXT */), highlight: c(13 /* COLOR_HIGHLIGHT */),
                                   highlightText: c(14 /* COLOR_HIGHLIGHTTEXT */))
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
