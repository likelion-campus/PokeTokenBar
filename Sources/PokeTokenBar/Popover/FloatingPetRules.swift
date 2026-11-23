import Foundation

// The floating pet's rules as shared code (stage 7 Task 22): the Mac keeps them in `UI/FloatingPetPanel.swift`
// (`FloatingPetController`, `PetClickRouter`, `PetHostingView`), an upstream AppKit file Windows cannot compile. Each member
// below is a twin of the Mac member of the same name: `twins.txt` holds the bodies together (a renamed copy, or a pin of a
// body rebuilt as values) and `PopoverPetTwinEquivalenceTests+Mac` drives the Mac's and the twin over the same inputs. The
// Mac app does not call any of it.

/// Twins of `FloatingPetController`'s pure statics, in the Mac's units (points; an origin is a bottom-left corner, y up).
enum FloatingPetRules {
    /// Squared movement (pt²) below which a mouse-up counts as a click, not a drag.
    static let clickThresholdSquared: CGFloat = 16  // ~4pt
    /// Vertical space above the sprite for a speech bubble (pt; the bubbles are Task 23's).
    static let bubbleHeadroom: CGFloat = 72
    /// Minimum panel width while a bubble is showing.
    static let bubbleMinWidth: CGFloat = 180

    /// Where the pet stands relative to its saved home during an agent "done" run (Task 23 runs; Task 22 is always home).
    enum RunPhase: Equatable {
        case home
        case away
        case returning
    }

    /// A window move persists the origin only at home. A user drag during a run cancels the return and becomes the new home.
    static func resolveMove(phase: RunPhase, userDragging: Bool) -> (phase: RunPhase, persist: Bool) {
        if userDragging { return (.home, true) }
        return (phase, phase == .home)
    }

    /// Motion (bob, run) needs an animated host and no Reduce Motion.
    static func allowsMotion(animated: Bool, reduceMotion: Bool) -> Bool { animated && !reduceMotion }

    /// What a click on the pet does: an egg is prayed over, a hatched Pokémon opens the popover.
    enum ClickAction: Equatable { case pray, openPopover }

    static func clickAction(subjectIsEgg: Bool) -> ClickAction { subjectIsEgg ? .pray : .openPopover }

    /// Praying refreshes usage every 30 prayers (30, 60, 90...).
    static let prayersPerRefresh = L.prayersPerQuip
    /// Minimum gap between prayer-triggered refreshes (the limit endpoints have their own rate limits).
    static let prayerRefreshInterval: TimeInterval = 30

    /// How many refresh milestones `count` prayers have passed.
    static func prayerRefreshMilestone(for count: Int) -> Int { max(0, count) / prayersPerRefresh }

    /// Refresh once a milestone is passed that was not refreshed yet AND the floor since the last refresh has passed.
    static func shouldRefreshOnPrayer(count: Int, lastRefreshedMilestone: Int, lastRefreshAt: Date?, now: Date) -> Bool {
        guard prayerRefreshMilestone(for: count) > lastRefreshedMilestone else { return false }
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= prayerRefreshInterval
    }

    static func isClick(from start: CGPoint, to end: CGPoint,
                        thresholdSquared: CGFloat = clickThresholdSquared) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        return dx * dx + dy * dy < thresholdSquared
    }

    /// Low Power Mode on the Mac, battery saver on Windows: the pet shows its still sprite.
    static func shouldAnimate(lowPower: Bool) -> Bool { !lowPower }

    /// Panel size for a given pet size and bubble visibility.
    static func panelSize(petSize: CGFloat, showingBubble: Bool) -> CGSize {
        if showingBubble {
            return CGSize(width: max(petSize, bubbleMinWidth),
                          height: petSize + bubbleHeadroom)
        }
        return CGSize(width: petSize, height: petSize)
    }

    static func panelOrigin(petOrigin: CGPoint, petSize: CGFloat, panelSize: CGSize) -> CGPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return CGPoint(x: petOrigin.x - xInset, y: petOrigin.y)
    }

    static func petOrigin(panelOrigin: CGPoint, petSize: CGFloat, panelSize: CGSize) -> CGPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return CGPoint(x: panelOrigin.x + xInset, y: panelOrigin.y)
    }
}

/// Twin of `PetClickRouter`: routes a plain click on the pet. Praying always counts and spawns its emoji at once (the
/// emoji are Task 23's: `spawnEmoji` is its seam); only the usage refresh it triggers is throttled.
@MainActor
final class PopoverPetClickRouter {
    private let pray: () -> Void
    private let prayerCount: () -> Int
    /// False once today's prayers are used up: the click then only refreshes the hover text, which says so.
    private let canPray: () -> Bool
    private let didPray: () -> Void
    private let spawnEmoji: () -> Void
    private let refreshUsage: () -> Void
    private let openPopover: () -> Void
    private let clock: () -> Date
    private var lastPrayerRefreshAt: Date?
    /// In memory only: after a restart the first click past a milestone may refresh once more, which is harmless.
    private var lastRefreshedMilestone = 0

    init(pray: @escaping () -> Void, prayerCount: @escaping () -> Int, canPray: @escaping () -> Bool = { true }, didPray: @escaping () -> Void = {}, spawnEmoji: @escaping () -> Void, refreshUsage: @escaping () -> Void,
         openPopover: @escaping () -> Void, clock: @escaping () -> Date) {
        self.pray = pray
        self.prayerCount = prayerCount
        self.canPray = canPray
        self.didPray = didPray
        self.spawnEmoji = spawnEmoji
        self.refreshUsage = refreshUsage
        self.openPopover = openPopover
        self.clock = clock
    }

    func handle(subjectIsEgg: Bool) {
        switch FloatingPetRules.clickAction(subjectIsEgg: subjectIsEgg) {
        case .pray:
            guard canPray() else { didPray(); return }
            pray()
            spawnEmoji()
            didPray()
            let count = prayerCount()
            let milestone = FloatingPetRules.prayerRefreshMilestone(for: count)
            if milestone < lastRefreshedMilestone { lastRefreshedMilestone = milestone }   // a new egg started over
            let now = clock()
            if FloatingPetRules.shouldRefreshOnPrayer(count: count, lastRefreshedMilestone: lastRefreshedMilestone,
                                                           lastRefreshAt: lastPrayerRefreshAt, now: now) {
                lastRefreshedMilestone = milestone
                lastPrayerRefreshAt = now
                refreshUsage()
            }
        case .openPopover:
            openPopover()
        }
    }
}

/// The pet's saved home: the Mac's two keys (`FloatingPetController.originXKey` / `originYKey`), the pet's origin in the
/// system's own screen coordinates. The Mac stores points with y up (the pet's bottom-left corner); Windows stores its
/// virtual-screen pixels of the same corner (x = left, y = bottom, y down). The two never meet: each system has its own
/// settings file, and a saved place that meets no screen goes back to the default corner (`FloatingPetPlacement`).
enum FloatingPetOrigin {
    static let originXKey = "floatingPetOriginX"
    static let originYKey = "floatingPetOriginY"

    /// The saved origin, nil until the pet was placed once. `double(forKey:)` reads a number whatever its stored form.
    static func saved(in defaults: UserDefaults) -> CGPoint? {
        guard defaults.object(forKey: originXKey) != nil, defaults.object(forKey: originYKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: originXKey), y: defaults.double(forKey: originYKey))
    }

    static func save(_ origin: CGPoint, in defaults: UserDefaults) {
        defaults.set(Double(origin.x), forKey: originXKey)
        defaults.set(Double(origin.y), forKey: originYKey)
    }
}

/// Where the pet window stands: `FloatingPetController.targetFrame` and `defaultPetOrigin` as values (pinned twins), in the
/// Mac's terms: points or pixels, y up, an origin is a bottom-left corner. Windows mirrors its screen pixels into this space
/// (y → −y) and back, so the Mac's rule reads the same on both: the saved home if the frame meets any screen's work area
/// ("visible frame": without the menu bar and Dock, the taskbar), else the default corner (bottom-right of the main
/// screen, 24 pt in). The Mac never clamps a pet that still meets a screen, and neither does Windows.
struct FloatingPetTarget: Equatable {
    var frame: CGRect
    /// The default corner was used (nothing saved, or the saved frame meets no screen).
    var isDefault: Bool
}

enum FloatingPetPlacement {
    /// `defaultPetOrigin`'s inset from the main screen's bottom-right corner (pt).
    static let defaultMargin: CGFloat = 24
    /// `defaultPetOrigin` with no main screen.
    static let noScreenOrigin = CGPoint(x: 120, y: 120)

    /// Twin of `FloatingPetController.defaultPetOrigin(petSize:)`; `mainVisible` is `NSScreen.main?.visibleFrame` (the
    /// Windows side passes the primary monitor's work area, mirrored).
    static func defaultPetOrigin(petSize: CGFloat, mainVisible: CGRect?, margin: CGFloat = defaultMargin) -> CGPoint {
        guard let visible = mainVisible else { return noScreenOrigin }
        return CGPoint(x: visible.maxX - petSize - margin, y: visible.minY + margin)
    }

    /// Twin of `FloatingPetController.targetFrame(petSize:showingBubble:)`. `away` is the agent run's origin (Task 23),
    /// `saved` the home (`FloatingPetOrigin.saved`), `visibleFrames` every screen's work area. `defaultPetSize` and `margin`
    /// are the default corner's at the main screen's scale (Windows: another monitor may have another DPI; the Mac's are
    /// `petSize` and 24).
    static func targetFrame(away: CGPoint? = nil, saved: CGPoint?, petSize: CGFloat, showingBubble: Bool, visibleFrames: [CGRect],
                            mainVisible: CGRect?, defaultPetSize: CGFloat? = nil, margin: CGFloat = defaultMargin) -> FloatingPetTarget {
        let fallbackSize = defaultPetSize ?? petSize
        func defaultFrame() -> FloatingPetTarget {
            let size = FloatingPetRules.panelSize(petSize: fallbackSize, showingBubble: showingBubble)
            let pet = defaultPetOrigin(petSize: fallbackSize, mainVisible: mainVisible, margin: margin)
            return FloatingPetTarget(frame: CGRect(origin: FloatingPetRules.panelOrigin(petOrigin: pet, petSize: fallbackSize, panelSize: size),
                                                   size: size), isDefault: true)
        }
        // The run's spot while away, else the saved home, else the default corner.
        guard let petOrigin = away ?? saved else { return defaultFrame() }
        let size = FloatingPetRules.panelSize(petSize: petSize, showingBubble: showingBubble)
        let frame = CGRect(origin: FloatingPetRules.panelOrigin(petOrigin: petOrigin, petSize: petSize, panelSize: size), size: size)
        guard visibleFrames.contains(where: { $0.intersects(frame) }) else { return defaultFrame() }
        return FloatingPetTarget(frame: frame, isDefault: false)
    }

    /// What `FloatingPetController.panelDidMove` saves for a panel at `panelOrigin`: the pet's origin (the panel is wider and
    /// centred while a bubble shows). Only at home (`FloatingPetRules.resolveMove`).
    static func savedPetOrigin(panelOrigin: CGPoint, petSize: CGFloat, showingBubble: Bool) -> CGPoint {
        let size = FloatingPetRules.panelSize(petSize: petSize, showingBubble: showingBubble)
        return FloatingPetRules.petOrigin(panelOrigin: panelOrigin, petSize: petSize, panelSize: size)
    }

    /// The index of the rectangle nearest to `point` (0 distance inside), nil for none: the monitor whose DPI sizes a pet
    /// saved at `point` (Windows' `MONITOR_DEFAULTTONEAREST` over the same rectangles).
    static func nearest(_ point: CGPoint, in rects: [CGRect]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, r) in rects.enumerated() {
            let dx = point.x < r.minX ? r.minX - point.x : (point.x >= r.maxX ? point.x - r.maxX + 1 : 0)
            let dy = point.y < r.minY ? r.minY - point.y : (point.y >= r.maxY ? point.y - r.maxY + 1 : 0)
            let d = dx * dx + dy * dy
            if let kept = best, kept.distance <= d { continue }
            best = (i, d)
        }
        return best?.index
    }
}

/// A screen in a top-left-origin pixel space (Windows' virtual screen: y down): its rectangle, its work area (without the
/// taskbar) and its scale (DPI / 96).
struct FloatingPetScreen: Equatable {
    var bounds: CGRect
    var work: CGRect
    var scale: CGFloat
    var isPrimary: Bool
}

/// Where the pet window goes in that space, and the scale its size was taken at.
struct FloatingPetScreenFrame: Equatable {
    /// The window's rectangle (pixels, y down).
    var frame: CGRect
    var scale: CGFloat
    var isDefault: Bool
    /// What `FloatingPetOrigin` keeps for it: the pet's bottom-left corner (x = left, y = bottom). Task 23's bubbles widen and
    /// heighten the window; the pet's corner is then `FloatingPetPlacement.savedPetOrigin` of the mirrored frame.
    var savedOrigin: CGPoint { CGPoint(x: frame.minX, y: frame.maxY) }
}

extension FloatingPetPlacement {
    /// The Mac's rule (`targetFrame`) on a y-down screen space, each screen at its own scale: the pet is sized at the scale
    /// of the screen nearest to its saved corner (`scale` when the window already has one: the system's DPI for it), the
    /// default corner at the primary screen's. Mirrored into the Mac's y-up space and back, so `targetFrame` decides.
    static func screenFrame(petSize: CGFloat, saved: CGPoint?, screens: [FloatingPetScreen], scale: CGFloat? = nil) -> FloatingPetScreenFrame? {
        guard let primary = screens.first(where: \.isPrimary) ?? screens.first else { return nil }
        func up(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height) }
        // The pixel just inside the saved bottom-left corner picks the monitor.
        let savedScale = scale ?? saved.flatMap { p in nearest(CGPoint(x: p.x + 0.5, y: p.y - 0.5), in: screens.map(\.bounds)).map { screens[$0].scale } }
            ?? primary.scale
        let target = targetFrame(saved: saved.map { CGPoint(x: $0.x, y: -$0.y) }, petSize: (petSize * savedScale).rounded(), showingBubble: false,
                                 visibleFrames: screens.map { up($0.work) }, mainVisible: up(primary.work),
                                 defaultPetSize: (petSize * primary.scale).rounded(), margin: (defaultMargin * primary.scale).rounded())
        let f = target.frame
        return FloatingPetScreenFrame(frame: CGRect(x: f.minX, y: -f.maxY, width: f.width, height: f.height),
                                      scale: target.isDefault ? primary.scale : savedScale, isDefault: target.isDefault)
    }
}

/// The pointer on the pet: `PetHostingView`'s `mouseDown` / `mouseDragged` / `mouseUp` as a value (pinned twins). Points are
/// screen points in any one coordinate system (the moves are translations, the click is a distance), so Windows feeds its
/// pixels as they are with the threshold at its DPI. The window follows the pointer from the first move, also within the
/// click distance, as on the Mac; once past it the press is a drag and the release clicks nothing.
struct FloatingPetPointer: Equatable {
    private(set) var mouseDownScreen: CGPoint?
    private(set) var originAtDown: CGPoint?
    private(set) var didDrag = false

    /// True once the pointer moved past the click threshold with the button held.
    var isDragging: Bool { didDrag }
    var isPressed: Bool { mouseDownScreen != nil }

    /// What a release did.
    struct Release: Equatable {
        /// A click (released within the click distance, never past it).
        var click: Bool
        /// The window moved during the press: its place is saved (the Mac's `windowDidMove` at home).
        var moved: Bool
    }

    mutating func down(at screen: CGPoint, windowOrigin: CGPoint) {
        mouseDownScreen = screen
        originAtDown = windowOrigin
        didDrag = false
    }

    /// The window's new origin for the pointer at `screen`, nil without a press.
    mutating func drag(to screen: CGPoint, thresholdSquared: CGFloat = FloatingPetRules.clickThresholdSquared) -> CGPoint? {
        guard let start = mouseDownScreen, let origin = originAtDown else { return nil }
        if !FloatingPetRules.isClick(from: start, to: screen, thresholdSquared: thresholdSquared) { didDrag = true }
        return CGPoint(x: origin.x + (screen.x - start.x), y: origin.y + (screen.y - start.y))
    }

    mutating func up(at screen: CGPoint, windowOrigin: CGPoint, thresholdSquared: CGFloat = FloatingPetRules.clickThresholdSquared) -> Release {
        defer {
            mouseDownScreen = nil
            originAtDown = nil
            didDrag = false
        }
        let moved = originAtDown.map { $0 != windowOrigin } ?? false
        guard !didDrag, let start = mouseDownScreen else { return Release(click: false, moved: moved) }
        return Release(click: FloatingPetRules.isClick(from: start, to: screen, thresholdSquared: thresholdSquared), moved: moved)
    }

    /// The press ended without a release (capture lost, the window went).
    mutating func cancel(windowOrigin: CGPoint) -> Release {
        let moved = originAtDown.map { $0 != windowOrigin } ?? false
        self = FloatingPetPointer()
        return Release(click: false, moved: moved)
    }
}

/// What stops the pet (user ruling 2026-11-18: the floating pet follows the Mac). The Mac's `FloatingPetView` hands its
/// `SpriteView` `animated: shouldAnimate(lowPower:)` with no Reduce Motion in it, and Reduce Motion gates only the bob and
/// the run (`allowsMotion`). So Windows' "Show animations" off (the Reduce Motion counterpart) leaves the GIF playing; only
/// battery saver (Low Power Mode) shows the still sprite. The popover's sprites keep Windows' approved rule (still with
/// animations off, `WinSpriteAnimator`); this is the pet's alone.
enum FloatingPetMotion {
    struct Gates: Equatable {
        /// The GIF plays (else the still sprite).
        var gif: Bool
        /// The bob and the run may move the pet (Task 23's).
        var motion: Bool
    }

    static func gates(lowPower: Bool, reduceMotion: Bool) -> Gates {
        let animated = FloatingPetRules.shouldAnimate(lowPower: lowPower)
        return Gates(gif: animated, motion: FloatingPetRules.allowsMotion(animated: animated, reduceMotion: reduceMotion))
    }
}

/// A press on the pet while the popover is open (user ruling 2026-11-18: as the Mac). The Mac's popover is `.transient`:
/// any press outside it, the pet's included, closes it, so a prayer or a drag leaves it closed; and `AppDelegate.openPopover`
/// opens nothing while the popover is still shown (dismissing), so the click on a hatched pet that closed it does not open
/// it again. On Windows the pet never takes the activation, so nothing closes the popover by itself: the press does, when it
/// ends (closing the active popover with the button still down moves the foreground away and Windows ends the pet's capture,
/// which loses the click or the drag).
struct FloatingPetPopoverPress: Equatable {
    /// The last press closed the open popover.
    private(set) var closedIt = false

    /// The button goes down on the pet (a click or the start of a drag): true = close the popover now.
    mutating func press(popoverOpen: Bool) -> Bool {
        closedIt = popoverOpen
        return popoverOpen
    }

    /// The release's click asks for the popover (`Opener.click`): whether it opens (`openPopover`'s guard).
    func clickOpens(popoverOpen: Bool) -> Bool { !closedIt && !popoverOpen }
}

/// Windows' `WM_DPICHANGED` on the pet's window (Task 22 review; the Mac's panel has no DPI of its own: a point is a point on
/// every screen). Growing in place at a mixed-DPI boundary could carry most of the window onto the other monitor and back,
/// a size flip without end, and mid-drag the window would jump off the grab point; so a drag keeps the size until the
/// release (the move's own `SetWindowPos` is where that message comes from), a change otherwise goes where Windows suggests
/// (its rectangle keeps the window on the monitor of the new DPI), and Windows' answer to the window's own
/// `UpdateLayeredWindow` (a placement or a new size, which chose the DPI) is not a new DPI.
enum FloatingPetDPIChange: Equatable {
    /// Nothing to do: the same DPI, or a message from inside the window's own picture update.
    case ignore
    /// A drag is on: the size stays, the DPI applies at the release (`atRelease`).
    case later
    /// Drawn at the new DPI now, at `frame`.
    case now(frame: CGRect)

    /// What the window does with `new` (y-down pixels; `frame` is the window now, `side` its side at `new`).
    static func decide(current: Int, new: Int, pressed: Bool, inOwnUpdate: Bool, frame: CGRect, side: CGFloat, suggested: CGRect?) -> FloatingPetDPIChange {
        guard new > 0, new != current else { return .ignore }
        if pressed { return .later }
        if inOwnUpdate { return .ignore }
        // Windows' rectangle when it sent one (its top-left; the side is the pet's at the new DPI, which the rectangle has to
        // within a rounding), else in place with the bottom-left kept (the pet's home corner).
        let origin = suggested.map { CGPoint(x: $0.minX, y: $0.minY) } ?? CGPoint(x: frame.minX, y: frame.maxY - side)
        return .now(frame: CGRect(origin: origin, size: CGSize(width: side, height: side)))
    }

    /// The DPI a drag deferred, applied at its release: nil when there is none or it is the window's already.
    static func atRelease(current: Int, pending: Int?) -> Int? {
        guard let pending, pending > 0, pending != current else { return nil }
        return pending
    }
}

/// The pet window's scaled frames (Windows draws its own pixels; the Mac's `SpriteView` lets Core Animation scale): one
/// subject at one size, at most `budget` bytes. Once full the frames kept stay and the rest are made each time they show
/// (Task 22 review M8: dropping everything and refilling made every frame of a loop larger than the budget again, forever).
struct FloatingPetScaledFrames<ID: Hashable> {
    let budget: Int
    private(set) var key: String?
    private(set) var frames: [ID: [UInt8]] = [:]
    private(set) var bytes = 0

    init(budget: Int) { self.budget = budget }

    /// The frame `id` of `key` (subject and size): kept, else made and kept while it fits. `made`: it was made now.
    mutating func frame(_ id: ID, key: String, make: () -> [UInt8]) -> (bytes: [UInt8], made: Bool, kept: Bool) {
        if self.key != key { self = FloatingPetScaledFrames(budget: budget); self.key = key }
        if let kept = frames[id] { return (kept, false, true) }
        let made = make()
        guard bytes + made.count <= budget else { return (made, true, false) }
        frames[id] = made
        bytes += made.count
        return (made, true, true)
    }
}

/// The pet's right-click menu: `PetHostingView.showContextMenu` as values (pinned twin): Open, Hide, Back view (checked).
enum FloatingPetMenu {
    enum Action: Equatable { case open, hide, toggleBackView }

    struct Entry: Equatable {
        let title: String
        let action: Action
        let checked: Bool
    }

    static func entries(l: L, backViewOn: Bool) -> [Entry] {
        [Entry(title: l.floatingPetMenuOpen, action: .open, checked: false),
         Entry(title: l.floatingPetMenuHide, action: .hide, checked: false),
         Entry(title: l.backViewLabel, action: .toggleBackView, checked: backViewOn)]
    }
}

/// What the pet shows now: `FloatingPetController.sync` / `show` and the `SpriteView` arguments of `FloatingPetView.body` as
/// one value (pinned twins). The view rebuilds when it changes and does nothing when it does not.
// --- fix/windows-pet-still: the session's lock state when the pet is made (begin) ---
/// Windows only: whether the session is locked when the pet's window is made (later the lock and unlock messages move it). Locked
/// only when Windows says so twice: `WTSSessionInfoEx`'s SessionFlags is LOCK (0) AND the input desktop is not the user's own
/// (the lock screen's secure desktop refuses a user's process). A LOCK while the user's desktop takes input, an unknown flag
/// (0xFFFFFFFF) or a value it could not read is unlocked: a PC that reported LOCK while unlocked would otherwise keep the pet
/// still for good (user report, kit 10). Behind a real lock screen both say locked, so the pet never animates there.
enum FloatingPetSession {
    static let lockFlag: UInt32 = 0, unknownFlag: UInt32 = 0xFFFF_FFFF

    /// `inputDesktop`: 1 the user's "Default" desktop, 0 another one or refused (the secure desktop), -1 opened but unnamed.
    static func locked(sessionFlags: UInt32, inputDesktop: Int32) -> Bool {
        sessionFlags == lockFlag && inputDesktop == 0
    }
}
// --- fix/windows-pet-still (end) ---

struct FloatingPetModel: Equatable {
    /// The pet is on screen: the setting is on and the displays are awake (`sync`).
    var visible: Bool
    /// The sprite box's side (pt, DIP on Windows): `store.floatingPetSize`.
    var petSize: CGFloat
    /// The representative subject, turned around when `companion.facesBack`; `speciesID` nil is the egg.
    var subject: PlazaSpriteSubjectKey
    /// `shouldAnimate(lowPower:)`: false shows the still sprite.
    var animated: Bool
    /// `store.animationQuality.frameFloor`: the GIF's frames are decimated to this frame length (`PopoverSpriteFrameCap`).
    var frameFloor: TimeInterval

    var subjectIsEgg: Bool { subject.speciesID == nil }

    @MainActor static func make(store: UsageStore, companion: CompanionStore, displayAwake: Bool, lowPower: Bool) -> FloatingPetModel {
        let subject = companion.representativeSubject
        return FloatingPetModel(
            visible: store.floatingPetEnabled && displayAwake,
            petSize: CGFloat(store.floatingPetSize),
            subject: PlazaSpriteSubjectKey(speciesID: subject.speciesID, shiny: subject.isShiny, form: subject.form, back: companion.facesBack),
            animated: FloatingPetRules.shouldAnimate(lowPower: lowPower),
            frameFloor: store.animationQuality.frameFloor)
    }
}

/// What the pet's clicks and its menu do (`FloatingPetController.petClicked`, `openPopover`, `PetHostingView.handleOpen` /
/// `handleHide` / `handleToggleBackView`, the app's `onHide`): shared, so both systems test it. `openPopover` is the host's
/// (the Mac's `AppDelegate.openPopover`: nothing when it is open). On Windows the press on the pet closes an open popover
/// (`FloatingPetPopoverPress`, the Mac's transient close) and `clickMayOpen` keeps that click from opening it again. Task 23
/// adds the agent bubble's dismissal in front.
@MainActor final class FloatingPetActions {
    /// Who asks for the popover: a click on a hatched pet, or the menu's Open (which always opens).
    enum Opener: Equatable { case click, menu }

    private let store: UsageStore
    private let companion: CompanionStore
    private let openPopover: @MainActor (Opener) -> Void
    /// Task 23's seams: the 🙏 burst and the hover text after a prayer.
    var spawnEmoji: () -> Void = {}
    var didPray: () -> Void = {}
    private(set) var clicks = 0, prayers = 0, opens = 0
    /// Whether a click may open the popover now (`FloatingPetPopoverPress.clickOpens`: not when the same press closed it). The
    /// host's; the menu's Open is not asked.
    var clickMayOpen: () -> Bool = { true }

    private lazy var router = PopoverPetClickRouter(
        pray: { [weak self] in self?.companion.pray() },
        prayerCount: { [weak self] in self?.companion.state.eggPrayers?.count ?? 0 },
        canPray: { [weak self] in self?.companion.canPray ?? false },
        didPray: { [weak self] in
            self?.prayers += 1
            self?.didPray()
        },
        spawnEmoji: { [weak self] in self?.spawnEmoji() },
        refreshUsage: { [weak self] in
            guard let store = self?.store else { return }
            Task { await store.refresh() }
        },
        openPopover: { [weak self] in self?.open(.click) },
        clock: clock)

    private let clock: () -> Date

    init(store: UsageStore, companion: CompanionStore, clock: @escaping () -> Date = Date.init,
         openPopover: @escaping @MainActor (Opener) -> Void) {
        self.store = store
        self.companion = companion
        self.clock = clock
        self.openPopover = openPopover
    }

    /// A plain click: prays over an egg, opens the popover for a hatched pet.
    func petClicked() {
        clicks += 1
        router.handle(subjectIsEgg: companion.representativeSubject.speciesID == nil)
    }

    /// A menu entry: Open always opens (also for an egg), Hide turns the pet off, Back view flips the setting.
    func perform(_ action: FloatingPetMenu.Action) {
        switch action {
        case .open: open(.menu)
        case .hide: store.floatingPetEnabled = false
        case .toggleBackView: store.alwaysFacesBack.toggle()
        }
    }

    private func open(_ opener: Opener) {
        if opener == .click, !clickMayOpen() { return }
        opens += 1
        openPopover(opener)
    }
}
