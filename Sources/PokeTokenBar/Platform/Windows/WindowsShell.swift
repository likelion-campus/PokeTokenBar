#if os(Windows)
import Foundation
import WinSDK

/// `PlatformShell` on Windows: `ShellExecuteW` opens pages and folders, `terminate` leaves through the one exit.
@MainActor struct WindowsShell: PlatformShellService {
    func open(_ url: URL) {
        // A page or a folder only: no other scheme reaches the shell from here.
        guard url.isFileURL || url.scheme == "https" || url.scheme == "http" else {
            AppLog.write("shell: not opening \(url.scheme ?? "?") URL")
            return
        }
        let target = url.isFileURL ? WinPath.native(url) : url.absoluteString
        let result = ShellExecuteW(nil, WinStr.w("open"), WinStr.w(target), nil, nil, SW_SHOWNORMAL)
        if Int(bitPattern: result) <= 32 { AppLog.write("shell: ShellExecuteW failed (\(Int(bitPattern: result)))") }
    }

    func terminate() { WindowsApp.exit(0, .menu) }
}

/// The update check on Windows: the shared `UpdateChecker` fed by `InstallerReleaseFeed`. It checks once at launch
/// and, when the tray menu opens, through `check()` (its own 30-minute cooldown). No timer: nothing here wakes the
/// process while it is idle.
@MainActor enum WindowsUpdates {
    private(set) static var checker: UpdateChecker?
    /// False under `--selftest`: nothing there may ask the network.
    private(set) static var liveChecks = false

    @discardableResult
    static func start(defaults: UserDefaults, checkNow: Bool) -> UpdateChecker {
        let made = UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", defaults: defaults,
                                 fetchLatest: { await InstallerReleaseFeed.latest() })
        checker = made
        liveChecks = checkNow
        if checkNow { Task { await made.check() } }
        return made
    }

    /// The release the tray menu offers (the Mac banner's `available`; a skipped release is not offered here).
    static var available: (version: String, url: String)? { checker?.available.map { ($0.version, $0.url) } }

    /// The tray menu opened: the Mac re-checks when its popover opens, behind the same 30-minute cooldown.
    static func menuOpened() {
        guard liveChecks, let checker else { return }
        Task { await checker.check() }
    }
}
#endif
