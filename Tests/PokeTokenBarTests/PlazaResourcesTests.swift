import AppKit
import XCTest
@testable import PokeTokenBar

final class PlazaResourcesTests: XCTestCase {
    func testTileSheetLoads() throws {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
        XCTAssertEqual(sheet.width, 640)
        XCTAssertEqual(sheet.height, 576)
    }

    func testFontRegistersAndResolves() {
        XCTAssertTrue(PlazaResources.registerFonts())
        XCTAssertTrue(PlazaResources.registerFonts(), "calling twice stays safe")
        XCTAssertNotNil(NSFont(name: PlazaResources.fontName, size: 11))
        XCTAssertEqual(PlazaResources.font(size: 11).fontName, PlazaResources.fontName)
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
    }

    func testMissingBundleReturnsNilInsteadOfCrashing() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertNil(PlazaResources.resourceBundle(searching: [missing]))
        XCTAssertNil(PlazaResources.tileSheet(in: nil))
        let font = PlazaResources.font(size: 11, in: nil)
        XCTAssertEqual(font.pointSize, 11)
        XCTAssertFalse(PlazaResources.registerFonts(in: nil))
    }
}
