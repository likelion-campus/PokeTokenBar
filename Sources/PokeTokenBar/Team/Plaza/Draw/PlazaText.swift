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

/// A piece of text in one font and one colour. A line or paragraph made of runs is one piece of text with the colours
/// changing inside it (SwiftUI's `Text + Text`: the chat log's time, name and message). The colour is the run's own
/// (alpha included); text made from a plain string takes its colour from the canvas's fill, as before.
struct PlazaTextRun: Equatable, Sendable {
    var text: String
    var font: PlazaFont
    var color: PlazaColor
}

/// One laid-out line of text. Typographic bounds like `CTLineGetTypographicBounds`: `ascent` and `descent` are both
/// positive distances from the baseline. `native` is the engine's own line (the Mac: a `CTLine`). `runs` is what a line
/// made from runs is made of (the pieces of the runs that fell on this line, trailing space left off a wrapped line); a
/// line made from a plain string has none.
final class PlazaTextLine: @unchecked Sendable {
    let width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat
    let native: AnyObject?
    let runs: [PlazaTextRun]

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat, native: AnyObject?, runs: [PlazaTextRun] = []) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.native = native
        self.runs = runs
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
    /// One line made of `runs`, each in its own font and colour (the line draws in those colours); `truncated` cuts it.
    func line(_ runs: [PlazaTextRun]) -> PlazaTextLine
    /// `runs` as ONE paragraph broken like `wrappedLines(_:font:width:)` breaks a plain text: a break may fall inside a run
    /// or between two, and each line carries the runs' pieces (`PlazaTextLine.runs`). No runs, or only empty ones, is one
    /// empty line.
    func wrappedLines(_ runs: [PlazaTextRun], width: CGFloat) -> [PlazaTextLine]
}
