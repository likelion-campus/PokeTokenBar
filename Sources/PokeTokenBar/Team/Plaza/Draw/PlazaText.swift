import Foundation

enum PlazaFontWeight: Sendable { case regular, semibold, bold }

/// The plaza's fonts (user decision): Galmuri at the two pixel-true sizes, the system font (Pretendard on Windows) and
/// the colour emoji font (Segoe UI Emoji on Windows).
enum PlazaFont: Hashable, Sendable {
    case plaza(PlazaTextSize)
    case system(size: CGFloat, weight: PlazaFontWeight)
    case emoji(size: CGFloat)
}

enum PlazaTextAlignment: Sendable { case natural, center }

/// A font's line metrics, signed like `NSFont`: `descender` is negative (below the baseline).
struct PlazaFontMetrics: Equatable, Sendable {
    let ascender: CGFloat, descender: CGFloat, leading: CGFloat
}

/// One laid-out line of text. Typographic bounds like `CTLineGetTypographicBounds`: `ascent` and `descent` are both
/// positive distances from the baseline. `native` is the engine's own line (the Mac: a `CTLine`).
final class PlazaTextLine: @unchecked Sendable {
    let width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat
    let native: AnyObject?

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat, native: AnyObject?) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.native = native
    }
}

/// Text that wraps inside a rectangle. `native` is the engine's own layout (the Mac: a `CTFramesetter`).
final class PlazaParagraph: @unchecked Sendable {
    let native: AnyObject?
    private let suggest: (CGSize) -> CGSize
    private let visible: (CGSize) -> Int

    init(native: AnyObject?, suggestedSize: @escaping (CGSize) -> CGSize, visibleLength: @escaping (CGSize) -> Int) {
        self.native = native
        suggest = suggestedSize
        visible = visibleLength
    }

    /// The size the text needs inside `limit` (`CTFramesetterSuggestFrameSizeWithConstraints`).
    func suggestedSize(limit: CGSize) -> CGSize { suggest(limit) }

    /// How much of the text (UTF-16 units) fits in a frame of `size` (`CTFrameGetVisibleStringRange`).
    func visibleLength(in size: CGSize) -> Int { visible(size) }
}

/// Makes and measures text; a `PlazaCanvas` draws what it makes. The Mac builds the same attributed strings the art
/// files built before (`CoreTextPlazaEngine`).
protocol PlazaTextEngine: Sendable {
    func metrics(_ font: PlazaFont) -> PlazaFontMetrics
    func line(_ text: String, font: PlazaFont) -> PlazaTextLine
    /// `line` cut at the end to `width` with `ellipsis` (`CTLineCreateTruncatedLine`); nil when that is impossible.
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine?
    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph
    /// `text` broken into lines at most `width` wide the way SwiftUI's `Text` wraps (the overlay panels' text): at word
    /// boundaries — a Korean word stays whole, where `paragraph` would break between its syllables —, after hyphens,
    /// between emoji, and a word wider than a line between its characters. Trailing spaces are not part of a line. Each
    /// line keeps the whole text's direction. An empty text is one empty line.
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine]
}
