import XCTest
@testable import PokeTokenBar

/// The Pokémon detail's star button and the Normal/Shiny picker were filled with a hard-coded white while their glyph and text
/// follow the appearance: in dark (and a black high-contrast theme) a near-white star sat on a white box, "the star shape cannot be
/// seen" (user report on the real PC). The fill is the appearance's `controlFill`, the glyph the primary label colour; this holds
/// that pair to WCAG's 3:1 for graphics in every appearance, and bans a hard-coded white box in the Dex parts.
@MainActor
final class DexGlyphButtonContrastTests: XCTestCase {
    private func over(_ c: PlazaColor, _ base: UInt32) -> UInt32 {
        func ch(_ v: Double, _ b: UInt32, _ shift: UInt32) -> UInt32 {
            let under = Double((b >> shift) & 0xFF)
            return UInt32(max(0, min(255, (v * c.alpha * 255 + under * (1 - c.alpha)).rounded())))
        }
        return ch(c.red, base, 16) << 16 | ch(c.green, base, 8) << 8 | ch(c.blue, base, 0)
    }

    func testTheStarGlyphIsReadableOnItsButtonInEveryAppearance() {
        let saved = (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast)
        defer { (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast) = saved }
        let black = PopoverHighContrast(window: 0x000000, text: 0xFFFFFF, highlight: 0x1AEBFF, highlightText: 0x000000)
        let white = PopoverHighContrast(window: 0xFFFFFF, text: 0x000000, highlight: 0x0000C0, highlightText: 0xFFFFFF)
        let cases: [(String, PopoverAppearance, PopoverHighContrast?, UInt32)] = [
            ("light", .light, nil, 0xFFFFFF), ("dark", .dark, nil, 0x2B2B2B),
            ("high contrast black", .light, black, 0x000000), ("high contrast white", .light, white, 0xFFFFFF),
        ]
        for (name, appearance, hc, page) in cases {
            PopoverAppearanceState.appearance = appearance
            PopoverAppearanceState.highContrast = hc
            let fill = over(PopoverAppearance.current.controlFill(alpha: 0.9), page)
            let glyph = over(PopoverColorRole.primary.plazaColor(), fill)
            let ratio = PopoverSurface.contrast(glyph, fill)
            XCTAssertGreaterThanOrEqual(ratio, 3, "\(name): the star glyph \(String(glyph, radix: 16)) on its button \(String(fill, radix: 16)) is \(ratio):1")
        }
    }

    func testTheDexPartsDrawNoHardCodedWhiteBox() throws {
        for file in ["DexDetailPart.swift", "DexBodyPart.swift"] {
            let url = SharedSources.sourcesRoot.appendingPathComponent("Popover/\(file)")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("roundedRect(") && line.contains("fill: PlazaColor(srgbRed: 1, green: 1, blue: 1") {
                XCTFail("\(file):\(i + 1) fills a box with a hard-coded white: use PopoverAppearance.current.controlFill (white in dark hides a light glyph)")
            }
        }
    }
}
