#if os(Windows)
import Foundation
import WinSDK

/// `PlatformShell` on Windows: `ShellExecuteW` opens pages and folders, `terminate` leaves through the one exit.
@MainActor struct WindowsShell: PlatformShellService {
    func open(_ url: URL) {
        if WindowsUpdates.keepsReleasePageClosed(url) { return }  // the user cancelled the in-app update, or a Setup runs
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

    /// "Update" without Homebrew (`UpdateChecker.applyUpdate`): the in-app install. true only when Setup has started and the
    /// app is leaving; false opens the release page (unless `WindowsUpdates` keeps it closed).
    func installUpdate(version: String) async -> Bool { await WindowsUpdates.install(version: version) }
}

/// The update check on Windows: the shared `UpdateChecker` fed by `InstallerReleaseFeed`. It checks once at launch
/// and, when the tray menu opens, through `check()` (its own 30-minute cooldown). No timer: nothing here wakes the
/// process while it is idle.
@MainActor enum WindowsUpdates {
    private(set) static var checker: UpdateChecker?
    /// False under `--selftest`: nothing there may ask the network.
    private(set) static var liveChecks = false

    @discardableResult
    static func start(defaults: UserDefaults, checkNow: Bool, notify: @escaping @MainActor (String) -> Void = { _ in },
                      language: @escaping @MainActor () -> L = { L(.en) }) -> UpdateChecker {
        // No Homebrew on Windows: without `{ nil }` every "Update" would search PATH for a `brew` and, if one listed the
        // team cask, start the Mac's `/bin/sh` upgrade (absent here) and quit the app.
        let made = UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", defaults: defaults,
                                 fetchLatest: { await fetchRespectingCooldown() }, brewLocator: { nil })
        checker = made
        liveChecks = checkNow
        self.defaults = defaults
        self.notify = notify
        self.language = language
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
        let answer: InstallerReleaseFeed.Answer
        if let loopback {
            answer = await InstallerReleaseFeed.fetch(from: loopback.feed, downloadPrefix: loopback.downloadPrefix)
        } else {
            answer = await InstallerReleaseFeed.fetch()
        }
        installers.record(answer)
        if let version = answer.installer?.version { lastCheckedVersion = version }
        switch answer.outcome {
        case .release(let release): return release
        case .noInstaller: emptyAnswers.noteEmptyAnswer(now: Date()); return nil
        case .failed: return nil
        }
    }

    // MARK: the in-app install (stage 8 Task 6)

    private static var defaults: UserDefaults?
    private static var notify: @MainActor (String) -> Void = { _ in }
    private static var language: @MainActor () -> L = { L(.en) }
    /// The CI selftest's loopback feed (`--selftest-update-from`); nil in every other run.
    private(set) static var loopback: LoopbackFeed?
    /// The version of the installer the last answered check named (the selftest drives an older one through `install`).
    private(set) static var lastCheckedVersion: String?
    /// The release page `applyUpdate` opens right after a false that must not open it (a cancel, a running Setup).
    private static var pageToKeepClosed: String?

    /// The one call site is `WindowsSelftestUpdate.prepare`, before the app is built (`WindowsSeamScanTests`).
    static func useLoopbackFeed(_ feed: LoopbackFeed) {
        loopback = feed
        AppLog.write("update: the feed is the CI loopback \(feed.feed.absoluteString); downloads only from \(LoopbackFeed.host)")
    }

    /// The in-app install of `version`. true only when Setup has started and the app is leaving; false: the caller opens
    /// the release page. Takes the installer of exactly that version from the last answered check, never a guess.
    static func install(version: String) async -> Bool {
        guard let installer = installer(for: version) else {
            AppLog.write("update: not installing v\(version) in-app: \(lastRejection?.description ?? "the checked installer is for another version"); "
                         + "the release page opens")
            return false
        }
        // No second silent try of a version whose Setup did not finish: the balloon told the user to take the page.
        if defaults?.string(forKey: WindowsUpdateInstaller.failedKey) == version {
            AppLog.write("update: v\(version) did not install in-app last time; the release page opens instead")
            return false
        }
        let page = checker?.updateTarget?.url
        let window = WinUpdateProgressWindow(l: language())
        AppLog.write("update: installing v\(version) in-app (\(installer.size) bytes)")
        let failure = await WindowsUpdateInstaller.install(installer, currentVersion: WindowsInstall.version,
                                                           defaults: defaults ?? .standard, loopback: loopback, progress: window)
                      ?? .launch  // nil only after `onLaunched`, which has left the app
        window.close()
        AppLog.write("update: v\(version) not installed: \(failure)\(failure.opensReleasePage ? "; the release page opens" : "")")
        if let text = failure.message(language()) {
            AppLog.write("update: told the user: \(text)")
            notify(text)
        }
        if !failure.opensReleasePage { pageToKeepClosed = page }
        return false
    }

    /// Whether `url` is the release page a cancelled or blocked install keeps closed; true once, then it opens again.
    static func keepsReleasePageClosed(_ url: URL) -> Bool {
        guard let page = pageToKeepClosed, url.absoluteString == page else { return false }
        pageToKeepClosed = nil
        AppLog.write("update: the release page stays closed")
        return true
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
