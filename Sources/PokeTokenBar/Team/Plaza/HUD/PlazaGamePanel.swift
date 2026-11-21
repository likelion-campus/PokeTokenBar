import Foundation
import Observation

/// The minigame invitation: a plate under the pills with the game's name, its rules, how many are in, and the answer
/// buttons. It never takes the keys (Y, N and M go through the scene) and covers only itself, so the plaza stays usable
/// while it shows. Hidden while a menu, the board or a card is open, and in photo mode.
@MainActor final class PlazaGameCardPanel: PlazaPanel {
    let id = PlazaPanelID.gameCard
    let anchor = PlazaPanelAnchor.topCenter
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let game: PlazaGameModel
    private let overlay: PlazaOverlayModel
    private let pills: PlazaPillsPanel
    private var observer: PlazaChangeObserver?

    static let minWidth: CGFloat = 240, buttonGap: CGFloat = 8, buttonPadding = CGSize(width: 10, height: 4), buttonsTop: CGFloat = 8
    private static let gold = PlazaColor(hex: 0xF2C14E)

    init(game: PlazaGameModel, overlay: PlazaOverlayModel, pills: PlazaPillsPanel) {
        self.game = game
        self.overlay = overlay
        self.pills = pills
        // The pills' stack sets where the card sits, so what the pills show is read as well.
        observer = PlazaChangeObserver(track: { _ = game.card; _ = overlay.content; _ = overlay.isPhotoMode; _ = overlay.countdown
                                                _ = overlay.banner; _ = overlay.hint },
                                       changed: { [weak self] in self?.onChange?() })
    }

    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaNameColorPickerPanel.held(oldValue) != PlazaNameColorPickerPanel.held(interaction) { onChange?() } }
    }

    var isVisible: Bool { game.card != nil && overlay.content == .none && !overlay.isPhotoMode }

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint {
        let pillsHeight = pills.stack(in: viewport, scale: scale, text: text).size.height
        return CGPoint(x: 0, y: PlazaRosterMetrics.margin + (pillsHeight > 0 ? pillsHeight + PlazaPanelStyle.pillSpacing : 0))
    }

    struct Placed {
        let size: CGSize
        /// Title first, then the lines: the text and where its line box sits (content points, origin top-left).
        let lines: [(text: String, frame: CGRect)]
        let buttons: [(button: PlazaGameView.Button, frame: CGRect)]
    }

    private(set) var placed: Placed?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Placed {
        guard let card = game.card else { return Placed(size: .zero, lines: [], buttons: []) }
        let font = PlazaFont.plaza(.body)
        let m = text.metrics(font)
        let lineH = (m.ascender - m.descender).rounded()
        let pad = PlazaMenuPanel.padding
        let strings = [card.title] + card.lines
        let widths = strings.map { PlazaPanelStyle.pixelUp(text.line($0, font: font).width, scale: scale) }
        let buttonWidths = card.buttons.map { PlazaPanelStyle.pixelUp(text.line($0.label, font: font).width, scale: scale) + 2 * Self.buttonPadding.width }
        let buttonsWidth = buttonWidths.reduce(0, +) + CGFloat(max(0, card.buttons.count - 1)) * Self.buttonGap
        let width = max(Self.minWidth, (widths + [buttonsWidth]).max()! + 2 * pad)
        var lines: [(String, CGRect)] = []
        var y = pad
        for (i, string) in strings.enumerated() {
            lines.append((string, CGRect(x: PlazaPanelStyle.pixel((width - widths[i]) / 2, scale: scale), y: y, width: widths[i], height: lineH)))
            y += lineH + PlazaMenuPanel.lineGap
        }
        y -= PlazaMenuPanel.lineGap
        var buttons: [(PlazaGameView.Button, CGRect)] = []
        if !card.buttons.isEmpty {
            y += Self.buttonsTop
            var x = PlazaPanelStyle.pixel((width - buttonsWidth) / 2, scale: scale)
            let height = lineH + 2 * Self.buttonPadding.height
            for (button, w) in zip(card.buttons, buttonWidths) {
                buttons.append((button, CGRect(x: x, y: y, width: w, height: height)))
                x += w + Self.buttonGap
            }
            y += height
        }
        return Placed(size: CGSize(width: width, height: y + pad), lines: lines, buttons: buttons)
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { layout(scale: scale, text: text).size }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        let text = graphics.text
        let p = layout(scale: scale, text: text)
        placed = p
        guard p.size != .zero else { return PlazaPanelDrawing() }
        let font = PlazaFont.plaza(.body)
        let m = text.metrics(font)
        let space = PlazaPanelSpace(content: p.size, room: 0)
        let held = PlazaNameColorPickerPanel.held(interaction)
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: p.size)))
            for (i, l) in p.lines.enumerated() {
                let base = space.canvas(CGPoint(x: l.frame.minX, y: l.frame.minY + m.ascender))
                let line = text.line(l.text, font: font)
                if i == 0 {
                    canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
                    canvas.draw(line, at: CGPoint(x: base.x + 1, y: base.y - 1))
                }
                canvas.setFillColor(i == 0 ? Self.gold : .white)
                canvas.draw(line, at: base)
            }
            for b in p.buttons {
                canvas.saveState()
                if !b.button.isEnabled {
                    canvas.setAlpha(0.45)
                } else if held == PlazaPanelHit(action: b.button.action, index: nil) {
                    canvas.setAlpha(PlazaPanelStyle.pressedOpacity)
                }
                let r = space.canvas(b.frame)
                canvas.setFillColor(PlazaColor(hex: 0x1D4F55))
                canvas.fillRoundedRect(r, radius: 6)
                canvas.setStrokeColor(PlazaColor(hex: 0x5FB7BD))
                canvas.strokeRoundedRect(r, radius: 6, lineWidth: 1)
                canvas.setFillColor(.white)
                canvas.draw(text.line(b.button.label, font: font),
                            at: space.canvas(CGPoint(x: b.frame.minX + Self.buttonPadding.width, y: b.frame.minY + Self.buttonPadding.height + m.ascender)))
                canvas.restoreState()
            }
        }
        var items = p.lines.map { PlazaAccessibilityItem(frame: $0.frame, role: .staticText, label: $0.text) }
        items += p.buttons.map {
            PlazaAccessibilityItem(frame: $0.frame, role: .button, label: $0.button.label,
                                   action: PlazaPanelHit(action: $0.button.action, index: nil), isEnabled: $0.button.isEnabled)
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: p.size))] } ?? [], accessibility: items)
    }

    /// A click on an enabled button answers; anywhere else on the plate is taken and does nothing.
    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let p = placed, CGRect(origin: .zero, size: p.size).contains(point) else { return nil }
        if let b = p.buttons.first(where: { $0.frame.contains(point) }), b.button.isEnabled {
            return PlazaPanelHit(action: b.button.action, index: nil)
        }
        return PlazaPanelHit(action: "card", index: nil)
    }
}

/// The minigame's big line in the middle of the window: the 3-2-1, the start, who is out, who won. The plaza's pixel
/// font drawn `magnify` times as big without smoothing, with a dark outline. It takes no clicks.
@MainActor final class PlazaGameTitlePanel: PlazaPanel {
    let id = PlazaPanelID.gameTitle
    let anchor = PlazaPanelAnchor.center
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let game: PlazaGameModel
    private var observer: PlazaChangeObserver?

    static let magnify: CGFloat = 6
    /// The outline, in the font's own (unmagnified) points.
    static let outline: CGFloat = 1

    init(game: PlazaGameModel) {
        self.game = game
        observer = PlazaChangeObserver(track: { _ = game.title }, changed: { [weak self] in self?.onChange?() })
    }

    var isVisible: Bool { game.title != nil }

    static func color(_ tone: PlazaGameView.Tone) -> PlazaColor {
        switch tone {
        case .count: .white
        case .go, .win: PlazaColor(hex: 0xF2C14E)
        case .out: PlazaColor(hex: 0xFF6B5A)
        }
    }

    /// The unmagnified text box: the line plus the outline all round.
    private func box(text: any PlazaTextEngine) -> (line: PlazaTextLine, size: CGSize, metrics: PlazaFontMetrics)? {
        guard let title = game.title else { return nil }
        let font = PlazaFont.plaza(.body)
        let line = text.line(title.text, font: font)
        let m = text.metrics(font)
        return (line, CGSize(width: line.width.rounded(.up) + 1 + 2 * Self.outline, height: (m.ascender - m.descender).rounded() + 2 * Self.outline), m)
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        guard let b = box(text: text) else { return .zero }
        return CGSize(width: b.size.width * Self.magnify, height: b.size.height * Self.magnify)
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        guard let title = game.title, let b = box(text: graphics.text) else { return PlazaPanelDrawing() }
        let size = CGSize(width: b.size.width * Self.magnify, height: b.size.height * Self.magnify)
        let space = PlazaPanelSpace(content: size, room: 0)
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            canvas.setShouldAntialias(false)
            canvas.setShouldSmoothFonts(false)
            canvas.scale(x: Self.magnify, y: Self.magnify)
            let base = CGPoint(x: Self.outline, y: Self.outline - b.metrics.descender)
            canvas.setFillColor(PlazaColor(hex: 0x16242B))
            for dx in [-1, 0, 1] as [CGFloat] {
                for dy in [-1, 0, 1] as [CGFloat] where dx != 0 || dy != 0 {
                    canvas.draw(b.line, at: CGPoint(x: base.x + dx * Self.outline, y: base.y + dy * Self.outline))
                    canvas.draw(b.line, at: CGPoint(x: base.x + 1 + dx * Self.outline, y: base.y + dy * Self.outline))
                }
            }
            // Twice, a point apart: the pixel font's one-point strokes would read as hollow between the outlines.
            canvas.setFillColor(Self.color(title.tone))
            canvas.draw(b.line, at: base)
            canvas.draw(b.line, at: CGPoint(x: base.x + 1, y: base.y))
        }
        let frame = CGRect(origin: .zero, size: size)
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: frame)] } ?? [],
                                 accessibility: [PlazaAccessibilityItem(frame: frame, role: .staticText, label: title.text)])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
