import XCTest
@testable import PokeTokenBar

/// The bundled plaza files through the platform's own graphics (ImageIO on the Mac, WIC on Windows). The Mac bundle,
/// the CryptoKit digests and the CoreText font grid are in `PlazaResourcesTests+Mac.swift`.
final class PlazaResourcesTests: XCTestCase {
    private func text(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(PlatformPlaza.graphics.assetURL(name, ext: ext), "\(name).\(ext)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTileSheetLoads() throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        XCTAssertEqual(sheet.width, 640)
        XCTAssertEqual(sheet.height, 576)
    }

    func testTallGrassSheetLoads() throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        XCTAssertEqual(sheet.width, 208)
        XCTAssertEqual(sheet.height, 144)
    }

    func testCreditsNameTheTallGrassLicense() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["RedVoxel", "CC-BY-SA 3.0", "https://creativecommons.org/licenses/by-sa/3.0/",
                       "https://opengameart.org/content/pokemon-inspired-16x16-tiles", "unmodified", "CC-BY-SA-3.0.txt", "winter and autumn"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testCreditsNameTheWaterBalloonArtist() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["rrcaseyr", "Water gun fight art", "https://opengameart.org/content/water-gun-fight-art", "plaza-water-balloon.png"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testLeafSheetLoads() throws {
        let sheet = try XCTUnwrap(BundledArt.image(PlazaResources.leafSheetName))
        XCTAssertEqual([sheet.width, sheet.height], [128, 160])
    }

    func testCreditsNameTheLeafSheetArtists() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["William Thompson", "Johann Charlot", "[LPC] Leaf Recolor", "https://opengameart.org/content/lpc-leaf-recolor",
                       "plaza-leaf-sheet.png", "CC-BY-SA 3.0"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testLicenseAndCreditsShipWithResources() {
        let graphics = PlatformPlaza.graphics
        XCTAssertNotNil(graphics.assetURL("Galmuri-OFL", ext: "txt"))
        XCTAssertNotNil(graphics.assetURL("CREDITS", ext: "md"))
        XCTAssertNotNil(graphics.assetURL("CC-BY-SA-3.0", ext: "txt"))
    }

    func testIceFilesLoad() throws {
        let cracks = try XCTUnwrap(BundledArt.image(PlazaResources.iceCrackSheetName))
        XCTAssertEqual([cracks.width, cracks.height], [256, 256])
        let gloss = try XCTUnwrap(BundledArt.image(PlazaResources.iceGlossSheetName))
        XCTAssertEqual([gloss.width, gloss.height], [84, 67])
        let frames = PlatformPlaza.graphics.assetURL(PlazaResources.iceShatterName, ext: "gif")
            .map { PlatformPlaza.graphics.decodeImageFrames(at: $0) } ?? []
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.width == 32 && $0.height == 32 })
    }

    func testCreditsNameTheIceArtists() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["Ice Mountains Tileset", "CookieEfedu", "CC-BY 4.0", "https://creativecommons.org/licenses/by/4.0/",
                       "https://opengameart.org/content/ice-mountains-tileset", "crack pixels",
                       "Some 16x16 floor tiles", "ChikenwingJJA", "Shattering Boulder", "Spring Spring"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }
}
