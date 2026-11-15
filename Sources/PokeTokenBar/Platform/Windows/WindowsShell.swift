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

    /// The installer of the release the last answered check offered, when it passed every check; else why not
    /// (`lastRejection`). Cleared when the latest release no longer has an installer (an installer removed from a bad
    /// release, D11), kept when a check could not ask, as the checker keeps its offer. The in-app update takes it only for
    /// the version it installs.
    private(set) static var lastInstaller: InstallerReleaseFeed.Installer?
    private(set) static var lastRejection: InstallerReleaseFeed.Rejection?

    /// What the checker's fetch does: skip the request while the last answer was "no Windows installer" (30 minutes, the
    /// Mac's cooldown after a successful check); otherwise ask.
    private static func fetchRespectingCooldown() async -> UpdateChecker.LatestRelease? {
        guard emptyAnswers.mayAsk(now: Date()) else { return nil }
        let answer = await InstallerReleaseFeed.fetch()
        switch answer.outcome {
        case .release(let release):
            lastInstaller = answer.installer
            lastRejection = answer.rejection
            return release
        case .noInstaller:
            lastInstaller = nil
            lastRejection = .noInstaller
            emptyAnswers.noteEmptyAnswer(now: Date())
            return nil
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
