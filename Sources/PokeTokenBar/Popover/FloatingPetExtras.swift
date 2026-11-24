import Foundation

// Stage 7 Task 23: the rest of the floating pet, shared (both systems test it): the speech bubble (limit alerts and agent
// activity), the hearts after strokes, the prayers' 🙏 and wobble, the hover text, the agent bob and the run to the cursor.
// Each piece is a twin of the Mac's member in `UI/FloatingPetPanel.swift` (`Tests/PopoverParity/twins.txt` holds the
// bodies together; `PopoverPetExtrasTwinEquivalenceTests+Mac` drives both over the same inputs). The Mac measures text
// with AppKit; here the measurement is a parameter, so Windows measures with DirectWrite and the Mac test passes the
// Mac's own measurement in.

/// The speech bubble: which one shows and what it says (`FloatingPetController.bubble`, `bubbleContent`, ...).
enum FloatingPetBubbles {
    /// Horizontal padding inside the bubble chrome (each side). Content + 2× this = `bubbleMinWidth`.
    static let bubbleHorizontalPadding: CGFloat = 8
    /// Fixed text column — wraps instead of growing past the panel (`bubbleMinWidth` − 16).
    static let bubbleContentWidth: CGFloat = FloatingPetRules.bubbleMinWidth - (bubbleHorizontalPadding * 2)
    /// `SpeechBubbleView` body `.lineLimit`.
    static let bubbleBodyLineLimit = 2
    /// How long the heart bubble stays after the last qualifying stroke.
    static let heartDuration: Duration = .milliseconds(1800)
    /// How long the callout stays up on its own when a hatch / evolution / graduation / Ditto line arrives.
    static let eventPopDuration: Duration = .seconds(6)

    /// The one bubble the pet shows. A limit alert outranks agent messages.
    enum Bubble: Equatable {
        case limit(UsageStore.LimitAlert)
        case agentWaiting(label: String?, message: String?, others: Int)
        case agentDone(label: String?, message: String?)
    }

    /// A limit alert outranks agents; among agents a fresh `done` outranks waiting.
    static func bubble(limitAlert: UsageStore.LimitAlert?, agent: AgentActivitySummary) -> Bubble? {
        if let limitAlert { return .limit(limitAlert) }
        if let done = agent.done { return .agentDone(label: done.label, message: done.message) }
        if let waiting = agent.waiting {
            return .agentWaiting(label: waiting.label, message: waiting.message, others: agent.otherWaitingCount)
        }
        return nil
    }

    struct SpeechBubbleContent: Equatable {
        var title: String
        var body: String
        var isCritical: Bool
    }

    /// What the measurement tells (the Mac's `SpeechBubbleLayout`): the chrome's size, the body's wrapped line count at the
    /// content column, the single-line widths, and whether the body passes `bubbleBodyLineLimit`.
    struct SpeechBubbleLayout: Equatable {
        var size: CGSize
        var bodyLineCount: Int
        var unclampedTitleWidth: CGFloat
        var unclampedBodyWidth: CGFloat
        var wouldTruncate: Bool
    }

    /// Measures a title and a body at `bubbleContentWidth` (the Mac: `measureSpeechBubbleLayout`, AppKit; Windows: DirectWrite).
    typealias Measure = (_ title: String, _ body: String) -> SpeechBubbleLayout

    static func bubbleContent(_ bubble: Bubble, l: L, measure: Measure) -> SpeechBubbleContent {
        switch bubble {
        case .limit(let alert):
            let title = alert.isCritical ? l.notifCritical : l.notifWarning
            return SpeechBubbleContent(title: title, body: bubbleBody(for: alert, title: title, l: l, measure: measure),
                                       isCritical: alert.isCritical)
        case .agentWaiting(let label, let message, let others):
            let title = agentTitle(label: label, unlabeled: l.agentWaitingTitle, status: l.agentWaitingStatus,
                                   count: others > 0 ? "+\(others)" : nil, measure: measure)
            return agentContent(title: title, body: message ?? l.agentWaitingDefaultBody, measure: measure)
        case .agentDone(let label, let message):
            let title = agentTitle(label: label, unlabeled: l.agentDoneTitle, status: l.agentDoneStatus, count: nil, measure: measure)
            return agentContent(title: title, body: message ?? l.agentDoneDefaultBody, measure: measure)
        }
    }

    private static func agentContent(title: String, body: String, measure: Measure) -> SpeechBubbleContent {
        SpeechBubbleContent(title: title, body: fittedBubbleBody(body, title: title, measure: measure), isCritical: false)
    }

    /// "<label> · <status>" (or the plain title without a label), then "+N" more waiting agents. The label — or the plain
    /// title — is cut with an ellipsis so the title stays on one line.
    static func agentTitle(label: String?, unlabeled: String, status: String, count: String?, measure: Measure) -> String {
        let lead = label ?? unlabeled
        var suffix = label == nil ? "" : " · " + status
        if let count { suffix += " " + count }
        func fits(_ title: String) -> Bool {
            measure(title, "").unclampedTitleWidth <= bubbleContentWidth
        }
        guard !fits(lead + suffix) else { return lead + suffix }
        let characters = Array(lead)
        func cut(_ count: Int) -> String {
            String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…" + suffix
        }
        // Invariant: `low` fits (or is the shortest cut), `high` does not.
        var low = 0, high = characters.count
        while high - low > 1 {
            let mid = (low + high) / 2
            if fits(cut(mid)) { low = mid } else { high = mid }
        }
        // Prefer a word boundary ("needs…", not "needs y…"); folder names and CJK have none.
        if let space = characters[..<low].lastIndex(of: " "), space >= low / 2 { return cut(space) }
        return cut(low)
    }

    /// Cut `text` with an ellipsis until it fits `bubbleBodyLineLimit`, so the view never clips it.
    static func fittedBubbleBody(_ text: String, title: String, measure: Measure) -> String {
        guard measure(title, text).wouldTruncate else { return text }
        let characters = Array(text)
        func ellipsized(_ count: Int) -> String {
            String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
        }
        // Invariant: `low` fits, `high` does not. Only fitting candidates are ever returned.
        var low = 0, high = characters.count
        while high - low > 1 {
            let mid = (low + high) / 2
            if measure(title, ellipsized(mid)).wouldTruncate {
                high = mid
            } else {
                low = mid
            }
        }
        return ellipsized(low)
    }

    /// The alert text, with its Claude account only when it still fits: the percentage matters more.
    static func bubbleBody(for alert: UsageStore.LimitAlert, title: String, l: L, measure: Measure) -> String {
        let full = alert.body(l)
        guard alert.account != nil, measure(title, full).wouldTruncate else { return full }
        return alert.body(l, withAccount: false)
    }

    /// Speech takes priority over hearts: limit alert, agent done, agent waiting, then a stroke.
    static func heartsShowing(afterStrokeWithAlertActive alertActive: Bool,
                              agent: AgentActivitySummary = .init()) -> Bool {
        !alertActive && bubble(limitAlert: nil, agent: agent) == nil
    }

    /// Reserve headroom for either speech or hearts, including agent-only speech.
    static func isShowingBubble(alertActive: Bool, heartsShowing: Bool,
                                agent: AgentActivitySummary = .init()) -> Bool {
        alertActive || bubble(limitAlert: nil, agent: agent) != nil || heartsShowing
    }

    /// The native tooltip would overlap the heart bubble, so it is cleared while hearts show.
    /// Limit alerts keep the tooltip as before.
    static func nativeToolTip(_ text: String, heartsShowing: Bool) -> String? {
        heartsShowing ? nil : text
    }

    /// Pop the callout only for an event not shown yet, while the pet is on screen and no speech or
    /// hearts bubble is up. An event that arrives when it cannot pop is dropped, not queued.
    static func shouldPopEvent(eventSeq: Int?, lastSeenSeq: Int?, petVisible: Bool, bubbleShowing: Bool) -> Bool {
        guard let eventSeq, eventSeq != lastSeenSeq else { return false }
        return petVisible && !bubbleShowing
    }
}

/// The speech bubble's chrome as values (`SpeechBubbleView.body`): what Windows draws around the text.
enum FloatingPetBubbleChrome {
    static let titleFontSize: CGFloat = 11   // bold
    static let bodyFontSize: CGFloat = 10
    static let titleBodySpacing: CGFloat = 2
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    /// The tail: a triangle (10, 0)–(20, 0)–(15, 6) below the box, 6 pt of bottom padding under the chrome.
    static let tailLeft: CGFloat = 10, tailRight: CGFloat = 20, tailTipX: CGFloat = 15, tailHeight: CGFloat = 6
    static let bottomPadding: CGFloat = 6
    /// The shadow: black at 15 %, radius 4, 2 pt down.
    static let shadowOpacity: CGFloat = 0.15, shadowRadius: CGFloat = 4, shadowOffsetY: CGFloat = 2
    /// The VStack spacing between the bubble and the sprite.
    static let spacingToSprite: CGFloat = 8
}

/// The agent's motion (`FloatingPetController`'s run and bob statics).
enum FloatingPetAgentMotion {
    /// Run to the cursor / back home.
    static let agentRunDuration: TimeInterval = 0.6
    /// Distance between the cursor and the panel after a run, so the pet never sits under the pointer.
    static let agentRunCursorGap: CGFloat = 16
    /// Half a bob cycle while an agent works. Must stay > 0: it is the frame cap of this loop.
    static let agentBobInterval: TimeInterval = 0.5
    /// The bob's squashed frame (`AgentBob`): scaled toward the feet.
    static let bobScaleX: CGFloat = 1.03, bobScaleY: CGFloat = 0.94

    /// Panel origin next to the cursor: below-right by default, flipped left/up at screen
    /// edges so the panel does not cover the pointer, then clamped to `visibleFrame`.
    /// When the panel is larger than the screen, the bottom-left (the pet) stays visible.
    static func runPanelOrigin(cursor: CGPoint, panelSize: CGSize, visibleFrame: CGRect,
                               gap: CGFloat = agentRunCursorGap) -> CGPoint {
        let fitsRight = cursor.x + gap + panelSize.width <= visibleFrame.maxX
        let fitsBelow = cursor.y - gap - panelSize.height >= visibleFrame.minY
        let x = fitsRight ? cursor.x + gap : cursor.x - gap - panelSize.width
        let y = fitsBelow ? cursor.y - gap - panelSize.height : cursor.y + gap
        return CGPoint(x: max(min(x, visibleFrame.maxX - panelSize.width), visibleFrame.minX),
                       y: max(min(y, visibleFrame.maxY - panelSize.height), visibleFrame.minY))
    }

    /// A done runs to the cursor unless the pet is already there for another agent's done.
    static func runsToCursor(phase: FloatingPetRules.RunPhase, motionAllowed: Bool, panelVisible: Bool) -> Bool {
        phase != .away && motionAllowed && panelVisible
    }

    static func shouldBob(working: Bool, motionAllowed: Bool) -> Bool {
        motionAllowed && working
    }

    /// `CAMediaTimingFunction(name: .easeInEaseOut)`: the cubic Bézier (0.42, 0, 0.58, 1) at time fraction `t`.
    static func easeInEaseOut(_ t: Double) -> Double { cubicEase(t, x1: 0.42, x2: 0.58) }

    /// A timing curve with control points (x1, 0) and (x2, 1): the y of the point whose x is `t` (bisection on the curve's
    /// parameter; x grows with it for these curves).
    static func cubicEase(_ t: Double, x1: Double, x2: Double) -> Double {
        let t = min(max(t, 0), 1)
        func coord(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if coord(mid, x1, x2) < t { lo = mid } else { hi = mid }
        }
        return coord((lo + hi) / 2, 0, 1)
    }
}

/// Detects a back-and-forth stroking motion from horizontal mouse samples (the Mac's `PettingDetector`).
struct FloatingPetPetting {
    /// Direction reversals needed within `window` to count as stroking.
    static let requiredReversals = 3
    static let window: TimeInterval = 1.2

    private var direction: CGFloat = 0      // 0 = not moving far enough yet, else -1 / +1
    private var extremeX: CGFloat = 0       // furthest x reached in the current direction
    private var lastTimestamp: TimeInterval?
    private var reversalTimes: [TimeInterval] = []

    mutating func reset() { self = FloatingPetPetting() }

    /// Feed one mouse sample. Returns true when this sample completes a reversal and the
    /// recent wiggle has at least `requiredReversals` of them. Every stroke must travel
    /// `minStroke` points, so jitter and slow drifting never reverse.
    mutating func feed(x: CGFloat, at time: TimeInterval, minStroke: CGFloat) -> Bool {
        guard let last = lastTimestamp, time - last <= Self.window else {
            reset()
            lastTimestamp = time
            extremeX = x
            return false
        }
        lastTimestamp = time
        reversalTimes.removeAll { time - $0 > Self.window }

        if direction == 0 {
            guard abs(x - extremeX) >= minStroke else { return false }
            direction = x > extremeX ? 1 : -1
            extremeX = x
            return false
        }
        if (x - extremeX) * direction > 0 {     // still travelling the same way
            extremeX = x
            return false
        }
        guard (extremeX - x) * direction >= minStroke else { return false }
        direction = -direction
        extremeX = x
        reversalTimes.append(time)
        return reversalTimes.count >= Self.requiredReversals
    }
}

/// The stroke the pet feels (`FloatingPetController.show` sets `PetHostingView.strokeDistance`).
enum FloatingPetStroke {
    /// Minimum horizontal travel (pt) for one stroke; scales with the pet size.
    static func distance(petSize: CGFloat) -> CGFloat { max(10, petSize * 0.15) }
}

/// The hover text (`FloatingPetView.hoverTooltip`).
enum FloatingPetHoverText {
    /// `sulkIdle` > 0 appends how long the companion has been sulking: hours below 48 h, days from there.
    static func hoverTooltip(todayTokens: Int, limitUtilization: Double?,
                             mode: UsageStore.LimitDisplayMode, l: L, sulkIdle: TimeInterval = 0,
                             eventLine: String? = nil, prayers: Int = 0, prayerHatchUsedToday: Bool = false) -> String {
        let usage = TokenFormatter.grouped(todayTokens)
        var base = l.floatingPetHoverTokensOnly(usage)
        if let pct = limitUtilization {
            let percent = TokenFormatter.percent(UsageStore.displayPercent(pct, mode: mode))
            base = l.floatingPetHoverWithLimit(usage, mode == .remaining ? l.percentRemaining(percent) : percent)
        }
        if sulkIdle > 0 {
            let hours = Int(sulkIdle / 3600)
            base += " · " + (hours < 48 ? l.floatingPetHoverSulkHours(hours) : l.floatingPetHoverSulkDays(hours / 24))
        }
        if let eventLine { base += "\n" + eventLine }
        if prayers > 0 { base += "\n" + l.prayerHoverLine(prayers) }
        if prayerHatchUsedToday { base += "\n" + l.prayerHatchUsedToday }
        return base
    }

    /// The callout's chrome (`showHoverCallout`): 11 pt text, 8 pt padding, corner radius 8, a 0.5 pt separator-coloured
    /// border, centred above the pet window 6 pt up.
    static let fontSize: CGFloat = 11, padding: CGFloat = 8, cornerRadius: CGFloat = 8, borderWidth: CGFloat = 0.5, gapAbovePet: CGFloat = 6
}

/// The prayers' 🙏 particles and the egg's wobble (`PrayerBurst`, `PrayerEmojiLayer`, `PrayerEmojiFrame`, the keyframes in
/// `FloatingPetView.body`). Each particle lives `lifetime`; the wobble runs once per prayer: no standing timer.
enum FloatingPetPrayerArt {
    /// A little longer than the 1 s float-and-fade, so a particle is gone only once it is invisible.
    static let lifetime: Duration = .milliseconds(1100)
    /// The float-and-fade (`withAnimation(.easeOut(duration: 1))`).
    static let riseDuration: TimeInterval = 1

    /// Emoji edge for a pet size (clamped so it stays legible at 48 pt and modest at 384 pt).
    static func emojiSize(petSize: CGFloat) -> CGFloat { min(max(petSize * 0.25, 14), 32) }

    /// One particle at `progress` (0 = just spawned, 1 = gone): its centre inside the pet's box (y down from the box top) and
    /// its opacity. The glyph is drawn at 80 % of `emojiSize`.
    static func particle(xFraction: Double, petSize: CGFloat, emojiSize: CGFloat, progress: Double) -> (center: CGPoint, opacity: Double) {
        // Centre x keeps the glyph fully inside [0, petSize]; it rises from the lower middle to the top edge.
        let x = emojiSize / 2 + CGFloat(xFraction) * (petSize - emojiSize)
        let startY = petSize * 0.7
        let endY = emojiSize / 2
        return (CGPoint(x: x, y: startY + (endY - startY) * CGFloat(progress)), 1 - progress)
    }

    /// SwiftUI's `.easeOut` timing (the cubic Bézier (0, 0, 0.58, 1)) at time fraction `t`.
    static func easeOut(_ t: Double) -> Double { FloatingPetAgentMotion.cubicEase(t, x1: 0, x2: 0.58) }

    /// The wobble's keyframes (degrees, seconds): linear from 0 through each.
    static let wobble: [(angle: Double, duration: TimeInterval)] = [(-9, 0.06), (9, 0.10), (-5, 0.08), (0, 0.06)]
    static var wobbleDuration: TimeInterval { wobble.reduce(0) { $0 + $1.duration } }

    /// The wobble's angle (degrees) `elapsed` seconds after a prayer; 0 before and after.
    static func wobbleAngle(at elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        var t = 0.0, from = 0.0
        for frame in wobble {
            if elapsed <= t + frame.duration { return from + (frame.angle - from) * (elapsed - t) / frame.duration }
            t += frame.duration
            from = frame.angle
        }
        return 0
    }
}

/// The heart bubble's pixel art (`HeartBubbleArt`): the Mac's own grid and colours, drawn one 2-DIP cell per character.
enum FloatingPetHeartArt {
    /// Pixel unit in points; an integer so edges stay crisp on 1x and 2x displays.
    static let pixel: CGFloat = 2
    static let rows = [
        "..OOOOOOOOOOOOO..",
        ".OWWWWWWWWWWWWWO.",
        "OWWWWWWWWWWWWWWWO",
        "OWWWWRRRWRRRWWWWO",
        "OWWWRHHRRRRRRWWWO",
        "OWWWRHRRRRRRDWWWO",
        "OWWWRRRRRRRRDWWWO",
        "OWWWWRRRRRRDWWWWO",
        "OWWWWWRRRRDWWWWWO",
        "OWWWWWWRRDWWWWWWO",
        "OWWWWWWWDWWWWWWWO",
        "OWWWWWWWWWWWWWWWO",
        ".OWWWWWWWWWWWWWO.",
        "..OOOOOWWWOOOOO..",
        ".......OWO.......",
        "........O........",
    ]

    static var height: CGFloat { CGFloat(rows.count) * pixel }
    static var width: CGFloat { CGFloat(rows[0].count) * pixel }
    /// How far the tail tip sticks into the sprite's visible top (pt).
    static let tailOverlap: CGFloat = 3

    /// The cell's colour as 0–255 RGB; nil = empty. Same colours in light and dark mode (game style).
    static func rgb(for cell: Character) -> (r: UInt8, g: UInt8, b: UInt8)? {
        switch cell {
        case "O": (0x20, 0x20, 0x20)
        case "W": (0xFF, 0xFF, 0xFF)
        case "R": (0xE0, 0x30, 0x3C)
        case "D": (0xA8, 0x20, 0x2C)
        case "H": (0xFF, 0x9A, 0xA2)
        default: nil
        }
    }

    /// Y of the bubble's top edge from the box top, so its tail tip lands `overlap` below the sprite's visible top
    /// (`SpriteVisibleTop.bubbleTopOffset`). Rounded to whole points.
    static func bubbleTopOffset(visibleTop: CGFloat, bubbleHeight: CGFloat, overlap: CGFloat) -> CGFloat {
        (visibleTop + overlap - bubbleHeight).rounded()
    }
}

/// The speech bubble's and the hearts' entrance (`FloatingPetView`: `.transition(.scale(scale: 0.8, anchor: .bottom)
/// .combined(with: .opacity))` under `.animation(animated ? .spring(response: 0.3, dampingFraction: 0.7) : nil)`, `animated`
/// being Low Power Mode off): from 0.8 of its size at its bottom centre and transparent, to whole on the spring. Leaving is
/// instant (the panel shrinks at the same moment). A bubble that changes its text while it shows does not pop again.
enum FloatingPetPopIn {
    static let response: Double = 0.3, dampingFraction: Double = 0.7
    static let fromScale: CGFloat = 0.8

    /// The spring's progress from 0 to 1 at `t` seconds after it began (at rest at 0; underdamped, so it overshoots a little).
    static func progress(at t: TimeInterval) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response, z = dampingFraction, wd = w0 * (1 - z * z).squareRoot()
        return 1 - exp(-z * w0 * t) * (cos(wd * t) + z * w0 / wd * sin(wd * t))
    }

    /// When the frames may stop: the swing's envelope below 1/1000 of the way.
    static var duration: TimeInterval { log(1000) / (dampingFraction * 2 * Double.pi / response) }

    static func scale(at t: TimeInterval) -> CGFloat { t >= duration ? 1 : fromScale + (1 - fromScale) * CGFloat(progress(at: t)) }
    static func opacity(at t: TimeInterval) -> Double { t >= duration ? 1 : min(1, max(0, progress(at: t))) }
}

/// Where the sprite's visible top is in its box (`SpriteVisibleTop`, read by the hearts): the share of each picture above
/// its first row with an alpha over 16 in the central band (35–65 % of the width; the whole width when the band is empty),
/// the median of those over the animation's frames, and that share of the aspect-fit picture below the box's top.
enum FloatingPetVisibleTop {
    static let alphaThreshold: UInt8 = 16
    static let centralBand: ClosedRange<Double> = 0.35...0.65

    /// `SpriteVisibleTop.inset`.
    static func inset(box: CGFloat, imageSize: CGSize, opaqueTopFraction: CGFloat) -> CGFloat {
        let fit = PopoverSpriteFit.size(for: imageSize, box: box)
        return (box - fit.height) / 2 + min(max(opaqueTopFraction, 0), 1) * fit.height
    }

    /// `SpriteVisibleTop.anchorFraction`: the median frame (the few frames that jump to the canvas top do not drag it).
    static func anchorFraction(of frameFractions: [CGFloat]) -> CGFloat {
        guard !frameFractions.isEmpty else { return 0 }
        return frameFractions.sorted()[frameFractions.count / 2]
    }

    /// `SpriteVisibleTop.scanOpaqueTopFraction` over a bitmap (alpha last, row 0 at the top); 0 when it is empty.
    static func opaqueTopFraction(of bitmap: PlazaBitmap) -> CGFloat {
        let w = bitmap.width, h = bitmap.height
        guard w > 0, h > 0, bitmap.bytes.count >= w * h * 4 else { return 0 }
        let bandStart = Int(Double(w) * centralBand.lowerBound)
        let bandEnd = max(bandStart + 1, Int(Double(w) * centralBand.upperBound))
        func firstOpaqueRow(columns: Range<Int>) -> Int? {
            for row in 0..<h {
                for column in columns where bitmap.bytes[(row * w + column) * 4 + 3] > alphaThreshold {
                    return row
                }
            }
            return nil
        }
        let row = firstOpaqueRow(columns: bandStart..<min(bandEnd, w)) ?? firstOpaqueRow(columns: 0..<w)
        return row.map { CGFloat($0) / CGFloat(h) } ?? 0
    }
}

/// The pet's agent reactions as a value (`FloatingPetController.handleAgentEvent`, `agentDidChange`, `returnHome`,
/// `expireAgentActivity`, `resetAgent`, `petClicked`'s acknowledgement and `sync`'s reset): the window does what the
/// returned effect says, arms one timer at `deadline` and asks `bobs` for the bob.
struct FloatingPetAgentFlow: Equatable {
    private(set) var tracker = AgentActivityTracker()
    private(set) var runPhase: FloatingPetRules.RunPhase = .home

    /// What the window does after a change.
    enum Effect: Equatable {
        /// Run to the cursor (`beginRun` then the 0.6 s move).
        case run
        /// Move back to the home frame; `returned()` when the move ends.
        case returnHome
        /// Show the state as it is (the bubble, the size, the bob).
        case sync
    }

    /// The tracker's next deadline: one timer there, none while idle or waiting.
    var deadline: Date? { tracker.deadline }
    var summary: AgentActivitySummary { tracker.summary }

    func bobs(motionAllowed: Bool) -> Bool { FloatingPetAgentMotion.shouldBob(working: tracker.summary.working, motionAllowed: motionAllowed) }

    /// A URL event (`handleAgentEvent`): dropped (nil) while the pet or the setting is off.
    mutating func handle(_ event: AgentActivityEvent, now: Date, enabled: Bool, motionAllowed: Bool, panelVisible: Bool) -> Effect? {
        guard enabled else { return nil }
        tracker.apply(event, now: now)
        return changed(motionAllowed: motionAllowed, panelVisible: panelVisible)
    }

    /// The timer at `deadline` fired (`expireAgentActivity`): nil when nothing expired yet (re-arm at `deadline`).
    mutating func expire(now: Date, motionAllowed: Bool, panelVisible: Bool) -> Effect? {
        tracker.expire(now: now) ? changed(motionAllowed: motionAllowed, panelVisible: panelVisible) : nil
    }

    /// A click on the pet or the menu's Open (`petClicked`, `openPopover`): answers questions, acknowledges results.
    mutating func acknowledge(motionAllowed: Bool, panelVisible: Bool) -> Effect? {
        tracker.dismissBubble() ? changed(motionAllowed: motionAllowed, panelVisible: panelVisible) : nil
    }

    /// `agentDidChange` and `returnHome`'s choice.
    private mutating func changed(motionAllowed: Bool, panelVisible: Bool) -> Effect {
        if tracker.summary.done != nil {
            return FloatingPetAgentMotion.runsToCursor(phase: runPhase, motionAllowed: motionAllowed, panelVisible: panelVisible) ? .run : .sync
        }
        guard runPhase == .away, panelVisible, motionAllowed else {
            if runPhase == .away { runPhase = .home }
            return .sync
        }
        runPhase = .returning
        return .returnHome
    }

    /// The run began (`beginRun`): away from home until the agents are answered or expire.
    mutating func beganRun() { runPhase = .away }

    /// The move home ended (`returnHome`'s completion): at home only if nothing else moved the pet meanwhile.
    mutating func returned() { if runPhase == .returning { runPhase = .home } }

    /// A drag during a run or a return becomes the new home (`resolveMove`).
    mutating func dragged() { runPhase = FloatingPetRules.resolveMove(phase: runPhase, userDragging: true).phase }

    /// `sync`'s reset: the pet or the setting turned off while agents were tracked or the pet was away.
    mutating func syncReset(enabled: Bool) -> Bool {
        guard !enabled, !tracker.agents.isEmpty || runPhase != .home else { return false }
        tracker.reset()
        runPhase = .home
        return true
    }

    /// `hide`: a hidden pet comes back at home, not where it last ran to.
    mutating func hidden() { runPhase = .home }
}
