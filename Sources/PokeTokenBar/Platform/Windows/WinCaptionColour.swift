#if os(Windows)
import Foundation
import WinSDK

/// Windows 11: the plaza window's standard title bar in the plaza's dark teal with light text and a light border
/// (`DWMWA_CAPTION_COLOR`, `DWMWA_TEXT_COLOR`, `DWMWA_BORDER_COLOR`), and `DWMWA_USE_IMMERSIVE_DARK_MODE` so the caption buttons
/// are light. The colours come from `PlazaCaptionTheme`. Windows 10 and high-contrast themes keep the system look: nothing is set,
/// and what was set is reset when a high-contrast theme starts. DWM keeps the colours when the window is inactive (the title
/// stays readable), so there is no second set of colours.
@MainActor enum WinCaptionColour {
    private static let darkMode: DWORD = 20, border: DWORD = 34, caption: DWORD = 35, text: DWORD = 36
    private static let colorDefault: UInt32 = 0xFFFF_FFFF  // DWMWA_COLOR_DEFAULT
    private typealias SetFn = @convention(c) (HWND?, DWORD, UnsafeRawPointer?, DWORD) -> Int32
    private static var applied: Set<Int> = []
    private static var loggedRejected = false

    static var buildNumber: Int { ProcessInfo.processInfo.operatingSystemVersion.patchVersion }

    /// The rule's answer for this machine now.
    static var wanted: Bool { PlazaCaptionTheme.shouldApply(buildNumber: buildNumber, highContrast: WinUIContext.systemHighContrast()) }

    /// Sets or resets the colours for the current state; returns whether they are set afterwards.
    @discardableResult
    static func update(_ hwnd: HWND) -> Bool {
        let key = Int(bitPattern: hwnd)
        if wanted {
            let c = PlazaCaptionTheme.plaza
            let ok = set(hwnd, darkMode, 1) && set(hwnd, caption, c.caption) && set(hwnd, text, c.text) && set(hwnd, border, c.border)
            if ok { applied.insert(key) } else if !loggedRejected {
                loggedRejected = true
                AppLog.write("plaza caption colour: DWM did not accept the attributes (build \(buildNumber)); the system title bar stays")
            }
            return ok
        }
        if applied.remove(key) != nil {
            _ = set(hwnd, darkMode, 0) && set(hwnd, caption, colorDefault) && set(hwnd, text, colorDefault) && set(hwnd, border, colorDefault)
        }
        return false
    }

    static func forget(_ hwnd: HWND) { applied.remove(Int(bitPattern: hwnd)) }

    private static func set(_ hwnd: HWND, _ attribute: DWORD, _ value: UInt32) -> Bool {
        guard let fn = WinDynamic.symbol("dwmapi.dll", "DwmSetWindowAttribute", as: SetFn.self) else { return false }
        var v = value
        return withUnsafePointer(to: &v) { fn(hwnd, attribute, $0, 4) } == 0
    }

    /// Whether the colours are set on `hwnd` (DWM accepted all four attributes). DWM cannot be asked what it holds:
    /// `DwmGetWindowAttribute` fails for these (write-only), so the selftest reads the pixel of the title bar instead.
    static func isSet(_ hwnd: HWND) -> Bool { applied.contains(Int(bitPattern: hwnd)) }
}
#endif
