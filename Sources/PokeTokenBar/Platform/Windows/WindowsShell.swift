#if os(Windows)
import Foundation
import WinSDK

/// `PlatformShell` on Windows: `ShellExecuteW` opens pages and folders, `terminate` leaves through the one exit.
@MainActor struct WindowsShell: PlatformShellService {
    func open(_ url: URL) { _ = openReturning(url) }

    /// Schemes the shell is handed from here: pages and folders, and `mailto:` (the Settings page's "Report a problem", stage 7
    /// Task 6). Nothing else ever reaches `ShellExecuteW` through this door.
    nonisolated static func isOpenable(_ url: URL) -> Bool {
        url.isFileURL || url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto"
    }

    /// Opens `url`; false when the shell refused (no mail app for `mailto:`, no handler), which the caller may tell the user.
    @discardableResult
    func openReturning(_ url: URL) -> Bool {
        guard Self.isOpenable(url) else {
            AppLog.write("shell: not opening \(url.scheme ?? "?") URL")
            return false
        }
        let target = url.isFileURL ? WinPath.native(url) : url.absoluteString
        let result = ShellExecuteW(nil, WinStr.w("open"), WinStr.w(target), nil, nil, SW_SHOWNORMAL)
        if Int(bitPattern: result) <= 32 {
            AppLog.write("shell: ShellExecuteW failed (\(Int(bitPattern: result)), \(url.isFileURL ? "file" : url.scheme ?? "?"))")
            return false
        }
        return true
    }

    /// Explorer with `file` selected (the Settings page's log file button): `explorer.exe /select,"<path>"`.
    @discardableResult
    static func revealInExplorer(_ file: URL) -> Bool {
        let parameters = "/select,\"\(WinPath.native(file))\""
        let result = ShellExecuteW(nil, WinStr.w("open"), WinStr.w("explorer.exe"), WinStr.w(parameters), nil, SW_SHOWNORMAL)
        if Int(bitPattern: result) <= 32 { AppLog.write("shell: Explorer /select failed (\(Int(bitPattern: result)))") }
        return Int(bitPattern: result) > 32
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
        // No Homebrew on Windows: without `{ nil }` every "Update" would search PATH for a `brew` and, if one listed the
        // team cask, start the Mac's `/bin/sh` upgrade (absent here) and quit the app.
        let made = UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", defaults: defaults,
                                 fetchLatest: { await fetchRespectingCooldown() }, brewLocator: { nil })
        checker = made
        liveChecks = checkNow
        if checkNow { Task { await made.check() } }
        return made
    }

    private static var emptyAnswers = InstallerReleaseFeed.EmptyAnswerCooldown()

    /// The installer the last answered check found (rules in `InstallerReleaseFeed.InstallerCache`, tested on both systems).
    private static var installers = InstallerReleaseFeed.InstallerCache()

    /// The checked installer for exactly this version, else nil.
    static func installer(for version: String) -> InstallerReleaseFeed.Installer? { installers.installer(for: version) }

    /// Why the last answered check has no installer, for the log line when "Update" opens the page instead.
    static var lastRejection: InstallerReleaseFeed.Rejection? { installers.lastRejection }

    /// What the checker's fetch does: skip the request while the last answer was "no Windows installer" (30 minutes, the
    /// Mac's cooldown after a successful check); otherwise ask.
    private static func fetchRespectingCooldown() async -> UpdateChecker.LatestRelease? {
        guard emptyAnswers.mayAsk(now: Date()) else { return nil }
        let answer = await InstallerReleaseFeed.fetch()
        installers.record(answer)
        switch answer.outcome {
        case .release(let release): return release
        case .noInstaller: emptyAnswers.noteEmptyAnswer(now: Date()); return nil
        case .failed: return nil
        }
    }

    /// The in-app install of `version` (stage 8 Task 6 fills this in). false: the caller opens the release page.
    static func install(version: String) async -> Bool { false }

    /// The release the tray menu offers (the Mac banner's `available`; a skipped release is not offered here).
    static var available: (version: String, url: String)? { checker?.available.map { ($0.version, $0.url) } }

    /// The tray menu opened: the Mac re-checks when its popover opens, behind the same 30-minute cooldown.
    static func menuOpened() {
        guard liveChecks, let checker else { return }
        Task { await checker.check() }
    }
}
#endif
