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
}
