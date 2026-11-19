import XCTest

/// The scan half of `DexGlyphButtonContrastTests` (it reads the sources, so it runs on the Mac only): a Dex part must not fill a box with a
/// hard-coded white while its glyph follows the appearance.
@MainActor
final class DexGlyphButtonScanTests: XCTestCase {
    func testTheDexPartsDrawNoHardCodedWhiteBox() async throws {
        for file in ["DexDetailPart.swift", "DexBodyPart.swift"] {
            let url = SharedSources.sourcesRoot.appendingPathComponent("Popover/\(file)")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("roundedRect(") && line.contains("fill: PlazaColor(srgbRed: 1, green: 1, blue: 1") {
                XCTFail("\(file):\(i + 1) fills a box with a hard-coded white: use PopoverAppearance.current.controlFill (white in dark hides a light glyph)")
            }
        }
    }

    /// Text and glyphs in the Dex parts take their colour from the appearance (or `DexPainter.ink(on:)` over a brand fill): a literal white or
    /// black is allowed only on an emoji, whose colour the font ignores.
    func testTheDexPartsPaintNoLiteralBlackOrWhiteInk() async throws {
        for file in ["DexDetailPart.swift", "DexBodyPart.swift", "DexLogPart.swift", "DexPainter.swift"] {
            let url = SharedSources.sourcesRoot.appendingPathComponent("Popover/\(file)")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where (line.contains("color: .white") || line.contains("color: .black")) {
                if line.contains("emoji") || line.contains("✨") || line.contains("f.medal") { continue }
                XCTFail("\(file):\(i + 1) paints with a literal white or black: use a PopoverColorRole or DexPainter.ink(on:)")
            }
        }
    }

    /// The pager's arrows are stroked paths (`drawChevron`), not font glyphs (a font glyph came out invisible on a real PC).
    func testThePagerDrawsItsArrowsAsPaths() async throws {
        let url = SharedSources.sourcesRoot.appendingPathComponent("Popover/DexBodyPart.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("p.drawChevron("), "the pager must draw its arrows with drawChevron")
        let glyphCalls = text.components(separatedBy: "\n").filter { $0.contains("drawGlyph(forward ?") || $0.contains("\"chevron.") }
        XCTAssertTrue(glyphCalls.isEmpty, "the pager's arrows are paths, not font glyphs: \(glyphCalls)")
    }
}
