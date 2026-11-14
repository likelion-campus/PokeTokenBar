import Foundation
import Observation

/// The member and campfire menus (`PlazaMemberMenuView` / `PlazaCampfireMenuView`, the SwiftUI views, before Track A Task 16)
/// and the tap-outside area under them. While a menu is open this panel covers the window: a click on a row chooses it
/// (`("choose", row)`), a click on the menu elsewhere does nothing, a click anywhere else cancels (`("cancel")`). The window
/// puts its host below the guide, toggles, chat log and minimap (a click on them reaches them) and above the scene and the
/// roster. The keys (arrows, Space/Enter, Esc) go through the scene as before; the panel only follows `PlazaOverlayModel`.
/// The menu opens centred under the pills, 8 points below them (14 from the top when there are none), `PlazaMenuText.width`
/// wide and as wide as its longest line when that is more.
@MainActor final class PlazaMenuPanel: PlazaPanel {
    let id = PlazaPanelID.menu
    let anchor = PlazaPanelAnchor.fill
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let model: PlazaOverlayModel
    private let pills: PlazaPillsPanel
    private var observer: PlazaChangeObserver?

    static let padding = PlazaRosterMetrics.padding + 2, lineGap: CGFloat = 4, markerGap: CGFloat = 6
    private static let gold = PlazaColor(hex: 0xF2C14E)

    init(model: PlazaOverlayModel, pills: PlazaPillsPanel) {
        self.model = model
        self.pills = pills
        // The pills' stack sets where the menu opens, so what the pills show is read as well.
        observer = PlazaChangeObserver(track: { _ = model.content; _ = model.countdown; _ = model.banner; _ = model.hint },
                                       changed: { [weak self] in self?.modelChanged() })
    }

    private var rendered: String?
    private var state: String { "\(model.content) \(model.countdown ?? "") \(model.banner ?? "") \(model.hint ?? "")" }
    private func modelChanged() { if rendered != state { onChange?() } }

    /// Pressed on a row: the row (marker and title) is drawn dimmed while the mouse is over it.
    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaNameColorPickerPanel.held(oldValue) != PlazaNameColorPickerPanel.held(interaction) { onChange?() } }
    }

    var isVisible: Bool {
        switch model.content {
        case .memberMenu, .campfireMenu: true
        default: false
        }
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { viewport }

    private struct Line {
        enum Kind { case name, status, notice, title, row(Int) }
        let kind: Kind
        let text: String
        let line: PlazaTextLine
        let color: PlazaColor
        let shadow: Bool
        let marked: Bool          // a row whose ▶ shows
        let width: CGFloat        // what it asks of the menu
    }

    struct Placed {
        let frame: CGRect          // the menu, in window points (top-left)
        let rows: [CGRect]         // each row's click area, in menu points
        let lines: [(String, String, CGRect)]
    }

    private var placed: Placed?

    private func lines(text: any PlazaTextEngine, scale: CGFloat) -> [Line] {
        let font = PlazaFont.plaza(.body)
        func make(_ kind: Line.Kind, _ string: String, _ color: PlazaColor, shadow: Bool = false, marked: Bool = false, maxWidth: CGFloat? = nil) -> Line {
            var line = text.line(string, font: font)
            if let maxWidth, line.width > maxWidth { line = text.truncated(line, width: maxWidth, ellipsis: text.line("…", font: font)) ?? line }
            var width = PlazaPanelStyle.pixelUp(line.width, scale: scale)
            if case .row = kind { width += PlazaPanelStyle.pixelUp(text.line("▶", font: font).width, scale: scale) + Self.markerGap }
            return Line(kind: kind, text: string, line: line, color: color, shadow: shadow, marked: marked, width: width)
        }
        switch model.content {
        case .memberMenu(let menu):
            var out = [make(.name, menu.nickname, PlazaNameColor.color(forMemberID: menu.memberID, chosen: menu.nameColor),
                            shadow: true, maxWidth: PlazaMenuText.width - 2 * Self.padding)]
            if let status = menu.status { out.append(make(.status, status, Self.gold)) }
            for (i, action) in menu.actions.enumerated() {
                out.append(make(.row(i), PlazaMenuText.title(action), .white, marked: action == menu.selection))
            }
            return out
        case .campfireMenu(let menu):
            var out = [make(.title, L(.ko).plazaCampfireMenuTitle(isJoin: menu.isJoin), Self.gold, shadow: true)]
            if let notice = PlazaMenuText.notice(menu) { out.append(make(.notice, notice, .white)) }
            for (i, row) in PlazaMenuText.rows(menu).enumerated() { out.append(make(.row(i), row, .white, marked: i == menu.selection)) }
            return out
        default: return []
        }
    }

    private func layout(viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> (lines: [Line], placed: Placed) {
        let ls = lines(text: text, scale: scale)
        let m = text.metrics(.plaza(.body))
        let lineH = (m.ascender - m.descender).rounded()
        let pad = Self.padding
        let width = max(PlazaMenuText.width, (ls.map(\.width).max() ?? 0) + 2 * pad)
        let height = 2 * pad + CGFloat(ls.count) * lineH + CGFloat(max(0, ls.count - 1)) * Self.lineGap
        let pillsHeight = pills.stack(in: viewport, scale: scale, text: text).size.height
        let top = PlazaRosterMetrics.margin + (pillsHeight > 0 ? pillsHeight + PlazaPanelStyle.pillSpacing : 0)
        let frame = CGRect(x: PlazaPanelStyle.pixel((viewport.width - width) / 2, scale: scale), y: top, width: width, height: height)
        var rows: [Int: CGRect] = [:], info: [(String, String, CGRect)] = []
        for (i, l) in ls.enumerated() {
            let y = pad + CGFloat(i) * (lineH + Self.lineGap)
            let r = CGRect(x: pad, y: y, width: width - 2 * pad, height: lineH)
            if case .row(let n) = l.kind { rows[n] = r }
            info.append(("\(l.kind)", l.text, CGRect(x: pad, y: y, width: l.width, height: lineH)))
        }
        return (ls, Placed(frame: frame, rows: rows.keys.sorted().map { rows[$0]! }, lines: info))
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        let text = graphics.text
        let (ls, p) = layout(viewport: viewport, scale: scale, text: text)
        placed = p
        guard !ls.isEmpty else { return PlazaPanelDrawing() }
        let m = text.metrics(.plaza(.body))
        let space = PlazaPanelSpace(content: p.frame.size, room: 0)
        let held = PlazaNameColorPickerPanel.held(interaction)
        let markerW = PlazaPanelStyle.pixelUp(text.line("▶", font: .plaza(.body)).width, scale: scale)
        let marker = text.line("▶", font: .plaza(.body))
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: p.frame.size)))
            for (i, l) in ls.enumerated() {
                let r = p.lines[i].2
                let base = space.canvas(CGPoint(x: r.minX, y: r.minY + m.ascender))
                canvas.saveState()
                if case .row(let n) = l.kind, held == PlazaPanelHit(action: "choose", index: n) { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
                var x = base.x
                if case .row = l.kind {
                    if l.marked {
                        canvas.setFillColor(.white)
                        canvas.draw(marker, at: CGPoint(x: x, y: base.y))
                    }
                    x += markerW + Self.markerGap
                }
                if l.shadow {
                    canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
                    canvas.draw(l.line, at: CGPoint(x: x + 1, y: base.y - 1))
                }
                canvas.setFillColor(l.color)
                canvas.draw(l.line, at: CGPoint(x: x, y: base.y))
                canvas.restoreState()
            }
        }
        var items: [PlazaAccessibilityItem] = []
        for (i, l) in ls.enumerated() {
            var f = p.lines[i].2
            f = f.offsetBy(dx: p.frame.minX, dy: p.frame.minY)
            switch l.kind {
            case .row(let n):
                items.append(PlazaAccessibilityItem(frame: p.rows[n].offsetBy(dx: p.frame.minX, dy: p.frame.minY), role: .menuItem,
                                                    label: l.text, action: PlazaPanelHit(action: "choose", index: n)))
            default:
                items.append(PlazaAccessibilityItem(frame: f, role: .staticText, label: l.text))
            }
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: p.frame)] } ?? [], accessibility: items)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let p = placed else { return nil }
        guard p.frame.contains(point) else { return PlazaPanelHit(action: "cancel", index: nil) }
        let local = CGPoint(x: point.x - p.frame.minX, y: point.y - p.frame.minY)
        if let i = p.rows.firstIndex(where: { $0.contains(local) }) { return PlazaPanelHit(action: "choose", index: i) }
        return PlazaPanelHit(action: "menu", index: nil)   // the menu's own background takes the click and does nothing
    }
}

/// The striped plate behind the roster, the menus and the card (`PlazaRosterBackground`, SwiftUI): a 10-point rounded plate
/// of `2D7F87` with 6-point 135° stripes in `2A7880`, a 3-point `1D4F55` line inset 1.5 and a 2-point `5FB7BD` line inset 4.
enum PlazaMenuBackground {
    /// `rect` in canvas coordinates (origin bottom-left).
    static func draw(on canvas: any PlazaCanvas, rect: CGRect) {
        canvas.saveState()
        canvas.clip(toRoundedRect: rect, radius: 10)
        canvas.setFillColor(PlazaColor(hex: 0x2D7F87))
        canvas.fill(rect)
        canvas.setFillColor(PlazaColor(hex: 0x2A7880))
        let h = rect.height
        var x = -h
        var odd = false
        func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: rect.minX + px, y: rect.minY + h - py) }
        while x < rect.width {
            if odd { canvas.fillPath(PlazaPath(points: [pt(x, 0), pt(x + 6, 0), pt(x + 6 + h, h), pt(x + h, h)], closed: true)) }
            odd.toggle()
            x += 6
        }
        canvas.restoreState()
        canvas.setStrokeColor(PlazaColor(hex: 0x1D4F55))
        canvas.strokeRoundedRect(rect.insetBy(dx: 1.5, dy: 1.5), radius: 8.5, lineWidth: 3)
        canvas.setStrokeColor(PlazaColor(hex: 0x5FB7BD))
        canvas.strokeRoundedRect(rect.insetBy(dx: 4, dy: 4), radius: 6, lineWidth: 2)
    }
}
