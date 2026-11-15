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

    /// The thumb's rectangle in the window's coordinates (`viewport`: the scrolling window in panel points, `offset` the
    /// drawn offset), on whole device pixels; nil while the content fits.
    func thumb(state: PlazaScrollState, offset: CGFloat, viewport: CGRect, scale: CGFloat) -> CGRect? {
        guard state.canScroll, state.content > 0 else { return nil }
        let length = min(viewport.height, max(Self.minLength, viewport.height * state.viewport / state.content))
        let travel = viewport.height - length
        let y = PlazaPanelStyle.pixel(travel * min(max(offset / state.maxOffset, 0), 1), scale: scale)
        return CGRect(x: viewport.maxX - Self.inset - Self.width, y: viewport.minY + y, width: Self.width, height: length)
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
            let tint = tintColor(step: step)
            let w = Int((Self.width * scale).rounded()), h = Int((2 * Self.cap * scale).rounded())
            guard let canvas = graphics.makeCanvas(width: w, height: h, colorSpace: .sRGB) else { return [] }
            canvas.scale(x: scale, y: scale)
            canvas.setFillColor(tint)
            canvas.fillRoundedRect(CGRect(x: 0, y: 0, width: Self.width, height: 2 * Self.cap), radius: Self.width / 2)
            guard let pill = canvas.makeImage(),
                  let top = pill.cropping(to: PlazaPixelRect(x: 0, y: 0, width: w, height: h / 2)),
                  let bottom = pill.cropping(to: PlazaPixelRect(x: 0, y: h / 2, width: w, height: h / 2)) else { return [] }
            caps[key] = (top, bottom)
        }
        guard let pair = caps[key] else { return [] }
        let tint = tintColor(step: step)
        return [
            .image(pair.top, frame: CGRect(x: r.minX, y: r.minY, width: r.width, height: Self.cap)),
            .color(tint, frame: CGRect(x: r.minX, y: r.minY + Self.cap, width: r.width, height: r.height - 2 * Self.cap)),
            .image(pair.bottom, frame: CGRect(x: r.minX, y: r.maxY - Self.cap, width: r.width, height: Self.cap)),
        ]
    }

    /// The height of a rounded end: half the thumb's width, rounded up to a whole point so the ends sit on device pixels.
    static let cap: CGFloat = 4

    private func tintColor(step: Int) -> PlazaColor {
        let v: Double = isDark ? 1 : 0
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: Self.strength * Double(step) / 12)
    }
}

/// A panel that scrolls shows an indicator; the window sets the system's scroller preference and appearance on it.
@MainActor protocol PlazaScrollIndicating: AnyObject {
    var scrollIndicator: PlazaScrollIndicator { get }
}
