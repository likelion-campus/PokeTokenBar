import Foundation
import Observation

/// The photo mode's frame (`PlazaOverlayView.photoFrame` before Track A Task 15): the window dimmed by half outside the area the
/// photo takes (`PlazaPhotoFrame.viewRect(in:)`), white corner brackets, and a one-line guide under the area that shrinks to
/// 70 % when it does not fit (`minimumScaleFactor(0.7)`) and is cut with "…" past that. It takes no clicks. The dim is four
/// colour rectangles around the hole (no window-sized bitmap); the brackets are four small images.
@MainActor final class PlazaPhotoFramePanel: PlazaPanel {
    let id = PlazaPanelID.photoFrame
    let anchor = PlazaPanelAnchor.fill
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let model: PlazaOverlayModel
    private var observer: PlazaChangeObserver?
    static let dim = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
    static let minimumScale: CGFloat = 0.7

    init(model: PlazaOverlayModel) {
        self.model = model
        observer = PlazaChangeObserver(track: { _ = model.isPhotoMode }, changed: { [weak self] in self?.modelChanged() })
    }

    private var rendered: Bool?
    private func modelChanged() { if rendered != model.isPhotoMode { onChange?() } }

    /// Photo mode, and the window big enough for a frame.
    var isVisible: Bool { model.isPhotoMode }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { viewport }

    /// The guide line as drawn: its scale (1 when it fits; down to 0.7), the line (cut when it does not fit even then), and
    /// its width after scaling.
    static func guide(width: CGFloat, text: any PlazaTextEngine) -> (line: PlazaTextLine, scale: CGFloat) {
        let font = PlazaFont.plaza(.body)
        var line = text.line(L(.ko).plazaPhotoGuide, font: font)
        guard line.width > width else { return (line, 1) }
        let scale = max(width / line.width, minimumScale)
        if line.width * scale > width {
            line = text.truncated(line, width: width / scale, ellipsis: text.line("…", font: font)) ?? line
        }
        return (line, scale)
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = model.isPhotoMode
        guard let hole = PlazaPhotoFrame.viewRect(in: viewport) else { return PlazaPanelDrawing() }
        func snap(_ v: CGFloat) -> CGFloat { PlazaPanelStyle.pixel(v, scale: scale) }
        let (l, t, r, b) = (snap(hole.minX), snap(hole.minY), snap(hole.maxX), snap(hole.maxY))
        var layers: [PlazaPanelLayer] = [
            .color(Self.dim, frame: CGRect(x: 0, y: 0, width: viewport.width, height: t)),
            .color(Self.dim, frame: CGRect(x: 0, y: t, width: l, height: b - t)),
            .color(Self.dim, frame: CGRect(x: r, y: t, width: viewport.width - r, height: b - t)),
            .color(Self.dim, frame: CGRect(x: 0, y: b, width: viewport.width, height: viewport.height - b)),
        ]
        // Brackets: an L stroked 3 wide with butt ends and a mitred corner, its centre line half a stroke inside the area.
        let arm = PlazaPhotoFrame.bracketArm, w = PlazaPhotoFrame.bracketWidth
        let box = CGSize(width: arm + w / 2 + 1, height: arm + w / 2 + 1)
        for (cx, cy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let origin = CGPoint(x: cx == 0 ? hole.minX : hole.maxX - box.width, y: cy == 0 ? hole.minY : hole.maxY - box.height)
            let space = PlazaPanelSpace(content: box, room: 0)
            // The corner and the arm ends in the box's own (top-left) coordinates.
            let corner = CGPoint(x: cx == 0 ? w / 2 : box.width - w / 2, y: cy == 0 ? w / 2 : box.height - w / 2)
            let dx: CGFloat = cx == 0 ? 1 : -1, dy: CGFloat = cy == 0 ? 1 : -1
            let path = PlazaControlStyle.canvasPath([CGPoint(x: corner.x, y: corner.y + dy * arm), corner, CGPoint(x: corner.x + dx * arm, y: corner.y)],
                                                    in: space)
            if let image = space.image(scale: scale, graphics: graphics, { canvas in
                canvas.setStrokeColor(.white)
                canvas.setLineJoin(.miter)
                canvas.strokePath(path, lineWidth: w, cap: .butt)
            }) {
                layers.append(.image(image, frame: CGRect(origin: origin, size: box)))
            }
        }
        // The guide: centred in the area's width and the bottom inset, scaled about its centre.
        let text = graphics.text
        let (line, shrink) = Self.guide(width: hole.width, text: text)
        let m = text.metrics(.plaza(.body))
        let lineH = (m.ascender - m.descender).rounded()
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height - PlazaPhotoFrame.bottomInset / 2)
        let drawn = CGSize(width: line.width * shrink, height: lineH * shrink)
        let box2 = PlazaPanelSpace(content: CGSize(width: ceil(drawn.width) + 2, height: ceil(drawn.height) + 2), room: 0)
        let frame = CGRect(x: snap(centre.x - box2.size.width / 2), y: snap(centre.y - box2.size.height / 2),
                           width: box2.size.width, height: box2.size.height)
        if let image = box2.image(scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(.white)
            canvas.translate(x: 0, y: 0)
            canvas.scale(x: shrink, y: shrink)
            // Baseline of the line in the scaled space: the centred line box, ascender below its top.
            let boxH = box2.size.height / shrink, boxW = box2.size.width / shrink
            canvas.draw(line, at: CGPoint(x: (boxW - line.width) / 2, y: (boxH - lineH) / 2 + (lineH - (m.ascender - m.descender)) / 2 - m.descender))
        }) {
            layers.append(.image(image, frame: frame))
        }
        let item = PlazaAccessibilityItem(frame: frame, role: .staticText, label: L(.ko).plazaPhotoGuide)
        return PlazaPanelDrawing(layers: layers, accessibility: [item])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
