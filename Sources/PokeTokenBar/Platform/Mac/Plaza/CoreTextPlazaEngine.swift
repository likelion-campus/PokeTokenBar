import AppKit
import CoreText

/// CoreText lines and frames built from the same attributed strings the art files built: `.plaza` and `.system`
/// text takes its colour from the context (`kCTForegroundColorFromContextAttributeName`), as in the name plate, the
/// chat bubble and the emotes; `.emoji` carries only its font, as `PlazaPondArt.wetImage` did.
struct CoreTextPlazaEngine: PlazaTextEngine {
    /// The engine's native line and paragraph.
    final class Line: @unchecked Sendable { let line: CTLine; init(_ line: CTLine) { self.line = line } }
    final class Paragraph: @unchecked Sendable { let setter: CTFramesetter; init(_ setter: CTFramesetter) { self.setter = setter } }

    static func ctLine(_ line: PlazaTextLine) -> CTLine? { (line.native as? Line)?.line }
    static func framesetter(_ paragraph: PlazaParagraph) -> CTFramesetter? { (paragraph.native as? Paragraph)?.setter }

    private static func emojiFont(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil) }

    private static func nsWeight(_ w: PlazaFontWeight) -> NSFont.Weight {
        switch w {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    /// Fonts: `.plaza` -> `PlazaResources.font`, `.system` -> `NSFont.systemFont(ofSize:weight:)`,
    /// `.emoji` -> `CTFontCreateWithName("Apple Color Emoji")`.
    static func attributes(_ font: PlazaFont) -> [NSAttributedString.Key: Any] {
        switch font {
        case .plaza(let size):
            [.font: PlazaResources.font(size), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        case .system(let size, let weight):
            [.font: NSFont.systemFont(ofSize: size, weight: nsWeight(weight)),
             NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        case .emoji(let size):
            [.font: emojiFont(size)]
        }
    }

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics {
        switch font {
        case .plaza(let size):
            let f = PlazaResources.font(size)
            return PlazaFontMetrics(ascender: f.ascender, descender: f.descender, leading: f.leading)
        case .system(let size, let weight):
            let f = NSFont.systemFont(ofSize: size, weight: Self.nsWeight(weight))
            return PlazaFontMetrics(ascender: f.ascender, descender: f.descender, leading: f.leading)
        case .emoji(let size):
            let f = Self.emojiFont(size)
            return PlazaFontMetrics(ascender: CTFontGetAscent(f), descender: -CTFontGetDescent(f), leading: CTFontGetLeading(f))
        }
    }

    func line(_ text: String, font: PlazaFont) -> PlazaTextLine {
        Self.wrap(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.attributes(font))))
    }

    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? {
        guard let l = Self.ctLine(line), let e = Self.ctLine(ellipsis),
              let cut = CTLineCreateTruncatedLine(l, Double(width), .end, e) else { return nil }
        return Self.wrap(cut)
    }

    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph {
        var attributes = Self.attributes(font)
        if alignment == .center {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            attributes[.paragraphStyle] = paragraph
        }
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return PlazaParagraph(
            native: Paragraph(setter),
            suggestedSize: { CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, $0, nil) },
            visibleLength: { size in
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
                return CTFrameGetVisibleStringRange(frame).length
            })
    }

    /// TextKit finds the breaks with SwiftUI's line-break strategy (`.standard`: CoreText alone ignores it and breaks
    /// Korean words); the lines are cut from one typesetter over the whole text, so each keeps its direction.
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine] {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        var attributes = Self.attributes(font)
        attributes[.paragraphStyle] = style
        let storage = NSTextStorage(string: text, attributes: attributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let utf16 = text as NSString
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            var r = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            while r.length > 0, let last = Unicode.Scalar(utf16.character(at: r.location + r.length - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(last) { r.length -= 1 }
            ranges.append(r)
        }
        guard !ranges.isEmpty else { return [line("", font: font)] }
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.attributes(font)))
        return ranges.map { Self.wrap(CTTypesetterCreateLine(typesetter, CFRange(location: $0.location, length: $0.length))) }
    }

    private static func wrap(_ line: CTLine) -> PlazaTextLine {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return PlazaTextLine(width: width, ascent: ascent, descent: descent, leading: leading, native: Line(line))
    }
}
