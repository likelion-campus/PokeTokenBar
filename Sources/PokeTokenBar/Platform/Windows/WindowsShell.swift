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

    @discardableResult
    static func start(defaults: UserDefaults, checkNow: Bool) -> UpdateChecker {
        let made = UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", defaults: defaults,
                                 fetchLatest: { await InstallerReleaseFeed.latest() })
        checker = made
        if checkNow { Task { await made.check() } }
        return made
    }
}
#endif
