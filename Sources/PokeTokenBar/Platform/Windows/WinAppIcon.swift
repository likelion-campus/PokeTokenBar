#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// The app's icon on a top-level window: the title bar (small), the taskbar button and Alt+Tab (big). The picture is the
/// exe's own icon resource (`1 ICON "assets\AppIcon.ico"` in `Sources/PokeTokenBarWin/PokeTokenBar.rc`), loaded at the size
/// the system metrics give for the window's DPI, so the entry that fits is chosen from the .ico and nothing is scaled twice.
/// A window made by `RegisterClassExW` without `hIcon` and never sent `WM_SETICON` shows the generic application icon.
/// `WinSinkWindow` applies this to every window it makes with a caption and again on `WM_DPICHANGED`.
enum WinAppIcon {
    /// `MAKEINTRESOURCE(1)`, the id the .rc gives the icon.
    private static let resourceID = 1
    private static let wmSetIcon: UINT = 0x0080, wmGetIcon: UINT = 0x007F
    static let iconSmall: WPARAM = 0, iconBig: WPARAM = 1
    nonisolated(unsafe) private static var loggedMissing = false

    private typealias MetricFn = @convention(c) (Int32, UINT) -> Int32

    /// SM_CXICON (11) / SM_CXSMICON (49) at `dpi` (square). Falls back to the system-DPI metrics before Windows 10 1607.
    static func size(big: Bool, dpi: UInt32) -> Int32 {
        let index: Int32 = big ? 11 : 49
        if let fn = WinDynamic.symbol("user32.dll", "GetSystemMetricsForDpi", as: MetricFn.self) { return fn(index, dpi) }
        return GetSystemMetrics(index)
    }

    /// A shared handle (the system caches it per size and owns it: never destroyed), nil when the exe has no icon resource.
    static func load(size: Int32) -> HICON? {
        guard let id = UnsafePointer<UInt16>(bitPattern: resourceID),
              let handle = LoadImageW(GetModuleHandleW(nil), id, UINT(IMAGE_ICON), size, size, UINT(LR_SHARED)) else { return nil }
        return HICON(bitPattern: Int(bitPattern: handle))
    }

    /// Sets the big and the small icon of `hwnd` for `dpi` (0 = the window's own). Returns whether both were set.
    @discardableResult
    static func apply(to hwnd: HWND, dpi: UInt32 = 0) -> Bool {
        let at = dpi == 0 ? ptb_window_dpi(UnsafeMutableRawPointer(hwnd)) : dpi
        guard let big = load(size: size(big: true, dpi: at)), let small = load(size: size(big: false, dpi: at)) else {
            if !loggedMissing {
                loggedMissing = true
                AppLog.write("app icon: the exe has no icon resource (id 1); windows show the default icon")
            }
            return false
        }
        _ = SendMessageW(hwnd, wmSetIcon, iconBig, LPARAM(Int(bitPattern: big)))
        _ = SendMessageW(hwnd, wmSetIcon, iconSmall, LPARAM(Int(bitPattern: small)))
        return true
    }

    /// The window's DPI (96 when unknown).
    static func currentDpi(of hwnd: HWND) -> UInt32 { ptb_window_dpi(UnsafeMutableRawPointer(hwnd)) }

    /// What the window holds now (`WM_GETICON`), for the selftest. `big`: ICON_BIG, else ICON_SMALL.
    static func current(of hwnd: HWND, big: Bool) -> HICON? {
        let r = SendMessageW(hwnd, wmGetIcon, big ? iconBig : iconSmall, 0)
        return HICON(bitPattern: Int(r))
    }

    /// The pixel width of an icon handle (`GetIconInfo` bitmap), 0 when unreadable.
    static func width(of icon: HICON) -> Int32 {
        var info = ICONINFO()
        guard GetIconInfo(icon, &info) else { return 0 }
        defer {
            if let c = info.hbmColor { _ = DeleteObject(c) }
            if let m = info.hbmMask { _ = DeleteObject(m) }
        }
        var bmp = BITMAP()
        guard let source = info.hbmColor ?? info.hbmMask,
              GetObjectW(source, Int32(MemoryLayout<BITMAP>.size), &bmp) != 0 else { return 0 }
        return bmp.bmWidth
    }
}
#endif
