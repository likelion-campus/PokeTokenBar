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

    func testCreditsNameTheBigTreeCut() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["(83, 48)", "42×48", "big tree", "plaza-tallgrass.png"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testCreditsNameTheWaterBalloonArtist() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["rrcaseyr", "Water gun fight art", "https://opengameart.org/content/water-gun-fight-art", "plaza-water-balloon.png"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testCreditsNameTheBalloonAndBlossomArtists() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["Kris Occhipinti", "Balloon Pop Sprite", "https://opengameart.org/content/balloon-pop-sprite", "plaza-balloons.png",
                       "CC-BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/", "No pixel is redrawn",
                       "tiopalada", "Spring VFX Pack", "https://opengameart.org/content/spring-vfx-pack", "plaza-sakura.png", "CC0 1.0",
                       "(490, 874)"] {
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

    func testSteamSheetLoads() throws {
        let steam = try XCTUnwrap(BundledArt.image(PlazaResources.steamSheetName))
        XCTAssertEqual([steam.width, steam.height], [224, 32])
    }

    func testTheSixFramesAreTheFirstSixCellsAndTheSeventhIsEmpty() throws {
        let steam = try XCTUnwrap(BundledArt.image(PlazaResources.steamSheetName))
        XCTAssertEqual(PlazaResources.steamFrames.count, 6)
        for (i, f) in PlazaResources.steamFrames.enumerated() {
            XCTAssertEqual([f.x, f.y, f.width, f.height], [32 * i, 0, 32, 32])
        }
        func opaque(_ rect: PlazaPixelRect) throws -> Int {
            let crop = try XCTUnwrap(steam.cropping(to: rect)).pixels.bytes
            return stride(from: 3, to: crop.count, by: 4).filter { crop[$0] != 0 }.count
        }
        XCTAssertEqual(try PlazaResources.steamFrames.map(opaque), [327, 321, 215, 80, 18, 4])
        XCTAssertEqual(try opaque(PlazaPixelRect(x: 192, y: 0, width: 32, height: 32)), 0, "the seventh cell is empty")
    }

    func testBombSheetHasFourFramesWithABomb() throws {
        let sheet = try XCTUnwrap(BundledArt.image(PlazaResources.bombSheetName))
        XCTAssertEqual([sheet.width, sheet.height], [64, 16])
        XCTAssertEqual(PlazaResources.bombFrames.count, 4)
        for f in PlazaResources.bombFrames {
            let crop = try XCTUnwrap(sheet.cropping(to: f)).pixels.bytes
            XCTAssertGreaterThan(stride(from: 3, to: crop.count, by: 4).filter { crop[$0] != 0 }.count, 80)
        }
    }

    func testFortuneCookieIsTheArtistsSixteenPixelCookie() throws {
        let image = try XCTUnwrap(BundledArt.image(PlazaResources.fortuneCookieName))
        XCTAssertEqual([image.width, image.height], [16, 16])
        let crop = image.pixels.cropped(to: PlazaFortuneArt.cookieCrop)
        let all = image.pixels.bytes, inside = crop.bytes
        func opaque(_ b: [UInt8]) -> Int { stride(from: 3, to: b.count, by: 4).filter { b[$0] != 0 }.count }
        XCTAssertEqual(opaque(all), 96)
        XCTAssertEqual(opaque(inside), 96, "the crop holds the whole cookie")
        let colours = Set((0..<crop.height).flatMap { y in (0..<crop.width).map { crop[$0, y] } }.filter { $0.a != 0 })
        XCTAssertEqual(colours, Set(PlazaFortuneArt.swaps.map(\.from)), "every colour of the cookie has a swap")
    }

    func testCreditsNameTheFortuneCookieArtist() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["ARoachIFoundOnMyPillow", "16x16 Food", "https://opengameart.org/content/16x16-food", "plaza-fortune-cookie.png", "CC0",
                       "8e54514fd7409a5924dd4fe016ac3ed245dfb481eaa54ed81a66c733737fb625", "(289, 358)"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testCreditsNameTheBombArtist() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["victordelima", "16-bit animated bomb", "https://opengameart.org/content/16-bit-animated-bomb", "plaza-bomb.png", "CC0",
                       "80843a315cd25afef02ed7388443be3edeedd84f4fe7a83538c02dbd2c3a5f41"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testCreditsNameTheSteamArtist() throws {
        let credits = try text("CREDITS", "md")
        for needle in ["Aidan_Walker", "Smoke Puff", "https://opengameart.org/content/smoke-puff", "plaza-steam.png", "CC0"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
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
