#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 23: the floating pet's extras (`pet.bubble`, `pet.hearts`, `pet.prayer`, `pet.hover`, `pet.agent`,
// `pet.extrasSettings`, `pet.extrasIdle`, `pet.extrasCapture`). Pets are FIXTURE companions over sample stores (`PetHarness`);
// agent events are FIXTURE `poketokenbar://agent` URLs given to the pet as the URL handler will; the limit alert and the
// companion event are the harness's stand-ins (the stores raise them only from a refresh and a hatch). Real input and the
// foreground only with `CI` set. With `--dump-ui <dir>` the panels go to `<dir>/pet/` ("Sample-data capture, Windows CI
// runner"). Runs after the Task 22 group and leaves no pet, window, timer or setting behind.

extension WindowsSelftest {
    @MainActor static func popoverPetExtrasChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPetExtras.run(r, app)
    }
}

@MainActor enum WindowsSelftestPetExtras {
    static let names = ["pet.bubble", "pet.hearts", "pet.prayer", "pet.hover", "pet.agent", "pet.extrasSettings", "pet.extrasIdle", "pet.extrasCapture"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        WinFloatingPet.spriteFetcherOverride = WindowsSelftestPopoverCompanion.fixtureFetcher()
        defer { WinFloatingPet.spriteFetcherOverride = nil }
        await bubbleCheck(r)
        await heartsCheck(r)
        await prayerCheck(r)
        await hoverCheck(r)
        await agentCheck(r)
        await settingsCheck(r, app)
        await idleCheck(r)
        await captureCheck(r)
        app.store.floatingPetEnabled = false
        PetHarness.clearSaved()
    }

    // MARK: - helpers

    typealias P = WindowsSelftestPopoverPet

    static func agent(_ query: String) -> AgentActivityEvent? { URL(string: "poketokenbar://agent?" + query).flatMap(AgentActivityEvent.init(url:)) }

    /// The window's rectangle on screen (the panel while a bubble or the hearts show).
    static func windowRect(_ w: WinPetWindow) -> RECT { P.rect(w.hwnd) }

    /// The expected panel for the window's pet box: `panelSize(petSize:showingBubble: true)` at its DPI, the box at its
    /// bottom, centred.
    static func expectedPanel(_ w: WinPetWindow) -> RECT {
        let scale = CGFloat(w.dpi) / 96
        let size = FloatingPetRules.panelSize(petSize: w.model.petSize, showingBubble: true)
        let width = Int32((size.width * scale).rounded()), height = Int32((size.height * scale).rounded())
        let side = w.frame.right - w.frame.left
        let left = w.frame.left - max(0, (width - side) / 2)
        return RECT(left: left, top: w.frame.bottom - height, right: left + width, bottom: w.frame.bottom)
    }

    static func same(_ a: RECT, _ b: RECT) -> Bool { a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom }

    /// A click by window messages at a screen point (client point from the window's rectangle now).
    static func postedClick(_ w: WinPetWindow, at p: POINT) {
        let r = windowRect(w)
        let lp = P.lParam(p.x - r.left, p.y - r.top)
        _ = SendMessageW(w.hwnd, 0x0201 /* WM_LBUTTONDOWN */, 1, lp)
        _ = SendMessageW(w.hwnd, 0x0202 /* WM_LBUTTONUP */, 0, lp)
    }

    /// Strokes by window messages (no button): `count` moves swinging `swing` pixels either side of `p`.
    static func postedStrokes(_ w: WinPetWindow, at p: POINT, swing: Int32, count: Int = 8) {
        for i in 0...count {
            let r = windowRect(w)
            let x = p.x + (i == 0 ? 0 : (i % 2 == 1 ? swing : -swing))
            _ = SendMessageW(w.hwnd, 0x0200 /* WM_MOUSEMOVE */, 0, P.lParam(x - r.left, p.y - r.top))
        }
    }

    /// The opaque pixels (alpha > 200) of the panel in rows `rows`.
    static func opaqueCount(_ w: WinPetWindow, rows: Range<Int>) -> Int {
        guard let snap = w.panelSnapshot() else { return 0 }
        var n = 0
        for y in max(0, rows.lowerBound)..<min(snap.height, rows.upperBound) {
            for x in 0..<snap.width where snap.bgra[(y * snap.width + x) * 4 + 3] > 200 { n += 1 }
        }
        return n
    }

    /// The pet box's top in the panel's picture (pixels).
    static func boxTop(_ w: WinPetWindow) -> Int { Int(w.frame.top - windowRect(w).top) }

    /// The stroke that the pet feels at its size and DPI, plus a margin, in pixels.
    static func strokeSwing(_ w: WinPetWindow) -> Int32 {
        Int32((FloatingPetStroke.distance(petSize: w.model.petSize) * CGFloat(w.dpi) / 96).rounded(.up)) + 6
    }

    /// A pet box's screen point at the opaque sprite pixel nearest its centre.
    static func spriteSpot(_ w: WinPetWindow) -> POINT? { P.opaquePoint(w).map { P.screen(w, $0) } }

    /// Waits for the pop-ins and the frames to end (nothing moves after).
    static func settle(_ h: PetHarness) async -> Bool {
        await WindowsSelftest.waitUntil(timeout: 2) { h.pet.extras.bubblePop == nil && h.pet.extras.heartsPop == nil && !h.pet.extras.armedTimers.contains("frame") }
    }

    // MARK: - pet.bubble: agent and limit bubbles, the panel, the click, the setting

    static func bubbleCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window, let spot = spriteSpot(w) else {
            r.add("pet.bubble", false, "the pet did not show a picture")
            return
        }
        var notes: [String] = []
        let box0 = w.frame, win0 = windowRect(w)
        // An agent waiting: the panel (180 x pet + 72 DIP, the pet at its bottom, centred), the bubble above the box, popping in.
        h.pet.handleAgentEvent(agent("state=waiting&label=poketokenbar&message=Approve%20the%20plan")!)
        let popping = h.pet.extras.bubblePop != nil && h.pet.extras.armedTimers.contains("frame")
        let settled = await settle(h)
        let panel = windowRect(w), expected = expectedPanel(w)
        let panelOK = same(panel, expected) && same(w.frame, box0)
        let bubbleRows = opaqueCount(w, rows: 0..<(boxTop(w) - Int((FloatingPetBubbleChrome.spacingToSprite * CGFloat(w.dpi) / 96).rounded())))
        let drawn = h.pet.extras.drawnBubble == .agentWaiting(label: "poketokenbar", message: "Approve the plan", others: 0)
        let waitingOK = popping && settled && panelOK && bubbleRows > 2000 && drawn
        notes.append("waiting: panel \(P.describe(panel)) (expected \(P.describe(expected)), pet box kept=\(same(w.frame, box0)))=\(panelOK), "
                     + "\(bubbleRows) opaque bubble pixels, drawn \(String(describing: h.pet.extras.drawnBubble))=\(drawn), popped in=\(popping), settled=\(settled)")
        // A limit alert outranks the agent; when it goes the agent's bubble is back.
        h.pet.extras.limitAlertForTesting = UsageStore.LimitAlert(key: "selftest", window: "5h", isCritical: true, utilization: 0.97)
        h.pet.sync()
        let limitDrawn: Bool = { if case .limit? = h.pet.extras.drawnBubble { return true } else { return false } }()
        h.pet.extras.limitAlertForTesting = nil
        h.pet.sync()
        let agentBack = h.pet.extras.drawnBubble == .agentWaiting(label: "poketokenbar", message: "Approve the plan", others: 0)
        notes.append("limit alert drawn over the agent=\(limitDrawn), agent back after it=\(agentBack)")
        // A click answers it: back to the pet box, where it was.
        postedClick(w, at: spot)
        let answered = h.pet.extras.drawnBubble == nil && same(windowRect(w), win0) && h.pet.extras.flow.summary.waiting == nil
        notes.append("click -> answered, window \(P.describe(windowRect(w))) back=\(answered)")
        // "React to agent activity" off: dropped.
        h.store.floatingPetAgentActivity = false
        let dropped0 = h.pet.extras.stats.dropped
        h.pet.handleAgentEvent(agent("state=waiting&label=x")!)
        let droppedOK = h.pet.extras.stats.dropped == dropped0 + 1 && h.pet.extras.drawnBubble == nil && same(windowRect(w), win0)
        h.store.floatingPetAgentActivity = true
        notes.append("setting off -> dropped=\(droppedOK)")
        let timers = h.pet.extras.armedTimers
        notes.append("timers after: \(timers)")
        r.add("pet.bubble", waitingOK && limitDrawn && agentBack && answered && droppedOK && timers.isEmpty, notes.joined(separator: "; "))
    }

    // MARK: - pet.hearts: strokes, the pixel art on the visible top, the 1.8 s, the tooltip

    static func heartsCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window, let spot = spriteSpot(w) else {
            r.add("pet.hearts", false, "the pet did not show a picture")
            return
        }
        var notes: [String] = []
        let win0 = windowRect(w)
        // A drag is no stroke.
        P.postedDrag(w, from: spot, through: [POINT(x: spot.x + 30, y: spot.y), POINT(x: spot.x - 30, y: spot.y), POINT(x: spot.x + 30, y: spot.y),
                                              POINT(x: spot.x - 30, y: spot.y), POINT(x: spot.x, y: spot.y)])
        let dragNoHearts = !h.pet.extras.heartsShowing
        h.pet.extras.setHovering(false)
        // Three reversals within 1.2 s: hearts for 1.8 s, the panel up, the tooltip cleared.
        let start = Date()
        postedStrokes(w, at: spot, swing: strokeSwing(w))
        let shown = h.pet.extras.heartsShowing && h.pet.extras.armedTimers.contains("hearts")
        let panelOK = same(windowRect(w), expectedPanel(w))
        let tooltipCleared = w.toolTipForTesting == nil
        _ = await settle(h)
        // The pixel art: the Mac's grid at its offset over the sprite's visible top (a red cell, row 4 column 8).
        var heartOK = false, heartAt = ""
        if let snap = w.panelSnapshot() {
            let scale = CGFloat(w.dpi) / 96
            let cell = max(1, Int((FloatingPetHeartArt.pixel * scale).rounded()))
            let side = Int(w.frame.right - w.frame.left)
            let artW = FloatingPetHeartArt.rows[0].count * cell
            let boxX = Int(w.frame.left - windowRect(w).left), boxY = boxTop(w)
            let visible = h.pet.extras.drawnHearts
            // The offset the window used, from the shared rule over the visible top it reads (`spriteVisibleTop`).
            let models = w.playback.models.first
            let images = (models?.frames.isEmpty ?? true) ? (models?.subject.image.map { [$0] } ?? []) : (models?.frames.map { $0.image } ?? [])
            let fraction = FloatingPetVisibleTop.anchorFraction(of: images.map { FloatingPetVisibleTop.opaqueTopFraction(of: $0.pixels) })
            let top = images.first.map { FloatingPetVisibleTop.inset(box: w.model.petSize, imageSize: CGSize(width: $0.width, height: $0.height), opaqueTopFraction: fraction) } ?? 0
            let offset = FloatingPetHeartArt.bubbleTopOffset(visibleTop: top, bubbleHeight: FloatingPetHeartArt.height, overlap: FloatingPetHeartArt.tailOverlap)
            let x = boxX + (side - artW) / 2 + 8 * cell + cell / 2, y = boxY + Int((offset * scale).rounded()) + 4 * cell + cell / 2
            if x >= 0, y >= 0, x < snap.width, y < snap.height {
                let i = (y * snap.width + x) * 4
                heartOK = visible && snap.bgra[i] == 0x3C && snap.bgra[i + 1] == 0x30 && snap.bgra[i + 2] == 0xE0 && snap.bgra[i + 3] == 255
                heartAt = "(\(x),\(y)) = \(snap.bgra[i + 2]),\(snap.bgra[i + 1]),\(snap.bgra[i]),\(snap.bgra[i + 3]) (visible top \(top), offset \(offset))"
            }
        }
        // Restarted by a stroke at ~1 s: still up at 2.2 s from the first; gone 1.8 s after the second.
        _ = await WindowsSelftest.waitUntil(timeout: 1) { Date().timeIntervalSince(start) >= 1.0 }
        postedStrokes(w, at: spot, swing: strokeSwing(w))
        let restart = Date()
        _ = await WindowsSelftest.waitUntil(timeout: 1.5) { Date().timeIntervalSince(start) >= 2.2 }
        let stillUp = h.pet.extras.heartsShowing
        let gone = await WindowsSelftest.waitUntil(timeout: 2.5) { !h.pet.extras.heartsShowing }
        let lasted = Date().timeIntervalSince(restart)
        let back = same(windowRect(w), win0) && w.toolTipForTesting != nil
        notes.append("drag -> no hearts=\(dragNoHearts); strokes -> hearts=\(shown), panel=\(panelOK), tooltip cleared=\(tooltipCleared); "
                     + "red cell \(heartAt)=\(heartOK); restarted -> up at 2.2 s=\(stillUp), gone \(String(format: "%.2f", lasted)) s after the second=\(gone), window and tooltip back=\(back)")
        // Speech up: no hearts.
        h.pet.handleAgentEvent(agent("state=waiting&label=a")!)
        postedStrokes(w, at: spot, swing: strokeSwing(w))
        let speechNoHearts = !h.pet.extras.heartsShowing
        h.pet.acknowledgeAgents()
        _ = await settle(h)
        let timers = h.pet.extras.armedTimers
        notes.append("waiting bubble -> strokes give no hearts=\(speechNoHearts); timers after \(timers)")
        let timingOK = gone && lasted >= 1.7 && lasted <= 2.4
        r.add("pet.hearts", dragNoHearts && shown && panelOK && tooltipCleared && heartOK && stillUp && timingOK && back && speechNoHearts && timers.isEmpty,
              notes.joined(separator: "; "))
    }

    // MARK: - pet.prayer: the 🙏 rising and the egg's wobble, then nothing

    static func prayerCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.eggIncubating)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window, let spot = spriteSpot(w) else {
            r.add("pet.prayer", false, "the egg did not show a picture")
            return
        }
        let p0 = h.companion.state.eggPrayers?.count ?? 0
        let ticks0 = h.pet.extras.stats.frameTicks
        let start = Date()
        postedClick(w, at: spot)
        let spawned = h.pet.extras.particles.count == 1 && h.pet.extras.wobbleStart != nil && h.pet.extras.armedTimers.contains("frame")
        var maxAngle = 0.0, rose = false
        _ = await WindowsSelftest.waitUntil(timeout: 0.6, poll: 0.01) {
            maxAngle = max(maxAngle, abs(h.pet.extras.wobbleAngle(at: Date())))
            rose = rose || (h.pet.extras.particleStates(at: Date()).first?.progress ?? 0) > 0.3
            return false
        }
        let ended = await WindowsSelftest.waitUntil(timeout: 1.5) { h.pet.extras.particles.isEmpty && h.pet.extras.wobbleStart == nil && h.pet.extras.armedTimers.isEmpty }
        let took = Date().timeIntervalSince(start)
        let ticks = h.pet.extras.stats.frameTicks - ticks0
        let prayed = (h.companion.state.eggPrayers?.count ?? 0) == p0 + 1
        let hoverLine = h.pet.currentHoverText().contains(L(h.companion.language).prayerHoverLine(p0 + 1))
        let ok = spawned && maxAngle >= 4 && rose && ended && took <= 1.6 && ticks >= 15 && ticks <= 50 && prayed && hoverLine
        r.add("pet.prayer", ok, "click on the egg -> prayed=\(prayed), one 🙏 and the wobble with the frame timer=\(spawned); wobble up to \(String(format: "%.1f", maxAngle))°, "
              + "rose=\(rose); all ended after \(String(format: "%.2f", took)) s=\(ended) with \(ticks) frames; the hover text counts it=\(hoverLine)")
    }

    // MARK: - pet.hover: the callout (real pointer, CI), the native tooltip, the event pop

    static func hoverCheck(_ r: WindowsSelftest.Recorder) async {
        let work = P.primaryWork()
        let h = await PetHarness.make(.hatched, saved: CGPoint(x: CGFloat(work.left + 420), y: CGFloat(work.top + 360)))
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window, let spot = spriteSpot(w) else {
            r.add("pet.hover", false, "the pet did not show a picture")
            return
        }
        var notes: [String] = []
        var ok = true
        let text = h.pet.currentHoverText()
        let tooltipOK = w.toolTipForTesting == text
        ok = ok && tooltipOK
        notes.append("native tooltip '\(w.toolTipForTesting ?? "none")' = the hover text=\(tooltipOK)")
        func calloutPlaced() -> (ok: Bool, line: String) {
            let c = h.pet.extras.callout
            guard c.isShown, let hwnd = c.hwnd else { return (false, "no callout") }
            let ex = DWORD(bitPattern: GetWindowLongW(hwnd, -20 /* GWL_EXSTYLE */))
            let styles = ex & WinPetCallout.exStyle == WinPetCallout.exStyle
            let f = P.rect(hwnd), pet = windowRect(w)
            let gap = Int32((FloatingPetHoverText.gapAbovePet * CGFloat(w.dpi) / 96).rounded())
            let centred = abs((f.left + f.right) - (pet.left + pet.right)) <= 2 && f.bottom == pet.top - gap
            return (styles && centred && IsWindowVisible(hwnd), "callout \(P.describe(f)) over \(P.describe(pet)) styles=\(styles) centred \(gap) px up=\(centred) text '\(c.text)'")
        }
        if WindowsSelftest.onCI {
            WindowsSelftestPopover.mouse(x: spot.x, y: spot.y, flags: DWORD(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE))
            let up = await WindowsSelftest.waitUntil(timeout: 2) { h.pet.extras.callout.isShown }
            let placed = calloutPlaced()
            let sameText = h.pet.extras.callout.text == text
            if let pic = h.pet.extras.callout.picture, let dir = P.dumpDirectory() {
                _ = WinUIDump.write(whiteBacked(pic.bgra, pic.width, pic.height), to: dir.appendingPathComponent("pet-callout-en.png"))
            }
            WindowsSelftestPopover.mouse(x: work.left + 20, y: work.top + 20, flags: DWORD(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE))
            let hidden = await WindowsSelftest.waitUntil(timeout: 2) { !h.pet.extras.callout.isShown }
            let hoverOK = up && placed.ok && sameText && hidden
            ok = ok && hoverOK
            notes.append("real pointer over the pet -> \(placed.line)=\(up && placed.ok), the hover text=\(sameText); away -> hidden=\(hidden)")
        } else {
            notes.append("the pointer: skipped (CI not set)")
        }
        // An event pops the callout by itself for 6 s (no pointer), then it goes.
        h.pet.extras.latestEventForTesting = CompanionStore.CompanionEvent(seq: 1_000, text: "FIXTURE: Bulbasaur hatched!", at: Date())
        h.pet.popEventIfNew()
        let popped = h.pet.extras.callout.isShown && h.pet.extras.callout.text.contains("FIXTURE: Bulbasaur hatched!")
            && h.pet.extras.armedTimers.contains("eventPop") && (w.toolTipForTesting ?? "").contains("FIXTURE: Bulbasaur hatched!")
        let placedPop = calloutPlaced()
        let start = Date()
        let gone = await WindowsSelftest.waitUntil(timeout: 7.5) { !h.pet.extras.callout.isShown }
        let lasted = Date().timeIntervalSince(start)
        let again = h.pet.extras.stats.eventPops
        h.pet.popEventIfNew()   // the same event is not news
        let once = h.pet.extras.stats.eventPops == again
        let popOK = popped && placedPop.ok && gone && lasted >= 5.8 && lasted <= 6.6 && once && h.pet.extras.armedTimers.isEmpty
        ok = ok && popOK
        notes.append("event -> callout by itself=\(popped) (\(placedPop.line)), gone after \(String(format: "%.2f", lasted)) s=\(gone), not again=\(once), timers \(h.pet.extras.armedTimers)")
        r.add("pet.hover", ok, notes.joined(separator: "; "))
    }

    // MARK: - pet.agent: the bob, the run to the pointer and back, the deadline, a drag during a run

    static func agentCheck(_ r: WindowsSelftest.Recorder) async {
        let work = P.primaryWork()
        let home = CGPoint(x: CGFloat(work.left + 300), y: CGFloat(work.top + 400))
        let h = await PetHarness.make(.hatched, saved: home)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window else {
            r.add("pet.agent", false, "the pet did not show a picture")
            return
        }
        var notes: [String] = []
        let box0 = w.frame
        // Working: the bob (the squashed frame every 0.5 s), one timer at the 10-minute deadline.
        h.pet.handleAgentEvent(agent("state=working&label=build")!)
        let fire = h.pet.extras.flow.deadline.map { $0.timeIntervalSinceNow } ?? -1
        let bobArmed = h.pet.extras.armedTimers.contains("bob") && h.pet.extras.armedTimers.contains("agent")
        let ticks0 = h.pet.extras.stats.bobTicks
        var squashedHeight: Int32 = 0
        _ = await WindowsSelftest.waitUntil(timeout: 1.3) {
            if h.pet.extras.squashed, squashedHeight == 0, let b = P.opaqueBox(w) { squashedHeight = b.box.bottom - b.box.top }
            return false
        }
        let bobTicks = h.pet.extras.stats.bobTicks - ticks0
        h.animations = false
        h.pet.refreshBob()
        let still = !h.pet.extras.armedTimers.contains("bob") && !h.pet.extras.squashed
        let unsquashedHeight = P.opaqueBox(w).map { $0.box.bottom - $0.box.top } ?? 0
        h.animations = true
        h.pet.refreshBob()
        let bobOK = bobArmed && fire > 590 && fire <= 600 && bobTicks >= 2 && bobTicks <= 3 && still && squashedHeight > 0 && squashedHeight < unsquashedHeight
        notes.append("working -> bob and the deadline in \(Int(fire)) s armed=\(bobArmed); \(bobTicks) bob frames in 1.3 s, squashed height \(squashedHeight) < \(unsquashedHeight); "
                     + "\"Show animations\" off -> no bob=\(still)")
        // Done: the run to the pointer's monitor next to it, away from home; a click acknowledges it and the pet comes home.
        var cursor = POINT()
        _ = GetCursorPos(&cursor)
        h.pet.handleAgentEvent(agent("state=done&label=build&message=Tests%20passed")!)
        let ran = await WindowsSelftest.waitUntil(timeout: 1.5) { h.pet.extras.move == nil && h.pet.extras.flow.runPhase == .away }
        let away = w.frame
        let screens = h.pet.screens()
        let screen = screens.first(where: { $0.bounds.contains(CGPoint(x: CGFloat(cursor.x), y: CGFloat(cursor.y))) }) ?? screens.first(where: { $0.isPrimary })
        var nearOK = false
        if let s = screen {
            let size = FloatingPetRules.panelSize(petSize: w.model.petSize, showingBubble: true)
            let px = CGSize(width: (size.width * s.scale).rounded(), height: (size.height * s.scale).rounded())
            let o = FloatingPetAgentMotion.runPanelOrigin(cursor: CGPoint(x: CGFloat(cursor.x), y: -CGFloat(cursor.y)), panelSize: px,
                                                          visibleFrame: CGRect(x: s.work.minX, y: -s.work.maxY, width: s.work.width, height: s.work.height),
                                                          gap: (FloatingPetAgentMotion.agentRunCursorGap * s.scale).rounded())
            let side = CGFloat(away.right - away.left)
            nearOK = abs(CGFloat(away.left) - (o.x + max(0, (px.width - side) / 2).rounded(.down))) <= 1 && abs(CGFloat(away.bottom) + o.y) <= 1
        }
        let savedKept = FloatingPetOrigin.saved(in: h.pet.defaults) == home
        postedClick(w, at: POINT(x: (away.left + away.right) / 2, y: (away.top + away.bottom) / 2))
        let back = await WindowsSelftest.waitUntil(timeout: 1.5) { h.pet.extras.flow.runPhase == .home && h.pet.extras.move == nil }
        let atHome = same(w.frame, box0)
        notes.append("done -> ran next to the pointer \(cursor.x),\(cursor.y): \(P.describe(away)) (rule)=\(ran && nearOK), home not saved=\(savedKept); "
                     + "click -> back home \(P.describe(w.frame))=\(back && atHome)")
        // A drag during the run: the move stops and the drag is the new home.
        h.pet.handleAgentEvent(agent("state=done&label=build")!)
        _ = await WindowsSelftest.waitUntil(timeout: 0.2) { false }
        let mid = w.frame
        let midPoint = POINT(x: (mid.left + mid.right) / 2, y: (mid.top + mid.bottom) / 2)
        let r0 = windowRect(w)
        _ = SendMessageW(w.hwnd, 0x0201, 1, P.lParam(midPoint.x - r0.left, midPoint.y - r0.top))
        for i in 1...4 {
            let rr = windowRect(w)
            _ = SendMessageW(w.hwnd, 0x0200, 1, P.lParam(midPoint.x + Int32(i * 10) - rr.left, midPoint.y - rr.top))
        }
        let rr = windowRect(w)
        _ = SendMessageW(w.hwnd, 0x0202, 0, P.lParam(midPoint.x + 40 - rr.left, midPoint.y - rr.top))
        let stopped = h.pet.extras.move == nil && h.pet.extras.flow.runPhase == .home
        _ = await WindowsSelftest.waitUntil(timeout: 0.8) { false }
        let stayed = w.frame.left == mid.left + 40 || abs(w.frame.left - (mid.left + 40)) <= 1
        let savedNew = FloatingPetOrigin.saved(in: h.pet.defaults) == CGPoint(x: CGFloat(w.frame.left), y: CGFloat(w.frame.bottom))
        notes.append("drag during the run -> stopped=\(stopped), stayed where dropped=\(stayed), saved as home=\(savedNew)")
        // Motion off: done shows at home (no run).
        h.pet.acknowledgeAgents()
        h.animations = false
        let homeNow = w.frame
        h.pet.handleAgentEvent(agent("state=done&label=lint")!)
        let noRun = h.pet.extras.move == nil && h.pet.extras.flow.runPhase == .home && same(w.frame, homeNow)
            && h.pet.extras.drawnBubble == .agentDone(label: "lint", message: nil)
        h.animations = true
        h.pet.acknowledgeAgents()
        h.pet.handleAgentEvent(agent("state=idle&label=build")!)
        h.pet.handleAgentEvent(agent("state=idle&label=lint")!)
        _ = await settle(h)
        let timers = h.pet.extras.armedTimers
        notes.append("motion off -> done at home, no run=\(noRun); after idle events timers \(timers)")
        r.add("pet.agent", bobOK && ran && nearOK && savedKept && back && atHome && stopped && stayed && savedNew && noRun && timers.isEmpty,
              notes.joined(separator: "; "))
    }

    // MARK: - pet.extrasSettings: the bubble and agent switches in the pet group (G12a)

    static func settingsCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI, let pet = WinFloatingPet.current, let tray = app.tray else {
            r.add("pet.extrasSettings", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("pet.extrasSettings", false, "no probe window"); return
        }
        defer { probe.destroy() }
        let l = app.companion.l
        app.store.floatingPetEnabled = false
        let host = WinPopoverHost(store: app.store, companion: app.companion, updater: nil, team: app.teamSettings, session: nil, feed: nil,
                                  tray: nil, loginItem: tray.loginItem, openPlaza: {})
        host.owner = app.sink.hwnd
        let p = WinPopover(host: host)
        p.makePage = WinSettingsPage.routed
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        p.present(.secondLaunch) { $0.showSettings = true }
        let up = await WindowsSelftest.waitUntil(timeout: 3) { p.hwnd.map { IsWindowVisible($0) } == true }
        await P.wait(0.4)
        guard up, let page = p.pageForTesting as? WinSettingsPage, let rows = page.petRowsForTesting else {
            r.add("pet.extrasSettings", false, "the Settings page did not open")
            p.close(.destroyed)
            return
        }
        let hiddenOff = rows.bubbleAlertsRow?.isVisible == false && rows.agentActivityRow?.isVisible == false
        if let c = rows.enableRow?.control { WinKit.send(c.parts[0], 0x00F5 /* BM_CLICK */) }
        let on = await WindowsSelftest.waitUntil(timeout: 3) { app.store.floatingPetEnabled && pet.window?.revealed == true }
        await P.wait(0.3)
        let shownOn = rows.bubbleAlertsRow?.isVisible == true && rows.agentActivityRow?.isVisible == true
        let titles = [rows.bubbleAlertsRow?.label, rows.agentActivityRow?.label, rows.agentActivityRow?.hint].map { $0.map { WinKit.text(of: $0.hwnd) } }
        let titlesOK = titles == [l.floatingPetBubbleAlertsLabel, l.floatingPetAgentActivityLabel, l.floatingPetAgentActivityHint]
        let bubbles0 = app.store.floatingPetBubbleAlerts, agents0 = app.store.floatingPetAgentActivity
        if let c = rows.bubbleAlertsRow?.control { WinKit.send(c.parts[0], 0x00F5) }
        if let c = rows.agentActivityRow?.control { WinKit.send(c.parts[0], 0x00F5) }
        let flipped = await WindowsSelftest.waitUntil(timeout: 2) {
            app.store.floatingPetBubbleAlerts == !bubbles0 && app.store.floatingPetAgentActivity == !agents0
        }
        if let h = p.hwnd, let area = page.areaForTesting, let stack = page.stackForTesting, let frames = stack.frames,
           let index = stack.sections.firstIndex(where: { $0.caption?.text == l.floatingPetSectionTitle.uppercased() }),
           index < frames.sections.count, let frame = frames.sections[index] {
            area.scroll(to: Int32(max(0, (frame.caption?.minY ?? frame.card?.minY ?? 0) - 8)))
            await P.wait(0.35)
            P.printWindow(h, "settings-pet-group-extras-en.png")
        }
        app.store.floatingPetBubbleAlerts = bubbles0
        app.store.floatingPetAgentActivity = agents0
        app.store.floatingPetEnabled = false
        p.close(.destroyed)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { pet.window == nil }
        r.add("pet.extrasSettings", hiddenOff && on && shownOn && titlesOK && flipped,
              "while off both rows hidden=\(hiddenOff); on=\(on) -> shown=\(shownOn); titles \(titles.map { $0 ?? "none" })=\(titlesOK); "
              + "clicked -> bubble alerts \(bubbles0) -> \(app.store.floatingPetBubbleAlerts), agent activity \(agents0) -> \(app.store.floatingPetAgentActivity) flipped=\(flipped)")
    }

    // MARK: - pet.extrasIdle: what stays up costs nothing (a waiting bubble), or only its own beat (the bob)

    static func idleCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.eggIncubating)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window else {
            r.add("pet.extrasIdle", false, "the pet did not show a picture")
            return
        }
        // A waiting bubble stays until it is answered: no timer, no picture after its pop-in.
        h.pet.handleAgentEvent(agent("state=waiting&label=review&message=Look%20at%20this")!)
        _ = await settle(h)
        let renders0 = h.pet.stats.renders, frames0 = h.pet.extras.stats.frameTicks
        await P.wait(3)
        let waitingTimers = h.pet.extras.armedTimers
        let waitingRenders = h.pet.stats.renders - renders0, waitingFrames = h.pet.extras.stats.frameTicks - frames0
        let waitingOK = waitingTimers.isEmpty && waitingRenders == 0 && waitingFrames == 0 && w.playback.clock.isArmed == false
        h.pet.acknowledgeAgents()
        // A working agent: the bob's two pictures a second and the one deadline timer; nothing else.
        h.pet.handleAgentEvent(agent("state=working&label=build")!)
        _ = await settle(h)
        let renders1 = h.pet.stats.renders
        await P.wait(3)
        let workingRenders = h.pet.stats.renders - renders1
        let workingTimers = Set(h.pet.extras.armedTimers)
        let workingOK = (5...7).contains(workingRenders) && workingTimers == ["bob", "agent"]
        h.pet.handleAgentEvent(agent("state=idle&label=build")!)
        let after = h.pet.extras.armedTimers
        r.add("pet.extrasIdle", waitingOK && workingOK && after.isEmpty,
              "waiting bubble up 3 s: timers \(waitingTimers), \(waitingRenders) renders, \(waitingFrames) frames, clock armed=\(w.playback.clock.isArmed) (all none)=\(waitingOK); "
              + "working 3 s: \(workingRenders) renders (the bob: 5-7), timers \(workingTimers.sorted())=\(workingOK); idle -> timers \(after)")
    }

    // MARK: - pet.extrasCapture (`--dump-ui <dir>`: pet/), the Mac renders' states

    static func whiteBacked(_ src: [UInt8], _ width: Int, _ height: Int) -> WinUIDump.Bitmap {
        var bgra = src
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let a = Int(bgra[i + 3])
            for c in 0..<3 { bgra[i + c] = UInt8(min(255, Int(bgra[i + c]) + (255 - a))) }
            bgra[i + 3] = 255
        }
        return WinUIDump.Bitmap(width: width, height: height, bgra: bgra)
    }

    static func captureCheck(_ r: WindowsSelftest.Recorder) async {
        guard let dir = P.dumpDirectory() else {
            r.add("pet.extrasCapture", true, "skipped: no --dump-ui")
            return
        }
        var written: [String] = [], failed: [String] = []
        func write(_ w: WinPetWindow, _ name: String) {
            guard let snap = w.panelSnapshot() else { failed.append(name); return }
            if WinUIDump.write(whiteBacked(snap.bgra, snap.width, snap.height), to: dir.appendingPathComponent("pet-\(name).png")) == 0 {
                written.append(name)
            } else {
                failed.append(name)
            }
        }
        // As the Mac's renders: a 96-point hatched pet, no bob (FloatingPetExtrasRendersMacTests).
        let waiting = ["state=waiting&label=a", "state=waiting&label=b", "state=working&label=c",
                       "state=waiting&label=poketokenbar&message=Approve%20the%20plan%20before%20I%20continue"]
        let cases: [(String, AppLanguage, [String])] = [("bubble-waiting-en", .en, waiting), ("bubble-waiting-ko", .ko, waiting),
                                                        ("bubble-done-en", .en, ["state=done"])]
        for (name, language, events) in cases {
            let h = await PetHarness.make(.hatched, language: language) { $0.animations = false }
            if await h.waitShown(), let w = h.window {
                for e in events { h.pet.handleAgentEvent(agent(e)!) }
                _ = await settle(h)
                write(w, name)
            } else {
                failed.append(name)
            }
            h.destroy()
        }
        // The hearts and a critical limit alert.
        let hh = await PetHarness.make(.hatched) { $0.animations = false }
        if await hh.waitShown(), let w = hh.window, let spot = spriteSpot(w) {
            postedStrokes(w, at: spot, swing: strokeSwing(w))
            _ = await settle(hh)
            write(w, "hearts-en")
            _ = await WindowsSelftest.waitUntil(timeout: 2.5) { !hh.pet.extras.heartsShowing }
            hh.pet.extras.limitAlertForTesting = UsageStore.LimitAlert(key: "selftest", window: "5h", isCritical: true, utilization: 0.97)
            hh.pet.sync()
            _ = await settle(hh)
            write(w, "bubble-limit-critical-en")
            hh.pet.extras.limitAlertForTesting = nil
            hh.pet.sync()
        } else {
            failed.append("hearts-en")
        }
        hh.destroy()
        // A prayer's 🙏 at the middle of its rise (eased progress 0.5), the clock held there; the box only (the Mac's frame).
        let egg = await PetHarness.make(.eggIncubating)
        if await egg.waitShown(), let w = egg.window, let spot = spriteSpot(w) {
            postedClick(w, at: spot)
            if let born = egg.pet.extras.particles.first?.born {
                var lo = 0.0, hi = 1.0
                for _ in 0..<40 { let mid = (lo + hi) / 2; if FloatingPetPrayerArt.easeOut(mid) < 0.5 { lo = mid } else { hi = mid } }
                let t = born.addingTimeInterval(max(lo, FloatingPetPrayerArt.wobbleDuration + 0.01))
                egg.pet.extras.now = { t }
                w.render()
                if let snap = w.snapshot(), WinUIDump.write(whiteBacked(snap.bgra, snap.side, snap.side), to: dir.appendingPathComponent("pet-prayer-mid.png")) == 0 {
                    written.append("prayer-mid")
                } else {
                    failed.append("prayer-mid")
                }
                egg.pet.extras.now = Date.init
            } else {
                failed.append("prayer-mid")
            }
            _ = await WindowsSelftest.waitUntil(timeout: 1.5) { egg.pet.extras.armedTimers.isEmpty }
        } else {
            failed.append("prayer-mid")
        }
        egg.destroy()
        r.add("pet.extrasCapture", failed.isEmpty, "wrote \(written.count) to \(dir.path): \(written); failed \(failed) (FIXTURE sprites: \(WindowsSelftestPopoverCompanion.spriteDirectory?.path ?? "none"))")
    }
}
#endif
