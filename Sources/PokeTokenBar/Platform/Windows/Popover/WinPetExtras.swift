#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Stage 7 Task 23: what the floating pet shows and does besides its sprite (the Mac's `FloatingPetController` and
/// `FloatingPetView` beyond Task 22): the speech bubble (a limit alert, an agent waiting or done), the hearts after strokes,
/// the prayers' 🙏 and the egg's wobble, the hover callout and its event pop, and the agent's bob and run to the cursor.
/// The rules are shared (`Popover/FloatingPetExtras.swift`); this class holds the state and the one-shot timers, and the
/// pet's window (`WinPetWindow`) draws what it says.
///
/// Idle: every transient ends on its own one-shot timer (hearts 1.8 s, prayers 1.1 s, wobble 0.3 s, run 0.6 s, event pop
/// 6 s, an agent's done 6 s, working 10 min); the frame timer runs only while a particle, the wobble or a move is on screen;
/// the bob's timer only while an agent works and motion is allowed. Nothing is armed while nothing shows.
@MainActor final class WinPetExtras {
    /// What a timer of this class calls back (on the main thread, from the timer's block).
    typealias Callback = @MainActor @Sendable () -> Void

    struct Stats: Equatable {
        var agentEvents = 0, dropped = 0, runs = 0, returns = 0, bobTicks = 0, frameTicks = 0
        var strokes = 0, hearts = 0, prayers = 0, eventPops = 0, calloutShows = 0, calloutHides = 0
    }

    /// The agents (the shared flow: tracker, run phase, effects).
    private(set) var flow = FloatingPetAgentFlow()
    private(set) var heartsShowing = false
    private(set) var particles: [(xFraction: Double, born: Date)] = []
    private(set) var wobbleStart: Date?
    /// The event line while the self-popped callout is up.
    private(set) var eventPopText: String?
    private(set) var squashed = false
    private(set) var stats = Stats()
    var lastSeenEventSeq: Int?
    var petting = FloatingPetPetting()
    private(set) var hovering = false
    /// The bubble the window drew last (`sync` draws again only when it changes), and whether it drew the hearts.
    private(set) var drawnBubble: FloatingPetBubbles.Bubble?
    private(set) var drawnHearts = false
    /// When the bubble and the hearts began to pop in (`FloatingPetPopIn`; nil: whole).
    private(set) var bubblePop: Date?, heartsPop: Date?

    /// A move of the pet (the run to the cursor and the way back), in screen pixels of the pet box's bottom-left.
    struct Move {
        var from: CGPoint, to: CGPoint, start: Date, duration: TimeInterval
        var returning: Bool
    }
    private(set) var move: Move?

    private var heartTimer: Timer?
    private var eventPopTimer: Timer?
    private var agentTimer: Timer?
    private var bobTimer: Timer?
    private var frameTimer: Timer?
    /// The clock (a seam: the selftest steps it).
    var now: () -> Date = Date.init
    /// Stand-ins the selftest sets for a limit alert and a companion event (the stores raise them only from a refresh and a
    /// hatch); the pet syncs after it sets them. Nil in the app.
    var limitAlertForTesting: UsageStore.LimitAlert?
    var latestEventForTesting: CompanionStore.CompanionEvent?

    let callout = WinPetCallout()

    /// The armed timers, by name (the selftest's and the idle checks' view: nothing armed while nothing shows).
    var armedTimers: [String] {
        [("hearts", heartTimer), ("eventPop", eventPopTimer), ("agent", agentTimer), ("bob", bobTimer), ("frame", frameTimer)]
            .filter { $0.1?.isValid == true }.map { $0.0 }
    }

    // MARK: - the speech bubble and the hearts

    /// The bubble the pet shows now (a limit alert outranks agents).
    func bubble(limitAlert: UsageStore.LimitAlert?) -> FloatingPetBubbles.Bubble? {
        FloatingPetBubbles.bubble(limitAlert: limitAlert, agent: flow.summary)
    }

    /// The panel's headroom is up (the Mac's `showingBubble`).
    func showingBubble(alertActive: Bool) -> Bool {
        FloatingPetBubbles.isShowingBubble(alertActive: alertActive, heartsShowing: heartsShowing, agent: flow.summary)
    }

    /// A stroke was felt (`petWasStroked`): hearts for 1.8 s unless speech is up; restarted by every stroke.
    func stroked(alertActive: Bool, started: () -> Void, ended: @escaping Callback) {
        stats.strokes += 1
        heartsShowing = FloatingPetBubbles.heartsShowing(afterStrokeWithAlertActive: alertActive, agent: flow.summary)
        guard heartsShowing else { return }
        stats.hearts += 1
        started()
        heartTimer?.invalidate()
        heartTimer = oneShot(after: Self.seconds(FloatingPetBubbles.heartDuration)) { [weak self] in
            guard let self else { return }
            self.heartTimer = nil
            self.heartsShowing = false
            ended()
        }
    }

    // MARK: - prayers

    /// A prayer (`PrayerBurst.spawn`): one 🙏 rising for 1 s and the egg's wobble; the frame timer runs until both end.
    func spawnPrayer(xFraction: Double = .random(in: 0...1), render: @escaping Callback) {
        stats.prayers += 1
        let t = now()
        particles.append((min(max(xFraction, 0), 1), t))
        wobbleStart = t
        startFrames(render: render)
    }

    /// The live particles at `t`: (xFraction, progress 0…1 of the eased rise).
    func particleStates(at t: Date) -> [(xFraction: Double, progress: Double)] {
        particles.compactMap { p in
            let age = t.timeIntervalSince(p.born)
            guard age < Self.seconds(FloatingPetPrayerArt.lifetime) else { return nil }
            return (p.xFraction, FloatingPetPrayerArt.easeOut(age / FloatingPetPrayerArt.riseDuration))
        }
    }

    /// The wobble's angle (degrees) at `t`.
    func wobbleAngle(at t: Date) -> Double {
        guard let start = wobbleStart else { return 0 }
        return FloatingPetPrayerArt.wobbleAngle(at: t.timeIntervalSince(start))
    }

    // MARK: - the pop-in

    /// What the window draws now: a bubble or the hearts that were not there pop in (while the pet animates).
    func drew(bubble: FloatingPetBubbles.Bubble?, hearts: Bool, at t: Date, animated: Bool, render: @escaping Callback) {
        if bubble != nil, drawnBubble == nil { bubblePop = animated ? t : nil }
        if bubble == nil { bubblePop = nil }
        if hearts, !drawnHearts { heartsPop = animated ? t : nil }
        if !hearts { heartsPop = nil }
        drawnBubble = bubble
        drawnHearts = hearts
        if let start = bubblePop, t.timeIntervalSince(start) >= FloatingPetPopIn.duration { bubblePop = nil }
        if let start = heartsPop, t.timeIntervalSince(start) >= FloatingPetPopIn.duration { heartsPop = nil }
        if bubblePop != nil || heartsPop != nil { startFrames(render: render) }
    }

    /// The pop's scale and opacity at `t` (whole when it is not popping).
    static func pop(_ start: Date?, at t: Date) -> (scale: CGFloat, opacity: Double) {
        guard let start else { return (1, 1) }
        let e = t.timeIntervalSince(start)
        return (FloatingPetPopIn.scale(at: e), FloatingPetPopIn.opacity(at: e))
    }

    // MARK: - the frame timer (particles, wobble, moves, pops)

    /// About 30 frames a second while something moves; it stops itself when nothing does.
    static let frameInterval: TimeInterval = 1.0 / 30

    private func startFrames(render: @escaping Callback) {
        guard frameTimer == nil else { return }
        frameTimer = oneShot(after: Self.frameInterval) { [weak self] in self?.frameTick(render: render) }
    }

    private var moveStep: ((CGPoint) -> Void)?, moveEnded: (() -> Void)?

    private func frameTick(render: @escaping Callback) {
        frameTimer = nil
        stats.frameTicks += 1
        let t = now()
        particles.removeAll { t.timeIntervalSince($0.born) >= Self.seconds(FloatingPetPrayerArt.lifetime) }
        if let start = wobbleStart, t.timeIntervalSince(start) >= FloatingPetPrayerArt.wobbleDuration { wobbleStart = nil }
        if let m = move {
            let f = min(1, t.timeIntervalSince(m.start) / m.duration)
            let e = FloatingPetAgentMotion.easeInEaseOut(f)
            moveStep?(CGPoint(x: m.from.x + (m.to.x - m.from.x) * e, y: m.from.y + (m.to.y - m.from.y) * e))
            if f >= 1 {
                move = nil
                let ended = moveEnded
                moveStep = nil
                moveEnded = nil
                ended?()
            }
        }
        render()   // the window's compose re-arms it while a pop goes on (`drew`)
        if !particles.isEmpty || wobbleStart != nil || move != nil { startFrames(render: render) }
    }

    /// Moves the pet box from `from` to `to` (screen pixels, its bottom-left) over the run's 0.6 s, ease-in-ease-out.
    func animateMove(from: CGPoint, to: CGPoint, returning: Bool, step: @escaping (CGPoint) -> Void, ended: @escaping () -> Void,
                     render: @escaping Callback) {
        move = Move(from: from, to: to, start: now(), duration: FloatingPetAgentMotion.agentRunDuration, returning: returning)
        moveStep = step
        moveEnded = ended
        if returning { stats.returns += 1 } else { stats.runs += 1 }
        startFrames(render: render)
    }

    /// A drag took the pet while it ran or came back: the move stops where it is (the drag is the new home).
    func cancelMove() {
        move = nil
        moveStep = nil
        moveEnded = nil
        flow.dragged()
    }

    // MARK: - agents

    /// A `poketokenbar://agent` event (`handleAgentEvent`); nil when dropped (the pet or the setting off).
    func handle(_ event: AgentActivityEvent, enabled: Bool, motionAllowed: Bool, panelVisible: Bool) -> FloatingPetAgentFlow.Effect? {
        let effect = flow.handle(event, now: now(), enabled: enabled, motionAllowed: motionAllowed, panelVisible: panelVisible)
        if effect == nil { stats.dropped += 1 } else { stats.agentEvents += 1 }
        return effect
    }

    func acknowledge(motionAllowed: Bool, panelVisible: Bool) -> FloatingPetAgentFlow.Effect? {
        flow.acknowledge(motionAllowed: motionAllowed, panelVisible: panelVisible)
    }

    func beganRun() { flow.beganRun() }
    func returned() { flow.returned() }

    /// One timer at the tracker's deadline (`scheduleAgentExpiry`); none while idle or waiting.
    func scheduleExpiry(fired: @escaping Callback) {
        agentTimer?.invalidate()
        agentTimer = nil
        guard let deadline = flow.deadline else { return }
        agentTimer = oneShot(after: max(0, deadline.timeIntervalSince(now()))) { [weak self] in
            self?.agentTimer = nil
            fired()
        }
    }

    /// The timer fired (`expireAgentActivity`): nil when nothing expired yet (re-arm).
    func expire(motionAllowed: Bool, panelVisible: Bool) -> FloatingPetAgentFlow.Effect? {
        flow.expire(now: now(), motionAllowed: motionAllowed, panelVisible: panelVisible)
    }

    /// The bob (`AgentBob`): the squashed frame every 0.5 s while an agent works and motion is allowed; off otherwise.
    func updateBob(active: Bool, render: @escaping Callback) {
        guard active else {
            bobTimer?.invalidate()
            bobTimer = nil
            if squashed {
                squashed = false
                render()
            }
            return
        }
        guard bobTimer == nil else { return }
        // The Mac's `Task.sleep(for: interval, tolerance: interval * 0.1)`.
        bobTimer = oneShot(after: FloatingPetAgentMotion.agentBobInterval, tolerance: FloatingPetAgentMotion.agentBobInterval * 0.1) { [weak self] in
            guard let self else { return }
            self.bobTimer = nil
            self.stats.bobTicks += 1
            WakeTrace.count("petBob")   // the idle gate's attribution: a Foundation timer is no message, so it counts itself
            self.squashed.toggle()
            render()
            self.updateBob(active: true, render: render)
        }
    }

    /// `sync`'s reset: the setting or the pet went off while agents were tracked or the pet was away.
    func syncReset(enabled: Bool) -> Bool {
        guard flow.syncReset(enabled: enabled) else { return false }
        agentTimer?.invalidate()
        agentTimer = nil
        move = nil
        moveStep = nil
        moveEnded = nil
        return true
    }

    // MARK: - the hover callout and the event pop

    func setHovering(_ on: Bool) {
        hovering = on
        if !on { petting.reset() }
    }

    /// A new hatch / evolution / graduation / Ditto line (`popEventIfNew`): the callout by itself for 6 s.
    func popEvent(_ text: String, ended: @escaping Callback) {
        stats.eventPops += 1
        eventPopText = text
        eventPopTimer?.invalidate()
        eventPopTimer = oneShot(after: Self.seconds(FloatingPetBubbles.eventPopDuration)) { [weak self] in
            guard let self else { return }
            self.eventPopTimer = nil
            self.eventPopText = nil
            ended()
        }
    }

    // MARK: - hidden

    /// The window went (`hide`): the transients end, the pet comes back at home, the callout goes; the agents stay tracked.
    func hidden() {
        heartTimer?.invalidate()
        heartTimer = nil
        heartsShowing = false
        eventPopTimer?.invalidate()
        eventPopTimer = nil
        eventPopText = nil
        bobTimer?.invalidate()
        bobTimer = nil
        squashed = false
        frameTimer?.invalidate()
        frameTimer = nil
        particles = []
        wobbleStart = nil
        move = nil
        moveStep = nil
        moveEnded = nil
        hovering = false
        petting.reset()
        drawnBubble = nil
        drawnHearts = false
        bubblePop = nil
        heartsPop = nil
        flow.hidden()
        hideCallout()
        callout.destroy()   // the pet hidden leaves no window of its own behind
    }

    /// Everything, the agents' timer too (the pet destroyed: a selftest harness).
    func destroy() {
        hidden()
        agentTimer?.invalidate()
        agentTimer = nil
        callout.destroy()
    }

    func showCallout(_ text: String, above petWindow: RECT, dpi: UINT) {
        if !callout.isShown { stats.calloutShows += 1 }
        callout.show(text, above: petWindow, dpi: dpi)
    }

    func hideCallout() {
        guard callout.isShown else { return }
        stats.calloutHides += 1
        callout.hide()
    }

    // MARK: - helpers

    static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    private func oneShot(after seconds: TimeInterval, tolerance: TimeInterval = 0, _ body: @escaping Callback) -> Timer {
        let timer = Timer(fire: Date().addingTimeInterval(seconds), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - the pet's part (the Mac's controller around the bubbles, hearts, hover and agents)

extension WinFloatingPet {
    /// The limit alert the bubble shows (`store.currentBubbleAlert`; the selftest's stand-in when it set one).
    var limitAlert: UsageStore.LimitAlert? { extras.limitAlertForTesting ?? store.currentBubbleAlert }
    /// The companion's newest event line (`companion.latestEvent`; the selftest's stand-in when it set one).
    var latestEvent: CompanionStore.CompanionEvent? { extras.latestEventForTesting ?? companion.latestEvent }

    /// Agent reactions are on (`agentEnabled`): the pet and "React to agent activity".
    var agentEnabled: Bool { store.floatingPetEnabled && store.floatingPetAgentActivity }

    /// The bob and the run may move the pet: battery saver off and Windows' "Show animations" on (`FloatingPetMotion`).
    var motionAllowed: Bool { FloatingPetMotion.gates(lowPower: lowPower(), reduceMotion: !animationsEnabled()).motion }

    private var panelVisible: Bool { window.map { IsWindowVisible($0.hwnd) } ?? false }

    /// Entry point for `poketokenbar://agent` events (`handleAgentEvent`). Dropped while the pet or the setting is off.
    func handleAgentEvent(_ event: AgentActivityEvent) {
        guard let effect = extras.handle(event, enabled: agentEnabled, motionAllowed: motionAllowed, panelVisible: panelVisible) else { return }
        agentChanged(effect)
    }

    /// `agentDidChange` after the flow decided: the bob, the one timer at the deadline, then the run, the way home or a redraw.
    private func agentChanged(_ effect: FloatingPetAgentFlow.Effect) {
        refreshBob()
        extras.scheduleExpiry { [weak self] in self?.agentDeadline() }
        switch effect {
        case .run:
            if let window { extras.hideCallout(); window.runToCursor() } else { sync() }
        case .returnHome:
            if let window { window.returnHome() } else { extras.returned(); sync() }
        case .sync:
            sync()
        }
        refreshHover()
    }

    /// The bob for the state now (an agent working, motion allowed, the pet on screen).
    func refreshBob() {
        extras.updateBob(active: extras.flow.bobs(motionAllowed: motionAllowed) && panelVisible) { [weak self] in self?.window?.render() }
    }

    /// The timer at the tracker's deadline (`expireAgentActivity`): a fire before it re-arms.
    private func agentDeadline() {
        if let effect = extras.expire(motionAllowed: motionAllowed, panelVisible: panelVisible) {
            agentChanged(effect)
        } else {
            extras.scheduleExpiry { [weak self] in self?.agentDeadline() }
        }
    }

    /// A click on the pet or the menu's Open: answers waiting agents and acknowledges done ones first (`petClicked`).
    func acknowledgeAgents() {
        guard let effect = extras.acknowledge(motionAllowed: motionAllowed, panelVisible: panelVisible) else { return }
        agentChanged(effect)
    }

    /// A stroke (`petWasStroked`): the hearts unless speech is up, the callout hidden while they show; when they end, the
    /// callout comes back if the pointer is still over the pet.
    func stroked() {
        extras.stroked(alertActive: limitAlert != nil, started: { [weak self] in
            guard let self else { return }
            self.extras.hideCallout()
            self.window?.setAccessibleName(L(self.companion.language).floatingPetHeartsLabel)   // `HeartBubbleView.accessibilityLabel`
            self.window?.render()
            self.refreshHover()
        }, ended: { [weak self] in
            guard let self else { return }
            self.window?.setAccessibleName(nil)
            self.window?.render()
            self.refreshHover()
            if self.extras.hovering { self.showHover() }
        })
    }

    /// The hover text now (`currentHoverText`).
    func currentHoverText() -> String {
        FloatingPetHoverText.hoverTooltip(
            todayTokens: store.todayTotalTokens,
            limitUtilization: store.highestLimitUtilization,
            mode: store.limitDisplayMode,
            l: L(companion.language),
            sulkIdle: companion.sulkIdle,
            eventLine: extras.eventPopText,
            prayers: companion.representativeSubject.speciesID == nil ? companion.state.eggPrayers?.count ?? 0 : 0,
            prayerHatchUsedToday: companion.representativeSubject.speciesID == nil && companion.isPrayerHatchUsedToday)
    }

    /// `showHoverCallout`: the callout centred above the pet with the hover text, unless speech or hearts are up.
    func showHover() {
        guard let window, IsWindowVisible(window.hwnd), window.revealed else { return }
        if extras.showingBubble(alertActive: limitAlert != nil) { extras.hideCallout(); return }
        extras.showCallout(currentHoverText(), above: window.windowRect, dpi: window.dpi)
    }

    /// What `sync` and `show` refresh (the native tooltip's text, cleared while the hearts show; the callout again where
    /// it is up), and `refreshHoverAfterPrayer` after a prayer and `windowDidMove` after a move.
    func refreshHover() {
        guard let window, IsWindowVisible(window.hwnd) else { extras.hideCallout(); return }
        window.setToolTip(FloatingPetBubbles.nativeToolTip(currentHoverText(), heartsShowing: extras.heartsShowing))
        if extras.callout.isShown { showHover() }
    }

    /// A new hatch / evolution / graduation / Ditto line shows by itself for 6 s (`popEventIfNew`), unless the pet is hidden or
    /// speech or hearts are up; one that cannot pop is dropped, not queued. When it ends the callout stays only under the
    /// pointer.
    func popEventIfNew() {
        guard let event = latestEvent, event.seq != extras.lastSeenEventSeq else { return }
        let pop = FloatingPetBubbles.shouldPopEvent(eventSeq: event.seq, lastSeenSeq: extras.lastSeenEventSeq, petVisible: panelVisible,
                                                    bubbleShowing: extras.showingBubble(alertActive: limitAlert != nil))
        extras.lastSeenEventSeq = event.seq
        guard pop else { return }
        extras.popEvent(event.text) { [weak self] in
            guard let self else { return }
            self.refreshHover()
            if self.extras.hovering { self.showHover() } else { self.extras.hideCallout() }
        }
        refreshHover()
        showHover()
    }
}

// MARK: - drawing

/// The system's look when the pet draws its bubble or callout (the popover sets the shared appearance only for itself, and the
/// pet may draw while no popover was ever made): Windows' app mode and high-contrast theme, read from the system.
struct WinPetLook: Equatable {
    var dark: Bool
    var highContrast: PopoverHighContrast?

    @MainActor static func system() -> WinPetLook {
        let hc = WinUIContext.systemHighContrast()
        return WinPetLook(dark: !hc && WinDarkMode.systemPrefersDark(), highContrast: hc ? WinUIContext.systemHighContrastColors() : nil)
    }

    private var appearance: PopoverAppearance { dark ? .dark : .light }

    /// The Mac's `windowBackgroundColor` (white in light; in dark Windows' dark window, the Mac's near-black); a high-contrast
    /// theme's window colour.
    var window: PlazaColor {
        if let hc = highContrast { return hc.color(hc.window, alpha: 1) }
        return dark ? PlazaColor(hex: PopoverSurface.darkWindow) : PlazaColor(srgbRed: 1, green: 1, blue: 1)
    }

    /// Text and lines: black in light, white in dark, at `alpha`; a high-contrast theme's text colour.
    func ink(_ alpha: Double) -> PlazaColor {
        if let hc = highContrast { return hc.color(hc.text, alpha: alpha) }
        let v = dark ? 1.0 : 0.0
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    /// `labelColor`, `secondaryLabelColor` (Windows' readable secondary, as the popover's), `separatorColor`, `.red`.
    var primary: PlazaColor { ink(PopoverLabelOpacity.primary) }
    var secondary: PlazaColor { ink(PopoverLabelOpacity.secondary(appearance, windows: true)) }
    var separator: PlazaColor { ink(PopoverLabelOpacity.separator) }
    var red: PlazaColor { highContrast == nil ? PopoverColorRole.systemRed.plazaColor(appearance) : ink(1) }
}

/// The pictures the pet's window composes around its sprite, in premultiplied BGRA (the window's DIB), at the window's DPI.
/// Plain functions of their inputs (no state), so callable from anywhere on the main thread.
enum WinPetDecor {
    static let titleFont = PlazaFont.system(size: FloatingPetBubbleChrome.titleFontSize, weight: .bold)
    static let bodyFont = PlazaFont.system(size: FloatingPetBubbleChrome.bodyFontSize, weight: .regular)

    /// The Mac's `measureSpeechBubbleLayout` over this system's text (DirectWrite through the plaza's engine): the text at the
    /// content column, the chrome's size, the body's wrapped lines against `bubbleBodyLineLimit`, the single-line widths.
    static func measure(_ text: any PlazaTextEngine) -> FloatingPetBubbles.Measure {
        { title, body in
            let column = FloatingPetBubbles.bubbleContentWidth
            let titleLines = text.wrappedLines(title, font: titleFont, width: column)
            let bodyLines = body.isEmpty ? [] : text.wrappedLines(body, font: bodyFont, width: column)
            let tm = text.metrics(titleFont), bm = text.metrics(bodyFont)
            let titleLine = tm.ascender - tm.descender + tm.leading, bodyLine = bm.ascender - bm.descender + bm.leading
            let textWidth = min(column, max(titleLines.map(\.width).max() ?? 0, bodyLines.map(\.width).max() ?? 0))
            let textHeight = (CGFloat(titleLines.count) * titleLine).rounded(.up) + FloatingPetBubbleChrome.titleBodySpacing
                + (CGFloat(bodyLines.count) * bodyLine).rounded(.up)
            let count = body.isEmpty ? 0 : max(1, bodyLines.count)
            return .init(size: CGSize(width: textWidth + FloatingPetBubbles.bubbleHorizontalPadding * 2, height: textHeight + 12 + 6),
                         bodyLineCount: count,
                         unclampedTitleWidth: text.line(title, font: titleFont).width,
                         unclampedBodyWidth: body.isEmpty ? 0 : text.line(body, font: bodyFont).width,
                         wouldTruncate: count > FloatingPetBubbles.bubbleBodyLineLimit)
        }
    }

    /// The speech bubble (`SpeechBubbleView`): the rounded box in the window colour with its shadow, the bold title (red when
    /// critical) over the body (secondary, two lines), the content column fixed at `bubbleContentWidth`. The Mac's tail is
    /// drawn inside the box's top-left in the box's colour (its `Path` fills the overlay's whole frame), so nothing of it
    /// shows; it is left out here. Returns the picture and its size in DIP (the 6 DIP bottom padding included).
    static func bubble(_ content: FloatingPetBubbles.SpeechBubbleContent, look: WinPetLook, scale: CGFloat) -> (image: PlazaImage, size: CGSize)? {
        let graphics = PlatformPlaza.graphics
        let text = graphics.text
        let column = FloatingPetBubbles.bubbleContentWidth
        let titleLines = text.wrappedLines(content.title, font: titleFont, width: column)
        let bodyLines = Array(text.wrappedLines(content.body, font: bodyFont, width: column).prefix(FloatingPetBubbles.bubbleBodyLineLimit))
        let tm = text.metrics(titleFont), bm = text.metrics(bodyFont)
        let titleLine = tm.ascender - tm.descender + tm.leading, bodyLine = bm.ascender - bm.descender + bm.leading
        let pad = FloatingPetBubbles.bubbleHorizontalPadding, vpad = FloatingPetBubbleChrome.verticalPadding
        let textHeight = CGFloat(titleLines.count) * titleLine + FloatingPetBubbleChrome.titleBodySpacing + CGFloat(bodyLines.count) * bodyLine
        let box = CGSize(width: column + pad * 2, height: (textHeight + vpad * 2).rounded(.up))
        // Room for the shadow around the box (radius 4, 2 down), then the 6 DIP the Mac pads below the bubble.
        let margin: CGFloat = 6
        let size = CGSize(width: box.width + margin * 2, height: box.height + margin + FloatingPetBubbleChrome.bottomPadding)
        let background = look.window
        let title = content.isCritical ? look.red : look.primary
        let body = look.secondary
        let space = PlazaPanelSpace(content: size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            let rect = space.canvas(CGRect(x: margin, y: margin, width: box.width, height: box.height))
            canvas.saveState()
            canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -FloatingPetBubbleChrome.shadowOffsetY * scale),
                                         blur: FloatingPetBubbleChrome.shadowRadius * scale,
                                         color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: FloatingPetBubbleChrome.shadowOpacity)))
            canvas.setFillColor(background)
            canvas.fillRoundedRect(rect, radius: FloatingPetBubbleChrome.cornerRadius)
            canvas.restoreState()
            var y = margin + vpad
            canvas.setFillColor(title)
            for line in titleLines {
                canvas.draw(line, at: space.canvas(CGPoint(x: margin + pad, y: y + tm.ascender)))
                y += titleLine
            }
            y += FloatingPetBubbleChrome.titleBodySpacing
            canvas.setFillColor(body)
            for line in bodyLines {
                canvas.draw(line, at: space.canvas(CGPoint(x: margin + pad, y: y + bm.ascender)))
                y += bodyLine
            }
        }) else { return nil }
        return (image, size)
    }

    /// The 🙏 glyph at `emojiSize` × 0.8 (`PrayerEmojiFrame`), as the pet's 🥚 is drawn.
    static func prayerGlyph(emojiSize: CGFloat, scale: CGFloat) -> PlazaImage? {
        let graphics = PlatformPlaza.graphics
        let font = PlazaFont.emoji(size: emojiSize * 0.8)
        let line = graphics.text.line("🙏", font: font)
        let m = graphics.text.metrics(font)
        let space = PlazaPanelSpace(content: CGSize(width: emojiSize, height: emojiSize), room: 0)
        return space.image(scale: scale, graphics: graphics) { canvas in
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            let h = m.ascender - m.descender
            canvas.draw(line, at: space.canvas(CGPoint(x: (emojiSize - line.width) / 2, y: (emojiSize - h) / 2 + m.ascender)))
        }
    }

    /// The hearts (`HeartBubbleView`): the Mac's pixel grid, one `pixel × scale` square per cell (whole pixels, so the edges
    /// stay crisp), opaque BGRA.
    static func hearts(scale: CGFloat) -> (bgra: [UInt8], w: Int, h: Int) {
        let cell = max(1, Int((FloatingPetHeartArt.pixel * scale).rounded()))
        let rows = FloatingPetHeartArt.rows
        let w = rows[0].count * cell, h = rows.count * cell
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let c = FloatingPetHeartArt.rgb(for: ch) else { continue }
                for dy in 0..<cell {
                    for dx in 0..<cell {
                        let o = ((row * cell + dy) * w + col * cell + dx) * 4
                        out[o] = c.b; out[o + 1] = c.g; out[o + 2] = c.r; out[o + 3] = 255
                    }
                }
            }
        }
        return (out, w, h)
    }

    /// Premultiplied BGRA scaled by (`sx`, `sy`) about the anchor (`ax`, `ay`) pixels, into a picture of the same size
    /// (SwiftUI's `scaleEffect(anchor:)`: what leaves the picture is cut), bilinear.
    static func scaledAbout(_ src: [UInt8], w: Int, h: Int, sx: CGFloat, sy: CGFloat, ax: CGFloat, ay: CGFloat) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard w > 0, h > 0, sx > 0, sy > 0 else { return out }
        src.withUnsafeBufferPointer { s in
            func at(_ x: Int, _ y: Int, _ k: Int) -> Double { x >= 0 && y >= 0 && x < w && y < h ? Double(s[(y * w + x) * 4 + k]) : 0 }
            for y in 0..<h {
                let fy = (CGFloat(y) + 0.5 - ay) / sy + ay - 0.5
                guard fy > -1, fy < CGFloat(h) else { continue }
                let y0 = Int(fy.rounded(.down)), wy = Double(fy) - Double(y0)
                for x in 0..<w {
                    let fx = (CGFloat(x) + 0.5 - ax) / sx + ax - 0.5
                    guard fx > -1, fx < CGFloat(w) else { continue }
                    let x0 = Int(fx.rounded(.down)), wx = Double(fx) - Double(x0)
                    let o = (y * w + x) * 4
                    for k in 0..<4 {
                        let v = at(x0, y0, k) * (1 - wx) * (1 - wy) + at(x0 + 1, y0, k) * wx * (1 - wy)
                            + at(x0, y0 + 1, k) * (1 - wx) * wy + at(x0 + 1, y0 + 1, k) * wx * wy
                        out[o + k] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
            }
        }
        return out
    }

    /// `image` (premultiplied RGBA) composed over the BGRA at (`x`, `y`) pixels with `opacity` (source over).
    static func compose(_ image: PlazaImage, into bits: UnsafeMutableRawPointer, width: Int, height: Int, x: Int, y: Int, opacity: Double = 1) {
        let bgra = PopoverSpriteScale.scaledBGRA(image.pixels, width: image.width, height: image.height)
        compose(bgra: bgra, w: image.width, h: image.height, into: bits, width: width, height: height, x: x, y: y, opacity: opacity)
    }

    static func compose(bgra src: [UInt8], w: Int, h: Int, into bits: UnsafeMutableRawPointer, width: Int, height: Int, x: Int, y: Int, opacity: Double = 1) {
        let p = bits.assumingMemoryBound(to: UInt8.self)
        let k = UInt32(max(0, min(255, (opacity * 255).rounded())))
        src.withUnsafeBufferPointer { s in
            for row in 0..<h {
                let dy = y + row
                guard dy >= 0, dy < height else { continue }
                for col in 0..<w {
                    let dx = x + col
                    guard dx >= 0, dx < width else { continue }
                    let si = (row * w + col) * 4
                    let a = UInt32(s[si + 3]) * k / 255
                    guard a > 0 else { continue }
                    let di = (dy * width + dx) * 4
                    let inv = 255 - a
                    for c in 0..<3 { p[di + c] = UInt8((UInt32(s[si + c]) * k / 255 + UInt32(p[di + c]) * inv / 255) & 0xFF) }
                    p[di + 3] = UInt8((a + UInt32(p[di + 3]) * inv / 255) & 0xFF)
                }
            }
        }
    }

}

// MARK: - the hover callout

/// The hover callout (`showHoverCallout`): a small window centred above the pet, the hover text in 11 pt on the window
/// colour with an 8 pt corner and a 0.5 pt separator border; it ignores the mouse (`ignoresMouseEvents`) and never takes the
/// activation. Made on first use, destroyed with the pet.
@MainActor final class WinPetCallout {
    static let className = "PokeTokenBarPetCallout"
    /// WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST.
    static let exStyle: DWORD = 0x0800_0000 | 0x0008_0000 | 0x0000_0020 | 0x0000_0080 | 0x0000_0008
    private var window: WinSinkWindow?
    private(set) var isShown = false
    private(set) var text = ""
    private(set) var frame = RECT()
    private var anchor = RECT(), shownDPI: UINT = 0
    /// The picture it shows (premultiplied BGRA; the selftest's capture).
    private(set) var picture: (width: Int, height: Int, bgra: [UInt8])?
    var hwnd: HWND? { window?.hwnd }

    func show(_ text: String, above pet: RECT, dpi: UINT) {
        if isShown, text == self.text, dpi == shownDPI, pet.left == anchor.left, pet.top == anchor.top, pet.right == anchor.right { return }
        anchor = pet
        shownDPI = dpi
        let scale = CGFloat(dpi) / 96
        let graphics = PlatformPlaza.graphics
        let font = PlazaFont.system(size: FloatingPetHoverText.fontSize, weight: .regular)
        let m = graphics.text.metrics(font)
        let lineHeight = m.ascender - m.descender + m.leading
        let lines = text.components(separatedBy: "\n").map { graphics.text.line($0, font: font) }
        let pad = FloatingPetHoverText.padding
        let size = CGSize(width: (lines.map(\.width).max() ?? 0).rounded(.up) + pad * 2, height: (CGFloat(lines.count) * lineHeight).rounded(.up) + pad * 2)
        // `hoverCalloutColors`: labelColor on windowBackgroundColor, a separatorColor border (inside the edge, as a layer's).
        let look = WinPetLook.system()
        let space = PlazaPanelSpace(content: size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            let rect = space.canvas(CGRect(origin: .zero, size: size))
            canvas.setFillColor(look.window)
            canvas.fillRoundedRect(rect, radius: FloatingPetHoverText.cornerRadius)
            let inset = FloatingPetHoverText.borderWidth / 2
            canvas.setStrokeColor(look.separator)
            canvas.strokeRoundedRect(rect.insetBy(dx: inset, dy: inset), radius: FloatingPetHoverText.cornerRadius - inset, lineWidth: FloatingPetHoverText.borderWidth)
            canvas.setFillColor(look.primary)
            for (i, line) in lines.enumerated() {
                canvas.draw(line, at: space.canvas(CGPoint(x: pad, y: pad + CGFloat(i) * lineHeight + m.ascender)))
            }
        }) else { return }
        let w = Int32(image.width), h = Int32(image.height)
        let gap = Int32((FloatingPetHoverText.gapAbovePet * scale).rounded())
        let left = (pet.left + pet.right) / 2 - w / 2, top = pet.top - gap - h
        if window == nil {
            window = try? WinSinkWindow(className: Self.className, title: "PokeTokenBar", style: 0x8000_0000 /* WS_POPUP */, exStyle: Self.exStyle,
                                        x: left, y: top, width: w, height: h)
        }
        guard let hwnd = window?.hwnd else { return }
        let bgra = PopoverSpriteScale.scaledBGRA(image.pixels, width: image.width, height: image.height)
        WinLayered.update(hwnd, bgra: bgra, width: Int(w), height: Int(h), x: left, y: top)
        picture = (Int(w), Int(h), bgra)
        _ = SetWindowPos(hwnd, HWND(bitPattern: -1) /* HWND_TOPMOST */, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW))
        isShown = true
        self.text = text
        frame = RECT(left: left, top: top, right: left + w, bottom: top + h)
    }

    func hide() {
        guard let hwnd = window?.hwnd, isShown else { return }
        _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_HIDEWINDOW))
        isShown = false
    }

    func destroy() {
        window?.destroy()
        window = nil
        isShown = false
    }
}

/// One `UpdateLayeredWindow` of a BGRA picture (premultiplied) at a place and size: a DIB made for the call and freed after
/// (the callout changes rarely; the pet's own window keeps its DIB).
enum WinLayered {
    @MainActor static func update(_ hwnd: HWND, bgra: [UInt8], width: Int, height: Int, x: Int32, y: Int32) {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(width)
        info.bmiHeader.biHeight = -Int32(height)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0
        guard let dc = CreateCompatibleDC(nil) else { return }
        defer { _ = DeleteDC(dc) }
        var p: UnsafeMutableRawPointer?
        guard let bitmap = CreateDIBSection(dc, &info, 0, &p, nil, 0), let p else { return }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        let old = SelectObject(dc, UnsafeMutableRawPointer(bitmap))
        defer { _ = SelectObject(dc, old) }
        bgra.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, width * height * 4)) }
        var size = SIZE(cx: Int32(width), cy: Int32(height))
        var source = POINT(x: 0, y: 0)
        var destination = POINT(x: x, y: y)
        var blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1)
        _ = UpdateLayeredWindow(hwnd, nil, &destination, &size, dc, &source, 0, &blend, 0x0000_0002 /* ULW_ALPHA */)
    }
}
#endif
