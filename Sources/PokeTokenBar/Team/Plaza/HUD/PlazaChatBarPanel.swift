import Foundation

/// The chat line's chrome where the field is a native control drawn by the OS and the plate around it is drawn by the plaza
/// (Windows, D13): the bar's fill and its border (orange while the megaphone is on), the 😀 button and, unfolded above the
/// field, the emoji grid of `PlazaChatEmojis`. The field itself is NOT drawn here: `fieldRect` says where the window puts its
/// native one-line field. Every place and size is the Mac's AppKit chat bar (`PlazaChatInput`): 16 points from the window's
/// bottom-left corner, `PlazaChatLog.width` wide, the field 12 from the top and 4 from the bottom, 12 from the left, the 😀
/// button 24 wide and 8 from the right, 4 after the field, centred on the field's line; unfolded, the grid sits 8 from the top,
/// centred, and the field 8 under it. The bar draws only while the chat is open.
///
/// Hits: `("emoji", nil)` the 😀 button, `("pick", i)` cell `i` of the unfolded grid, `("bar", nil)` the rest of the plate (it takes
/// the click so nothing under it gets it; the window keeps the keyboard in the field).
@MainActor final class PlazaChatBarPanel: PlazaPanel {
    let id = PlazaPanelID.chatBar
    let anchor = PlazaPanelAnchor.bottomLeading
    var offset: CGPoint { CGPoint(x: Self.margin, y: Self.margin) }
    var onChange: (() -> Void)?

    /// The bar's look: `PlazaChatInput`'s layer (fill, border width and colours, corner radius).
    static let fill = PlazaColor(hex: 0x1D4F5C, alpha: 0.95)
    static let border = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
    static let loudBorder = PlazaColor(hex: 0xF08A24)
    static let borderWidth: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    /// From the window's bottom-left corner (`PlazaMacWindow`: bottom −16, leading 16).
    static let margin: CGFloat = 16
    static var width: CGFloat { PlazaChatLog.width }
    /// The field's insets in the bar (`PlazaChatInput`'s constraints, which place the field's alignment rect).
    static let fieldTop: CGFloat = 12, fieldBottom: CGFloat = 4, fieldLeading: CGFloat = 12
    /// A borderless `NSTextField`'s frame is its alignment rect outset by this much left and right; its text starts this far in.
    static let fieldTextInset: CGFloat = 2
    /// The 😀 button: its size as AppKit lays the borderless 16-point button out, 8 from the bar's right edge, 4 after the field.
    static let emojiButtonSize = CGSize(width: 24, height: 19)
    /// A grid button's size as AppKit lays a borderless 20-point emoji button out, centred in its cell (what a click hits).
    static let gridButtonSize = CGSize(width: 29, height: 24)
    static let emojiButtonTrailing: CGFloat = 8, emojiButtonGap: CGFloat = 4
    /// The unfolded grid: 8 from the bar's top, the field 8 under it.
    static let gridTop: CGFloat = 8, gridGap: CGFloat = 8
    /// The 😀 button's and the grid's emoji sizes (`PlazaChatInput`: system font 16 and 20).
    static let buttonEmojiSize: CGFloat = 16, gridEmojiSize: CGFloat = 20

    /// The field's height: the body font's line, rounded up (`PlazaChatInput.fieldHeight`).
    let fieldHeight: CGFloat

    /// The chat is open: the bar is shown.
    var isOpen = false { didSet { if isOpen != oldValue { onChange?() } } }
    /// The megaphone is on: the border is orange.
    var isLoud = false { didSet { if isLoud != oldValue { onChange?() } } }
    /// The emoji grid is unfolded above the field (the bar grows upward).
    var isEmojiOpen = false { didSet { if isEmojiOpen != oldValue { onChange?() } } }

    init(fieldHeight: CGFloat) {
        self.fieldHeight = fieldHeight
    }

    var isVisible: Bool { isOpen }

    static var gridRows: Int { (PlazaChatEmojis.all.count + PlazaChatEmojis.columns - 1) / PlazaChatEmojis.columns }
    static var gridSize: CGSize {
        CGSize(width: CGFloat(PlazaChatEmojis.columns) * PlazaChatEmojis.cell, height: CGFloat(gridRows) * PlazaChatEmojis.cell)
    }

    /// The bar in points, closed or unfolded (the Mac's `fittingSize`).
    var barSize: CGSize {
        let top = isEmojiOpen ? Self.gridTop + Self.gridSize.height + Self.gridGap : Self.fieldTop
        return CGSize(width: Self.width, height: top + fieldHeight + Self.fieldBottom)
    }

    /// Where the native field goes: panel points, origin top-left. This is the AppKit field's frame (10…326), whose text starts
    /// `fieldTextInset` in (at 12, the constraint): the native field keeps the same margin, so the text sits where the Mac's does.
    var fieldRect: CGRect {
        let top = isEmojiOpen ? Self.gridTop + Self.gridSize.height + Self.gridGap : Self.fieldTop
        let right = Self.width - Self.emojiButtonTrailing - Self.emojiButtonSize.width - Self.emojiButtonGap + Self.fieldTextInset
        let left = Self.fieldLeading - Self.fieldTextInset
        return CGRect(x: left, y: top, width: right - left, height: fieldHeight)
    }

    /// The 😀 button, centred on the field's line.
    var emojiButtonRect: CGRect {
        let f = fieldRect
        return CGRect(x: Self.width - Self.emojiButtonTrailing - Self.emojiButtonSize.width, y: f.midY - Self.emojiButtonSize.height / 2,
                      width: Self.emojiButtonSize.width, height: Self.emojiButtonSize.height)
    }

    /// The unfolded grid's buttons (what a click hits and VoiceOver reads), each centred in its cell, in `gridCells` order.
    var gridButtons: [CGRect] {
        gridCells.map { c in
            CGRect(x: c.midX - Self.gridButtonSize.width / 2, y: c.midY - Self.gridButtonSize.height / 2,
                   width: Self.gridButtonSize.width, height: Self.gridButtonSize.height)
        }
    }

    /// The unfolded grid's cells in `PlazaChatEmojis.all` order, row by row (empty while folded).
    var gridCells: [CGRect] {
        guard isEmojiOpen else { return [] }
        let x0 = (Self.width - Self.gridSize.width) / 2
        return PlazaChatEmojis.all.indices.map { i in
            CGRect(x: x0 + CGFloat(i % PlazaChatEmojis.columns) * PlazaChatEmojis.cell,
                   y: Self.gridTop + CGFloat(i / PlazaChatEmojis.columns) * PlazaChatEmojis.cell,
                   width: PlazaChatEmojis.cell, height: PlazaChatEmojis.cell)
        }
    }

    /// The border's colour now.
    var borderColor: PlazaColor { isLoud ? Self.loudBorder : Self.border }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        let s = barSize
        return CGSize(width: PlazaPanelStyle.pixelUp(s.width, scale: scale), height: PlazaPanelStyle.pixelUp(s.height, scale: scale))
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        let bar = size(in: viewport, scale: scale, text: graphics.text)
        let space = PlazaPanelSpace(content: bar, room: 0)   // the layer's border lies inside its bounds
        let text = graphics.text
        let buttonLine = text.line("😀", font: .emoji(size: Self.buttonEmojiSize))
        let gridLines = isEmojiOpen ? PlazaChatEmojis.all.map { text.line($0, font: .emoji(size: Self.gridEmojiSize)) } : []
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            let r = space.canvas(CGRect(origin: .zero, size: bar))
            canvas.setFillColor(Self.fill)
            canvas.fillRoundedRect(r, radius: Self.cornerRadius)
            canvas.setStrokeColor(borderColor)
            canvas.strokeRoundedRect(r.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2),
                                     radius: Self.cornerRadius - Self.borderWidth / 2, lineWidth: Self.borderWidth)
            canvas.setFillColor(.white)
            Self.drawCentred(buttonLine, in: emojiButtonRect, text: text, size: Self.buttonEmojiSize, canvas: canvas, space: space, scale: scale)
            for (line, cell) in zip(gridLines, gridCells) {
                Self.drawCentred(line, in: cell, text: text, size: Self.gridEmojiSize, canvas: canvas, space: space, scale: scale)
            }
        }
        let l = L(.ko)
        var items = [PlazaAccessibilityItem(frame: emojiButtonRect, role: .button, label: l.plazaChatEmoji,
                                            action: PlazaPanelHit(action: "emoji", index: nil))]
        for (i, cell) in gridButtons.enumerated() {
            items.append(PlazaAccessibilityItem(frame: cell, role: .button, label: PlazaChatEmojis.all[i], action: PlazaPanelHit(action: "pick", index: i)))
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: items, tooltips: [PlazaTooltip(frame: emojiButtonRect, text: l.plazaChatEmoji)])
    }

    /// An emoji centred in `rect` (panel points) on its font's line, on whole device pixels.
    private static func drawCentred(_ line: PlazaTextLine, in rect: CGRect, text: any PlazaTextEngine, size: CGFloat,
                                    canvas: any PlazaCanvas, space: PlazaPanelSpace, scale: CGFloat) {
        let m = text.metrics(.emoji(size: size))
        let top = rect.midY - (m.ascender - m.descender) / 2
        let origin = PlazaControlStyle.snapped(CGPoint(x: rect.midX - line.width / 2, y: top + m.ascender), scale: scale)
        canvas.draw(line, at: space.canvas(origin))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        if let i = gridButtons.firstIndex(where: { $0.contains(point) }) { return PlazaPanelHit(action: "pick", index: i) }
        if emojiButtonRect.contains(point) { return PlazaPanelHit(action: "emoji", index: nil) }
        return CGRect(origin: .zero, size: barSize).contains(point) ? PlazaPanelHit(action: "bar", index: nil) : nil
    }
}
