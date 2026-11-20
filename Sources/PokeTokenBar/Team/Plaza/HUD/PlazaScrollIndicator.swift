import Foundation

/// The scroll indicator of a scrolling panel (the chat log, the board, the card): what a SwiftUI `ScrollView` showed on the
/// Mac with the system's overlay scrollers. A thin rounded thumb on the trailing edge of the scrolling window, drawn over the
/// content (it takes no width). It appears when the content scrolls and stays for `holdSeconds`, then fades out over
/// `fadeSeconds`; with the system setting "Always show scroll bars" (`alwaysVisible`) it stays, still without narrowing the
/// content. Its length is the window's share of the content (not under `minLength`), its place follows the offset, and it is
/// absent while the content fits.
///
/// The thumb is one solid middle layer and two cached cap images (the rounded ends: a handful of tiny bitmaps per backing
/// scale and fade step, never one per scroll step). Time: a one-shot `hold` timer after the last scroll, then a `fade`
/// timer that beats `fadeBeat` apart; both exist only for that second or so after a scroll, so an idle or hidden plaza has no
/// timer. Each fade beat is one render of the panel (`onChange`).
@MainActor final class PlazaScrollIndicator {
    static let width: CGFloat = 7
    /// From the window's trailing edge.
    static let inset: CGFloat = 2
    static let minLength: CGFloat = 24
    static let holdSeconds: TimeInterval = 0.7
    static let fadeSeconds: TimeInterval = 0.4
    static let fadeBeat: TimeInterval = 1.0 / 30
    /// The thumb's alpha at full strength: the system's knob is half transparent.
    static let strength: Double = 0.5

    var onChange: (() -> Void)?
    /// The legacy scroller's width (`NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)`; measured against the SwiftUI chat log: its
    /// content became 323 points wide where 340 had been, the scroller sat at x = 323, 17 wide, full height).
    static let legacyWidth: CGFloat = 17
    /// How much width a scrolling window gives to the scroller while the content overflows: the legacy scroller's, in "always show" mode.
    var reservedWidth: CGFloat { alwaysVisible ? Self.legacyWidth : 0 }

    /// "Always show scroll bars": the thumb stays (a scrolling panel renders again when this changes).
    var alwaysVisible = false { didSet { if alwaysVisible != oldValue { reset(); onChange?() } } }
    /// The window's dark appearance: the knob is light instead of dark (as `NSScroller`'s default knob style).
    var isDark = false { didSet { if isDark != oldValue { onChange?() } } }
    /// Tests that compare a panel with its SwiftUI original (which drew no scroller off screen) turn the thumb off.
    var isDisabled = false
    private(set) var opacity: CGFloat = 0

    private let hold: PlazaAnimationClock
    private let fade: PlazaAnimationClock
    var isTimerRunning: Bool { hold.isRunning || fade.isRunning }

    init(schedule: ((TimeInterval, @escaping @MainActor () -> Bool) -> PlazaAnimationClock.Stop)? = nil) {
        hold = PlazaAnimationClock(interval: Self.holdSeconds, schedule: schedule)
        fade = PlazaAnimationClock(interval: Self.fadeBeat, schedule: schedule)
        hold.onTick = { [weak self] in
            guard let self else { return }
            hold.setRunning(false)
            fade.setRunning(true)
        }
        fade.onTick = { [weak self] in
            guard let self else { return }
            let left = 1 - CGFloat(fade.beats) * CGFloat(Self.fadeBeat / Self.fadeSeconds)
            opacity = max(0, left)
            if left <= 0 { fade.setRunning(false) }
            onChange?()
        }
    }

    /// The content scrolled (the panel renders by itself right after): full strength again, the pause starts over.
    func scrolled() {
        guard !alwaysVisible, !isDisabled else { return }
        fade.setRunning(false)
        hold.setRunning(false)
        opacity = 1
        hold.setRunning(true)
    }

    /// Nothing shows and nothing runs (the panel closed).
    func reset() {
        hold.setRunning(false)
        fade.setRunning(false)
        opacity = 0
    }

    // MARK: the legacy scroller as a control ("always show scroll bars")

    /// `AppleScrollerPagingBehavior`: 0 (the default) a click in the track pages by one viewport toward the click; 1 jumps to the spot clicked.
    /// Read from the global preferences when the mouse goes down (`UserDefaults.standard` searches the global domain).
    var pagingBehavior: () -> Int = { UserDefaults.standard.integer(forKey: "AppleScrollerPagingBehavior") }
    /// While the knob is held: how far below the knob's top the press was, and what the offset and the pointer were at the press.
    private var grab: (inside: CGFloat, y: CGFloat, offset: CGFloat)?
    var isDragging: Bool { grab != nil }

    /// The legacy scroller's track (the full-height strip at the window's trailing edge) holds `point`.
    func tracks(_ point: CGPoint, state: PlazaScrollState, viewport: CGRect) -> Bool {
        alwaysVisible && state.canScroll && CGRect(x: viewport.maxX - Self.legacyWidth, y: viewport.minY, width: Self.legacyWidth, height: viewport.height).contains(point)
    }

    /// Mouse down in the track: on the knob it is picked up (dragging follows); above or below it the content pages one viewport that way, or,
    /// with the "jump to the spot that's clicked" preference, the knob jumps to the click. True when the offset moved.
    func scrollerDown(at point: CGPoint, state: inout PlazaScrollState, viewport: CGRect, scale: CGFloat) -> Bool {
        guard let knob = thumb(state: state, offset: state.offset, viewport: viewport, scale: scale) else { return false }
        if point.y >= knob.minY && point.y <= knob.maxY {
            grab = (point.y - knob.minY, point.y, state.offset)
            return false
        }
        let travel = viewport.height - knob.height
        if pagingBehavior() == 1, travel > 0 {
            let fraction = min(max((point.y - viewport.minY - knob.height / 2) / travel, 0), 1)
            return state.scrollTo(offset: fraction * state.maxOffset)
        }
        return state.scrollTo(offset: state.offset + (point.y < knob.minY ? -viewport.height : viewport.height))
    }

    /// The knob follows the pointer in proportion (the knob's travel is the content's range), wherever the pointer is, even outside the track.
    func scrollerDrag(to point: CGPoint, state: inout PlazaScrollState, viewport: CGRect, scale: CGFloat) -> Bool {
        guard let grab, let knob = thumb(state: state, offset: state.offset, viewport: viewport, scale: scale) else { return false }
        let travel = viewport.height - knob.height
        guard travel > 0 else { return false }
        return state.scrollTo(offset: grab.offset + (point.y - grab.y) / travel * state.maxOffset)
    }

    func scrollerUp() { grab = nil }

    /// The thumb's rectangle in the window's coordinates (`viewport`: the scrolling window in panel points, `offset` the
    /// drawn offset), on whole device pixels; nil while the content fits.
    func thumb(state: PlazaScrollState, offset: CGFloat, viewport: CGRect, scale: CGFloat) -> CGRect? {
        guard state.canScroll, state.content > 0 else { return nil }
        let length = min(viewport.height, max(Self.minLength, viewport.height * state.viewport / state.content))
        let travel = viewport.height - length
        let y = PlazaPanelStyle.pixel(travel * min(max(offset / state.maxOffset, 0), 1), scale: scale)
        let x = alwaysVisible ? viewport.maxX - Self.legacyWidth + (Self.legacyWidth - Self.width) / 2 : viewport.maxX - Self.inset - Self.width
        return CGRect(x: x, y: viewport.minY + y, width: Self.width, height: length)
    }

    private struct CapKey: Hashable { let step: Int, dark: Bool, scale: CGFloat }
    private var caps: [CapKey: (top: PlazaImage, bottom: PlazaImage)] = [:]

    /// The thumb's layers (none while hidden, faded out or when the content fits).
    func layers(state: PlazaScrollState, offset: CGFloat, viewport: CGRect, scale: CGFloat, graphics: any PlazaGraphics) -> [PlazaPanelLayer] {
        let a = alwaysVisible ? 1 : opacity
        guard !isDisabled, a > 0.01, let r = thumb(state: state, offset: offset, viewport: viewport, scale: scale) else { return [] }
        let step = Int((a * 12).rounded())
        guard step > 0 else { return [] }
        let key = CapKey(step: step, dark: isDark, scale: scale)
        if caps[key] == nil {
            if caps.count > 40 { caps = [:] }
            let w = Int((Self.width * scale).rounded()), h = Int((2 * Self.cap * scale).rounded())
            guard let canvas = graphics.makeCanvas(width: w, height: h, colorSpace: .sRGB) else { return [] }
            canvas.scale(x: scale, y: scale)
            // The system's knob has a light edge (a dark one in the dark appearance): an outer pill and the knob inside it, so it shows on
            // a dark plate as well as a light one.
            canvas.setFillColor(edgeColor(step: step))
            canvas.fillRoundedRect(CGRect(x: 0, y: 0, width: Self.width, height: 2 * Self.cap), radius: Self.width / 2)
            canvas.setFillColor(tintColor(step: step))
            canvas.fillRoundedRect(CGRect(x: Self.edge, y: Self.edge, width: Self.width - 2 * Self.edge, height: 2 * Self.cap - 2 * Self.edge),
                                   radius: (Self.width - 2 * Self.edge) / 2)
            guard let pill = canvas.makeImage(),
                  let top = pill.cropping(to: PlazaPixelRect(x: 0, y: 0, width: w, height: h / 2)),
                  let bottom = pill.cropping(to: PlazaPixelRect(x: 0, y: h / 2, width: w, height: h / 2)) else { return [] }
            caps[key] = (top, bottom)
        }
        guard let pair = caps[key] else { return [] }
        let tint = tintColor(step: step), edge = edgeColor(step: step)
        var track: [PlazaPanelLayer] = []
        if alwaysVisible {   // the legacy scroller's track: a strip the full height at the window's trailing edge, with a line on its left
            let v: Double = isDark ? 1 : 0
            let strip = CGRect(x: viewport.maxX - Self.legacyWidth, y: viewport.minY, width: Self.legacyWidth, height: viewport.height)
            track = [.color(PlazaColor(srgbRed: v, green: v, blue: v, alpha: isDark ? 0.09 : 0.06), frame: strip),
                     .color(PlazaColor(srgbRed: v, green: v, blue: v, alpha: isDark ? 0.18 : 0.12), frame: CGRect(x: strip.minX, y: strip.minY, width: 1, height: strip.height))]
        }
        let middle = CGRect(x: r.minX, y: r.minY + Self.cap, width: r.width, height: r.height - 2 * Self.cap)
        return track + [
            .image(pair.top, frame: CGRect(x: r.minX, y: r.minY, width: r.width, height: Self.cap)),
            .color(edge, frame: CGRect(x: middle.minX, y: middle.minY, width: Self.edge, height: middle.height)),
            .color(tint, frame: CGRect(x: middle.minX + Self.edge, y: middle.minY, width: middle.width - 2 * Self.edge, height: middle.height)),
            .color(edge, frame: CGRect(x: middle.maxX - Self.edge, y: middle.minY, width: Self.edge, height: middle.height)),
            .image(pair.bottom, frame: CGRect(x: r.minX, y: r.maxY - Self.cap, width: r.width, height: Self.cap)),
        ]
    }

    /// The height of a rounded end: half the thumb's width, rounded up to a whole point so the ends sit on device pixels.
    static let cap: CGFloat = 4

    /// The knob's edge: light around a dark knob, dark around a light one.
    static let edge: CGFloat = 1
    private func edgeColor(step: Int) -> PlazaColor {
        let v: Double = isDark ? 0 : 1
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: 0.45 * Double(step) / 12)
    }

    private func tintColor(step: Int) -> PlazaColor {
        let v: Double = isDark ? 1 : 0
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: Self.strength * Double(step) / 12)
    }
}

/// A panel that scrolls shows an indicator; the window sets the system's scroller preference and appearance on it.
@MainActor protocol PlazaScrollIndicating: AnyObject {
    var scrollIndicator: PlazaScrollIndicator { get }
}
