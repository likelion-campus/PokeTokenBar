import AppKit
import CoreText
import CryptoKit
import XCTest
@testable import PokeTokenBar

final class PlazaResourcesTests: XCTestCase {
    func testTileSheetLoads() throws {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
        XCTAssertEqual(sheet.width, 640)
        XCTAssertEqual(sheet.height, 576)
    }

    func testTallGrassSheetLoads() throws {
        let sheet = try XCTUnwrap(PlazaResources.tallGrassSheet())
        XCTAssertEqual(sheet.width, 208)
        XCTAssertEqual(sheet.height, 144)
    }

    /// The CC-BY-SA credit says "unmodified", so the bundled bytes must stay the original file.
    func testTallGrassSheetIsTheUnmodifiedOriginal() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        let url = try XCTUnwrap(PlazaResources.resourceURL("plaza-tallgrass", "png", in: bundle))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "d8b02d00acf54d3daf21c33e1cd7873ba6d82b3aa949989258e5d785885319fd")
    }

    func testCreditsNameTheTallGrassLicense() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        let url = try XCTUnwrap(PlazaResources.resourceURL("CREDITS", "md", in: bundle))
        let credits = try String(contentsOf: url, encoding: .utf8)
        for needle in ["RedVoxel", "CC-BY-SA 3.0", "https://creativecommons.org/licenses/by-sa/3.0/",
                       "https://opengameart.org/content/pokemon-inspired-16x16-tiles", "unmodified", "CC-BY-SA-3.0.txt", "winter and autumn"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    /// The CC-BY-SA credit says "unmodified", so the bundled bytes must stay the original file.
    func testWaterBalloonIsTheUnmodifiedOriginalAndCredited() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        let url = try XCTUnwrap(PlazaResources.resourceURL("plaza-water-balloon", "png", in: bundle))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "3ae2d716a639227daa849d3885306be9798bb89dc7c62a2507518887fca1902b")
        let credits = try String(contentsOf: try XCTUnwrap(PlazaResources.resourceURL("CREDITS", "md", in: bundle)), encoding: .utf8)
        for needle in ["rrcaseyr", "Water gun fight art", "https://opengameart.org/content/water-gun-fight-art", "plaza-water-balloon.png"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }

    func testFontsRegisterAndResolve() {
        XCTAssertTrue(PlazaResources.registerFonts())
        XCTAssertTrue(PlazaResources.registerFonts(), "calling twice stays safe")
        for size in PlazaTextSize.allCases {
            let font = PlazaResources.font(size)
            XCTAssertEqual(font.fontName, size.fontName)
            XCTAssertEqual(font.pointSize, size.points)
        }
    }

    /// One font pixel is exactly one point at each size, so it is a whole number of device pixels on 1x and 2x
    /// screens. Off the grid (Galmuri11 at 14pt is 2.33 pixels a dot on Retina) the strokes come out uneven.
    func testEachSizeIsOnItsFontsPixelGrid() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        for size in PlazaTextSize.allCases {
            let url = try XCTUnwrap(PlazaResources.resourceURL(size.fileName, "ttf", in: bundle))
            let descriptor = try XCTUnwrap((CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first)
            XCTAssertEqual(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, size.fontName,
                           "the name the app asks for is the font in that file")
            let unitsPerEm = CTFontGetUnitsPerEm(CTFontCreateWithFontDescriptor(descriptor, 12, nil))
            let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(unitsPerEm), nil)
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
            var grid = 0
            for scalar in "가나한글ㅎABab12".unicodeScalars {
                var char = UniChar(scalar.value), glyph = CGGlyph(0)
                CTFontGetGlyphsForCharacters(font, &char, &glyph, 1)
                CTFontCreatePathForGlyph(font, glyph, nil)?.applyWithBlock { element in
                    let count = switch element.pointee.type {
                    case .moveToPoint, .addLineToPoint: 1
                    case .addQuadCurveToPoint: 2
                    case .addCurveToPoint: 3
                    default: 0
                    }
                    for i in 0..<count {
                        let p = element.pointee.points[i]
                        grid = gcd(grid, Int(p.x.rounded()))
                        grid = gcd(grid, Int(p.y.rounded()))
                    }
                }
            }
            XCTAssertGreaterThan(grid, 0, size.fileName)
            let pixelsPerEm = CGFloat(unitsPerEm) / CGFloat(grid)
            XCTAssertEqual(size.points, pixelsPerEm, "\(size.fileName): one font pixel must be one point")
        }
    }

    func testBuildScriptCopiesResourceBundle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let lines = script.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("PokeTokenBar_PokeTokenBar.bundle") && $0.contains("Contents/Resources") },
                      "build-app.sh must copy the SwiftPM resource bundle into Contents/Resources")
    }

    func testLicenseAndCreditsShipWithResources() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        XCTAssertNotNil(PlazaResources.resourceURL("Galmuri-OFL", "txt", in: bundle))
        XCTAssertNotNil(PlazaResources.resourceURL("CREDITS", "md", in: bundle))
        XCTAssertNotNil(PlazaResources.resourceURL("CC-BY-SA-3.0", "txt", in: bundle))
    }

    func testMissingBundleReturnsNilInsteadOfCrashing() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertNil(PlazaResources.resourceBundle(searching: [missing]))
        XCTAssertNil(PlazaResources.tileSheet(in: nil))
        XCTAssertNil(PlazaResources.tallGrassSheet(in: nil))
        XCTAssertNil(PlazaResources.iceCrackSheet(in: nil))
        XCTAssertNil(PlazaResources.iceGlossSheet(in: nil))
        XCTAssertEqual(PlazaResources.iceShatterFrames(in: nil).count, 0)
        let font = PlazaResources.font(.small, in: nil)
        XCTAssertEqual(font.pointSize, PlazaTextSize.small.points)
        XCTAssertFalse(PlazaResources.registerFonts(in: nil))
    }

    private static let iceDigests: [(name: String, ext: String, sha: String)] = [
        ("plaza-ice-cracks", "png", "28faadcc4cddd8cc8a6962bb5c5a5bdd475c4133d174ac979a3d74a309397f3e"),
        ("plaza-ice-gloss", "png", "9973d4d6674d0f3cb475d33878f832ee05dc057e2adfae006577688c85d01214"),
        ("plaza-ice-shatter", "gif", "b5907dd9b03aec03bd4a26acb48b125d8af528a7170dbc1326562d88b54587db")
    ]

    func testIceFilesAreTheUnmodifiedOriginals() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        for file in Self.iceDigests {
            let url = try XCTUnwrap(PlazaResources.resourceURL(file.name, file.ext, in: bundle), file.name)
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, file.sha, file.name)
        }
    }

    func testIceFilesLoad() throws {
        let cracks = try XCTUnwrap(PlazaResources.iceCrackSheet(in: PlazaResources.resourceBundle()))
        XCTAssertEqual([cracks.width, cracks.height], [256, 256])
        let gloss = try XCTUnwrap(PlazaResources.iceGlossSheet(in: PlazaResources.resourceBundle()))
        XCTAssertEqual([gloss.width, gloss.height], [84, 67])
        let frames = PlazaResources.iceShatterFrames(in: PlazaResources.resourceBundle())
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.width == 32 && $0.height == 32 })
    }

    func testCreditsNameTheIceArtists() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        let url = try XCTUnwrap(PlazaResources.resourceURL("CREDITS", "md", in: bundle))
        let credits = try String(contentsOf: url, encoding: .utf8)
        for needle in ["Ice Mountains Tileset", "CookieEfedu", "CC-BY 4.0", "https://creativecommons.org/licenses/by/4.0/",
                       "https://opengameart.org/content/ice-mountains-tileset", "crack pixels",
                       "Some 16x16 floor tiles", "ChikenwingJJA", "Shattering Boulder", "Spring Spring"] {
            XCTAssertTrue(credits.contains(needle), needle)
        }
    }
}
