import Foundation

// MARK: Task 20 — the empty Pokédex (the Mac's `CollectionView.emptyState`)

/// "No Pokémon caught yet!": the animated Pikachu (96 pt, a GIF slot), the title (`callout` semibold) and the hint
/// (`caption`, secondary, centred), 10 pt apart, 28 pt above and below.
@MainActor final class DexEmptyPart: PopoverPart {
    static let sprite: CGFloat = 96
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 28
    var onChange: (() -> Void)?
    private(set) var title: String, hint: String
    private var laid: (size: CGSize, spriteFrame: CGRect, title: CGRect, hintLines: [(PlazaTextLine, CGRect)])?

    init(title: String, hint: String) {
        self.title = title
        self.hint = hint
    }

    func update(title: String, hint: String) {
        guard title != self.title || hint != self.hint else { return }
        self.title = title
        self.hint = hint
        laid = nil
        onChange?()
    }

    private let titleFont = PlazaFont.system(size: 12, weight: .semibold), hintFont = PlazaFont.system(size: 10, weight: .regular)

    private func compute(width: CGFloat, text: any PlazaTextEngine) {
        let tm = CompanionHeaderPart.lineHeight(titleFont, text), hm = CompanionHeaderPart.lineHeight(hintFont, text)
        var y = Self.padding
        let sprite = CGRect(x: (width - Self.sprite) / 2, y: y, width: Self.sprite, height: Self.sprite)
        y += Self.sprite + Self.spacing
        let tl = text.line(title, font: titleFont)
        let titleRect = CGRect(x: (width - tl.width) / 2, y: y, width: tl.width, height: tm.height)
        y += tm.height + Self.spacing
        let lines = text.wrappedLines(hint, font: hintFont, width: width)
        var placed: [(PlazaTextLine, CGRect)] = []
        for l in lines {
            placed.append((l, CGRect(x: (width - l.width) / 2, y: y, width: l.width, height: hm.height)))
            y += hm.height
        }
        laid = (CGSize(width: width, height: y + Self.padding), sprite, titleRect, placed)
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        if laid?.size.width != width { compute(width: width, text: text) }
        return laid?.size ?? .zero
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        if laid == nil { compute(width: 332, text: graphics.text) }
        guard let lay = laid else { return PopoverDrawing(drawing: PlazaPanelDrawing()) }
        let space = PlazaPanelSpace(content: lay.size, room: 0)
        let tm = CompanionHeaderPart.lineHeight(titleFont, graphics.text), hm = CompanionHeaderPart.lineHeight(hintFont, graphics.text)
        let title = self.title
        let picture = space.image(scale: scale, graphics: graphics) { canvas in
            canvas.setFillColor(PopoverColorRole.primary.plazaColor())
            canvas.draw(graphics.text.line(title, font: self.titleFont), at: space.canvas(CGPoint(x: lay.title.minX, y: lay.title.minY + tm.ascender)))
            canvas.setFillColor(PopoverColorRole.secondary.plazaColor())
            for (line, r) in lay.hintLines { canvas.draw(line, at: space.canvas(CGPoint(x: r.minX, y: r.minY + hm.ascender))) }
        }
        let items = [PlazaAccessibilityItem(frame: lay.title, role: .staticText, label: title),
                     PlazaAccessibilityItem(frame: CGRect(x: 0, y: lay.title.maxY + Self.spacing, width: lay.size.width, height: lay.size.height - lay.title.maxY - Self.spacing - Self.padding),
                                            role: .staticText, label: hint)]
        let layers: [PlazaPanelLayer] = picture.map { [.image($0, frame: CGRect(origin: .zero, size: lay.size))] } ?? []
        // SpriteView(speciesID: 25, size: 96, animated: true)
        let slot = SpriteSlot(frame: lay.spriteFrame, subject: PlazaSpriteSubjectKey(speciesID: 25, shiny: false, form: nil, back: false), bob: false, animated: true)
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items), spriteSlots: [slot])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
