import XCTest
@testable import PokeTokenBar

/// Reads the bundled tall-grass sheet and checks pixel colours on the shared pixels.
extension PlazaTallGrassLayerTests {
    func testSetArtRetexturesTheBandsInPlace() async throws {
        let layer = PlazaTallGrassLayer(map: map, art: try XCTUnwrap(PlatformPlaza.tallGrassArt()))
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let snowy = try XCTUnwrap(PlazaTallGrassArt(sheet: PlazaSnowSheet.tallGrass(sheet)))
        let z = try XCTUnwrap(layer.bandZ(at: a))
        layer.rustle(cue(.bounce))
        layer.update(dt: 0.05)
        XCTAssertEqual(layer.activeRustles.count, 1)
        layer.setArt(snowy)
        XCTAssertTrue(layer.activeRustles.isEmpty)
        XCTAssertEqual(layer.bandZ(at: a), z)
        XCTAssertEqual(layer.bandOffset(at: a), .zero)
        let image = try XCTUnwrap(layer.bandTexture(at: a)).image
        XCTAssertFalse(SnowPixels.contains(image, rgb: [0x99E550, 0x6ABE30]))
    }
}

/// Test helper: does an image hold a fully opaque pixel of one of these colours?
enum SnowPixels {
    static func contains(_ image: PlazaImage, rgb: Set<UInt32>) -> Bool {
        let raw = image.pixels.bytes
        for i in stride(from: 0, to: raw.count, by: 4) where raw[i + 3] == 255 {
            if rgb.contains(UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2])) { return true }
        }
        return false
    }
}
