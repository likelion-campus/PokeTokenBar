#if os(Windows)
import Foundation

/// SF Symbol name → a Segoe Fluent Icons (Windows 11) or Segoe MDL2 Assets (Windows 10) glyph (stage 7 D15), from the
/// shared `PopoverGlyphTable` (tested on both systems against the Mac popover's symbol list). nil means the font has no
/// acceptable glyph and the caller draws `fallback(symbol:)` as text instead.
enum WinGlyphs {
    static func codePoint(symbol: String, fluent: Bool) -> UInt16? {
        PopoverGlyphTable.entry(symbol)?.codePoint(fluent: fluent)
    }

    /// The glyph as a one-character string for `DrawTextW` in the icon font.
    static func text(symbol: String, fluent: Bool) -> String? {
        codePoint(symbol: symbol, fluent: fluent).map { String(decoding: [$0], as: UTF16.self) }
    }

    /// The text to draw where no glyph exists (an emoji in Segoe UI Emoji).
    static func fallback(symbol: String) -> String? { PopoverGlyphTable.entry(symbol)?.fallback }
}
#endif
