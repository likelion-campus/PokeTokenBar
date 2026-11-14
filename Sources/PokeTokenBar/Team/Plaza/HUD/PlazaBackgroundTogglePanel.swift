import Foundation
import Observation

/// What the SwiftUI controls at the window's top left looked like and where they sat (`PlazaChatLogView.swift`'s toggle and
/// picker, `PlazaShortcutGuideView.swift`, before Track A Task 15): one pill look, and the placement of the three in a stack.
enum PlazaControlStyle {
    /// The toggle's, picker's and guide's pill look is the clock's: fill, stroke, corner radius, text colour and font.
    static var pill: PlazaPanelStyle.Pill { PlazaPanelStyle.clock }
    static let margin = PlazaRosterMetrics.margin
    /// The guide sits this far under the toggle's host, the picker this far right of it.
    static let guideGap: CGFloat = 6, pickerGap: CGFloat = 8

    /// The text's height in a one-line row: the font's ascender − descender, rounded (SwiftUI's `Text`).
    static func lineHeight(_ text: any PlazaTextEngine) -> CGFloat {
        let m = text.metrics(pill.font)
        return (m.ascender - m.descender).rounded()
    }

    /// `r` (content points) with its edges on the device-pixel grid: SwiftUI draws a pill's fill and stroke on whole device
    /// pixels, though the pill sits at a fraction of a point inside its hosting view.
    static func snapped(_ r: CGRect, scale: CGFloat) -> CGRect {
        let x0 = PlazaPanelStyle.pixel(r.minX, scale: scale), y0 = PlazaPanelStyle.pixel(r.minY, scale: scale)
        return CGRect(x: x0, y: y0, width: PlazaPanelStyle.pixel(r.maxX, scale: scale) - x0, height: PlazaPanelStyle.pixel(r.maxY, scale: scale) - y0)
    }

    /// `points` as a canvas path (the panel's content points -> canvas, y flipped).
    static func canvasPath(_ points: [CGPoint], closed: Bool = false, in space: PlazaPanelSpace, origin: CGPoint = .zero) -> PlazaPath {
        PlazaPath(points: points.map { space.canvas(CGPoint(x: $0.x + origin.x, y: $0.y + origin.y)) }, closed: closed)
    }

    /// A chevron (SF Symbols `chevron.right` / `chevron.down`, 9 pt bold, as measured): the polyline's points.
    static func chevron(folded: Bool, at x: CGFloat, centreY: CGFloat) -> [CGPoint] {
        folded ? [CGPoint(x: x + 2.5, y: centreY - 3.25), CGPoint(x: x + 5.75, y: centreY), CGPoint(x: x + 2.5, y: centreY + 3.25)]
               : [CGPoint(x: x + 1.75, y: centreY - 2.25), CGPoint(x: x + 5.25, y: centreY + 1.25), CGPoint(x: x + 8.75, y: centreY - 2.25)]
    }

    /// A text origin on the device-pixel grid (SwiftUI places a `Text` on whole device pixels).
    static func snapped(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: PlazaPanelStyle.pixel(p.x, scale: scale), y: PlazaPanelStyle.pixel(p.y, scale: scale))
    }
}

/// The eye button at the window's top left that hides or shows the plaza's map and background (`PlazaBackgroundToggle`
/// before Track A Task 15): an eye icon (`eye.slash` while the background shows, `eye` while it is hidden) and the text.
/// A click anywhere on the pill toggles; the controller keeps the keys with the scene.
@MainActor final class PlazaBackgroundTogglePanel: PlazaPanel {
    let id = PlazaPanelID.backgroundToggle
    let anchor = PlazaPanelAnchor.topLeading
    var offset: CGPoint { CGPoint(x: PlazaControlStyle.margin - PlazaPanelStyle.strokeRoom, y: PlazaControlStyle.margin - PlazaPanelStyle.strokeRoom) }
    var onChange: (() -> Void)?
    private let model: PlazaBackgroundModel
    private var observer: PlazaChangeObserver?

    /// The icon's advance plus its gap to the text (measured from `Label(…, systemImage:)` in Galmuri 12).
    static let iconSlot: CGFloat = 26.625
    /// `eye.slash` is taller than the text line, `eye` is not (measured): the row's height and the text's drop.
    static let slashExtra: CGFloat = 0.875

    init(model: PlazaBackgroundModel) {
        self.model = model
        observer = PlazaChangeObserver(track: { _ = model.isHidden }, changed: { [weak self] in self?.modelChanged() })
    }

    /// What the last render showed: a model write that changes nothing since (the controller sets what the window already
    /// shows when it opens) is not reported.
    private var rendered: Bool?
    private func modelChanged() { if rendered != model.isHidden { onChange?() } }

    var isVisible: Bool { true }

    struct Layout {
        let content: CGSize     // the pill, as SwiftUI sized it (fractional)
        let host: CGSize        // what the hosting view was: whole points, one taller (measured)
        let line: PlazaTextLine
        let title: String
        var origin: CGPoint { CGPoint(x: (host.width - content.width) / 2, y: (host.height - content.height) / 2) }
    }

    private var cache: (key: String, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let hidden = model.isHidden
        let key = "\(hidden) \(scale) \(String(describing: type(of: text)))"
        if let cache, cache.key == key { return cache.layout }
        let title = hidden ? L(.ko).plazaBackgroundShow : L(.ko).plazaBackgroundHide
        let line = text.line(title, font: PlazaControlStyle.pill.font)
        let height = PlazaControlStyle.lineHeight(text) + (hidden ? 0 : Self.slashExtra)
        let content = CGSize(width: 16 + Self.iconSlot + PlazaPanelStyle.pixelUp(line.width, scale: scale), height: 10 + height)
        let result = Layout(content: content, host: CGSize(width: content.width.rounded(.up), height: content.height.rounded(.up) + 1),
                            line: line, title: title)
        cache = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        PlazaPanelSpace(content: layout(scale: scale, text: text).host).size
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = model.isHidden
        let l = layout(scale: scale, text: graphics.text)
        let space = PlazaPanelSpace(content: l.host)
        let o = l.origin
        let style = PlazaControlStyle.pill
        let m = graphics.text.metrics(style.font)
        let hidden = model.isHidden
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            let r = space.canvas(PlazaControlStyle.snapped(CGRect(origin: o, size: l.content), scale: scale))
            canvas.setFillColor(style.fill)
            canvas.fillRoundedRect(r, radius: style.cornerRadius)
            canvas.setFillColor(style.text)
            let top = 5 + (hidden ? 0 : Self.slashExtra)
            canvas.draw(l.line, at: space.canvas(PlazaControlStyle.snapped(CGPoint(x: o.x + 8 + Self.iconSlot, y: o.y + top + m.ascender), scale: scale)))
            Self.drawEye(on: canvas, space: space, origin: o, slash: !hidden, style: style)
            canvas.setStrokeColor(style.stroke)
            canvas.strokeRoundedRect(r, radius: style.cornerRadius, lineWidth: style.lineWidth)
        }
        let item = PlazaAccessibilityItem(frame: space.panel(CGRect(origin: o, size: l.content)), role: .button, label: l.title,
                                          action: PlazaPanelHit(action: "toggle", index: nil))
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: [item])
    }

    /// `eye` / `eye.slash` as chrome: an almond outline, an iris ring and a pupil, and for the slash a diagonal with a
    /// gap in the pill's colour, in the ink boxes the SF Symbols measured (x 9.25–25.25; y 6.4–16.4, slash 6.9–17.5).
    private static func drawEye(on canvas: any PlazaCanvas, space: PlazaPanelSpace, origin o: CGPoint, slash: Bool, style: PlazaPanelStyle.Pill) {
        let cx: CGFloat = 17.25, cy: CGFloat = slash ? 11.9 : 11.375
        let a: CGFloat = 7.6, h: CGFloat = 4.5
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in 0...16 {
            let x = -a + 2 * a * CGFloat(i) / 16
            let y = h * (1 - (x / a) * (x / a))
            top.append(CGPoint(x: cx + x, y: cy - y))
            bottom.append(CGPoint(x: cx + x, y: cy + y))
        }
        canvas.setStrokeColor(style.text)
        canvas.setFillColor(style.text)
        canvas.setLineJoin(.round)
        canvas.strokePath(PlazaControlStyle.canvasPath(top + bottom.reversed(), closed: true, in: space, origin: o), lineWidth: 1.3, cap: .round)
        let c = space.canvas(CGPoint(x: cx + o.x, y: cy + o.y))
        canvas.strokeEllipse(in: CGRect(x: c.x - 2.8, y: c.y - 2.8, width: 5.6, height: 5.6), lineWidth: 1.2)
        canvas.fillEllipse(in: CGRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6))
        if slash {
            let line = PlazaControlStyle.canvasPath([CGPoint(x: 10.8, y: 7.4), CGPoint(x: 23.7, y: 17.2)], in: space, origin: o)
            canvas.setStrokeColor(style.fill)
            canvas.strokePath(line, lineWidth: 2.8, cap: .butt)
            canvas.setStrokeColor(style.text)
            canvas.strokePath(line, lineWidth: 1.3, cap: .round)
        }
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        // The pill, padding included (the button's label carried its padding and background).
        guard let l = cache?.layout else { return nil }
        let r = PlazaPanelSpace(content: l.host).panel(CGRect(origin: l.origin, size: l.content))
        return r.contains(point) ? PlazaPanelHit(action: "toggle", index: nil) : nil
    }
}
