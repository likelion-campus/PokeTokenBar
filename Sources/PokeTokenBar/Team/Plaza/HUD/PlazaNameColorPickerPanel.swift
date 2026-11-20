import Foundation
import Observation

/// The name-colour button right of the background toggle and, opened, the palette under it (`PlazaNameColorPicker`, the SwiftUI
/// view, before Track A Task 15): a pill with a dot in the current colour; a click opens twelve swatches in rows of six, a
/// click on one picks it (`("choose", index)`, the palette's index) and the controller closes it. The ring marks the current.
@MainActor final class PlazaNameColorPickerPanel: PlazaPanel {
    let id = PlazaPanelID.nameColorPicker
    let anchor = PlazaPanelAnchor.topLeading
    var onChange: (() -> Void)?
    private let model: PlazaNameColorModel
    private let toggle: PlazaBackgroundTogglePanel
    private var observer: PlazaChangeObserver?
    private var toggleObserver: PlazaChangeObserver?

    /// The hit held down while the mouse is still over it: that button's content is drawn dimmed (`.buttonStyle(.plain)`).
    var interaction = PlazaPanelInteraction() {
        didSet { if Self.held(oldValue) != Self.held(interaction) { onChange?() } }
    }
    static func held(_ i: PlazaPanelInteraction) -> PlazaPanelHit? { i.pressed != nil && i.pressed == i.hovered ? i.pressed : nil }

    static let columns = 6, swatch: CGFloat = 20, cell: CGFloat = 24, cellGap: CGFloat = 4
    private static let dark = PlazaColor(hex: 0x14161F)

    init(model: PlazaNameColorModel, toggle: PlazaBackgroundTogglePanel, background: PlazaBackgroundModel) {
        self.model = model
        self.toggle = toggle
        observer = PlazaChangeObserver(track: { _ = model.current; _ = model.isOpen }, changed: { [weak self] in self?.modelChanged() })
        // The picker sits right of the toggle, whose width follows its text: it moves with it.
        toggleObserver = PlazaChangeObserver(track: { _ = background.isHidden }, changed: { [weak self] in self?.modelChanged() })
        self.background = background
    }

    private weak var background: PlazaBackgroundModel?
    private var rendered: String?
    private var state: String { "\(model.current) \(model.isOpen) \(background?.isHidden ?? false)" }
    private func modelChanged() { if rendered != state { onChange?() } }

    var isVisible: Bool { true }
    var offset: CGPoint { CGPoint(x: 0, y: PlazaControlStyle.margin - PlazaPanelStyle.strokeRoom) }

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint {
        let host = toggle.layout(scale: scale, text: text).host
        return CGPoint(x: PlazaControlStyle.margin + host.width + PlazaControlStyle.pickerGap - PlazaPanelStyle.strokeRoom, y: offset.y)
    }

    struct Layout {
        let size: CGSize, button: CGRect, line: PlazaTextLine, grid: CGRect?, isOpen: Bool
    }

    private var cache: (key: String, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let open = model.isOpen
        let key = "\(open) \(scale) \(String(describing: type(of: text)))"
        if let cache, cache.key == key { return cache.layout }
        let style = PlazaControlStyle.pill
        let line = text.line(L(.ko).plazaNameColor, font: style.font)
        let button = CGRect(x: 0, y: 0, width: 16 + 12 + 6 + PlazaPanelStyle.pixelUp(line.width, scale: scale),
                            height: 10 + PlazaControlStyle.lineHeight(text))
        var size = button.size
        var grid: CGRect?
        if open {
            let rows = (PlazaNameColor.hexes.count + Self.columns - 1) / Self.columns
            let g = CGSize(width: 16 + CGFloat(Self.columns) * Self.cell + CGFloat(Self.columns - 1) * Self.cellGap,
                           height: 16 + CGFloat(rows) * Self.cell + CGFloat(rows - 1) * Self.cellGap)
            grid = CGRect(x: 0, y: button.maxY + 6, width: g.width, height: g.height)
            size = CGSize(width: max(size.width, g.width), height: grid!.maxY)
        }
        let result = Layout(size: size, button: button, line: line, grid: grid, isOpen: open)
        cache = (key, result)
        return result
    }

    private func host(_ l: Layout) -> CGSize { CGSize(width: l.size.width.rounded(.up), height: l.size.height.rounded(.up)) }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        PlazaPanelSpace(content: host(layout(scale: scale, text: text))).size
    }

    private func swatchRect(_ i: Int, grid: CGRect) -> CGRect {
        CGRect(x: grid.minX + 8 + CGFloat(i % Self.columns) * (Self.cell + Self.cellGap),
               y: grid.minY + 8 + CGFloat(i / Self.columns) * (Self.cell + Self.cellGap), width: Self.cell, height: Self.cell)
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        let l = layout(scale: scale, text: graphics.text)
        let space = PlazaPanelSpace(content: host(l))
        let style = PlazaControlStyle.pill
        let m = graphics.text.metrics(style.font)
        let current = model.current
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            let held = Self.held(interaction)
            canvas.saveState()
            if held?.action == "toggle" { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
            let b = space.canvas(l.button)
            canvas.setFillColor(style.fill)
            canvas.fillRoundedRect(b, radius: style.cornerRadius)
            let dot = space.canvas(CGRect(x: 8, y: l.button.midY - 6, width: 12, height: 12))
            canvas.setFillColor(PlazaColor(hex: current))
            canvas.fillEllipse(in: dot)
            canvas.setStrokeColor(Self.dark)
            canvas.strokeEllipse(in: dot, lineWidth: 1.5)
            canvas.setFillColor(style.text)
            canvas.draw(l.line, at: space.canvas(PlazaControlStyle.snapped(CGPoint(x: 8 + 12 + 6, y: 5 + m.ascender), scale: scale)))
            canvas.setStrokeColor(style.stroke)
            canvas.strokeRoundedRect(b, radius: style.cornerRadius, lineWidth: style.lineWidth)
            canvas.restoreState()
            if let grid = l.grid {
                let g = space.canvas(grid)
                canvas.setFillColor(style.fill)
                canvas.fillRoundedRect(g, radius: style.cornerRadius)
                for (i, hex) in PlazaNameColor.hexes.enumerated() {
                    let cell = swatchRect(i, grid: grid)
                    let c = space.canvas(CGRect(x: cell.minX + 2, y: cell.minY + 2, width: Self.swatch, height: Self.swatch))
                    canvas.saveState()
                    if held == PlazaPanelHit(action: "choose", index: i) { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
                    canvas.setFillColor(PlazaColor(hex: hex))
                    canvas.fillEllipse(in: c)
                    canvas.setStrokeColor(Self.dark)
                    canvas.strokeEllipse(in: c, lineWidth: 1.5)
                    if hex == current {
                        canvas.setStrokeColor(.white)
                        canvas.strokeEllipse(in: space.canvas(cell), lineWidth: 2)
                    }
                    canvas.restoreState()
                }
                canvas.setStrokeColor(style.stroke)
                canvas.strokeRoundedRect(g, radius: style.cornerRadius, lineWidth: style.lineWidth)
            }
        }
        var items = [PlazaAccessibilityItem(frame: space.panel(l.button), role: .button, label: L(.ko).plazaNameColor,
                                            action: PlazaPanelHit(action: "toggle", index: nil))]
        if let grid = l.grid {
            for i in PlazaNameColor.hexes.indices {
                items.append(PlazaAccessibilityItem(frame: space.panel(swatchRect(i, grid: grid)), role: .button,
                                                    label: L(.ko).plazaNameColorChoice(i + 1), action: PlazaPanelHit(action: "choose", index: i)))
            }
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: items)
    }

    /// The pill (padding included) toggles; a swatch is a circle in its 24-point cell. The gaps between swatches and the
    /// palette's background are not buttons.
    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let l = cache?.layout else { return nil }
        let space = PlazaPanelSpace(content: host(l))
        if space.panel(l.button).contains(point) { return PlazaPanelHit(action: "toggle", index: nil) }
        guard let grid = l.grid else { return nil }
        for i in PlazaNameColor.hexes.indices {
            let c = space.panel(swatchRect(i, grid: grid))
            // The label is a `Circle` fill (20 pt) with its 1.5 stroke overlay, then `.padding(2)` (no `contentShape`, so the
            // padding is not clickable) and, for the current colour, the 2-pt white ring: the circle out to the stroke's outer
            // edge, out to the ring's for the current one (PlazaChatLogView.swift, the picker's `ForEach`, before Task 15).
            let radius: CGFloat = PlazaNameColor.hexes[i] == model.current ? Self.cell / 2 + 1 : Self.swatch / 2 + 0.75
            if hypot(point.x - c.midX, point.y - c.midY) <= radius { return PlazaPanelHit(action: "choose", index: i) }
        }
        return nil
    }
}
