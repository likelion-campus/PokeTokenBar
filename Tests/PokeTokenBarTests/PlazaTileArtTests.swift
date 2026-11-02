import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaTileArtTests: XCTestCase {
    /// The full map is rendered once per class; tests that only inspect the result reuse it.
    private static let sharedMapImage: CGImage? = PlazaResources.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0) }
    private func sharedMap() throws -> CGImage { try XCTUnwrap(Self.sharedMapImage) }

    private func sheet() throws -> CGImage { try XCTUnwrap(PlazaResources.tileSheet()) }

    /// 2x2 보드와 쉼터 한 칸이 있는 작은 지도. 왼쪽 위 2x2는 나무다.
    private func smallMap(_ at: String = ".") throws -> PlazaMap {
        try PlazaMap(rows: ["TT" + at + "...", "TT.NN.", "...NN.", "..S..."])
    }

    func testMapImageSize() throws {
        let img = try sharedMap()
        XCTAssertEqual(img.width, 48 * 32); XCTAssertEqual(img.height, 32 * 32)
    }

    func testDeterministic() throws {
        let sheet = try sheet()
        let a = pixels(try sharedMap())
        let b = pixels(PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet))
        XCTAssertEqual(a.count, 48 * 32 * 32 * 32 * 4)
        XCTAssertEqual(a, b)
    }

    func testFlowerCellDiffersFromPlainGrassAndTreeCellIsNotGrass() throws {
        let sheet = try sheet()
        // 같은 위치 (2,0): 잔디 변형이 같으니 꽃이 있는 쪽만 달라야 한다.
        let plain = pixels(PlazaTileArt.mapImage(try smallMap("."), sheet: sheet))
        let flower = pixels(PlazaTileArt.mapImage(try smallMap("f"), sheet: sheet))
        XCTAssertNotEqual(tile(plain, 2, 0, width: 6 * 32), tile(flower, 2, 0, width: 6 * 32))

        // 나무 칸 (0,0)의 가운데 픽셀은 잔디 변형 8종의 같은 위치 색과 모두 다르다.
        let tree = pixels(PlazaTileArt.mapImage(try smallMap("."), sheet: sheet))
        let treeColor = pixel(tree, 16, 16, width: 6 * 32)
        let sheetPx = pixels(sheet)
        for (c, r) in [(0, 9), (1, 9), (0, 10), (1, 10), (5, 9), (8, 9), (5, 10), (8, 10)] {
            let grass = pixel(sheetPx, c * 16 + 8, r * 16 + 8, width: sheet.width)
            XCTAssertNotEqual(treeColor, grass, "variant (\(c),\(r))")
        }
    }

    func testArtIsUpscaledTwiceWithoutSmoothing() throws {
        let px = pixels(PlazaTileArt.mapImage(try smallMap(), sheet: try sheet()))
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

    /// The board is drawn as the two-cell signpost from the sheet, at the board tile.
    func testBoardIsDrawnAsTheSignpost() throws {
        let sheet = try sheet(), sheetPx = pixels(sheet), map = PlazaMapData.map
        let mapPx = pixels(try sharedMap()), width = map.width * 32
        var compared = 0
        for sy in 0..<16 {
            for sx in 0..<32 {
                let s = pixel(sheetPx, 34 * 16 + sx, 2 * 16 + sy, width: sheet.width)
                guard s[3] == 255 else { continue }
                let m = pixel(mapPx, map.boardTile.x * 32 + sx * 2, map.boardTile.y * 32 + sy * 2, width: width)
                XCTAssertEqual(Array(m[0..<3]), Array(s[0..<3]), "(\(sx),\(sy))")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 100, "the sign has opaque pixels to compare")
    }

    func testEveryPixelIsOpaque() throws {
        let px = pixels(try sharedMap())
        XCTAssertFalse(stride(from: 3, to: px.count, by: 4).contains { px[$0] != 255 })
    }

    private func pixel(_ px: [UInt8], _ x: Int, _ y: Int, width: Int) -> [UInt8] {
        Array(px[(y * width + x) * 4..<(y * width + x) * 4 + 4])
    }

    private func tile(_ px: [UInt8], _ tx: Int, _ ty: Int, width: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<32 {
            let start = ((ty * 32 + row) * width + tx * 32) * 4
            out += px[start..<start + 32 * 4]
        }
        return out
    }

    /// RGBA8 비트맵 컨텍스트에 그려 실제 바이트를 반환한다.
    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }
}
