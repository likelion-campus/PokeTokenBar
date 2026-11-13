import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaIceArtTests: XCTestCase {
    private func rgba(_ image: CGImage) -> [UInt8] {
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    /// Opaque pixels by colour, plus clear (alpha 0) under key `nil`.
    private func counts(_ image: CGImage) -> [UInt32?: Int] {
        let d = rgba(image)
        var result: [UInt32?: Int] = [:]
        for i in stride(from: 0, to: d.count, by: 4) {
            if d[i + 3] == 0 { result[nil, default: 0] += 1; continue }
            XCTAssertEqual(d[i + 3], 255)
            result[UInt32(d[i]) << 16 | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]), default: 0] += 1
        }
        return result
    }

    private func pixel(_ d: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> UInt32? {
        let i = (y * w + x) * 4
        return d[i + 3] == 0 ? nil : UInt32(d[i]) << 16 | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2])
    }

    private func solid(_ w: Int, _ h: Int, _ color: UInt32, set: [(Int, Int, UInt32)] = []) -> CGImage {
        var d = [UInt8](repeating: 255, count: w * h * 4)
        func put(_ x: Int, _ y: Int, _ c: UInt32) {
            let i = (y * w + x) * 4
            d[i] = UInt8(c >> 16 & 0xFF); d[i + 1] = UInt8(c >> 8 & 0xFF); d[i + 2] = UInt8(c & 0xFF)
        }
        for y in 0..<h { for x in 0..<w { put(x, y, color) } }
        for s in set { put(s.0, s.1, s.2) }
        let provider = CGDataProvider(data: Data(d) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testTheGlossCellKeepsItsThreeLightColours() throws {
        let sheet = try XCTUnwrap(PlazaResources.iceGlossSheet(in: PlazaResources.resourceBundle()))
        let gloss = PlazaIceArt.gloss(fromSheet: sheet)
        XCTAssertEqual([gloss.width, gloss.height], [16, 16])
        let c = counts(gloss)
        XCTAssertEqual(c[0xB5D3EF], 97)
        XCTAssertEqual(c[0xC0DBF3], 45)
        XCTAssertEqual(c[0xD0E5F8], 15)
        XCTAssertEqual(c[nil], 99)
    }

    func testCracksKeepOnlyTheCrackPixelsAndMirrorTheSecondSix() throws {
        let sheet = try XCTUnwrap(PlazaResources.iceCrackSheet(in: PlazaResources.resourceBundle()))
        let cracks = PlazaIceArt.cracks(fromSheet: sheet)
        XCTAssertEqual(cracks.count, 12)
        XCTAssertTrue(cracks.allSatisfy { $0.width == 16 && $0.height == 16 })
        for (i, expected) in [59, 59, 58, 48, 62, 47].enumerated() {
            let c = counts(cracks[i])
            XCTAssertEqual(c[0x6A97C6], expected, "cell \(i)")
            XCTAssertEqual(c[nil, default: 0] + expected, 256, "cell \(i): everything else is clear")
        }
        for i in 0..<6 {
            let a = rgba(cracks[i]), b = rgba(cracks[6 + i])
            for y in 0..<16 { for x in 0..<16 {
                XCTAssertEqual(pixel(b, 16, x, y), pixel(a, 16, 15 - x, y), "cell \(i) (\(x),\(y))")
            } }
        }
    }

    func testShardsAreFramesTwoToFourRecoloured() throws {
        let frames = PlazaResources.iceShatterFrames(in: PlazaResources.resourceBundle())
        let shards = PlazaIceArt.shards(fromFrames: frames)
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.width == 32 && $0.height == 32 })
        let opaque = shards.map { 1024 - counts($0)[nil, default: 0] }
        XCTAssertEqual(opaque, [205, 97, 12])
        let first = counts(shards[0])
        XCTAssertEqual(first[0x6A98C8], 99)
        XCTAssertEqual(first[0x8FB7DE], 58)
        XCTAssertEqual(first[0xD8EAF8], 39)
        XCTAssertEqual(first[0xF4FAFF], 9)
        XCTAssertEqual(counts(shards[2])[0x6A98C8], 12)
        XCTAssertEqual(PlazaIceArt.shards(fromFrames: Array(frames.prefix(3))).count, 0)
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

    private func snowMap() throws -> CGImage {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
        let art = PlazaResources.tallGrassSheet().map(PlazaSnowSheet.tallGrass).flatMap(PlazaTallGrassArt.init(sheet:))
        return PlazaTileArt.mapImage(PlazaMapData.map, sheet: PlazaSnowSheet.tiles(sheet), tallGrass: art)
    }

    func testTheOverlaysMatchTheApprovedMock() throws {
        let map = PlazaMapData.map
        let image = try snowMap()
        let gloss = PlazaIceArt.load().gloss
        XCTAssertNotNil(gloss)
        let expected: [TilePoint: (w: Int, h: Int, c: [UInt32: Int], clear: Int)] = [
            TilePoint(x: 32, y: 14): (288, 288, [0xADCDEC: 51797, 0xB5D3EF: 2038, 0x94B9DF: 1040, 0xC0DBF3: 900,
                                                0xC8DEF4: 420, 0xD0E5F8: 297], 26452),
            TilePoint(x: 5, y: 13): (384, 160, [0xADCDEC: 33180, 0xB5D3EF: 1213, 0x94B9DF: 1460, 0xC0DBF3: 531,
                                               0xC8DEF4: 408, 0xD0E5F8: 172], 24476),
            TilePoint(x: 20, y: 24): (160, 160, [0xADCDEC: 11012, 0xB5D3EF: 223, 0x94B9DF: 480, 0xC0DBF3: 89,
                                                0xC8DEF4: 212, 0xD0E5F8: 28], 13556)
        ]
        let ponds = PlazaIce.ponds(in: map)
        XCTAssertEqual(Set(ponds.map(\.anchor)), Set(expected.keys))
        for pond in ponds {
            let e = try XCTUnwrap(expected[pond.anchor])
            let overlay = PlazaIceArt.overlay(mapImage: image, pond: pond, gloss: gloss)
            XCTAssertEqual([overlay.width, overlay.height], [e.w, e.h], "\(pond.anchor)")
            let c = counts(overlay)
            for (color, n) in e.c { XCTAssertEqual(c[color], n, "\(pond.anchor) #\(String(color, radix: 16))") }
            XCTAssertEqual(c[nil], e.clear, "\(pond.anchor) clear")
            XCTAssertEqual(c.values.reduce(0, +), e.w * e.h, "\(pond.anchor) has no other colours")
        }
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

    func testWithoutTheFilesThePiecesAreEmptyAndTheOverlayStillBuilds() throws {
        let none = PlazaIceArt.load(bundle: nil)
        XCTAssertNil(none.gloss)
        XCTAssertEqual(none.cracks.count, 0)
        XCTAssertEqual(none.shards.count, 0)
        let pond = try XCTUnwrap(PlazaIce.ponds(in: PlazaMapData.map).first { $0.anchor == TilePoint(x: 32, y: 14) })
        let c = counts(PlazaIceArt.overlay(mapImage: try snowMap(), pond: pond, gloss: nil))
        for color in PlazaIceArt.glossColors { XCTAssertNil(c[color]) }
        XCTAssertEqual(c[0xADCDEC], 51797 + 3235)
    }
}
