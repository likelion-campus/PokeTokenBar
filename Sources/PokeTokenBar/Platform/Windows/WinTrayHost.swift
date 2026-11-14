#if os(Windows)
import Foundation
import Observation
import WinSDK

/// Wires the tray icon to the stores: static companion icon (egg until hatched), tooltip with today's numbers, the
/// menu and its actions. The Mac's `AppDelegate` status-item code, minus the animation (decided after idle numbers).
@MainActor final class WinTrayHost {
    static let hintKey = "windows.trayHintShown"

    let tray: WinTray
    private let window: WinSinkWindow
    private let store: UsageStore
    private let companion: CompanionStore
    private let defaults: UserDefaults

    /// Task 10 fills these; until then the login item is disabled and no update entry shows.
    var loginState: TrayMenuModel.LoginState = .unavailable
    var availableUpdate: (version: String, url: String)?

    private(set) var menuOpen = false
    private(set) var lastAction: TrayMenuModel.Action = .none
    private(set) var lastTip = ""
    private(set) var iconPixels = 0
    private(set) var iconSource = "none"
    private(set) var iconLoads = 0
    private var iconKey: String?
    private var iconGeneration = 0
    private var loggedIconFailure = false

    init(window: WinSinkWindow, store: UsageStore, companion: CompanionStore, defaults: UserDefaults) {
        self.window = window
        self.store = store
        self.companion = companion
        self.defaults = defaults
        tray = WinTray(window: window)
        tray.onActivate = { [weak self] in self?.openMenu(at: Self.cursor()) }
        tray.onContextMenu = { [weak self] point in self?.openMenu(at: point) }
        window.on(0x02E0 /* WM_DPICHANGED */) { [weak self] _, _ in self?.reloadIcon(); return nil }
        window.on(UINT(WM_SETTINGCHANGE)) { [weak self] _, _ in self?.reloadIcon(); return nil }
    }

    func start(showFirstRunHint: Bool) {
        refreshTip()
        tray.add()
        if showFirstRunHint, tray.isPresent, !defaults.bool(forKey: Self.hintKey) {
            defaults.set(true, forKey: Self.hintKey)
            _ = tray.showBalloon(title: "PokeTokenBar", body: companion.l.trayFirstRunHint, sound: false)
        }
        reloadIcon()
        observeCompanionSprite()
    }

    /// Called whenever the store or companion changed.
    func refresh() {
        refreshTip()
        reloadIcon()
    }

    func showAlreadyRunning() {
        _ = tray.showBalloon(title: "PokeTokenBar", body: companion.l.alreadyRunning, sound: false)
    }

    func menuItems() -> [TrayMenuModel.Item?] {
        TrayMenuModel.items(l: companion.l, todayTokens: store.todayTotalTokens,
                            todayCost: store.showsCost ? store.todayUsageCost : nil,
                            login: loginState, update: availableUpdate?.version)
    }

    /// Blocks in the system menu loop until it is dismissed (no drain timer meanwhile; F17), then runs the action.
    func openMenu(at point: POINT) {
        guard !menuOpen else { return }  // the shell sends several events for one click, queued behind the menu
        menuOpen = true
        store.requestNotificationAuthorizationIfNeeded()  // as the Mac does when the popover opens
        let items = menuItems()
        let chosen = WinPopupMenu.run(items, at: point, owner: window.hwnd)
        menuOpen = false
        if let chosen, let item = items[chosen] { perform(item.action) }
    }

    func resetLastAction() { lastAction = .none }

    func perform(_ action: TrayMenuModel.Action) {
        lastAction = action
        switch action {
        case .refresh:
            Task { await store.refresh() }
        case .openLogFolder:
            let folder = PlatformCompat.logsDirectory()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.open(WinPath.native(folder))
        case .openRelease:
            if let url = availableUpdate?.url { Self.open(url) }
        case .quit:
            WindowsApp.exit(0, .menu)
        case .toggleLaunchAtLogin, .none:
            break
        }
    }

    // MARK: - tooltip and icon

    private func refreshTip() {
        lastTip = TrayMenuModel.tooltip(l: companion.l, todayTokens: store.todayTotalTokens,
                                        todayCost: store.showsCost ? store.todayUsageCost : nil, note: store.menuToolTip)
        tray.setTip(lastTip)
    }

    /// The small-icon size for the DPI of the window's monitor.
    func iconPixelSize() -> Int {
        typealias DpiFn = @convention(c) (HWND?) -> UINT
        typealias MetricsFn = @convention(c) (Int32, UINT) -> Int32
        let dpi = WinDynamic.symbol("user32.dll", "GetDpiForWindow", as: DpiFn.self)?(window.hwnd) ?? 96
        if let metrics = WinDynamic.symbol("user32.dll", "GetSystemMetricsForDpi", as: MetricsFn.self) {
            let n = Int(metrics(Int32(SM_CXSMICON), dpi == 0 ? 96 : dpi))
            if n > 0 { return n }
        }
        return max(16, Int(GetSystemMetrics(SM_CXSMICON)))
    }

    /// The egg, or the representative subject's static sprite once hatched. Reloads only when the subject, its
    /// facing or the icon size changed; a failed download is retried at the next refresh.
    private func reloadIcon() {
        let subject = companion.representativeSubject
        let back = companion.facesBack
        let size = iconPixelSize()
        let key = "\(subject.speciesID ?? 0)-\(subject.isShiny)-\(subject.form.map { "\($0)" } ?? "")-\(back)-\(size)"
        guard key != iconKey else { return }
        iconKey = key
        iconGeneration += 1
        let generation = iconGeneration
        Task { @MainActor in
            var png: Data?
            var source = "egg"
            if let id = subject.speciesID {
                png = await SpriteStore.shared.data(speciesID: id, animated: false, shiny: subject.isShiny,
                                                    form: subject.form, back: back)
                source = "species \(id)"
            }
            if png == nil {
                png = await SpriteStore.shared.eggData()
                source = "egg"
            }
            guard generation == iconGeneration else { return }
            guard let png, let icon = WinIcon(png: png, size: size) else {
                iconKey = nil  // try again at the next refresh
                if !loggedIconFailure {
                    loggedIconFailure = true
                    AppLog.write("tray: no sprite icon (\(png == nil ? "download" : "decode") failed); keeping the generic icon")
                }
                return
            }
            tray.setIcon(icon)
            iconPixels = size
            iconSource = source
            iconLoads += 1
        }
    }

    /// The Mac's `observeCompanionSprite` keys (subject, facing), without frames.
    private func observeCompanionSprite() {
        withObservationTracking {
            _ = companion.representativeSubject
            _ = companion.facesBack
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reloadIcon()
                self.observeCompanionSprite()
            }
        }
    }

    // MARK: - small helpers

    private static func cursor() -> POINT {
        var p = POINT()
        _ = GetCursorPos(&p)
        return p
    }

    private static func open(_ target: String) {
        _ = WinStr.w("open").withUnsafeBufferPointer { verb in
            WinStr.w(target).withUnsafeBufferPointer { file in
                ShellExecuteW(nil, verb.baseAddress, file.baseAddress, nil, nil, Int32(SW_SHOWNORMAL))
            }
        }
    }
}
#endif
