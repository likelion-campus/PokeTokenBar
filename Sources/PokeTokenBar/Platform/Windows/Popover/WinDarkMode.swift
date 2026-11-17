#if os(Windows)
import Foundation
import WinSDK

/// Dark mode for the popover (stage 7 Task 16, D15): reading the app mode, theming the native controls and the window frame.
/// Win32 does not follow the app mode by itself (`COLOR_WINDOW` stays white), so the kit draws its own surfaces from
/// `WinUIColors` and asks the common controls for their dark variants here.
enum WinDarkMode {
    /// Windows 10 1903 (build 18362) is the first release whose controls have the dark themes below; an older system never
    /// reports dark, so nothing is half-dressed.
    static let firstBuild = 18362
    static var isSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.patchVersion >= firstBuild }

    /// `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` = 0: the user chose dark for apps.
    /// Missing (an older system, a policy) is light.
    static func systemPrefersDark() -> Bool {
        if testHighContrast { return false }
        if let forced = testOverride { return forced }
        guard isSupported, case .value(let bytes) = WinRegistry.bytes("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                                      "AppsUseLightTheme"), bytes.count >= 4 else { return false }
        return bytes[0] | bytes[1] | bytes[2] | bytes[3] == 0
    }

    /// SELFTEST HOOK, not a user setting: `WindowsSelftestPopoverDark` sets this to switch the popover's appearance without
    /// touching the runner's registry; the environment variable `PTB_SELFTEST_APPEARANCE=dark|light` sets it at start so a batch
    /// run can capture every page in dark. Nothing in the shipped app sets either.
    /// `PTB_SELFTEST_APPEARANCE=highcontrast`: the capture run that simulates a high-contrast theme (see `WinUIContext.sysColor`).
    static let testHighContrast = ProcessInfo.processInfo.environment["PTB_SELFTEST_APPEARANCE"] == "highcontrast"

    nonisolated(unsafe) static var testOverride: Bool? = {
        switch ProcessInfo.processInfo.environment["PTB_SELFTEST_APPEARANCE"] {
        case "dark": return true
        case "light": return false
        default: return nil
        }
    }()

    /// The visual-style class a control kind is given in dark: buttons, scroll bars, trackbars, tabs and spinners the Explorer
    /// dark theme, text fields and drop-down lists the "common file dialog" one (its field and list colours). Kinds drawn by
    /// the kit itself (glyph buttons, pills, labels, drawn parts) need none.
    static func themeName(for kind: WinControl.Kind) -> String? {
        switch kind {
        case .button, .checkbox, .radioGroup, .trackbar, .stepper, .tabs, .progress: return "DarkMode_Explorer"
        case .edit, .combo: return "DarkMode_CFD"
        case .label, .glyphButton, .link, .drawnItem, .drawn: return nil
        }
    }

    /// `SetWindowTheme(hwnd, name, nil)`. A failure is logged once per name (the control then stays light-themed: legible, as
    /// the text colours it draws are the kit's).
    @discardableResult
    static func setTheme(_ hwnd: HWND?, _ name: String) -> Bool {
        typealias Fn = @convention(c) (HWND?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?) -> Int32
        guard let set = WinDynamic.symbol("uxtheme.dll", "SetWindowTheme", as: Fn.self) else { return false }
        let hr = WinStr.w(name).withUnsafeBufferPointer { set(hwnd, $0.baseAddress, nil) }
        if hr != 0, !failedNames.contains(name) {
            failedNames.insert(name)
            AppLog.write("popover dark mode: SetWindowTheme(\(name)) failed: \(hr)")
        }
        return hr == 0
    }
    nonisolated(unsafe) private static var failedNames: Set<String> = []

    /// The window frame (the border and shadow DWM draws, a title bar if there were one) in the app's mode:
    /// `DWMWA_USE_IMMERSIVE_DARK_MODE` (20; 19 before build 18985).
    @discardableResult
    static func setFrame(_ hwnd: HWND?, dark: Bool) -> Bool {
        typealias Fn = @convention(c) (HWND?, DWORD, UnsafeRawPointer?, DWORD) -> Int32
        guard isSupported, let set = WinDynamic.symbol("dwmapi.dll", "DwmSetWindowAttribute", as: Fn.self) else { return false }
        var on: Int32 = dark ? 1 : 0
        let attribute: DWORD = ProcessInfo.processInfo.operatingSystemVersion.patchVersion >= 18985 ? 20 : 19
        return withUnsafePointer(to: &on) { set(hwnd, attribute, $0, 4) } == 0
    }
}
#endif
