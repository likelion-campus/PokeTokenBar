import Foundation

/// Text and small pictures of the activity parts, made once and reused (stage 7 Task 12): a hover re-renders the part
/// without drawing any text again, because every text is an image cached by what it says, its font, its colour and the
/// scale. The bars, ticks and swatches are `.color` layers (no bitmap at all).
@MainActor final class ActivityDrawing {
    struct Key: Hashable {
        var text: String
        var size: Int
        var weight: Int
        var color: PlazaColor
        var scale: Int
        var maxWidth: Int
    }

    struct Piece {
        var image: PlazaImage?
        var width: CGFloat
        var height: CGFloat
    }

    private var texts: [Key: Piece] = [:]
    private var pictures: [String: PlazaImage] = [:]
    /// Pictures and texts made since the last `resetCounts` (the selftest reads how many a hover made).
    private(set) var made = 0
    /// How many of `made` are texts (a hover must make none; it may make the two bars it changes).
    private(set) var madeTexts = 0

    func resetCounts() { made = 0; madeTexts = 0 }

    static func weight(_ w: Int) -> PlazaFontWeight { w >= 700 ? .bold : (w >= 500 ? .semibold : .regular) }

    /// The line height of the Mac's text at `size` (the font's ascender - descender, rounded, as `PlazaPill.textBox`).
    static func lineHeight(_ size: CGFloat, text: any PlazaTextEngine) -> CGFloat {
        let m = text.metrics(.system(size: size, weight: .regular))
        return (m.ascender - m.descender).rounded()
    }

    func width(_ s: String, size: CGFloat, weight: Int = 400, graphics: any PlazaGraphics) -> CGFloat {
        s.isEmpty ? 0 : graphics.text.line(s, font: .system(size: size, weight: Self.weight(weight))).width
    }

    /// The text as an image at `origin` (top-left, DIP), cut with an ellipsis at `maxWidth`. `width` is what it takes.
    func text(_ s: String, size: CGFloat, weight: Int = 400, color: PlazaColor, at origin: CGPoint, maxWidth: CGFloat? = nil,
              scale: CGFloat, graphics: any PlazaGraphics) -> (layer: PlazaPanelLayer?, width: CGFloat) {
        guard !s.isEmpty else { return (nil, 0) }
        let key = Key(text: s, size: Int(size * 10), weight: weight, color: color, scale: Int(scale * 100), maxWidth: Int((maxWidth ?? 0) * 10))
        let piece: Piece
        if let cached = texts[key] {
            piece = cached
        } else {
            if texts.count > 400 { texts.removeAll() }
            let font = PlazaFont.system(size: size, weight: Self.weight(weight))
            let engine = graphics.text
            var line = engine.line(s, font: font)
            if let maxWidth { line = PlazaPanelText.cut(line, width: maxWidth, font: font, text: engine, scale: scale) }
            let m = engine.metrics(font)
            let height = (m.ascender - m.descender).rounded()
            let content = CGSize(width: PlazaPanelStyle.pixelUp(line.width, scale: scale), height: height)
            let space = PlazaPanelSpace(content: content, room: 0)
            let image = space.image(scale: scale, graphics: graphics) { canvas in
                canvas.setFillColor(color)
                canvas.draw(line, at: space.canvas(CGPoint(x: 0, y: m.ascender)))
            }
            made += 1
            madeTexts += 1
            piece = Piece(image: image, width: line.width, height: height)
            texts[key] = piece
        }
        guard let image = piece.image else { return (nil, piece.width) }
        return (.image(image, frame: CGRect(x: origin.x, y: origin.y, width: PlazaPanelStyle.pixelUp(piece.width, scale: scale), height: piece.height)),
                piece.width)
    }

    /// A small picture drawn once per `key` (the switch dots, the flame, the heatmap grid).
    func picture(_ key: String, size: CGSize, scale: CGFloat, graphics: any PlazaGraphics,
                 _ draw: (any PlazaCanvas, PlazaPanelSpace) -> Void) -> PlazaImage? {
        let full = "\(key)@\(Int(scale * 100))"
        if let cached = pictures[full] { return cached }
        if pictures.count > 40 { pictures.removeAll() }
        let space = PlazaPanelSpace(content: size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in draw(canvas, space) }) else { return nil }
        made += 1
        pictures[full] = image
        return image
    }

    /// An emoji through the colour text path (`PlazaFont.emoji`: Segoe UI Emoji with DirectWrite colour glyph layers on Windows),
    /// drawn at `alpha` (a tint the emoji cannot take: the Mac's gray symbol becomes the same glyph at the label's opacity).
    func emoji(_ s: String, size: CGFloat, alpha: Double, at origin: CGPoint, scale: CGFloat, graphics: any PlazaGraphics)
        -> (layer: PlazaPanelLayer?, width: CGFloat, height: CGFloat) {
        let font = PlazaFont.emoji(size: size)
        let engine = graphics.text
        let line = engine.line(s, font: font)
        let m = engine.metrics(font)
        let height = (m.ascender - m.descender).rounded()
        let width = PlazaPanelStyle.pixelUp(line.width, scale: scale)
        let image = picture("emoji-\(s)-\(Int(size * 10))-\(Int(alpha * 100))", size: CGSize(width: width, height: height), scale: scale, graphics: graphics) { canvas, space in
            canvas.setAlpha(CGFloat(alpha))
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0))
            canvas.draw(line, at: space.canvas(CGPoint(x: 0, y: m.ascender)))
        }
        return (image.map { .image($0, frame: CGRect(x: origin.x, y: origin.y, width: width, height: height)) }, width, height)
    }

    /// One bar (`MonthDailyTrend`'s `RoundedRectangle(cornerRadius: 1)`, stacked segments clipped to it) as a small picture.
    func bar(width: CGFloat, height: CGFloat, color: PlazaColor, segments: [(PlazaColor, CGFloat)], at origin: CGPoint, scale: CGFloat,
             graphics: any PlazaGraphics) -> PlazaPanelLayer? {
        let key = "bar-\(Int(width * 100))x\(Int(height * 100))-\(segments.isEmpty ? "\(color)" : segments.map { "\($0.0)\(Int($0.1 * 100))" }.joined())"
        guard let image = picture(key, size: CGSize(width: width, height: height), scale: scale, graphics: graphics, { canvas, space in
            let box = space.canvas(CGRect(x: 0, y: 0, width: width, height: height))
            canvas.clip(toRoundedRect: box, radius: 1)
            if segments.isEmpty {
                canvas.setFillColor(color)
                canvas.fill(box)
            } else {
                var y = box.minY
                for (c, h) in segments {
                    canvas.setFillColor(c)
                    canvas.fill(CGRect(x: box.minX, y: y, width: box.width, height: h))
                    y += h
                }
            }
        }) else { return nil }
        return .image(image, frame: CGRect(x: origin.x, y: origin.y, width: width, height: height))
    }

    // MARK: shared pieces

    static let dot: CGFloat = 4
    static let dotSpacing: CGFloat = 3

    static func dotsWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * dot + CGFloat(max(0, count - 1)) * dotSpacing
    }

    /// The switch dots (`PageDots`): the current one at 75 % of the secondary colour, the others at 25 %.
    func dots(count: Int, current: Int, at origin: CGPoint, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaPanelLayer? {
        let size = CGSize(width: Self.dotsWidth(count), height: Self.dot)
        guard let image = picture("dots-\(count)-\(current)", size: size, scale: scale, graphics: graphics, { canvas, space in
            for i in 0..<count {
                let r = CGRect(x: CGFloat(i) * (Self.dot + Self.dotSpacing), y: 0, width: Self.dot, height: Self.dot)
                canvas.setFillColor(PopoverColorRole.secondary.plazaColor(alpha: i == current ? 0.75 : 0.25))
                canvas.fillEllipse(in: space.canvas(r))
            }
        }) else { return nil }
        return .image(image, frame: CGRect(origin: origin, size: size))
    }
}

/// Sets of keys the parts share: the next index when an arrow key moves a selection along `items` (nil entries cannot be
/// selected), starting at `start` when nothing is selected.
enum ActivityKeys {
    static func move(_ selectable: [Bool], from current: Int?, by step: Int, start: Int?) -> Int? {
        guard let first = current ?? start else { return selectable.firstIndex(of: true) }
        guard current != nil else { return selectable.indices.contains(first) && selectable[first] ? first : nil }
        var i = first + step
        while selectable.indices.contains(i) {
            if selectable[i] { return i }
            i += step
        }
        return current
    }
}
