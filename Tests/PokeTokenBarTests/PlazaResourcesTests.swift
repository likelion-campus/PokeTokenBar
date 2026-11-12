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
                       "https://opengameart.org/content/pokemon-inspired-16x16-tiles", "unmodified", "CC-BY-SA-3.0.txt", "snow days"] {
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
        let font = PlazaResources.font(.small, in: nil)
        XCTAssertEqual(font.pointSize, PlazaTextSize.small.points)
        XCTAssertFalse(PlazaResources.registerFonts(in: nil))
    }
}
