#if os(Windows)
import Foundation
import Observation
import WinSDK

/// Entry point of the Windows app. `main.swift` calls `main()` synchronously on the process main thread: an
/// `async` main would move main-actor work to a pool thread within a second and lose the windows (F16).
public enum WindowsApp {
    /// The process main thread (the selftest compares against it).
    nonisolated(unsafe) static var mainThreadID: DWORD = 0

    public static func main() -> Never {
        _ = RunLoop.main  // first, before any window: Foundation's initializer turns on CF's message mask (F4)
        mainThreadID = GetCurrentThreadId()
        let arguments = CommandLine.arguments
        // Synchronous top-level code on the main thread: the main actor's executor is this thread (F16).
        MainActor.assumeIsolated { () -> Never in run(arguments) }
    }

    @MainActor private static func run(_ arguments: [String]) -> Never {
        if arguments.contains("--version") {
            try? FileHandle.standardOutput.write(contentsOf: Data(((WindowsInstall.version ?? "0.0.0-dev") + "\n").utf8))
            WindowsApp.exit(0, .helper)
        }
        if let i = arguments.firstIndex(of: "--selftest-defaults-writer") {
            WindowsSelftest.runDefaultsWriter(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-guard-reader") {
            WindowsSelftest.runGuardReader(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-defaults-reader") {
            WindowsSelftest.runDefaultsReader(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-waker-hunt") { WindowsSelftestWakers.run(Array(arguments[(i + 1)...])) }
        if let i = arguments.firstIndex(of: "--selftest-crash") { WindowsSelftestCrash.run(Array(arguments[(i + 1)...])) }
        if arguments.contains("--ime-check") { WinImeCheck.run() }

        let app = WindowsAppDelegate(arguments: arguments)
        guard app.launch() else { WindowsApp.exit(app.yielded ? 3 : 1, .launchFailed) }
        if arguments.contains("--selftest") {
            let out = arguments.firstIndex(of: "--selftest-out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("PokeTokenBar-selftest.json")
            WindowsSelftest.start(app, writingTo: out)
        }
        WinMainLoop.run(app.loopStrategy) { false }
        WindowsApp.exit(0, .menu)  // not reached: the loop only ends through an exit
    }
}

extension WindowsApp {
    /// Set at launch; `exit` takes the icon out of the notification area on every exit path.
    @MainActor static var trayToRemove: WinTray?

    enum ExitReason: String { case menu, endSession, closeRequest, selftest, helper, launchFailed }

    /// The only way Windows code leaves the process (scan-enforced): settings are lost unless synchronized (F2), and
    /// the log line is lost unless flushed.
    @MainActor static func exit(_ code: Int32, _ reason: ExitReason) -> Never {
        WinDefaultsSync.flushNow()
        WindowsCrashLog.markClean()
        AppLog.writeAndFlush("exit code=\(code) reason=\(reason.rawValue)")
        trayToRemove?.remove()
        crtExit(code)
    }

    /// The selftest's control case only (`defaults.control`): a plain `exit` that skips the sync, to show F2 holds.
    @MainActor static func exitWithoutSyncForF2Control(_ code: Int32) -> Never {
        crtExit(code)
    }
}

/// The C runtime's `exit`. Called only by the two functions above (`WindowsSeamScanTests`).
private func crtExit(_ code: Int32) -> Never {
    exit(code)
}

/// The Windows counterpart of the Mac's `AppDelegate`: builds the stores in the Mac's order and keeps them running
/// under the main loop. The tray icon is Task 6; the popover comes with Task 7.
@MainActor final class WindowsAppDelegate {
    let arguments: [String]
    private(set) var store: UsageStore!
    private(set) var companion: CompanionStore!
    /// Built in `launch()`, after the single-instance check, so a yielding second start writes nothing.
    private(set) var teamSettings: TeamSettings!
    private(set) var defaults: WinSyncingDefaults!
    private(set) var sink: WinSinkWindow!
    private(set) var tray: WinTrayHost?
    private(set) var loopStrategy: WinMainLoop.Strategy = .cfRunLoopWithMessages
    private(set) var mutexName = ""
    private(set) var yielded = false

    // What the selftest observes.
    private(set) var refreshCount = 0
    private(set) var companionUpdates = 0
    private(set) var lastCompanionSawUsage = false
    private(set) var showRequests = 0

    init(arguments: [String]) { self.arguments = arguments }

    /// The Mac's `applicationDidFinishLaunching` order. false = yielded to a running instance, or failed (logged).
    func launch() -> Bool {
        _ = RunLoop.main  // 1 (F4; before any window)
        mutexName = WinSingleInstance.mutexName(stateDirectory: AppStatePaths.directory(),
                                                defaultDirectory: Self.defaultStateDirectory)
        if WinSingleInstance.acquire(name: mutexName) == .yielded {  // 2 (before anything that writes)
            yielded = true
            AppLog.writeAndFlush("duplicate instance: yielding to the instance already running (\(mutexName))")
            return false
        }
        if arguments.contains("--selftest-second") {
            AppLog.writeAndFlush("--selftest-second: no running instance held \(mutexName)")
            return false
        }
        WindowsCrashLog.install(version: WindowsInstall.version ?? "0.0.0-dev")  // 3
        Self.setPerMonitorDpiAwareness()  // 4
        loopStrategy = WinMainLoop.prepare()  // 5
        do {  // 6
            sink = try WinSinkWindow(title: mutexName)
        } catch {
            AppLog.writeAndFlush("launch failed: \(error)")
            return false
        }
        Self.installExitHandlers(on: sink)
        sink.on(WinSingleInstance.showMessage) { [weak self] _, _ in
            self?.showRequests += 1
            self?.tray?.showAlreadyRunning()
            return 0
        }
        if !WinMessageHook.install() { AppLog.write("text input stays ANSI: no WH_GETMESSAGE hook") }  // 7
        Platform.current = WindowsPlatform.live(window: sink)  // 8
        WindowsPlatform.limitsFactory = WindowsLimitsProviders()  // 8: Claude limits from the credentials file

        let teamSuite = TeamSettings.suiteName(for: AppStatePaths.directory(), defaultDirectory: Self.defaultStateDirectory)
        var guarded: [String?] = [nil, teamSuite]  // 8b: before the first read of defaults
        if let own = WinDefaultsSync.selftestSuiteName { guarded = [own, teamSuite] }  // the selftest never guards the real plist
        WinDefaultsSync.guardAtLaunch(suites: guarded.filter { $0 != nil || WinDefaultsSync.selftestSuiteName == nil })
        let defaults = WinDefaultsSync.makeAppDefaults()  // 9
        self.defaults = defaults
        let store = UsageStore(defaults: defaults)  // 10
        let companion = CompanionStore(defaults: defaults)
        self.store = store
        self.companion = companion
        // The update check starts at step 14 (`WindowsUpdates`); the tray menu reads it.
        // Task 19: TeamRuntime (the team link and the plaza feed).
        Task { await companion.preparePokemonProfiles() }
        store.localizationLanguage = companion.language
        store.onRefresh = { [weak self] in self?.storeRefreshed() }
        teamSettings = TeamSettings(defaults: Self.teamDefaults(fallback: defaults))  // 11
        let tray = WinTrayHost(window: sink, store: store, companion: companion, defaults: defaults)
        self.tray = tray
        WindowsApp.trayToRemove = tray.tray
        WindowsNotifications.install(presenter: WinBalloonPresenter(tray: tray.tray), tray: tray.tray)  // Task 8
        tray.start(showFirstRunHint: !arguments.contains("--selftest"))
        WinDefaultsSync.flushNow()  // 12: a fresh team.memberID survives an early crash
        WinDefaultsSync.start()
        observeStore()  // 13
        applyState()
        // 14: the update check (Mac: `updater.check()` at launch; the tray menu re-checks when it opens). The selftest
        // never asks the network. Launch at login is not touched here: only the tray toggle writes it (off by default).
        WindowsUpdates.start(defaults: defaults, checkNow: !arguments.contains("--selftest"))
        AppLog.write("windows app launched pid=\(GetCurrentProcessId()) loop=\(loopStrategy.rawValue) "
            + "mutex=\(mutexName)\(arguments.contains("--autostart") ? " autostart" : "")")
        return true
    }

    /// `WM_CLOSE` (Restart Manager, the installer) and `WM_ENDSESSION(TRUE)` (sign-out, shutdown) leave through
    /// `WindowsApp.exit`, which saves the settings first.
    static func installExitHandlers(on window: WinSinkWindow) {
        window.on(UINT(WM_CLOSE)) { _, _ in WindowsApp.exit(0, .closeRequest) }
        window.on(UINT(WM_ENDSESSION)) { wParam, _ in
            if wParam != 0 { WindowsApp.exit(0, .endSession) }
            return 0
        }
    }

    static var defaultStateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar", isDirectory: true)
    }

    /// The Mac's `TeamSettings.defaultStore()` choice (standard, or a per-state-folder suite), as a syncing defaults.
    private static func teamDefaults(fallback: WinSyncingDefaults) -> WinSyncingDefaults {
        guard let suite = TeamSettings.suiteName(for: AppStatePaths.directory(), defaultDirectory: defaultStateDirectory)
        else { return fallback }
        return WinSyncingDefaults(suiteName: suite) ?? fallback
    }

    private static func setPerMonitorDpiAwareness() {
        typealias Fn = @convention(c) (OpaquePointer?) -> Int32
        guard let set = WinDynamic.symbol("user32.dll", "SetProcessDpiAwarenessContext", as: Fn.self) else { return }
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is ((DPI_AWARENESS_CONTEXT)-4). Fails harmlessly when a
        // manifest already set it (Task 12).
        if set(OpaquePointer(bitPattern: -4)) == 0 {
            AppLog.write("SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2): \(GetLastError())")
        }
    }

    /// The Mac's `observeStore`, same tracked values. `MenuBarContent.lines` lives in `UI/` (Mac-only), so its body
    /// is inlined.
    private func observeStore() {
        withObservationTracking {
            _ = store.menuLines(growthText: store.showGrowthInMenu ? companion.menuGrowthText : nil)
            _ = store.menuToolTip
            _ = store.alwaysFacesBack
            _ = store.menuLimitColorRuns()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyState()
                self.observeStore()
            }
        }
    }

    private func applyState() {
        noteCompanionInputs()
        AppWiring.updateCompanion(companion, from: store)
        tray?.refresh()
    }

    private func storeRefreshed() {
        refreshCount += 1
        noteCompanionInputs()
        AppWiring.storeRefreshed(companion, store)
    }

    private func noteCompanionInputs() {
        companionUpdates += 1
        lastCompanionSawUsage = store.hasUsageData
    }
}
#endif
