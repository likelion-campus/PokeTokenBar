import XCTest
@testable import PokeTokenBar

final class PlazaIceArtTests: XCTestCase {
    func rgba(_ image: PlazaImage) -> [UInt8] { image.pixels.bytes }

    /// Opaque pixels by colour, plus clear (alpha 0) under key `nil`.
    func counts(_ image: PlazaImage) -> [UInt32?: Int] {
        let d = rgba(image)
        var result: [UInt32?: Int] = [:]
        for i in stride(from: 0, to: d.count, by: 4) {
            if d[i + 3] == 0 { result[nil, default: 0] += 1; continue }
            XCTAssertEqual(d[i + 3], 255)
            result[UInt32(d[i]) << 16 | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]), default: 0] += 1
        }
        return result
    }

    func pixel(_ d: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> UInt32? {
        let i = (y * w + x) * 4
        return d[i + 3] == 0 ? nil : UInt32(d[i]) << 16 | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2])
    }

    private func solid(_ w: Int, _ h: Int, _ color: UInt32, set: [(Int, Int, UInt32)] = []) -> PlazaImage {
        func rgba(_ c: UInt32) -> PlazaRGBA { PlazaRGBA(r: UInt8(c >> 16 & 0xFF), g: UInt8(c >> 8 & 0xFF), b: UInt8(c & 0xFF), a: 255) }
        var bitmap = PlazaBitmap(width: w, height: h, fill: rgba(color))
        for s in set { bitmap[s.0, s.1] = rgba(s.2) }
        return PlazaImage(bitmap: bitmap)
    }

    func testOverlayRulesOnASyntheticMap() throws {
        let map = try PlazaMap(rows: ["SN....", "......", "..ww..", "......"])
        let image = solid(192, 128, 0x6DB955, set: [
            (70, 70, 0x5AAEE4), (71, 70, 0x328E41), (72, 70, 0x123456), (73, 70, 0x165C88),
            (40, 40, 0x5AAEE4), (41, 40, 0x1E7CB8), (42, 40, 0x165C88), (43, 40, 0x328E41), (44, 40, 0x123456)
        ])
        let pond = try XCTUnwrap(PlazaIce.ponds(in: map).first)
        let overlay = PlazaIceArt.overlay(mapImage: image, pond: pond, gloss: nil)
        XCTAssertEqual([overlay.width, overlay.height], [128, 96])
        let d = rgba(overlay)
        func at(_ x: Int, _ y: Int) -> UInt32? { pixel(d, 128, x, y) }
        XCTAssertEqual(at(38, 38), 0xADCDEC)
        XCTAssertEqual(at(39, 38), 0xADCDEC)
        XCTAssertEqual(at(40, 38), 0xADCDEC)
        XCTAssertEqual(at(41, 38), 0x94B9DF)
        XCTAssertEqual(at(8, 8), 0xC8DEF4)
        XCTAssertEqual(at(9, 8), 0xADCDEC)
        XCTAssertEqual(at(10, 8), 0x94B9DF)
        XCTAssertNil(at(11, 8))
        XCTAssertNil(at(12, 8))
        XCTAssertEqual(at(70, 40), 0xADCDEC)
        XCTAssertNil(at(0, 0))
    }

    func testAPondAtTheMapCornerIsClippedToTheMap() throws {
        let map = try PlazaMap(rows: ["SN....", "......", "......", "....ww"])
        let image = solid(192, 128, 0x6DB955, set: [])
        let pond = try XCTUnwrap(PlazaIce.ponds(in: map).first)
        let overlay = PlazaIceArt.overlay(mapImage: image, pond: pond, gloss: nil)
        XCTAssertEqual([overlay.width, overlay.height], [128, 96])
        let d = rgba(overlay)
        XCTAssertEqual(pixel(d, 128, 40, 40), 0xADCDEC)
        XCTAssertNil(pixel(d, 128, 5, 5))
    }

    func testGlossPatchesAreFixedPerPond() {
        typealias P = PlazaIceArt.GlossPatch
        XCTAssertEqual(PlazaIceArt.glossPatches.count, 3)
        XCTAssertEqual(PlazaIceArt.glossPatches[TilePoint(x: 32, y: 14)],
                       [P(i: 1, j: 1, n: 2, rx: 30, ry: 22), P(i: 4, j: 3, n: 2, rx: 31, ry: 23),
                        P(i: 1, j: 5, n: 1, rx: 15, ry: 12), P(i: 5, j: 0, n: 1, rx: 15, ry: 12)])
        XCTAssertEqual(PlazaIceArt.glossPatches[TilePoint(x: 5, y: 13)],
                       [P(i: 1, j: 0, n: 2, rx: 30, ry: 22), P(i: 5, j: 1, n: 1, rx: 15, ry: 12),
                        P(i: 8, j: 0, n: 1, rx: 15, ry: 12)])
        XCTAssertEqual(PlazaIceArt.glossPatches[TilePoint(x: 20, y: 24)], [P(i: 1, j: 1, n: 1, rx: 15, ry: 12)])
    }
}
