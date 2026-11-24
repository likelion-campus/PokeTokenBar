#if os(Windows)
import Foundation
import Observation
import WinSDK

/// Entry point of the Windows app. `main.swift` calls `main()` synchronously on the process main thread: an
/// `async` main would move main-actor work to a pool thread within a second and lose the windows (F16).
public enum WindowsApp {
    /// The process main thread (the selftest compares against it).
    nonisolated(unsafe) static var mainThreadID: DWORD = 0

    /// The command line the app runs with: what `main` decided (stage 7 Task 23: a `poketokenbar:` link's start never gets here
    /// with its own arguments). The one place Windows code reads its arguments from; reading `CommandLine.arguments` or
    /// `ProcessInfo.processInfo.arguments` anywhere else is refused by `WindowsSeamScanTests` (the selftest's own files apart).
    nonisolated(unsafe) private(set) static var launchArguments: [String] = []

    public static func main() -> Never {
        // --- stage 7 Task 23: a `poketokenbar:` link (WinAgentLink) (begin) ---
        // Before anything else, COM and the run loop included: a link's start reads nothing but the link, sets nothing up and
        // ends (`WinAgentLink.handleStart`); every other start goes on with its arguments, which every later reader takes from
        // `launchArguments`.
        let arguments = MainActor.assumeIsolated { WinAgentLink.handleStart(CommandLine.arguments) }
        launchArguments = arguments
        // --- stage 7 Task 23 (end) ---
        WinCom.initializeUIThread()  // STA before anything touches COM (TSF, the IME and the emoji panel need it; stage 6 D16)
        _ = RunLoop.main  // first, before any window: Foundation's initializer turns on CF's message mask (F4)
        mainThreadID = GetCurrentThreadId()
        // Synchronous top-level code on the main thread: the main actor's executor is this thread (F16).
        MainActor.assumeIsolated { () -> Never in run(arguments) }
    }

    @MainActor private static func run(_ arguments: [String]) -> Never {
        WindowsSelftest.isolateStateIfNeeded(arguments)  // a person's --selftest never touches their real save
        WinTimeZone.publishSystemZone()  // before anything reads TimeZone.current (its own Windows lookup fails on a localized zone name)
        if arguments.contains("--version") {
            try? FileHandle.standardOutput.write(contentsOf: Data(((WindowsInstall.version ?? "0.0.0-dev") + "\n").utf8))
            WindowsApp.exit(0, .helper)
        }
        if let i = arguments.firstIndex(of: "--selftest-defaults-writer") {
            WindowsSelftest.runDefaultsWriter(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-menu-exit") {
            WindowsSelftest.runMenuExit(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-dialog-exit") {
            WindowsSelftest.runDialogExit(Array(arguments[(i + 1)...]))   // stage 7 Task 15
        }
        if let i = arguments.firstIndex(of: WindowsSelftest.exitStuckFlag) {
            WindowsSelftest.runExitStuck(Array(arguments[(i + 1)...]))  // stage 8: the bounded exit's helper
        }
        if let i = arguments.firstIndex(of: "--selftest-guard-reader") {
            WindowsSelftest.runGuardReader(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-defaults-reader") {
            WindowsSelftest.runDefaultsReader(Array(arguments[(i + 1)...]))
        }
        if let i = arguments.firstIndex(of: "--selftest-waker-hunt") { WindowsSelftestWakers.run(Array(arguments[(i + 1)...])) }
        if let i = arguments.firstIndex(of: "--selftest-park") { WindowsSelftestWakers.park(Array(arguments[(i + 1)...])) }
        if let i = arguments.firstIndex(of: "--selftest-net-burst") { WindowsSelftestNetBurst.run(Array(arguments[(i + 1)...])) }
        if let i = arguments.firstIndex(of: "--selftest-crash") { WindowsSelftestCrash.run(Array(arguments[(i + 1)...])) }
        if arguments.contains("--tz-hunt") { WindowsSelftestLanguage.runTimeZoneHunt(arguments) }  // CI diagnostics
        if arguments.contains("--language-probe") { WindowsSelftestLanguage.runProbe(arguments) }  // CI: facts under another language
        if arguments.contains("--ime-check") { WinImeCheck.run() }
        if arguments.contains("--team-probe") { WindowsTeamProbe.main(arguments) }  // Task 19: the PC check's team probe
        if arguments.contains("--set-team-code") || arguments.contains("--clear-team-code") { WindowsTeamCodeTool.run(arguments) }
        if arguments.contains("--import-save") { WindowsImportSaveTool.run(arguments) }
        if let i = arguments.firstIndex(of: "--selftest-plaza-placement") { WindowsSelftest.runPlazaPlacement(Array(arguments[(i + 1)...])) }
        if let i = arguments.firstIndex(of: "--selftest-popover-helper") { WindowsSelftestPopoverWindow.runHelper(Array(arguments[(i + 1)...])) }  // stage 7 Task 4
        WindowsSelftestUpdate.prepare(arguments)  // stage 8 Task 6: the CI-only update flags (the loopback feed, before the checker exists)

        let app = WindowsAppDelegate(arguments: arguments)
        guard app.launch() else { WindowsApp.exit(app.yielded ? 3 : 1, .launchFailed) }
        WindowsInstall.leaveInstallFolder()  // not the install folder: Setup updates it, and what the app starts inherits it
        if arguments.contains("--selftest") {
            let out = arguments.firstIndex(of: "--selftest-out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("PokeTokenBar-selftest.json")
            if let why = SelftestOutputTarget.refusal(for: out) {
                AppLog.write("selftest: \(why)")
                try? FileHandle.standardOutput.write(contentsOf: Data((why + "\n").utf8))
                WindowsApp.exit(2, .selftest)
            }
            WindowsSelftest.start(app, writingTo: out)
        }
        // The idle gate's plaza windows (WindowsSelftestPlaza.swift). Not a `--selftest…` flag on purpose: those switch the app to
        // the selftest's own settings suite, and the gate's settings (refresh off) are in the app's plist.
        if let i = arguments.firstIndex(of: "--plaza-idle-probe") {
            WindowsSelftest.startPlazaIdle(app, mode: i + 1 < arguments.count ? arguments[i + 1] : "visible")
        }
        if arguments.contains("--popover-kit-idle-probe") { WindowsSelftest.startPopoverKitIdle() }  // stage 7 Task 3: the gate's open-kit window
        if arguments.contains("--popover-sprite-idle-probe") { WindowsSelftestPopover.startSpriteIdle() }  // stage 7 Task 8: an animating sprite open
        // --- stage 7 Task 5: the gate's open Home page (begin) ---
        if let i = arguments.firstIndex(of: "--popover-home-idle-probe") {
            WindowsSelftestPopoverHome.startIdleProbe(mode: i + 1 < arguments.count ? arguments[i + 1] : "seconds")
        }
        // --- stage 7 Task 5: the gate's open Home page (end) ---
        // --- stage 7 Task 12: the gate's open activity chart (begin) ---
        if let i = arguments.firstIndex(of: "--popover-activity-idle-probe") {
            WindowsSelftestPopoverActivity.startIdleProbe(mode: i + 1 < arguments.count ? arguments[i + 1] : "bars")
        }
        // --- stage 7 Task 12: the gate's open activity chart (end) ---
        // --- stage 7 Task 13: the gate's open recap page (begin) ---
        if arguments.contains("--popover-recap-idle-probe") { WindowsSelftestPopoverRecap.startIdleProbe() }
        // --- stage 7 Task 13: the gate's open recap page (end) ---
        // --- stage 7 Task 22: the gate's floating pet windows (begin) ---
        if let i = arguments.firstIndex(of: "--pet-idle-probe") {
            WindowsSelftestPopoverPet.startIdleProbe(mode: i + 1 < arguments.count ? arguments[i + 1] : "still")
        }
        // --- stage 7 Task 22 (end) ---
        // --- stage 7 Task 9: the gate's Home page with the companion header (begin) ---
        if let i = arguments.firstIndex(of: "--popover-companion-idle-probe") {
            WindowsSelftestPopoverCompanion.startIdleProbe(mode: i + 1 < arguments.count ? arguments[i + 1] : "still")
        }
        // --- stage 7 Task 9 (end) ---
        if let i = arguments.firstIndex(of: "--popover-idle-probe") {  // stage 7 Task 4: the gate's popover windows (open / closed after open)
            WindowsSelftestPopoverWindow.startIdleProbe(app, mode: i + 1 < arguments.count ? arguments[i + 1] : "open")
        }
        if WakeTrace.enabled {  // the gate measures from about +30 s: a snapshot just before it, one at exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 28) {
                AppLog.write(WakeTrace.snapshot("start", loops: WinMainLoop.iterations))
                AppLog.write(WinHTTPFetch.trace.snapshot("start"))  // the worker threads' fetches (run 44143290510)
            }
        }
        WindowsSelftestUpdate.start(arguments)  // stage 8 Task 6: "Update" as the tray item does it, under the CI-only flags
        WinMainLoop.run(app.loopStrategy) { false }
        WindowsApp.exit(0, .menu)  // not reached: the loop only ends through an exit
    }
}

extension WindowsApp {
    /// Set at launch; `exit` takes the icon out of the notification area on every exit path.
    @MainActor static var trayToRemove: WinTray?
    /// Set at launch; `exit` closes the team links (close_notify, DNS-SD goodbye) and joins the socket thread, once.
    @MainActor static var teamTransportToShutdown: WindowsTeamTransport?
    /// Stage 7 Task 4: set at launch; `exit` closes an open popover first, so its page commits a changed field (D5) before the
    /// settings are saved.
    @MainActor static var popoverToClose: WinPopover?

    /// The selftest's helper only: told each step of the exit as it completes (`tray removed`, `team shutdown done`).
    @MainActor static var exitStepObserver: ((String) -> Void)?

    enum ExitReason: String { case menu, endSession, closeRequest, selftest, helper, launchFailed, update }

    /// The cooperative part of the exit (the team's goodbye and the socket thread) shares this much, counted from the start
    /// of `exit`. Setup waits 30 s for the app to close and then refuses, so the whole exit stays far below that; healthy
    /// exits take well under a second. The data (popover commit, settings flush and backup) is spent first and never cut.
    static let exitBudget: TimeInterval = 5

    /// The only way Windows code leaves the process (scan-enforced): settings are lost unless synchronized (F2), and
    /// the log line is lost unless flushed.
    @MainActor static func exit(_ code: Int32, _ reason: ExitReason) -> Never {
        let began = Date()
        WinModalPump.cancelModalLoops()  // an exit asked for inside a modal loop closes the menu first
        if WakeTrace.enabled {  // the idle gate's attribution
            AppLog.write(WakeTrace.snapshot("exit", loops: WinMainLoop.iterations))
            AppLog.write(WinHTTPFetch.trace.snapshot("exit"))
        }
        if let line = WindowsSelftestPopoverWindow.idleProbeExitLine() { AppLog.write(line) }  // stage 7 Task 4: the idle gate's popover state at exit
        if let line = WindowsSelftestPopoverPet.idleProbeExitLine() { AppLog.write(line) }  // stage 7 Task 22: the idle gate's pet and object counts at exit
        popoverToClose?.close(.quit)  // stage 7 Task 4
        WinDefaultsSync.flushNow()
        WindowsCrashLog.markClean()
        if reason == .selftest {
            WinDefaultsSync.removeSelftestSuiteFile()  // the selftest's own, empty settings file (nothing of a person's)
            WindowsSelftest.removeTemporaryState()
        }
        if let line = WinPlazaLive.openPlazaLine { AppLog.write(line) }  // an open plaza's counters (idle measurements read them)
        AppLog.writeAndFlush("exit code=\(code) reason=\(reason.rawValue)")
        trayToRemove?.remove()
        exitStepObserver?("tray removed")
        teamTransportToShutdown?.shutdown(within: max(0, exitBudget - Date().timeIntervalSince(began)))
        teamTransportToShutdown = nil
        exitStepObserver?("team shutdown done")
        crtExit(code)
    }

    /// A `poketokenbar:` link's start ends here (stage 7 Task 23): it loaded no settings and made no crash marker, log, tray
    /// or team, so there is nothing to save, and `exit` would flush settings it never read. The other caller of `crtExit`.
    static func exitForLink() -> Never {
        crtExit(0)
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
    /// The team link and the plaza feed (`PokeTokenBarApp`'s `teamRuntime`). The transport opens nothing until the
    /// user has a team: `TeamSession` starts it only when `teamSettings.isReady`.
    private(set) var teamRuntime: TeamRuntime!
    private(set) var usageReporter: UsageReporter?
    private(set) var teamTransport: WindowsTeamTransport!
    /// The plaza (`PokeTokenBarApp`'s `plaza`): built at launch with the Mac's arguments, its window only on the user's action.
    private(set) var plaza: PlazaWindowController!
    /// The team settings' store, which the plaza's preferences share (the Mac's `TeamSettings.defaultStore()`).
    private(set) var teamSettingsDefaults: WinSyncingDefaults!
    private(set) var defaults: WinSyncingDefaults!
    private(set) var sink: WinSinkWindow!
    private(set) var tray: WinTrayHost?
    /// Stage 7 Task 4: the tray popover, built at launch; its window exists only while the user has it open.
    private(set) var popover: WinPopover?
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
        if WinSingleInstance.acquire(name: mutexName, quietly: arguments.contains("--autostart")) == .yielded {  // 2 (before anything that writes)
            yielded = true
            AppLog.writeAndFlush("duplicate instance: yielding to the instance already running (\(mutexName))")
            return false
        }
        if arguments.contains("--selftest-second") {
            AppLog.writeAndFlush("--selftest-second: no running instance held \(mutexName)")
            return false
        }
        WindowsCrashLog.install(version: WindowsInstall.version ?? "0.0.0-dev",
                                instance: WinSingleInstance.stateSuffix(stateDirectory: AppStatePaths.directory(), defaultDirectory: Self.defaultStateDirectory))  // 3
        PlazaStoreSpriteFetcher.report = { AppLog.write($0) }   // fix/windows-pet-still: what the GIF loader finds, in the log
        Self.setPerMonitorDpiAwareness()  // 4
        loopStrategy = WinMainLoop.prepare()  // 5
        do {  // 6
            sink = try WinSinkWindow(title: mutexName)
        } catch {
            AppLog.writeAndFlush("launch failed: \(error)")
            return false
        }
        Self.installExitHandlers(on: sink)
        WinModalPump.install(on: sink)
        sink.on(WinSingleInstance.showMessage) { [weak self] _, _ in
            self?.showRequests += 1
            self?.secondLaunch()  // stage 7 Task 4: the popover (ruling 3); was the "already running" balloon
            return 0
        }
        WinAgentLink.install(on: sink) { WinFloatingPet.current?.handleAgentEvent($0) }  // stage 7 Task 23: links from a second start (nil pet: dropped, as on the Mac)
        if !WinMessageHook.install() { AppLog.write("text input stays ANSI: no WH_GETMESSAGE hook") }  // 7
        WinAppUserModelID.set()  // before any notification: the toast is attributed to the id the installer put on the shortcut
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
        WinUILanguage.migrateStoredLanguage(companion: companion, defaults: defaults)  // before the first read of companion.language
        self.store = store
        self.companion = companion
        // The update check starts at step 14 (`WindowsUpdates`); the tray menu reads it.
        Task { await companion.preparePokemonProfiles() }
        store.localizationLanguage = companion.language
        store.onRefresh = { [weak self] in self?.storeRefreshed() }
        teamSettingsDefaults = Self.teamDefaults(fallback: defaults)
        teamSettings = TeamSettings(defaults: teamSettingsDefaults)  // 11
        let tray = WinTrayHost(window: sink, store: store, companion: companion, defaults: defaults)
        self.tray = tray
        WindowsApp.trayToRemove = tray.tray
        let balloons = WinBalloonPresenter(tray: tray.tray)
        tray.balloons = balloons
        WindowsNotifications.install(presenter: balloons, tray: tray.tray)  // Task 8
        WinPlazaLive.install(defaults: defaults, events: Platform.current.events as? WindowsSystemEvents)  // stage 6: before the plaza
        startTeam(balloons: balloons, tray: tray)  // 11b (Task 19); the plaza (stage 6 Task 5)
        startUsageReporter()
        tray.start(showFirstRunHint: !arguments.contains("--selftest"))
        WinDefaultsSync.flushNow()  // 12: a fresh team.memberID survives an early crash
        WinDefaultsSync.start()
        observeStore()  // 13
        observePlaza()
        observePlazaNickname()
        observePlazaTeamName()
        observePlazaRoster()
        applyState()
        // 14: the update check (Mac: `updater.check()` at launch; the tray menu re-checks when it opens). The selftest
        // never asks the network. Launch at login is not touched here: only the tray toggle writes it (off by default).
        WindowsUpdates.start(defaults: defaults, checkNow: !arguments.contains("--selftest"),
                             notify: { balloons.post(.init(id: "update", title: "PokeTokenBar", body: $0, sound: false, kind: .app)) },
                             language: { [companion] in companion.l })
        makePopover(updater: WindowsUpdates.checker)  // stage 7 Task 4
        makeFloatingPet()  // stage 7 Task 22: shown at launch when the setting is on (the Mac's FloatingPetController in launch)
        // Stage 8 Task 6: what the last in-app update did (one balloon when Setup put the previous app back), once the tray
        // can show it; the selftest's own settings never hold the marker.
        if !WinDefaultsSync.selftestOwnsSettings {
            let report: @MainActor () -> WindowsUpdateInstaller.LaunchReport = { [defaults, companion, balloons] in
                WindowsUpdateInstaller.reportAtLaunch(defaults: defaults, currentVersion: WindowsInstall.version, l: companion.l,
                                                      balloon: { balloons.post(.init(id: "update", title: "PokeTokenBar", body: $0, sound: false, kind: .app)) }).report
            }
            if case .setupRunning = report() { WindowsUpdateInstaller.afterSetup { _ = report() } }  // Setup started this app: after it ends
        }
        AppLog.write("windows app launched pid=\(GetCurrentProcessId()) loop=\(loopStrategy.rawValue) "
            + "mutex=\(mutexName)\(arguments.contains("--autostart") ? " autostart" : "")")
        // The Mac's plaza-dev.sh flag: opens the plaza at launch (a user's own command line, so it may come forward).
        if arguments.contains("--open-plaza") { openPlaza() }
        return true
    }

    /// The Mac's `openPlaza`: only while the team is ready (a notification can outlive the team); a second call brings the
    /// open window forward. The tray's "광장 열기", a team balloon's click and `--open-plaza` come here, nothing else.
    func openPlaza() {
        guard teamSettings.isReady else { return }
        if let popover, popover.dialogIsOpen { popover.bringDialogForward(); return }   // stage 7 Task 15: its dialog is app-modal
        popover?.close(.plaza)  // stage 7 D3: the plaza opening closes the popover
        plaza.show()
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

    /// The Mac's team wiring (`PokeTokenBarApp`): the runtime with the platform transport, the notifier, then
    /// `start()`; `AppWiringDriftScanTests` holds the two to the same arguments and order. The Mac posts only from a
    /// bundled app (its notification center crashes without a bundle); balloons have no such limit. The tray shows
    /// the teammates line while the team is on.
    private func startTeam(balloons: WinBalloonPresenter, tray: WinTrayHost) {
        let transport = WindowsTeamTransport(events: Platform.current.events as? WindowsSystemEvents)
        teamTransport = transport
        WindowsApp.teamTransportToShutdown = transport
        teamRuntime = TeamRuntime(settings: teamSettings, companion: companion, transport: transport)
        makePlaza()
        teamRuntime.plaza = plaza
        teamRuntime.notifier = TeamNotifier(
            settings: teamSettings, poster: WindowsTeamNotificationPoster(presenter: balloons),
            isPlazaFrontmost: { [weak plaza] in plaza?.isFrontmost ?? false },
            showInPlaza: { [weak plaza] in plaza?.showBanner($0) })
        teamRuntime.start()
        let settings = teamSettings!, session = teamRuntime.session, feed = teamRuntime.feed
        tray.teammatesOnline = { settings.isReady ? session.members.count : nil }
        tray.plazaUnread = { settings.isReady ? feed.unreadCount : nil }   // the Mac's plazaAvailable / plazaUnread
        tray.onOpenPlaza = { [weak self] in self?.openPlaza() }
        balloons.onClick = { [weak self] kind in if kind == .team { self?.openPlaza() } }   // the Mac's team notification delegate
    }

    /// The Mac's plaza controller, built with the AppDelegate's arguments (`AppWiringDriftScanTests` holds them); the preferences
    /// live in the team settings' syncing store, where the Mac's `PlazaPreferences()` default puts them.
    private func makePlaza() {
        // Named and typed as the Mac's AppDelegate has them, so the call below is its text (the drift scan compares it).
        let teamSettings: TeamSettings = self.teamSettings, companion: CompanionStore? = self.companion
        plaza = PlazaWindowController(
            preferences: PlazaPreferences(defaults: teamSettingsDefaults), loader: PlazaCharacterLoader(),
            nickname: { [teamSettings] in TeamSettings.validNickname(teamSettings.nickname) ?? "" },
            memberID: { [teamSettings] in teamSettings.memberID },
            subject: { [companion] in companion!.representativeSubject },
            myRosterEntry: { [companion, teamSettings] in
                PlazaRoster.myEntry(companion: companion!, teamSettings: teamSettings) },
            teamName: { [teamSettings] in teamSettings.currentTeam?.name },
            nameColor: { [teamSettings] in teamSettings.nameColor },
            chooseNameColor: { [teamSettings] in teamSettings.nameColor = $0 },
            schedule: { [teamSettings] in teamSettings.schedule },
            evolutionStage: { [companion] in companion!.representativeEvolutionStage },
            pokemonTypes: { try? await PokeAPIClient.shared.pokemonDetails(speciesID: $0).types },
            grantItem: { [companion] in companion!.receivePlazaItem($0) },
            pray: { [companion] in companion!.pray() },
            prayerCount: { [companion] in companion!.state.eggPrayers?.count ?? 0 },
            canPray: { [companion] in companion!.canPray },
            session: teamRuntime.session, feed: teamRuntime.feed)
    }

    /// 광장 캐릭터는 플로팅 펫과 같은 대표 대상을 따른다. 광장이 닫혀 있으면 두 호출 모두 아무 일도 안 한다. (The Mac's.)
    private func observePlaza() {
        withObservationTracking {
            _ = companion.representativeSubject
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePlaza()
                await self.plaza.refreshCharacter()
            }
        }
    }

    /// 내 칸에 쓰이는 모든 입력이 바뀌면 목록을 다시 만든다. (The Mac's.)
    private func observePlazaRoster() {
        withObservationTracking {
            _ = PlazaRoster.myEntry(companion: companion, teamSettings: teamSettings)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePlazaRoster()
                self.plaza.refreshMyEntry()
            }
        }
    }

    private func observePlazaNickname() {
        withObservationTracking {
            _ = teamSettings.nickname
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePlazaNickname()
                self.plaza.refreshNickname()
            }
        }
    }

    /// 팀 이름을 바꾸거나 다른 팀으로 옮기면 광장 창 제목도 바꾼다. (The Mac's.)
    private func observePlazaTeamName() {
        withObservationTracking {
            _ = teamSettings.currentTeam?.name
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePlazaTeamName()
                self.plaza.refreshTitle()
            }
        }
    }

    /// The Mac's `TeamSettings.defaultStore()` choice (standard, or a per-state-folder suite), as a syncing defaults.
    static func teamDefaults(fallback: WinSyncingDefaults) -> WinSyncingDefaults {
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

    /// The usage reporter (the Mac's `usageReporter` after `teamRuntime.start()`), on the team settings' own store.
    /// Not for a selftest run or a state folder of its own (CI fixtures, dev instances): those never write to the live
    /// sheet. The settings caption then reads "not sent yet", as on the Mac.
    private func startUsageReporter() {
        guard UsageReporter.shouldRun(stateDirectory: AppStatePaths.directory(), defaultDirectory: Self.defaultStateDirectory,
                                      isSelftest: arguments.contains("--selftest")) else { return }
        let reporter = UsageReporter(
            settings: teamSettings, defaults: teamSettingsDefaults,
            appVersion: WindowsInstall.version ?? "0", platform: "windows",
            inputs: { [unowned self] in UsageReportInputs.from(self.store) })
        reporter.start()
        usageReporter = reporter
    }

    private func storeRefreshed() {
        refreshCount += 1
        noteCompanionInputs()
        AppWiring.storeRefreshed(companion, store)
        usageReporter?.storeRefreshed()
    }

    private func noteCompanionInputs() {
        companionUpdates += 1
        lastCompanionSawUsage = store.hasUsageData
    }
}
// --- stage 7 Task 4: the popover (begin) ---
extension WindowsAppDelegate {
    /// The tray popover (stage 7 D2–D4): a left click or key select on the icon toggles it, the menu's "Settings…" opens it
    /// on Settings (the Mac's `showPopover { $0.showSettings = true }`), the menu closes it first, a second launch opens it.
    fileprivate func makePopover(updater: UpdateChecker?) {
        guard let tray else { return }
        let host = WinPopoverHost(store: store, companion: companion, updater: updater, team: teamSettings,
                                  session: teamRuntime.session, feed: teamRuntime.feed, tray: tray, loginItem: tray.loginItem,
                                  openPlaza: { [weak self] in self?.openPlaza() })
        host.owner = sink.hwnd
        host.usageReporter = usageReporter
        let made = WinPopover(host: host)
        // --- stage 7 Task 6: Settings (begin) ---
        made.makePage = WinSettingsPage.routed
        // --- stage 7 Task 6: Settings (end) ---
        popover = made
        WindowsApp.popoverToClose = made
        tray.onSelect = { [weak made] select in
            switch select {
            case .click(let point): made?.toggle(.trayClick(point))
            case .key: made?.toggle(.trayKey)
            }
        }
        tray.onOpenSettings = { [weak made] in made?.present(.trayMenu) { $0.showSettings = true } }
        tray.onOpenDex = { [weak made] in made?.present(.trayMenu) { $0.openRepresentativeDex() } }   // stage 7 Task 20
        tray.onMenuWillOpen = { [weak made] in made?.close(.iconClick) }
        tray.onBlockedByDialog = { [weak made] in made?.bringDialogForward() }   // stage 7 Task 15
    }

    /// A second start (`WinSingleInstance.showMessage`): the popover, also when the plaza is in front (it opens over it, and
    /// the plaza is there again when it closes); already open: brought forward. No popover (launch failed half-way): the
    /// balloon of before.
    fileprivate func secondLaunch() {
        if let popover { popover.present(.secondLaunch) { _ in } } else { tray?.showAlreadyRunning() }
    }
}
// --- stage 7 Task 4: the popover (end) ---
// --- stage 7 Task 22: the floating pet (begin) ---
extension WindowsAppDelegate {
    /// The floating pet (the Mac's `FloatingPetController` made in `applicationDidFinishLaunching`): it shows itself while
    /// `store.floatingPetEnabled` is on. A press on the pet closes an open popover (the Mac's transient popover closes on any
    /// press outside it) and a click on a hatched pet opens a closed one; the menu's Open always opens it. The pet goes below
    /// an open popover.
    fileprivate func makeFloatingPet() {
        let pet = WinFloatingPet(store: store, companion: companion, defaults: defaults, openPopover: { [weak self] opener in
            WinFloatingPet.openPopover(self?.popover, opener)
        }, configure: { [weak self] pet in
            pet.popoverWindow = { [weak self] in self?.popover?.hwnd }
            pet.menuOwner = { [weak self] in self?.sink?.hwnd }
            pet.popoverIsOpen = { [weak self] in self?.popover?.isOpen == true }
            pet.closePopover = { [weak self] in self?.popover?.close(.deactivated) }
        })
        WinFloatingPet.install(pet)
    }
}
// --- stage 7 Task 22 (end) ---
#endif
