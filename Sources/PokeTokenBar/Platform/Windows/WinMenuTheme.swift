#if os(Windows)
import Foundation
import WinSDK

/// Dark popup menus (tray, floating pet, drop-downs, text-box context menus).
///
/// Windows draws a popup menu itself and keeps it light unless the process opts in to dark app mode. The only way to have the system
/// draw dark menus (items, frame, rounded border, per-monitor DPI, accessible names, keyboard) is an undocumented `uxtheme.dll`
/// export, which is what most dark Win32 apps use. Owner-drawing the items was rejected: it loses the items' accessible names and
/// leaves the menu's frame light.
///
/// How: by ORDINAL (never imported by name), gated by build, and never fatal.
///   - build below 17763 (before 1809): nothing is called ("below 17763").
///   - 17763 to 18361 (1809, 1903 pre-release): ordinal 135 is `AllowDarkModeForApp(BOOL)`.
///   - 18362 and later: ordinal 135 is `SetPreferredAppMode(enum)`. Builds newer than `testedThrough` still try this form and the
///     log says "newer than tested".
///   - ordinals 104 `RefreshImmersiveColorPolicyState` and 136 `FlushMenuThemes` follow every change.
/// A missing export, an unknown build or a failed call leaves the menus light (today's look) and logs one line.
///
/// Mode: `allowDark` follows Windows' own app mode (`AppsUseLightTheme`, the same value the popover's dark mode follows), so menu and
/// popover agree. A real high-contrast theme gets `default` (the system's own colours, never dark). Only the selftest's appearance
/// hook forces dark or light. The mode is checked on every menu open (one registry read, no timer, nothing per message), which
/// also covers a live theme switch.
///
/// Kill-switch: environment variable `PTB_LIGHT_MENUS=1`, or `HKCU\Software\PokeTokenBar\LightMenus` = DWORD 1.
enum WinMenuTheme {
    static let killSwitchEnvironment = "PTB_LIGHT_MENUS"
    static let killSwitchKey = "Software\\PokeTokenBar", killSwitchValue = "LightMenus"
    static let firstBuild = 17763, enumBuild = 18362, testedThrough = 26100

    enum Mode: Int32 { case `default` = 0, allowDark = 1, forceDark = 2, forceLight = 3 }

    /// SELFTEST HOOK: behave as if the kill-switch were set (the fault variant of the pixel checks).
    nonisolated(unsafe) static var testDisabled = false
    nonisolated(unsafe) private static var applied: Mode?
    nonisolated(unsafe) private static var loggedLines: Set<String> = []
    /// What the last apply did, for the selftest and the log: "SetPreferredAppMode(allowDark)", "skipped: ...".
    nonisolated(unsafe) private(set) static var lastOutcome = "not applied"
    nonisolated(unsafe) private(set) static var applies = 0

    static var killSwitchSet: Bool {
        let environment = ProcessInfo.processInfo.environment  // our own switch, not a usage location (UsageEnvironment's scan)
        if environment[killSwitchEnvironment] == "1" { return true }
        if case .value(let bytes) = WinRegistry.bytes(killSwitchKey, killSwitchValue), bytes.count >= 4 { return bytes[0] | bytes[1] | bytes[2] | bytes[3] != 0 }
        return false
    }

    /// The mode the menus should be in now.
    @MainActor static func wantedMode() -> Mode {
        if testDisabled || killSwitchSet { return .default }
        if WinUIContext.systemHighContrast() { return .default }  // the system's own colours
        if let forced = WinDarkMode.testOverride { return forced ? .forceDark : .forceLight }
        return .allowDark
    }

    /// Called before every menu opens: sets the mode when it differs from what is set (the first menu, a theme switch).
    @MainActor static func ensure() {
        let want = wantedMode()
        guard want != applied else { return }
        apply(want)
    }

    private static func log(_ line: String) {
        lastOutcome = line
        guard loggedLines.insert(line).inserted else { return }
        AppLog.write("dark menus: \(line)")
    }

    @MainActor private static func apply(_ mode: Mode) {
        applied = mode
        applies += 1
        let build = Int(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)
        if testDisabled || killSwitchSet {
            if build >= firstBuild { call(mode: .default, build: build, reason: "kill-switch") }
            else { log("skipped: kill-switch set") }
            return
        }
        guard build >= firstBuild else { log("skipped: build \(build) is below \(firstBuild)"); return }
        call(mode: mode, build: build, reason: nil)
    }

    @MainActor private static func call(mode: Mode, build: Int, reason: String?) {
        let wide = WinStr.w("uxtheme.dll")
        guard let module = GetModuleHandleW(wide) ?? LoadLibraryExW(wide, nil, 0x0800 /* LOAD_LIBRARY_SEARCH_SYSTEM32 */) else {
            log("skipped: uxtheme.dll not loaded"); return
        }
        func export(_ ordinal: Int) -> FARPROC? { GetProcAddress(module, UnsafePointer<CChar>(bitPattern: ordinal)) }
        guard let setter = export(135) else { log("skipped: uxtheme ordinal 135 is missing (build \(build))"); return }
        typealias IntCall = @convention(c) (Int32) -> Int32
        typealias VoidCall = @convention(c) () -> Void
        let form: String
        if build >= enumBuild {
            unsafeBitCast(setter, to: IntCall.self)(mode.rawValue)
            form = "SetPreferredAppMode(\(mode))" + (build > testedThrough ? ", build \(build) is newer than tested (\(testedThrough)), enum form tried" : ", build \(build)")
        } else {
            unsafeBitCast(setter, to: IntCall.self)(mode == .allowDark || mode == .forceDark ? 1 : 0)
            form = "AllowDarkModeForApp(\(mode == .allowDark || mode == .forceDark)), build \(build)"
        }
        if let refresh = export(104) { unsafeBitCast(refresh, to: VoidCall.self)() }
        if let flush = export(136) { unsafeBitCast(flush, to: VoidCall.self)() }
        log(form + (reason.map { " (\($0))" } ?? ""))
    }
}
#endif
