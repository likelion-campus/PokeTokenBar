import Foundation

/// Every SF Symbol the Mac popover draws (`Tests/PopoverParity/sf-symbols.txt`), as a glyph of Windows' own icon fonts
/// (stage 7 Task 3, D15): Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10 and 11). Code points and names
/// are Microsoft's (learn.microsoft.com, "Segoe Fluent Icons font" and "Segoe MDL2 Assets icons"); the two fonts share most
/// code points. A symbol with no acceptable glyph in either font has none and a `fallback` text instead (an emoji the caller
/// draws as text); `note` says where a glyph only approximates the Mac's symbol. `WinGlyphs` is the Windows entry point.
enum PopoverGlyphTable {
    struct Entry: Equatable, Sendable {
        /// Segoe Fluent Icons code point, nil when that font has no acceptable glyph.
        let fluent: UInt16?
        /// Segoe MDL2 Assets code point, nil when that font has no acceptable glyph.
        let mdl2: UInt16?
        /// The glyph's name in Microsoft's list (Fluent's when both have one).
        let name: String
        /// Text in place of a glyph when neither font has one.
        let fallback: String?
        /// Why the glyph differs from the Mac's symbol, if it does.
        let note: String?

        init(_ fluent: UInt16?, _ mdl2: UInt16?, _ name: String, fallback: String? = nil, note: String? = nil) {
            self.fluent = fluent
            self.mdl2 = mdl2
            self.name = name
            self.fallback = fallback
            self.note = note
        }

        /// The code point for the font in use, nil when the caller draws `fallback`.
        func codePoint(fluent useFluent: Bool) -> UInt16? { useFluent ? fluent : mdl2 }
    }

    static let entries: [String: Entry] = [
        "arrow.clockwise": Entry(0xE72C, 0xE72C, "Refresh"),
        "arrow.right": Entry(0xE72A, 0xE72A, "Forward"),
        "arrow.triangle.2.circlepath": Entry(0xE895, 0xE895, "Sync"),
        "arrow.up.arrow.down": Entry(0xE8CB, 0xE8CB, "Sort"),
        "arrowtriangle.left.fill": Entry(0xF08D, 0xEDD9, "CaretSolidLeft / CaretLeftSolid8"),
        "arrowtriangle.right.fill": Entry(0xF08F, 0xEDDA, "CaretSolidRight / CaretRightSolid8"),
        "chart.bar.xaxis": Entry(0xE9D2, 0xE9D2, "AreaChart", note: "an area chart: neither font has a bar chart"),
        "checkmark": Entry(0xE73E, 0xE73E, "CheckMark"),
        "checkmark.circle": Entry(0xE930, 0xE930, "Completed"),
        "checkmark.seal.fill": Entry(0xEC61, 0xEC61, "CompletedSolid", note: "a filled circle with a check: no seal shape"),
        "chevron.backward": Entry(0xE76B, 0xE76B, "ChevronLeft"),
        "chevron.down": Entry(0xE70D, 0xE70D, "ChevronDown"),
        "chevron.forward": Entry(0xE76C, 0xE76C, "ChevronRight"),
        "chevron.left": Entry(0xE76B, 0xE76B, "ChevronLeft"),
        "chevron.right": Entry(0xE76C, 0xE76C, "ChevronRight"),
        "exclamationmark.triangle": Entry(0xE7BA, 0xE7BA, "Warning"),
        "exclamationmark.triangle.fill": Entry(0xE814, 0xE814, "IncidentTriangle"),
        "eye": Entry(0xE890, 0xE890, "View"),
        "eye.slash": Entry(0xED1A, 0xE9A9, "Hide / PasswordKeyHide", note: "MDL2 has no Hide: its password-box eye with a slash"),
        "flame.fill": Entry(nil, nil, "-", fallback: "\u{1F525}", note: "no flame in either font: the 🔥 emoji (Segoe UI Emoji)"),
        "gearshape": Entry(0xE713, 0xE713, "Settings"),
        "key.slash.fill": Entry(0xE8D7, 0xE8D7, "Permissions", note: "a key without the slash: neither font crosses a key out"),
        "magnifyingglass": Entry(0xE721, 0xE721, "Search"),
        "map": Entry(0xE800, 0xE707, "Nav2DMapView / MapPin", note: "MDL2 has no folded map: its map pin"),
        "power": Entry(0xE7E8, 0xE7E8, "PowerButton"),
        "questionmark.circle": Entry(0xE9CE, 0xE9CE, "Unknown"),
        "sparkle": Entry(nil, nil, "-", fallback: "\u{2728}", note: "no plain sparkle in either font: the ✨ emoji"),
        "sparkles": Entry(nil, nil, "-", fallback: "\u{2728}", note: "no plain sparkles in either font: the ✨ emoji"),
        "star": Entry(0xE734, 0xE734, "FavoriteStar"),
        "star.fill": Entry(0xE735, 0xE735, "FavoriteStarFill"),
        "xmark.circle.fill": Entry(0xEB90, 0xEB90, "StatusErrorFull"),
    ]

    static func entry(_ symbol: String) -> Entry? { entries[symbol] }
}
