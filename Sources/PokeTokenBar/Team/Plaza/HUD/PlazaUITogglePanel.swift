import Foundation
import Observation

/// The button that hides or shows all of the plaza's panels at once (the roster, chat log, minimap and so on; see
/// `PlazaPanelID.hiddenWithUI`): the background toggle's pill and eye (`eye.slash` while the UI shows, `eye` while it is hidden).
/// While the UI is hidden this is the only panel of the top-left row left. A click anywhere on the pill toggles.
@MainActor final class PlazaUITogglePanel: PlazaPanel {
    let id = PlazaPanelID.uiToggle
    let anchor = PlazaPanelAnchor.topLeading
    var offset: CGPoint { CGPoint(x: 0, y: PlazaControlStyle.margin - PlazaPanelStyle.strokeRoom) }
    var onChange: (() -> Void)?
    private let model: PlazaUIModel
    private let toggle: PlazaBackgroundTogglePanel
    private let picker: PlazaNameColorPickerPanel
    private weak var background: PlazaBackgroundModel?
    private var observer: PlazaChangeObserver?
    private var toggleObserver: PlazaChangeObserver?

    /// Pressed (mouse down on the pill and still over it): the pill is drawn dimmed.
    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaBackgroundTogglePanel.isPressed(oldValue) != PlazaBackgroundTogglePanel.isPressed(interaction) { onChange?() } }
    }

    init(model: PlazaUIModel, toggle: PlazaBackgroundTogglePanel, picker: PlazaNameColorPickerPanel, background: PlazaBackgroundModel) {
        self.model = model
        self.toggle = toggle
        self.picker = picker
        self.background = background
        observer = PlazaChangeObserver(track: { _ = model.isHidden }, changed: { [weak self] in self?.modelChanged() })
        // The button sits right of the picker, which sits right of the background toggle, whose width follows its text: it moves with it.
        toggleObserver = PlazaChangeObserver(track: { _ = background.isHidden }, changed: { [weak self] in self?.modelChanged() })
    }

    private var rendered: String?
    private var state: String { "\(model.isHidden) \(background?.isHidden ?? false)" }
    private func modelChanged() { if rendered != state { onChange?() } }

    var isVisible: Bool { true }

    /// Where the button sits: the single place to change. Right of the name-colour pill, the gap the picker keeps to the toggle.
    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint {
        let toggleHost = toggle.layout(scale: scale, text: text).host
        let pickerButton = picker.layout(scale: scale, text: text).button
        let x = PlazaControlStyle.margin + toggleHost.width + PlazaControlStyle.pickerGap + pickerButton.width.rounded(.up) + PlazaControlStyle.pickerGap
        return CGPoint(x: x - PlazaPanelStyle.strokeRoom, y: offset.y)
    }

    struct Layout {
        let content: CGSize     // the pill (fractional)
        let host: CGSize        // whole points, one taller (as the background toggle's)
        let line: PlazaTextLine
        let title: String
        var origin: CGPoint { CGPoint(x: (host.width - content.width) / 2, y: (host.height - content.height) / 2) }
    }

    private var cache: (key: String, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let hidden = model.isHidden
        let key = "\(hidden) \(scale) \(String(describing: type(of: text)))"
        if let cache, cache.key == key { return cache.layout }
        let title = hidden ? L(.ko).plazaUIShow : L(.ko).plazaUIHide
        let line = text.line(title, font: PlazaControlStyle.pill.font)
        let height = PlazaControlStyle.lineHeight(text) + (hidden ? 0 : PlazaBackgroundTogglePanel.slashExtra)
        let content = CGSize(width: 16 + PlazaBackgroundTogglePanel.iconSlot + PlazaPanelStyle.pixelUp(line.width, scale: scale), height: 10 + height)
        let result = Layout(content: content, host: CGSize(width: content.width.rounded(.up), height: content.height.rounded(.up) + 1),
                            line: line, title: title)
        cache = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        PlazaPanelSpace(content: layout(scale: scale, text: text).host).size
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        let l = layout(scale: scale, text: graphics.text)
        let space = PlazaPanelSpace(content: l.host)
        let o = l.origin
        let style = PlazaControlStyle.pill
        let m = graphics.text.metrics(style.font)
        let hidden = model.isHidden
        let symbol = PlatformPlaza.symbolImage(named: hidden ? "eye" : "eye.slash", pointSize: 12, weight: .regular, scale: scale, color: style.text)
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            canvas.saveState()
            if PlazaBackgroundTogglePanel.isPressed(interaction) { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
            let r = space.canvas(PlazaControlStyle.snapped(CGRect(origin: o, size: l.content), scale: scale))
            canvas.setFillColor(style.fill)
            canvas.fillRoundedRect(r, radius: style.cornerRadius)
            canvas.setFillColor(style.text)
            let top = 5 + (hidden ? 0 : PlazaBackgroundTogglePanel.slashExtra)
            let textX = o.x + 8 + PlazaBackgroundTogglePanel.iconSlot
            canvas.draw(l.line, at: space.canvas(PlazaControlStyle.snapped(CGPoint(x: textX, y: o.y + top + m.ascender), scale: scale)))
            if let symbol {
                canvas.draw(symbol.image, in: space.canvas(CGRect(x: o.x + 8.6, y: o.y + 4.75, width: symbol.size.width, height: symbol.size.height)))
            } else {
                PlazaBackgroundTogglePanel.drawEye(on: canvas, space: space, origin: o, slash: !hidden, style: style)
            }
            canvas.setStrokeColor(style.stroke)
            canvas.strokeRoundedRect(r, radius: style.cornerRadius, lineWidth: style.lineWidth)
            canvas.restoreState()
        }
        let item = PlazaAccessibilityItem(frame: space.panel(CGRect(origin: o, size: l.content)), role: .button, label: l.title,
                                          action: PlazaPanelHit(action: "toggle", index: nil))
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: [item])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let l = cache?.layout else { return nil }
        let r = PlazaPanelSpace(content: l.host).panel(CGRect(origin: l.origin, size: l.content))
        return r.contains(point) ? PlazaPanelHit(action: "toggle", index: nil) : nil
    }
}
