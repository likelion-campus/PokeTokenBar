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
    /// Task 23's seams: the pointer came over the pet or left it (the hover callout), and where it moved without a button held
    /// (strokes, in screen pixels). Nil: no tracking at all.
    var onHoverChange: ((Bool) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?

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
        let next = FloatingPetModel.make(store: store, companion: companion, displayAwake: !displayAsleep(), lowPower: lowPower())
        let previous = model
        model = next
        guard next.visible else {
            hideWindow()
            return
        }
        if let window {
            if next != previous { window.apply(next) }
            return
        }
        guard let made = WinPetWindow(pet: self, model: next) else { return }
        window = made
        stats.shows += 1
    }

    private func hideWindow() {
        guard let window else { return }
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isDestroyed, g == self.generation else { return }
                    self.sync()
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
        var side = 0
    }

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
            self?.noteClock()   // fix/windows-pet-still: a GIF that came (or not) changes what the log says
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
        noteClock()   // fix/windows-pet-still
    }

    // --- fix/windows-pet-still: why the pet moves or stands, in the user's log (begin) ---
    /// What decides whether the pet moves, compared before anything is written (a frame changes none of it).
    struct ClockState: Equatable {
        var subject: PlazaSpriteSubjectKey
        var frames: Int, loading: Bool, energySaver: Bool, gifOn: Bool
        var active: Bool, visible: Bool, displayAsleep: Bool, locked: Bool, disconnected: Bool
        var floor: TimeInterval

        var moving: Bool { gifOn && active && frames > 1 }

        /// The one reason a hatched pet stands still, first match (nil while it moves or for the egg, which has no GIF).
        var stillReason: String? {
            guard let species = subject.speciesID, !moving else { return nil }
            if energySaver { return "Energy saver is on (Windows' battery or energy saver, as the Mac's Low Power Mode)" }
            if !gifOn { return "animation is off for the pet" }
            if !active {
                let why = [!visible ? "not shown" : nil, displayAsleep ? "displays asleep" : nil, locked ? "session locked" : nil,
                           disconnected ? "session disconnected" : nil].compactMap { $0 }
                return "the clock is stopped (\(why.isEmpty ? "hidden" : why.joined(separator: ", ")))"
            }
            if !PokemonAssets.hasAnimatedSprite(speciesID: species) { return "#\(species) has no animated sprite (Gen V GIFs end at #649)" }
            if loading { return "its GIF is loading" }
            if frames == 1 { return "its GIF has one frame at the \(floor) s floor" }
            return "no GIF for #\(species) yet (the download failed; asked again every 2-30 s)"
        }
    }
    private(set) var loggedClock: ClockState?

    /// One line in the app's log when what keeps the pet moving or still changes: the state and its inputs (never per frame).
    func noteClock() {
        guard !isDestroyed, revealed, let pet, let sprite = playback.models.first else { return }
        let state = ClockState(subject: model.subject, frames: sprite.frames.count, loading: sprite.isLoading, energySaver: !model.animated,
                               gifOn: playback.animationsEnabled, active: playback.isActive, visible: IsWindowVisible(hwnd),
                               displayAsleep: pet.displayAsleep(), locked: locked, disconnected: disconnected, floor: model.frameFloor)
        guard state != loggedClock else { return }
        loggedClock = state
        var status = SYSTEM_POWER_STATUS()
        let power = GetSystemPowerStatus(&status)
            ? withUnsafeBytes(of: status) { "ACLineStatus=\($0[0]) SystemStatusFlag=\($0[3])" } : "power status unread"
        let what = state.moving ? "moving (\(state.frames) frames at the \(state.floor) s floor)"
            : state.subject.speciesID == nil ? "an egg (no GIF)" : "still: \(state.stillReason ?? "")"
        AppLog.write("floating pet: \(what); #\(state.subject.speciesID.map(String.init) ?? "egg") frames=\(state.frames) loading=\(state.loading) "
                     + "GIF asks=\(sprite.gifAsks) energy saver=\(state.energySaver) (\(power)) Show animations=\(pet.animationsEnabled()) "
                     + "clock=\(state.active) visible=\(state.visible) displays asleep=\(state.displayAsleep) locked=\(state.locked) "
                     + "disconnected=\(state.disconnected)")
    }
    // --- fix/windows-pet-still (end) ---

    // MARK: - placement

    /// Places the window again from the saved home, the monitors now and its DPI (a display change, a new size): the Mac's
    /// `targetFrame` (the home if it meets a work area, else the default corner), drawn there. Nothing is saved: only a drag
    /// moves the home (review M11; the Mac saves the fallback corner, see the inventory's F1).
    func place(scale: CGFloat? = nil) {
        guard !isDestroyed, let pet,
              let placed = FloatingPetPlacement.screenFrame(petSize: model.petSize, saved: FloatingPetOrigin.saved(in: pet.defaults),
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
        // A drag over a monitor of another DPI gets its WM_DPICHANGED from inside this call: deferred to the release.
        _ = SetWindowPos(hwnd, nil, x, y, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        drawnFrame = frame   // the window is there now: the next picture needs no place
        pet?.stats.moves += 1
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

    /// The pointer in screen pixels: the message's client point plus where the window is now.
    private func screenPoint(_ lParam: LPARAM) -> CGPoint {
        CGPoint(x: CGFloat(frame.left) + CGFloat(Int16(truncatingIfNeeded: lParam)),
                y: CGFloat(frame.top) + CGFloat(Int16(truncatingIfNeeded: lParam >> 16)))
    }

    private var origin: CGPoint { CGPoint(x: CGFloat(frame.left), y: CGFloat(frame.top)) }

    /// The Mac's 4 pt click distance at this DPI.
    private var thresholdSquared: CGFloat {
        let s = CGFloat(dpi) / 96
        return FloatingPetRules.clickThresholdSquared * s * s
    }

    private func buttonDown(_ lParam: LPARAM) {
        guard !isDestroyed, !inMenu, let pet else { return }
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
            if let to = pointer.drag(to: p, thresholdSquared: thresholdSquared) { move(toTopLeft: to) }
            return
        }
        guard let pet, pet.onHoverChange != nil || pet.onPointerMove != nil else { return }
        if !hovering, pet.onHoverChange != nil {
            var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0000_0002 /* TME_LEAVE */,
                                      hwndTrack: hwnd, dwHoverTime: 0)
            _ = TrackMouseEvent(&tme)
            hovering = true
            pet.onHoverChange?(true)
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
        if let action { pet.actions.perform(action) }
    }

    /// The window is now on a monitor of another DPI (dragged over, or a scale change): `FloatingPetDPIChange` decides.
    private func dpiChanged(_ newDPI: UINT, suggested: RECT?) {
        guard !isDestroyed, let pet else { return }
        let f = CGRect(x: CGFloat(frame.left), y: CGFloat(frame.top), width: CGFloat(frame.right - frame.left), height: CGFloat(frame.bottom - frame.top))
        let s = suggested.map { CGRect(x: CGFloat($0.left), y: CGFloat($0.top), width: CGFloat($0.right - $0.left), height: CGFloat($0.bottom - $0.top)) }
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

    /// Draws the current picture into the window (`UpdateLayeredWindow`, premultiplied alpha), its bottom-left kept.
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
        guard ensureSurface(side), let bits = surface.bits else {
            pet.stats.renderFailures += 1
            return
        }
        memset(bits, 0, side * side * 4)
        drawPicture(into: bits, side: side, scale: scale)
        _ = GdiFlush()
        var size = SIZE(cx: Int32(side), cy: Int32(side))
        var source = POINT(x: 0, y: 0)
        var destination = POINT(x: frame.left, y: frame.top)
        var blend = BLENDFUNCTION(BlendOp: 0 /* AC_SRC_OVER */, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 /* AC_SRC_ALPHA */)
        // A new frame of the same window: only the picture (no place or size: no window-position work for every frame).
        let same = drawnFrame.map { $0.left == frame.left && $0.top == frame.top && $0.right == frame.right && $0.bottom == frame.bottom } ?? false
        // A place or a size of the window's own choosing: a WM_DPICHANGED sent from inside is not a new DPI (review I2).
        inOwnUpdate = true
        let done = same
            ? UpdateLayeredWindow(hwnd, nil, nil, nil, surface.dc, &source, 0, &blend, 0x0000_0002 /* ULW_ALPHA */)
            : UpdateLayeredWindow(hwnd, nil, &destination, &size, surface.dc, &source, 0, &blend, 0x0000_0002 /* ULW_ALPHA */)
        inOwnUpdate = false
        if done {
            pet.stats.renders += 1
            drawnSide = side
            drawnFrame = frame
        } else {
            pet.stats.renderFailures += 1
            if !loggedFailure {
                loggedFailure = true
                AppLog.write("floating pet: UpdateLayeredWindow \(side)x\(side) failed: \(GetLastError())")
            }
        }
    }

    /// The picture the Mac's `SpriteView` shows in the pet's box: the GIF's frame, else the still (cropped to its content
    /// while an animated pet waits for its GIF: `SpriteLoader.animationPlaceholder`), else the egg sprite, else 🥚 at 62 % of
    /// the box. Fitted inside the box with its aspect, centred, scaled smoothly as the Mac shows sprites (`PopoverSpriteScale`).
    private func drawPicture(into bits: UnsafeMutableRawPointer, side: Int, scale: CGFloat) {
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
        let w = max(1, Int((fit.width * scale).rounded())), h = max(1, Int((fit.height * scale).rounded()))
        let x = Int(((box - fit.width) / 2 * scale).rounded()), y = Int(((box - fit.height) / 2 * scale).rounded())
        let bytes = scaledBytes(picture, w, h, task: sprite.taskID)
        let x0 = max(0, x), x1 = min(side, x + w)
        guard x1 > x0 else { return }
        bytes.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            for row in 0..<h {
                let dy = y + row
                guard dy >= 0, dy < side else { continue }
                (bits + (dy * side + x0) * 4).copyMemory(from: base + (row * w + (x0 - x)) * 4, byteCount: (x1 - x0) * 4)
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

    private func ensureSurface(_ side: Int) -> Bool {
        if surface.dc != nil, surface.side == side { return true }
        releaseSurface()
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(side)
        info.bmiHeader.biHeight = -Int32(side)   // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0         // BI_RGB
        guard let dc = CreateCompatibleDC(nil) else { return false }
        var p: UnsafeMutableRawPointer?
        guard let b = CreateDIBSection(dc, &info, 0 /* DIB_RGB_COLORS */, &p, nil, 0), p != nil else {
            AppLog.write("floating pet: CreateDIBSection \(side)x\(side) failed: \(GetLastError())")
            _ = DeleteDC(dc)
            return false
        }
        surface = Surface(dc: dc, bitmap: b, old: SelectObject(dc, UnsafeMutableRawPointer(b)), bits: p, side: side)
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

    /// What the window shows now, premultiplied BGRA top-down (the selftest's captures and checks).
    func snapshot() -> (side: Int, bgra: [UInt8])? {
        guard let bits = surface.bits, surface.side > 0 else { return nil }
        let n = surface.side * surface.side * 4
        return (surface.side, Array(UnsafeRawBufferPointer(start: bits, count: n)))
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
