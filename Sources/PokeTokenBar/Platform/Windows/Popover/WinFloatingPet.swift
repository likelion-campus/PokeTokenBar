#if os(Windows)
import CPlazaD2D
import Foundation
import Observation
import WinSDK

/// The floating pet (stage 7 Task 22): the Mac's `FloatingPetController` and its `NSPanel` (`UI/FloatingPetPanel.swift`) on
/// Windows. The representative companion's sprite in a small always-on-top window that never takes the activation or the
/// keyboard, dragged by its visible pixels, its place remembered; a click prays over an egg or opens the popover, a right
/// click opens the Mac's menu (Open, Turn off, Back view). Turned on and off by the popover footer's eye, the Settings group,
/// the tray menu and the pet's own menu (`store.floatingPetEnabled`, the Mac's one switch).
///
/// The rules are shared (`FloatingPetRules.swift`: placement, pointer, clicks, menu, what it shows, all twins of the Mac's);
/// this file is the window: a `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` popup (no taskbar button,
/// not in Alt+Tab, never activated by a click) whose per-pixel-alpha picture goes in through `UpdateLayeredWindow`, so a
/// transparent pixel lets the click through to the window below (the Mac's transparent panel does the same).
///
/// Idle: hidden (the setting off, or the displays asleep, as the Mac's `sync`) leaves no window, timer, bitmap or
/// registration. Shown with a still picture (the egg, a sprite without a GIF, battery saver, the session locked) it has no
/// timer and draws only when what it shows changes. Windows' "Show animations" off does not stop the GIF (`FloatingPetMotion`:
/// the Mac's Reduce Motion stops only the bob and the run; user ruling 2026-11-18). Shown animating, the shared sprite clock
/// (`PopoverSpritePlayback`, one one-shot `Timer(fire:)`) wakes once per frame of the GIF decimated to the animation-quality
/// floor (`PopoverSpriteFrameCap`, the Mac's `capFrameRate`), and each frame is one `UpdateLayeredWindow` of a premultiplied
/// DIB (the frames are scaled once and kept, within `WinPetWindow.scaledBudget`).
@MainActor final class WinFloatingPet {
    struct Stats: Equatable {
        var syncs = 0, shows = 0, hides = 0, renders = 0, renderFailures = 0, placements = 0, defaultPlacements = 0, saves = 0
        var moves = 0, clicks = 0, menus = 0, dpiChanges = 0, displayChanges = 0, sessionEvents = 0, powerEvents = 0, scales = 0
        /// DPI changes a drag deferred to its release, and Windows' answers to the window's own update (ignored).
        var dpiDeferred = 0, dpiIgnored = 0
        /// The foreground given back after the pet's menu, and frames scaled again because the kept ones filled the budget.
        var foregroundRestores = 0, scaledUncached = 0
        /// Presses that closed the open popover (`FloatingPetPopoverPress`).
        var popoverClosesOnPress = 0
    }

    /// The app's pet, made at launch (the selftest and the idle probe read it).
    static var current: WinFloatingPet?
    /// Where sprites come from instead of the sprite store (the selftest's and the idle probe's FIXTURE folder).
    static var spriteFetcherOverride: (any PlazaSpriteFetching)?

    let store: UsageStore
    let companion: CompanionStore
    let defaults: UserDefaults
    let actions: FloatingPetActions

    /// The open popover's window: a pet that appears while it is open goes below it (the Mac's popover stands above the pet's
    /// floating level); nil while it is closed.
    var popoverWindow: () -> HWND? = { nil }
    /// The window the pet's menu belongs to (the app's hidden sink, as the tray menu's): the menu takes the foreground there,
    /// the Mac's `NSApp.activate` before its context menu.
    var menuOwner: () -> HWND? = { nil }
    /// The popover is open, and closing it as an outside press does (the Mac's transient popover; `FloatingPetPopoverPress`).
    var popoverIsOpen: () -> Bool = { false }
    var closePopover: () -> Void = {}
    /// Windows' "Show animations" (the Mac's Reduce Motion, inverted): stops the pet's motion, not its GIF (`FloatingPetMotion`).
    var animationsEnabled: () -> Bool = { WinSpriteAnimator.systemAnimationsEnabled() }
    /// Battery saver (the Mac's Low Power Mode): the still sprite.
    var lowPower: () -> Bool = { WinFloatingPet.batterySaverOn() }
    var displayAsleep: () -> Bool = { Platform.current.events.displaysAreAsleep }
    /// The session at the lock screen when a window is made (review I4: a window made there, the displays waking at the lock
    /// screen, must not animate behind it); `WM_WTSSESSION_CHANGE` moves it afterwards.
    var sessionLocked: () -> Bool = { WinFloatingPet.sessionNow().locked }
    var screens: () -> [FloatingPetScreen] = { WinFloatingPet.monitorScreens() }
    /// Observers of the pointer coming over the pet or leaving it, and of where it moved without a button held (screen pixels;
    /// the selftest's). The pet's own hover callout and strokes (Task 23) do not need them.
    var onHoverChange: ((Bool) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?
    /// Task 23: the bubbles, hearts, prayers, hover callout and agent activity (state and one-shot timers).
    let extras = WinPetExtras()

    fileprivate(set) var stats = Stats()
    /// The last press on the pet and whether it closed the popover.
    fileprivate var press = FloatingPetPopoverPress()
    private(set) var model: FloatingPetModel?
    private(set) var window: WinPetWindow?
    private var generation = 0
    private(set) var isDestroyed = false

    /// A pet over these stores. `configure` sets the knobs before the first `sync` (a selftest harness, the idle probe).
    init(store: UsageStore, companion: CompanionStore, defaults: UserDefaults,
         openPopover: @escaping @MainActor (FloatingPetActions.Opener) -> Void, configure: (WinFloatingPet) -> Void = { _ in }) {
        self.store = store
        self.companion = companion
        self.defaults = defaults
        actions = FloatingPetActions(store: store, companion: companion, openPopover: openPopover)
        configure(self)
        actions.clickMayOpen = { [weak self] in
            guard let self else { return true }
            return self.press.clickOpens(popoverOpen: self.popoverIsOpen())
        }
        // --- stage 7 Task 23 (begin) ---
        extras.lastSeenEventSeq = latestEvent?.seq   // an event from before the pet existed is not news
        actions.spawnEmoji = { [weak self] in
            guard let self, let w = self.window else { return }
            self.extras.spawnPrayer { [weak w] in w?.render() }
        }
        actions.didPray = { [weak self] in self?.refreshHover() }
        // --- stage 7 Task 23 (end) ---
        observe()
        sync()
    }

    /// The app's pet, made once at launch: the displays' sleep and wake hide and show it (the Mac's `setDisplayAwake`).
    static func install(_ pet: WinFloatingPet) {
        current = pet
        guard !installedSystemHandlers else { return }
        installedSystemHandlers = true
        Platform.current.events.onScreensSleep { MainActor.assumeIsolated { WinFloatingPet.current?.sync() } }
        Platform.current.events.onScreensWake { MainActor.assumeIsolated { WinFloatingPet.current?.sync() } }
    }

    private static var installedSystemHandlers = false

    /// What the app's pet asks of the popover: a click on a hatched pet opens it, nothing when it is open (the Mac's
    /// `AppDelegate.openPopover` guard; the press already closed an open one: `FloatingPetPopoverPress`); the menu's Open always
    /// opens it (a close still pending from the menu taking the foreground runs first, inside `present`).
    static func openPopover(_ popover: WinPopover?, _ opener: FloatingPetActions.Opener) {
        guard let popover else { return }
        if opener == .click, popover.isOpen { return }
        popover.present(.pet) { _ in }
    }

    /// Shows, updates or hides the window for the settings now (the Mac's `sync`). Nothing changes when nothing did.
    func sync() {
        guard !isDestroyed else { return }
        stats.syncs += 1
        if extras.syncReset(enabled: agentEnabled) { extras.updateBob(active: false) {} }   // Task 23: `sync`'s reset
        let next = FloatingPetModel.make(store: store, companion: companion, displayAwake: !displayAsleep(), lowPower: lowPower())
        let previous = model
        model = next
        guard next.visible else {
            hideWindow()
            return
        }
        if let window {
            // Task 23: a new bubble (a limit alert, an agent) is drawn; anything else draws nothing.
            if next != previous {
                window.apply(next)
            } else if extras.bubble(limitAlert: limitAlert) != extras.drawnBubble {
                window.render()
            }
            refreshHover()
            return
        }
        guard let made = WinPetWindow(pet: self, model: next) else { return }
        window = made
        stats.shows += 1
    }

    private func hideWindow() {
        guard let window else { return }
        extras.hidden()   // Task 23: the transients end, the callout goes, the pet comes back at home
        window.destroy()
        self.window = nil
        stats.hides += 1
    }

    /// The window was destroyed by Windows itself (the session ending): forget it.
    fileprivate func windowGone(_ w: WinPetWindow) {
        guard window === w else { return }
        window = nil
        stats.hides += 1
    }

    /// Stops observing and hides (a selftest harness; the app's pet lives as long as the app).
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        generation += 1
        hideWindow()
        extras.destroy()
    }

    private func observe() {
        guard !isDestroyed else { return }
        let g = generation
        withObservationTracking {
            _ = store.floatingPetEnabled
            _ = store.floatingPetSize
            _ = store.animationQuality
            _ = companion.representativeSubject
            _ = companion.facesBack
            // --- stage 7 Task 23: what the bubble and the hover text show (the Mac's `observeSettings`) (begin) ---
            _ = store.floatingPetAgentActivity
            _ = store.currentBubbleAlert
            _ = store.todayTotalTokens
            _ = store.highestLimitUtilization
            _ = store.limitDisplayMode
            _ = companion.language
            _ = companion.sulkIdle
            _ = companion.state.eggPrayers
            _ = companion.latestEvent
            // --- stage 7 Task 23 (end) ---
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isDestroyed, g == self.generation else { return }
                    self.sync()
                    self.popEventIfNew()
                    self.observe()
                }
            }
        }
    }

    // MARK: - the system

    /// `GetSystemPowerStatus`'s `SystemStatusFlag` (byte 3 of the struct): 1 while battery saver (Energy saver) is on.
    static func batterySaverOn() -> Bool {
        var status = SYSTEM_POWER_STATUS()
        guard GetSystemPowerStatus(&status) else { return false }
        return withUnsafeBytes(of: status) { $0[3] } & 1 != 0
    }

    /// This session now (`WTSQuerySessionInformationW`, `WTSSessionInfoEx`); unlocked and connected when it cannot be read.
    static func sessionNow() -> (locked: Bool, disconnected: Bool) {
        var locked: Int32 = 0, disconnected: Int32 = 0
        _ = ptb_session_state(&locked, &disconnected)
        return (locked != 0, disconnected != 0)
    }

    /// The monitors now (`EnumDisplayMonitors`, effective DPI) in the shared placement's terms.
    static func monitorScreens() -> [FloatingPetScreen] {
        WinPlazaPlacement.monitors().map { m in
            FloatingPetScreen(bounds: rect(m.bounds), work: rect(m.work), scale: CGFloat(m.dpi) / 96, isPrimary: m.isPrimary)
        }
    }

    private static func rect(_ r: WinPlazaPlacement.Rect) -> CGRect {
        CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.width), height: CGFloat(r.height))
    }
}

/// The pet's window while it is shown: made when the pet appears, destroyed when it goes (`WinFloatingPet.sync`).
@MainActor final class WinPetWindow {
    static let className = "PokeTokenBarPet"
    /// WS_POPUP: no frame, no caption.
    static let style: DWORD = 0x8000_0000
    /// WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST.
    static let exStyle: DWORD = 0x0800_0000 | 0x0008_0000 | 0x0000_0080 | 0x0000_0008
    /// GUID_POWER_SAVING_STATUS {E00958C0-C213-4ACE-AC77-FECCED2EEEA5}: battery saver turned on or off.
    static var powerSavingGUID: GUID {
        GUID(Data1: 0xE009_58C0, Data2: 0xC213, Data3: 0x4ACE, Data4: (0xAC, 0x77, 0xFE, 0xCC, 0xED, 0x2E, 0xEE, 0xA5))
    }
    /// The scaled frames kept for the current subject and size: a 384-DIP pet at 200 % with "Smooth" would need about 66 MB.
    /// Once full, the frames kept stay and the rest are scaled as they come, every time (review M8: dropping all and refilling
    /// scaled every frame of such a loop forever): at most one scale per frame shown, of the frames past the first ~20.
    static let scaledBudget = 48 << 20

    let window: WinSinkWindow
    var hwnd: HWND { window.hwnd }
    private weak var pet: WinFloatingPet?
    private(set) var model: FloatingPetModel
    let playback: PopoverSpritePlayback
    /// The DPI the picture is drawn at (the window's).
    private(set) var dpi: UINT
    /// The window's rectangle on the virtual screen (pixels).
    private(set) var frame: RECT
    private(set) var pointer = FloatingPetPointer()
    private(set) var locked = false, disconnected = false
    private(set) var sessionNotify = false
    private(set) var powerNotify = false
    private(set) var isDestroyed = false
    private var powerRegistration: UnsafeMutableRawPointer?
    private var surface = Surface()
    private var scaled = FloatingPetScaledFrames<ObjectIdentifier>(budget: WinPetWindow.scaledBudget)
    private var placeholders: [ObjectIdentifier: (source: PlazaImage, cropped: PlazaImage)] = [:]
    private var eggGlyph: (key: String, image: PlazaImage)?
    private var hovering = false
    private var inMenu = false, destroyAfterMenu = false
    private var loggedFailure = false
    /// Inside the window's own `UpdateLayeredWindow` (a `WM_DPICHANGED` sent from there is ignored), and the DPI a drag
    /// deferred to its release (its moves' `SetWindowPos` brings it).
    private var inOwnUpdate = false
    private(set) var pendingDPI: UINT?
    /// The side of the picture on screen (0: nothing drawn yet), and where the last picture went.
    private var drawnSide = 0
    private var drawnFrame: RECT?

    private struct Surface {
        var dc: HDC?, bitmap: HBITMAP?, old: HGDIOBJ?, bits: UnsafeMutableRawPointer?
        var width = 0, height = 0
    }
    /// The native tooltip (the Mac's `hosting.toolTip`): the hover text after 600 ms, cleared while the hearts show.
    private var tooltips: WinTooltips?
    private var tooltipText: String?
    private var tooltipDark = false
    /// The picture's pieces kept between frames: the bubble's picture for its text and DPI, the 🙏 glyph, the sprite's visible top.
    private var bubbleImage: (key: String, image: PlazaImage, size: CGSize)?
    private var prayerImage: (key: String, bgra: [UInt8], w: Int, h: Int)?
    private var heartsImage: (scale: CGFloat, bgra: [UInt8], w: Int, h: Int)?
    private var visibleTopCache: (key: String, top: CGFloat)?

    init?(pet: WinFloatingPet, model: FloatingPetModel) {
        guard let placed = FloatingPetPlacement.screenFrame(petSize: model.petSize, saved: FloatingPetOrigin.saved(in: pet.defaults),
                                                            screens: pet.screens()) else {
            AppLog.write("floating pet: no monitor to stand on")
            return nil
        }
        let r = Self.rect(placed.frame)
        do {
            window = try WinSinkWindow(className: Self.className, title: "PokeTokenBar", style: Self.style, exStyle: Self.exStyle,
                                       x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top)
        } catch {
            AppLog.write("floating pet: \(error)")
            return nil
        }
        self.pet = pet
        self.model = model
        playback = PopoverSpritePlayback(fetcher: WinFloatingPet.spriteFetcherOverride ?? PlatformPlaza.spriteFetcher())
        frame = r
        dpi = UINT((placed.scale * 96).rounded())
        pet.stats.placements += 1
        if placed.isDefault { pet.stats.defaultPlacements += 1 }
        // A pet over two monitors gets the DPI Windows gives the window (the monitor with most of it): sized again at it.
        let real = WinUIContext.dpi(of: hwnd)
        if real != dpi, let again = FloatingPetPlacement.screenFrame(petSize: model.petSize, saved: FloatingPetOrigin.saved(in: pet.defaults),
                                                                       screens: pet.screens(), scale: CGFloat(real) / 96) {
            frame = Self.rect(again.frame)
            dpi = real
        }
        register()
        sessionNotify = ptb_window_session_notify(UnsafeMutableRawPointer(hwnd), 1) == 1
        // Read after registering: a lock from here on arrives as a message.
        locked = pet.sessionLocked()
        var guid = Self.powerSavingGUID
        powerRegistration = RegisterPowerSettingNotification(hwnd, &guid, 0 /* DEVICE_NOTIFY_WINDOW_HANDLE */)
        powerNotify = powerRegistration != nil
        playback.onInvalidate = { [weak self] _ in
            self?.render()
            self?.reveal()
        }
        playback.shouldTick = { [weak self] in self?.canAnimate ?? false }
        apply(model, first: true)
        // The first default placement becomes the saved home (the Mac's `windowDidMove` after its first `setFrame`). A saved
        // home that meets no monitor now is kept (review M11: a monitor away for a moment; the pet goes back when it returns).
        if FloatingPetOrigin.saved(in: pet.defaults) == nil { persist() }
        // On screen once the first picture is in (the sprite cache answers in milliseconds), so a new window does not flash the
        // 🥚; a load still out after `revealDelay` shows what there is (the 🥚, as the Mac shows it without a cached sprite).
        let timer = Timer(fire: Date().addingTimeInterval(Self.revealDelay), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// The longest a new window waits for its first picture before it shows (a one-shot timer, only while it waits).
    static let revealDelay: TimeInterval = 0.3
    private var revealTimer: Timer?
    private(set) var revealed = false

    private func reveal() {
        guard !isDestroyed, !destroyAfterMenu, !revealed else { return }
        revealed = true
        revealTimer?.invalidate()
        revealTimer = nil
        render()
        showOnScreen()
        refreshActivity()
        pet?.refreshHover()   // Task 23: the tooltip's text, a callout already wanted
    }

    /// What the pet shows changed (`FloatingPetModel`): the sprite, its size, the frame floor, animated or still.
    func apply(_ next: FloatingPetModel, first: Bool = false) {
        guard !isDestroyed else { return }
        let resized = !first && next.petSize != model.petSize
        model = next
        playback.animationsEnabled = gifPlays
        playback.frameFloor = next.frameFloor
        playback.update(slots: [SpriteSlot(frame: CGRect(x: 0, y: 0, width: next.petSize, height: next.petSize), subject: next.subject,
                                           bob: false, animated: next.animated)])
        if resized { place() } else { render() }
        refreshActivity()
    }

    /// The clock runs while the window shows, the displays are on and the session is the console's and unlocked.
    var canAnimate: Bool {
        !isDestroyed && IsWindowVisible(hwnd) && !(pet?.displayAsleep() ?? true) && !locked && !disconnected
    }

    /// The GIF plays unless battery saver is on (`model.animated`); Windows' "Show animations" is Reduce Motion's input, which
    /// stops only motion (`FloatingPetMotion`; the pet has none of its own until Task 23).
    private var gifPlays: Bool {
        FloatingPetMotion.gates(lowPower: !model.animated, reduceMotion: !(pet?.animationsEnabled() ?? true)).gif
    }

    func refreshActivity() {
        guard !isDestroyed else { return }
        let enabled = gifPlays
        if playback.animationsEnabled != enabled {
            playback.animationsEnabled = enabled
            render()
        }
        playback.isActive = canAnimate
        pet?.refreshBob()   // Task 23: the bob follows the same motion rule
    }

    // MARK: - placement

    /// Places the window again from the saved home, the monitors now and its DPI (a display change, a new size): the Mac's
    /// `targetFrame` (the home if it meets a work area, else the default corner), drawn there. Nothing is saved: only a drag
    /// moves the home (review M11; the Mac saves the fallback corner, see the inventory's F1).
    func place(scale: CGFloat? = nil) {
        guard !isDestroyed, let pet else { return }
        // Task 23: a pet that ran to the cursor stays there until it comes back (its bottom-left kept, drawn at the new size).
        guard pet.extras.flow.runPhase == .home else { render(); return }
        guard let placed = FloatingPetPlacement.screenFrame(petSize: model.petSize, saved: FloatingPetOrigin.saved(in: pet.defaults),
                                                            screens: pet.screens(), scale: scale ?? CGFloat(dpi) / 96) else { return }
        frame = Self.rect(placed.frame)
        dpi = UINT((placed.scale * 96).rounded())
        pet.stats.placements += 1
        if placed.isDefault { pet.stats.defaultPlacements += 1 }
        render()
    }

    /// The pet's bottom-left corner is its home (`FloatingPetOrigin`), saved when a drag moved it there (and once, at the first
    /// default placement).
    private func persist() {
        guard let pet else { return }
        let origin = CGPoint(x: CGFloat(frame.left), y: CGFloat(frame.bottom))
        guard FloatingPetOrigin.saved(in: pet.defaults) != origin else { return }
        FloatingPetOrigin.save(origin, in: pet.defaults)
        pet.stats.saves += 1
    }

    /// Topmost, below the popover when it is open and topmost, shown without the activation. A popover waiting to close
    /// after a deactivation has left the topmost band (`HWND_NOTOPMOST`): placed after it the pet would leave it too (review M7).
    private func showOnScreen() {
        let popover = pet?.popoverWindow().flatMap { IsWindowVisible($0) && DWORD(bitPattern: GetWindowLongW($0, -20 /* GWL_EXSTYLE */)) & 0x8 /* WS_EX_TOPMOST */ != 0 ? $0 : nil }
        _ = SetWindowPos(hwnd, popover ?? HWND(bitPattern: -1) /* HWND_TOPMOST */, 0, 0, 0, 0,
                         UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW))
    }

    private func move(toTopLeft p: CGPoint) {
        let x = Int32(p.x.rounded()), y = Int32(p.y.rounded())
        guard x != frame.left || y != frame.top else { return }
        let w = frame.right - frame.left, h = frame.bottom - frame.top
        frame = RECT(left: x, top: y, right: x + w, bottom: y + h)
        let r = windowRect
        // A drag over a monitor of another DPI gets its WM_DPICHANGED from inside this call: deferred to the release.
        _ = SetWindowPos(hwnd, nil, r.left, r.top, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        // The window is there now (its size unchanged): the next picture of the same size needs no place.
        if let d = drawnFrame { drawnFrame = RECT(left: r.left, top: r.top, right: r.left + d.right - d.left, bottom: r.top + d.bottom - d.top) }
        pet?.stats.moves += 1
        if pet?.extras.callout.isShown == true { pet?.refreshHover() }   // Task 23: `windowDidMove` moves the callout along
    }

    // MARK: - Task 23: the panel, the run and the way home

    /// The window's rectangle: the pet box, or the Mac's panel around it while a bubble or the hearts show
    /// (`panelSize(petSize:showingBubble:)`: at least 180 DIP wide, 72 DIP of headroom; the pet at its bottom, centred).
    var windowRect: RECT {
        guard let pet, pet.extras.showingBubble(alertActive: pet.limitAlert != nil) else { return frame }
        let scale = CGFloat(dpi) / 96
        let panel = FloatingPetRules.panelSize(petSize: model.petSize, showingBubble: true)
        let w = Int32((panel.width * scale).rounded()), h = Int32((panel.height * scale).rounded())
        let side = frame.right - frame.left
        let left = frame.left - max(0, (w - side) / 2)
        return RECT(left: left, top: frame.bottom - h, right: left + w, bottom: frame.bottom)
    }

    /// The pet box's bottom-left now (screen pixels): what a run moves, as the home is that corner.
    private var petBottomLeft: CGPoint { CGPoint(x: CGFloat(frame.left), y: CGFloat(frame.bottom)) }

    /// An agent's done (`runToCursor` / `beginRun`): the panel next to the pointer on the pointer's monitor (`runPanelOrigin`,
    /// on a y-up mirror of the screen so the Mac's rule reads as it is), at that monitor's DPI, reached in 0.6 s. The home is
    /// not saved.
    func runToCursor() {
        guard let pet else { return }
        var cursor = POINT()
        let screens = pet.screens()
        guard GetCursorPos(&cursor),
              let screen = screens.first(where: { $0.bounds.contains(CGPoint(x: CGFloat(cursor.x), y: CGFloat(cursor.y))) })
                  ?? screens.first(where: { $0.isPrimary }) else { pet.sync(); return }
        let toDPI = UINT((screen.scale * 96).rounded())
        let panel = FloatingPetRules.panelSize(petSize: model.petSize, showingBubble: true)
        let size = CGSize(width: (panel.width * screen.scale).rounded(), height: (panel.height * screen.scale).rounded())
        let work = screen.work
        let origin = FloatingPetAgentMotion.runPanelOrigin(cursor: CGPoint(x: CGFloat(cursor.x), y: -CGFloat(cursor.y)), panelSize: size,
                                                           visibleFrame: CGRect(x: work.minX, y: -work.maxY, width: work.width, height: work.height),
                                                           gap: (FloatingPetAgentMotion.agentRunCursorGap * screen.scale).rounded())
        // The panel's bottom-left in y-down pixels; the pet box at its bottom, centred (`petOrigin(panelOrigin:)`).
        let side = CGFloat(pictureSide(at: toDPI))
        let target = CGPoint(x: origin.x + max(0, (size.width - side) / 2).rounded(.down), y: -origin.y)
        pet.extras.beganRun()
        pet.extras.animateMove(from: petBottomLeft, to: target, returning: false,
                               step: { [weak self] p in self?.moveForRun(to: p) },
                               ended: { [weak self] in self?.settle(at: toDPI) },
                               render: { [weak self] in self?.render() })
    }

    /// The agents are answered (`returnHome`): back to the home frame (`targetFrame`) in 0.6 s, then at home.
    func returnHome() {
        guard let pet, let placed = FloatingPetPlacement.screenFrame(petSize: model.petSize, saved: FloatingPetOrigin.saved(in: pet.defaults),
                                                                     screens: pet.screens(), scale: CGFloat(dpi) / 96) else {
            pet?.extras.returned()
            pet?.sync()
            return
        }
        let toDPI = UINT((placed.scale * 96).rounded())
        pet.extras.animateMove(from: petBottomLeft, to: CGPoint(x: placed.frame.minX, y: placed.frame.maxY), returning: true,
                               step: { [weak self] p in self?.moveForRun(to: p) },
                               ended: { [weak self] in
                                   self?.settle(at: toDPI)
                                   self?.pet?.extras.returned()
                                   self?.pet?.sync()
                               },
                               render: { [weak self] in self?.render() })
    }

    /// One frame of a run or the way back: the pet box's bottom-left moves (drawn by the frame's render), nothing is saved.
    private func moveForRun(to p: CGPoint) {
        let x = Int32(p.x.rounded()), bottom = Int32(p.y.rounded())
        let side = frame.right - frame.left
        frame = RECT(left: x, top: bottom - side, right: x + side, bottom: bottom)
    }

    /// The move ended on a monitor of `toDPI`: drawn at it there (the messages its frames caused came from inside the
    /// window's own updates and were not a new DPI).
    private func settle(at toDPI: UINT) {
        guard !isDestroyed, toDPI != dpi, toDPI > 0 else { return }
        dpi = toDPI
        pet?.stats.dpiChanges += 1
        render()
    }

    /// The native tooltip's text (nil clears it): the Mac's `hosting.toolTip`, shown by the system after 600 ms (the app's
    /// `NSInitialToolTipDelay`, as the popover's), its lines as the hover text's; dressed dark in dark mode as the popover's.
    func setToolTip(_ text: String?) {
        let dark = text != nil && WinPetLook.system().dark
        if let made = tooltips, text != nil, dark != tooltipDark {   // the app mode changed: a tooltip dressed for it
            made.destroy()
            tooltips = nil
            tooltipText = nil
        }
        guard text != tooltipText else { return }
        tooltipText = text
        if tooltips == nil, text != nil {
            let made = WinTooltips(owner: hwnd, font: nil, maxWidth: Int32((280 * CGFloat(dpi) / 96).rounded()))
            tooltipDark = dark
            if dark {
                let palette = WinUIColors.resolve(highContrast: false, dark: true, accent: nil, system: { GetSysColor($0) })
                made.dress(background: palette.card, text: palette.text)
            }
            tooltips = made
        }
        tooltips?.set(text?.replacingOccurrences(of: "\n", with: "\r\n"), for: hwnd, in: nil)
    }

    private static func rect(_ r: CGRect) -> RECT {
        RECT(left: Int32(r.minX.rounded()), top: Int32(r.minY.rounded()), right: Int32(r.maxX.rounded()), bottom: Int32(r.maxY.rounded()))
    }

    // MARK: - messages

    private func register() {
        let w = window
        w.on(0x0021 /* WM_MOUSEACTIVATE */) { _, _ in 3 /* MA_NOACTIVATE: a click never activates the pet */ }
        w.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
        w.on(0x0201 /* WM_LBUTTONDOWN */) { [weak self] _, lParam in
            self?.buttonDown(lParam)
            return 0
        }
        w.on(0x0200 /* WM_MOUSEMOVE */) { [weak self] _, lParam in
            self?.mouseMoved(lParam)
            return 0
        }
        w.on(0x0202 /* WM_LBUTTONUP */) { [weak self] _, lParam in
            self?.buttonUp(lParam)
            return 0
        }
        w.on(0x0215 /* WM_CAPTURECHANGED */) { [weak self] _, _ in
            self?.captureLost()
            return 0
        }
        w.on(0x02A3 /* WM_MOUSELEAVE */) { [weak self] _, _ in
            guard let self, self.hovering else { return 0 }
            self.hovering = false
            self.pet?.extras.setHovering(false)   // Task 23: `mouseExited` (strokes reset, the callout goes)
            self.pet?.extras.hideCallout()
            self.pet?.onHoverChange?(false)
            return 0
        }
        // A right click (DefWindowProc turns the button's release into WM_CONTEXTMENU), the Mac's `rightMouseDown`.
        w.on(0x007B /* WM_CONTEXTMENU */) { [weak self] _, lParam in
            self?.contextMenu(at: lParam)
            return 0
        }
        w.on(0x02E0 /* WM_DPICHANGED */) { [weak self] wParam, lParam in
            // lParam: Windows' suggested window rectangle at the new DPI.
            let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee
            self?.dpiChanged(UINT(wParam & 0xFFFF), suggested: suggested)
            return 0
        }
        w.on(0x007E /* WM_DISPLAYCHANGE */) { [weak self] _, _ in
            self?.pet?.stats.displayChanges += 1
            self?.place()
            return 0
        }
        w.on(0x001A /* WM_SETTINGCHANGE */) { [weak self] wParam, _ in
            if wParam == 0x002F /* SPI_SETWORKAREA */ {
                self?.pet?.stats.displayChanges += 1
                self?.place()
            } else if wParam == 0x1043 /* SPI_SETCLIENTAREAANIMATION */ {
                self?.refreshActivity()
            }
            return nil
        }
        w.on(0x02B1 /* WM_WTSSESSION_CHANGE */) { [weak self] wParam, _ in
            self?.sessionChanged(Int(wParam))
            return 0
        }
        w.on(0x0218 /* WM_POWERBROADCAST */) { [weak self] wParam, _ in
            if wParam == 0x8013 /* PBT_POWERSETTINGCHANGE */ {
                self?.pet?.stats.powerEvents += 1
                self?.pet?.sync()   // battery saver: the model's `animated`
            }
            return 1
        }
        w.on(0x0002 /* WM_DESTROY */) { [weak self] _, _ in
            self?.destroyedFromOutside()
            return nil
        }
    }

    /// The pointer in screen pixels: the message's client point plus where the window is now (the panel's top-left while a
    /// bubble shows).
    private func screenPoint(_ lParam: LPARAM) -> CGPoint {
        let r = drawnFrame ?? windowRect
        return CGPoint(x: CGFloat(r.left) + CGFloat(Int16(truncatingIfNeeded: lParam)),
                       y: CGFloat(r.top) + CGFloat(Int16(truncatingIfNeeded: lParam >> 16)))
    }

    private var origin: CGPoint { CGPoint(x: CGFloat(frame.left), y: CGFloat(frame.top)) }

    /// The Mac's 4 pt click distance at this DPI.
    private var thresholdSquared: CGFloat {
        let s = CGFloat(dpi) / 96
        return FloatingPetRules.clickThresholdSquared * s * s
    }

    private func buttonDown(_ lParam: LPARAM) {
        guard !isDestroyed, !inMenu, let pet else { return }
        pet.extras.petting.reset()   // Task 23: a press is no stroke (`mouseDown`)
        _ = SetCapture(hwnd)
        pointer.down(at: screenPoint(lParam), windowOrigin: origin)
        // An open popover closes for this press, as the Mac's transient popover on any press outside it (a prayer or a drag
        // leaves it closed; the click that closed it does not open it again: `FloatingPetActions.clickMayOpen`). It closes
        // when the press ends, not now: closing the active popover hands the foreground to another window, and Windows then
        // ends the pet's capture with the button still down, losing the click or the drag (run 44129424988: no prayer).
        closeWhenReleased = pet.press.press(popoverOpen: pet.popoverIsOpen())
    }

    /// The press found the popover open: it closes when the press ends (`buttonUp`, `captureLost`), before the click acts.
    private var closeWhenReleased = false

    private func closePopoverForThePress() {
        guard closeWhenReleased, let pet else { return }
        closeWhenReleased = false
        pet.stats.popoverClosesOnPress += 1
        pet.closePopover()
    }

    private func mouseMoved(_ lParam: LPARAM) {
        guard !isDestroyed else { return }
        let p = screenPoint(lParam)
        if pointer.isPressed {
            pet?.extras.petting.reset()   // a drag never counts as a stroke (`mouseDragged`)
            if let to = pointer.drag(to: p, thresholdSquared: thresholdSquared) {
                // A drag during the run, away or on the way back is the new home (`panelDidMove`/`resolveMove`): the move stops.
                if let extras = pet?.extras, extras.move != nil || extras.flow.runPhase != .home { extras.cancelMove() }
                move(toTopLeft: to)
            }
            return
        }
        guard let pet else { return }
        // Task 23: the hover callout (`mouseEntered`) and the strokes (`mouseMoved`, screen x in DIP: the panel widens and
        // re-centres when a bubble appears, which would shift client x mid-gesture).
        if !hovering {
            var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0000_0002 /* TME_LEAVE */,
                                      hwndTrack: hwnd, dwHoverTime: 0)
            _ = TrackMouseEvent(&tme)
            hovering = true
            pet.extras.setHovering(true)
            pet.showHover()
            pet.onHoverChange?(true)
        }
        let scale = CGFloat(dpi) / 96
        if pet.extras.petting.feed(x: p.x / scale, at: Double(UInt32(bitPattern: GetMessageTime())) / 1000,
                                   minStroke: FloatingPetStroke.distance(petSize: model.petSize)) {
            pet.stroked()
        }
        pet.onPointerMove?(p)
    }

    private func buttonUp(_ lParam: LPARAM) {
        guard !isDestroyed, pointer.isPressed else { return }
        let release = pointer.up(at: screenPoint(lParam), windowOrigin: origin, thresholdSquared: thresholdSquared)
        _ = ReleaseCapture()
        closePopoverForThePress()
        applyDeferredDPI()
        if release.moved { persist() }
        guard release.click, let pet else { return }
        pet.stats.clicks += 1
        pet.acknowledgeAgents()   // Task 23: a click answers waiting agents and acknowledges done ones first (`petClicked`)
        pet.actions.petClicked()
    }

    private func captureLost() {
        guard pointer.isPressed else { return }
        let moved = pointer.cancel(windowOrigin: origin).moved
        closePopoverForThePress()
        applyDeferredDPI()
        if moved { persist() }
    }

    private func contextMenu(at lParam: LPARAM) {
        guard !isDestroyed, !inMenu, !pointer.isPressed, let pet else { return }
        var at = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        if at.x == -1 && at.y == -1 { at = POINT(x: (frame.left + frame.right) / 2, y: (frame.top + frame.bottom) / 2) }
        if hovering {
            hovering = false
            pet.extras.setHovering(false)
            pet.extras.hideCallout()
            pet.onHoverChange?(false)
        }
        let entries = FloatingPetMenu.entries(l: pet.companion.l, backViewOn: pet.store.alwaysFacesBack)
        let items: [TrayMenuModel.Item?] = entries.map { TrayMenuModel.Item(title: $0.title, enabled: true, checked: $0.checked, action: .none) }
        pet.stats.menus += 1
        let owner = pet.menuOwner() ?? hwnd
        inMenu = true
        // The menu takes the foreground to its owner; the pet never took it (WS_EX_NOACTIVATE), so it goes back to the window
        // that had it (review I3: after Escape, Back view or Turn off the user's window has the keyboard again). Not after
        // Open (the popover takes it), and never to the popover (the Mac's transient popover closes on a click outside it).
        let popover = pet.popoverWindow()
        let chosen = WinPopupMenu.run(items, at: at, owner: owner, below: true) { chosen, previous in
            let action = chosen.flatMap { entries.indices.contains($0) ? entries[$0].action : nil }
            return action != .open && previous != popover
        }
        inMenu = false
        if WinPopupMenu.gaveBack { pet.stats.foregroundRestores += 1 }
        if destroyAfterMenu { finishDestroy() }
        let action = chosen.flatMap { entries.indices.contains($0) ? entries[$0].action : nil }
        if action == .open { pet.acknowledgeAgents() }   // Task 23: the menu's Open answers agents too (`openPopover`)
        if let action { pet.actions.perform(action) }
    }

    /// The window is now on a monitor of another DPI (dragged over, or a scale change): `FloatingPetDPIChange` decides.
    private func dpiChanged(_ newDPI: UINT, suggested: RECT?) {
        guard !isDestroyed, let pet else { return }
        let f = CGRect(x: CGFloat(frame.left), y: CGFloat(frame.top), width: CGFloat(frame.right - frame.left), height: CGFloat(frame.bottom - frame.top))
        var s = suggested.map { CGRect(x: CGFloat($0.left), y: CGFloat($0.top), width: CGFloat($0.right - $0.left), height: CGFloat($0.bottom - $0.top)) }
        // Task 23: while a bubble shows the window is the panel: its suggested rectangle holds the pet box at its bottom, centred.
        if let r = s, windowRect.left != frame.left || windowRect.top != frame.top {
            let side = CGFloat(pictureSide(at: newDPI))
            s = CGRect(x: r.minX + max(0, (r.width - side) / 2).rounded(.down), y: r.maxY - side, width: side, height: side)
        }
        switch FloatingPetDPIChange.decide(current: Int(dpi), new: Int(newDPI), pressed: pointer.isPressed, inOwnUpdate: inOwnUpdate,
                                           frame: f, side: CGFloat(pictureSide(at: newDPI)), suggested: s) {
        case .ignore:
            if inOwnUpdate, newDPI != dpi { pet.stats.dpiIgnored += 1 }
        case .later:
            pendingDPI = newDPI
            pet.stats.dpiDeferred += 1
        case .now(let next):
            dpi = newDPI
            pendingDPI = nil
            frame = Self.rect(next)
            pet.stats.dpiChanges += 1
            render()
        }
    }

    /// The DPI a drag deferred, at its release: drawn at it where the drag left the pet (its bottom-left kept).
    private func applyDeferredDPI() {
        defer { pendingDPI = nil }
        guard let at = FloatingPetDPIChange.atRelease(current: Int(dpi), pending: pendingDPI.map { Int($0) }) else { return }
        dpi = UINT(at)
        pet?.stats.dpiChanges += 1
        render()
    }

    /// The window's side at `dpi` (pixels).
    private func pictureSide(at dpi: UINT) -> Int { max(1, Int((model.petSize * CGFloat(dpi) / 96).rounded())) }

    private func sessionChanged(_ code: Int) {
        pet?.stats.sessionEvents += 1
        switch code {
        case 7: locked = true        // WTS_SESSION_LOCK
        case 8: locked = false       // WTS_SESSION_UNLOCK
        case 2, 4: disconnected = true   // WTS_CONSOLE_DISCONNECT, WTS_REMOTE_DISCONNECT
        case 1, 3: disconnected = false  // WTS_CONSOLE_CONNECT, WTS_REMOTE_CONNECT
        default: return
        }
        refreshActivity()
    }

    // MARK: - drawing

    /// Draws the current picture into the window (`UpdateLayeredWindow`, premultiplied alpha), its bottom-left kept: the
    /// sprite in its box and, around it (Task 23), the speech bubble or the hearts above it, the 🙏 rising over it, the
    /// wobble and the bob's squash; the window is the Mac's panel while a bubble or the hearts show.
    func render() {
        guard !isDestroyed, let pet else { return }
        // A new subject still loading keeps the picture on screen (the Mac's `SpriteView` keeps its pixels until the load
        // lands), instead of a 🥚 between two sprites. A new size or DPI draws at once (the 🥚 only while nothing ever loaded).
        // A new window draws nothing until its first load lands or `revealDelay` passes (review M9: the 🥚's DirectWrite
        // rasterising for a picture nobody sees).
        if let sprite = playback.models.first, sprite.current == nil, sprite.isLoading, !revealed || drawnSide == pictureSide(at: dpi) {
            return
        }
        let scale = CGFloat(dpi) / 96
        let side = pictureSide(at: dpi)
        frame = RECT(left: frame.left, top: frame.bottom - Int32(side), right: frame.left + Int32(side), bottom: frame.bottom)
        let win = windowRect
        let width = Int(win.right - win.left), height = Int(win.bottom - win.top)
        guard ensureSurface(width, height), let bits = surface.bits else {
            pet.stats.renderFailures += 1
            return
        }
        memset(bits, 0, width * height * 4)
        compose(into: bits, width: width, height: height, boxX: Int(frame.left - win.left), boxY: Int(frame.top - win.top), side: side, scale: scale)
        _ = GdiFlush()
        var size = SIZE(cx: Int32(width), cy: Int32(height))
        var source = POINT(x: 0, y: 0)
        var destination = POINT(x: win.left, y: win.top)
        var blend = BLENDFUNCTION(BlendOp: 0 /* AC_SRC_OVER */, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 /* AC_SRC_ALPHA */)
        // A new frame of the same window: only the picture (no place or size: no window-position work for every frame).
        let same = drawnFrame.map { $0.left == win.left && $0.top == win.top && $0.right == win.right && $0.bottom == win.bottom } ?? false
        // A place or a size of the window's own choosing: a WM_DPICHANGED sent from inside is not a new DPI (review I2).
        inOwnUpdate = true
        let done = same
            ? UpdateLayeredWindow(hwnd, nil, nil, nil, surface.dc, &source, 0, &blend, 0x0000_0002 /* ULW_ALPHA */)
            : UpdateLayeredWindow(hwnd, nil, &destination, &size, surface.dc, &source, 0, &blend, 0x0000_0002 /* ULW_ALPHA */)
        inOwnUpdate = false
        if done {
            pet.stats.renders += 1
            drawnSide = side
            drawnFrame = win
        } else {
            pet.stats.renderFailures += 1
            if !loggedFailure {
                loggedFailure = true
                AppLog.write("floating pet: UpdateLayeredWindow \(width)x\(height) failed: \(GetLastError())")
            }
        }
    }

    /// The window's picture (`FloatingPetView.body`, the bottom-aligned `VStack(spacing: 8)`): the box at the bottom centre
    /// with the sprite (turned by the prayer's wobble), the 🙏 over it and the hearts on its visible top, all three squashed
    /// toward the box's feet on the bob's frame (`AgentBob` wraps them); the speech bubble 8 DIP above the box, over the rest
    /// (`zIndex(1)`). A bubble or hearts that just appeared pop in (`FloatingPetPopIn`).
    private func compose(into bits: UnsafeMutableRawPointer, width: Int, height: Int, boxX: Int, boxY: Int, side: Int, scale: CGFloat) {
        guard let pet else { return }
        let extras = pet.extras
        let now = extras.now()
        let bubble = extras.bubble(limitAlert: pet.limitAlert)
        let hearts = extras.heartsShowing && bubble == nil
        extras.drew(bubble: bubble, hearts: hearts, at: now, animated: model.animated) { [weak self] in self?.render() }
        drawPicture(into: bits, width: width, height: height, boxX: boxX, boxY: boxY, scale: scale, wobble: extras.wobbleAngle(at: now))
        let particles = extras.particleStates(at: now)
        if !particles.isEmpty, let glyph = prayerGlyph(scale: scale) {
            let emoji = FloatingPetPrayerArt.emojiSize(petSize: model.petSize)
            for particle in particles {
                let at = FloatingPetPrayerArt.particle(xFraction: particle.xFraction, petSize: model.petSize, emojiSize: emoji, progress: particle.progress)
                WinPetDecor.compose(bgra: glyph.bgra, w: glyph.w, h: glyph.h, into: bits, width: width, height: height,
                                    x: boxX + Int((at.center.x * scale).rounded()) - glyph.w / 2,
                                    y: boxY + Int((at.center.y * scale).rounded()) - glyph.h / 2, opacity: at.opacity)
            }
        }
        if hearts {
            let art = heartsPicture(scale: scale)
            let pop = WinPetExtras.pop(extras.heartsPop, at: now)
            let bgra = pop.scale == 1 ? art.bgra
                : WinPetDecor.scaledAbout(art.bgra, w: art.w, h: art.h, sx: pop.scale, sy: pop.scale, ax: CGFloat(art.w) / 2, ay: CGFloat(art.h))
            let offset = FloatingPetHeartArt.bubbleTopOffset(visibleTop: spriteVisibleTop(), bubbleHeight: FloatingPetHeartArt.height,
                                                             overlap: FloatingPetHeartArt.tailOverlap)
            WinPetDecor.compose(bgra: bgra, w: art.w, h: art.h, into: bits, width: width, height: height,
                                x: boxX + (side - art.w) / 2, y: boxY + Int((offset * scale).rounded()), opacity: pop.opacity)
        }
        if extras.squashed {   // x 1.03, y 0.94 about the box's bottom centre
            let n = width * height * 4
            let layer = Array(UnsafeRawBufferPointer(start: bits, count: n))
            let squashed = WinPetDecor.scaledAbout(layer, w: width, h: height, sx: FloatingPetAgentMotion.bobScaleX, sy: FloatingPetAgentMotion.bobScaleY,
                                                   ax: CGFloat(boxX) + CGFloat(side) / 2, ay: CGFloat(boxY + side))
            squashed.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: n) }
        }
        if let bubble, let picture = bubblePicture(bubble, scale: scale) {
            let image = picture.image
            let pop = WinPetExtras.pop(extras.bubblePop, at: now)
            var bgra = PopoverSpriteScale.scaledBGRA(image.pixels, width: image.width, height: image.height)
            if pop.scale != 1 {   // about the bubble view's bottom centre (its 6 DIP pad below the box included)
                bgra = WinPetDecor.scaledAbout(bgra, w: image.width, h: image.height, sx: pop.scale, sy: pop.scale,
                                               ax: CGFloat(image.width) / 2, ay: CGFloat(image.height))
            }
            let y = boxY - Int((FloatingPetBubbleChrome.spacingToSprite * scale).rounded()) - image.height
            WinPetDecor.compose(bgra: bgra, w: image.width, h: image.height, into: bits, width: width, height: height,
                                x: (width - image.width) / 2, y: y, opacity: pop.opacity)
        }
    }

    /// The bubble's picture for its text, the DPI and the appearance (made again only when one changes).
    private func bubblePicture(_ bubble: FloatingPetBubbles.Bubble, scale: CGFloat) -> (image: PlazaImage, size: CGSize)? {
        guard let pet else { return nil }
        let content = FloatingPetBubbles.bubbleContent(bubble, l: L(pet.companion.language), measure: WinPetDecor.measure(PlatformPlaza.graphics.text))
        let look = WinPetLook.system()
        let key = "\(content)|\(dpi)|\(look)"
        if let kept = bubbleImage, kept.key == key { return (kept.image, kept.size) }
        guard let made = WinPetDecor.bubble(content, look: look, scale: scale) else { return nil }
        bubbleImage = (key, made.image, made.size)
        return made
    }

    /// The 🙏 glyph at this pet size and DPI, in BGRA.
    private func prayerGlyph(scale: CGFloat) -> (bgra: [UInt8], w: Int, h: Int)? {
        let emoji = FloatingPetPrayerArt.emojiSize(petSize: model.petSize)
        let key = "\(emoji)@\(scale)"
        if let kept = prayerImage, kept.key == key { return (kept.bgra, kept.w, kept.h) }
        guard let image = WinPetDecor.prayerGlyph(emojiSize: emoji, scale: scale) else { return nil }
        let bgra = PopoverSpriteScale.scaledBGRA(image.pixels, width: image.width, height: image.height)
        prayerImage = (key, bgra, image.width, image.height)
        return (bgra, image.width, image.height)
    }

    /// The hearts' pixels at this DPI.
    private func heartsPicture(scale: CGFloat) -> (bgra: [UInt8], w: Int, h: Int) {
        if let kept = heartsImage, kept.scale == scale { return (kept.bgra, kept.w, kept.h) }
        let made = WinPetDecor.hearts(scale: scale)
        heartsImage = (scale, made.bgra, made.w, made.h)
        return made
    }

    /// The sprite's visible top in DIP from the box's top (`CompanionSpriteView.visibleTop`): the median frame's opaque top
    /// over the GIF's frames, else the still's; 0 while nothing loaded (the Mac's `visibleTop ?? 0` under its 🥚). Kept per
    /// picture set and size.
    private func spriteVisibleTop() -> CGFloat {
        guard let sprite = playback.models.first else { return 0 }
        let images = sprite.frames.isEmpty ? (sprite.subject.image.map { [$0] } ?? []) : sprite.frames.map { $0.image }
        guard let first = images.first else { return 0 }
        let key = "\(ObjectIdentifier(first).hashValue)|\(images.count)|\(model.petSize)"
        if let kept = visibleTopCache, kept.key == key { return kept.top }
        let fraction = FloatingPetVisibleTop.anchorFraction(of: images.map { FloatingPetVisibleTop.opaqueTopFraction(of: $0.pixels) })
        let top = FloatingPetVisibleTop.inset(box: model.petSize, imageSize: CGSize(width: first.width, height: first.height), opaqueTopFraction: fraction)
        visibleTopCache = (key, top)
        return top
    }

    /// The picture the Mac's `SpriteView` shows in the pet's box: the GIF's frame, else the still (cropped to its content
    /// while an animated pet waits for its GIF: `SpriteLoader.animationPlaceholder`), else the egg sprite, else 🥚 at 62 % of
    /// the box. Fitted inside the box with its aspect, centred, scaled smoothly as the Mac shows sprites (`PopoverSpriteScale`),
    /// turned by the prayer's wobble (degrees clockwise about the box's centre: `.rotationEffect`), written into the window's
    /// picture at the box (`boxX`, `boxY`); what leaves the window is cut.
    private func drawPicture(into bits: UnsafeMutableRawPointer, width: Int, height: Int, boxX: Int, boxY: Int, scale: CGFloat, wobble: Double = 0) {
        guard let sprite = playback.models.first else { return }
        let box = model.petSize
        let picture: PlazaImage?
        if let image = sprite.current {
            picture = model.animated && !sprite.isAnimating && model.subject.speciesID != nil ? placeholder(image) : image
        } else {
            picture = eggGlyphImage(box: box, scale: scale)
        }
        guard let picture else { return }
        let fit = PopoverSpriteFit.size(for: CGSize(width: picture.width, height: picture.height), width: box, height: box)
        var w = max(1, Int((fit.width * scale).rounded())), h = max(1, Int((fit.height * scale).rounded()))
        var x = boxX + Int(((box - fit.width) / 2 * scale).rounded()), y = boxY + Int(((box - fit.height) / 2 * scale).rounded())
        var bytes = scaledBytes(picture, w, h, task: sprite.taskID)
        if abs(wobble) > 0.001 {
            let turned = PopoverSpriteScale.rotateBilinear(bytes, width: w, height: h, degrees: wobble)
            x += (w - turned.1) / 2
            y += (h - turned.2) / 2
            (bytes, w, h) = turned
        }
        let x0 = max(0, x), x1 = min(width, x + w)
        guard x1 > x0 else { return }
        bytes.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            for row in 0..<h {
                let dy = y + row
                guard dy >= 0, dy < height else { continue }
                (bits + (dy * width + x0) * 4).copyMemory(from: base + (row * w + (x0 - x)) * 4, byteCount: (x1 - x0) * 4)
            }
        }
    }

    private func scaledBytes(_ picture: PlazaImage, _ w: Int, _ h: Int, task: String?) -> [UInt8] {
        let got = scaled.frame(ObjectIdentifier(picture), key: "\(task ?? "egg")|\(w)x\(h)") {
            PopoverSpriteScale.scaledBGRA(picture.pixels, width: w, height: h)
        }
        if got.made { pet?.stats.scales += 1 }
        if !got.kept { pet?.stats.scaledUncached += 1 }
        return got.bytes
    }

    /// The Mac's `animationPlaceholder`: a still cropped square to its content, kept per picture while the window lives.
    private func placeholder(_ image: PlazaImage) -> PlazaImage {
        let id = ObjectIdentifier(image)
        if let kept = placeholders[id], kept.source === image { return kept.cropped }
        if placeholders.count > 8 { placeholders = [:] }
        let cropped = PlazaEggCrop.square(image)
        placeholders[id] = (image, cropped)
        return cropped
    }

    /// The 🥚 the Mac shows where no picture loaded (`Text("🥚")` at 62 % of the box): Segoe UI Emoji in colour through the
    /// plaza's DirectWrite path, as the popover's sprite slots draw it.
    private func eggGlyphImage(box: CGFloat, scale: CGFloat) -> PlazaImage? {
        let key = "\(box)@\(scale)"
        if let kept = eggGlyph, kept.key == key { return kept.image }
        let graphics = PlatformPlaza.graphics
        let font = PlazaFont.emoji(size: box * 0.62)
        let line = graphics.text.line("🥚", font: font)
        let m = graphics.text.metrics(font)
        let space = PlazaPanelSpace(content: CGSize(width: box, height: box), room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            let h = m.ascender - m.descender
            canvas.draw(line, at: space.canvas(CGPoint(x: (box - line.width) / 2, y: (box - h) / 2 + m.ascender)))
        }) else { return nil }
        eggGlyph = (key, image)
        return image
    }

    private func ensureSurface(_ width: Int, _ height: Int) -> Bool {
        if surface.dc != nil, surface.width == width, surface.height == height { return true }
        releaseSurface()
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(width)
        info.bmiHeader.biHeight = -Int32(height)   // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0         // BI_RGB
        guard let dc = CreateCompatibleDC(nil) else { return false }
        var p: UnsafeMutableRawPointer?
        guard let b = CreateDIBSection(dc, &info, 0 /* DIB_RGB_COLORS */, &p, nil, 0), p != nil else {
            AppLog.write("floating pet: CreateDIBSection \(width)x\(height) failed: \(GetLastError())")
            _ = DeleteDC(dc)
            return false
        }
        surface = Surface(dc: dc, bitmap: b, old: SelectObject(dc, UnsafeMutableRawPointer(b)), bits: p, width: width, height: height)
        return true
    }

    private func releaseSurface() {
        if let dc = surface.dc {
            _ = SelectObject(dc, surface.old)
            _ = DeleteDC(dc)
        }
        if let b = surface.bitmap { _ = DeleteObject(UnsafeMutableRawPointer(b)) }
        surface = Surface()
    }

    /// The pet's box as the window shows it now, premultiplied BGRA top-down (the selftest's captures and checks).
    func snapshot() -> (side: Int, bgra: [UInt8])? {
        guard let panel = panelSnapshot(), let win = drawnFrame else { return nil }
        let side = Int(frame.right - frame.left), x0 = Int(frame.left - win.left), y0 = Int(frame.top - win.top)
        guard side > 0, x0 >= 0, y0 >= 0, x0 + side <= panel.width, y0 + side <= panel.height else { return nil }
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            let from = ((y0 + row) * panel.width + x0) * 4
            out.replaceSubrange(row * side * 4..<(row + 1) * side * 4, with: panel.bgra[from..<from + side * 4])
        }
        return (side, out)
    }

    /// The window's name, what a screen reader reads for it: the hearts' label while they show (the Mac's
    /// `HeartBubbleView.accessibilityLabel`), else the app's.
    func setAccessibleName(_ name: String?) {
        _ = SetWindowTextW(hwnd, WinStr.w(name ?? "PokeTokenBar"))
    }

    /// The native tooltip's text now (the selftest's).
    var toolTipForTesting: String? { tooltipText }

    /// The whole window as it shows now (the panel with its bubble or hearts; Task 23's checks and captures).
    func panelSnapshot() -> (width: Int, height: Int, bgra: [UInt8])? {
        guard let bits = surface.bits, surface.width > 0, surface.height > 0 else { return nil }
        return (surface.width, surface.height, Array(UnsafeRawBufferPointer(start: bits, count: surface.width * surface.height * 4)))
    }

    // MARK: - closing

    /// Frees everything it made: the window, the clock and loads, the bitmap, the session and power registrations. Inside its
    /// own menu the window is hidden at once and goes when the menu returns (the menu loop is on its message's stack).
    func destroy() {
        guard !isDestroyed, !destroyAfterMenu else { return }
        if inMenu {
            destroyAfterMenu = true
            playback.isActive = false
            _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
            return
        }
        finishDestroy()
    }

    private func finishDestroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        revealTimer?.invalidate()
        revealTimer = nil
        if pointer.isPressed {
            if pointer.cancel(windowOrigin: origin).moved { persist() }
            _ = ReleaseCapture()
        }
        release()
        window.destroy()
    }

    private func release() {
        playback.release()
        if sessionNotify { _ = ptb_window_session_notify(UnsafeMutableRawPointer(hwnd), 0) }
        sessionNotify = false
        if let r = powerRegistration { _ = UnregisterPowerSettingNotification(r) }
        powerRegistration = nil
        releaseSurface()
        scaled = FloatingPetScaledFrames(budget: Self.scaledBudget)
        placeholders = [:]
        eggGlyph = nil
        tooltips?.destroy()   // Task 23
        tooltips = nil
        tooltipText = nil
        bubbleImage = nil
        prayerImage = nil
        heartsImage = nil
        visibleTopCache = nil
    }

    /// Windows destroyed the window (the session ending): free the rest, tell the pet.
    private func destroyedFromOutside() {
        guard !isDestroyed else { return }
        isDestroyed = true
        revealTimer?.invalidate()
        revealTimer = nil
        release()
        pet?.windowGone(self)
    }
}
#endif
