import XCTest
@testable import PokeTokenBar

final class PlazaTileArtTests: XCTestCase {
    /// A synthetic opaque sheet (36 x 18 cells) where every pixel differs: a blit from the wrong cell cannot pass.
    private static let sheet = PlazaImage(bitmap: PlazaTestImages.patterned(width: 36 * 16, height: 18 * 16, alpha: .noneSkipLast))
    private static let fullMap = PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet)

    func pixel(_ px: [UInt8], _ x: Int, _ y: Int, width: Int) -> [UInt8] {
        Array(px[(y * width + x) * 4..<(y * width + x) * 4 + 4])
    }

    func tile(_ px: [UInt8], _ tx: Int, _ ty: Int, width: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<32 {
            let start = ((ty * 32 + row) * width + tx * 32) * 4
            out += px[start..<start + 32 * 4]
        }
        return out
    }

    func testMapImageSizeAndOpacityOnASyntheticSheet() {
        let img = Self.fullMap
        XCTAssertEqual(img.width, 48 * 32); XCTAssertEqual(img.height, 32 * 32)
        let px = img.pixels.bytes
        XCTAssertFalse(stride(from: 3, to: px.count, by: 4).contains { px[$0] != 255 })
    }

    func testDeterministicOnASyntheticSheet() {
        let again = PlazaTileArt.mapImage(PlazaMapData.map, sheet: Self.sheet)
        XCTAssertEqual(Self.fullMap.pixels.bytes, again.pixels.bytes)
    }

    func testWaterIsTheSheetWaterCellDoubled() throws {
        let sp = Self.sheet.pixels.bytes, w = 8 * 32
        let map = try PlazaMap(rows: ["........", "........", "..ww....", "..ww....", "........", "T..NN.S."])
        let img = PlazaTileArt.mapImage(map, sheet: Self.sheet).pixels.bytes
        var expected: [UInt8] = []
        for r in 0..<32 { for c in 0..<32 { expected += pixel(sp, 3 * 16 + c / 2, 7 * 16 + r / 2, width: Self.sheet.width) } }
        XCTAssertEqual(tile(img, 2, 2, width: w), expected)
    }

    func testArtIsUpscaledTwiceOnASyntheticSheet() throws {
        let map = try PlazaMap(rows: ["TT....", "TT.NN.", "...NN.", "..S..."])
        let px = PlazaTileArt.mapImage(map, sheet: Self.sheet).pixels.bytes
        let w = 6 * 32
        for by in stride(from: 0, to: 4 * 32, by: 2) {
            for bx in stride(from: 0, to: w, by: 2) {
                let c = pixel(px, bx, by, width: w)
                XCTAssertEqual(pixel(px, bx + 1, by, width: w), c)
                XCTAssertEqual(pixel(px, bx, by + 1, width: w), c)
                XCTAssertEqual(pixel(px, bx + 1, by + 1, width: w), c)
            }
        }
    }

    func testPlainGrassIsOneOpaqueGreen() throws {
        let map = try PlazaMap(rows: ["TT....", "TT.NN.", "...NN.", "..S..."])
        let image = PlazaTileArt.plainGrassImage(map)
        XCTAssertEqual([image.width, image.height], [192, 128])
        let px = image.pixels.bytes
        for i in stride(from: 0, to: px.count, by: 4) { XCTAssertEqual(Array(px[i..<i + 4]), [0x6D, 0xB9, 0x55, 255]) }
    }
}
