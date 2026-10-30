import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaTileArtTests: XCTestCase {
    func testMapImageSize() {
        let img = PlazaTileArt.mapImage(PlazaMapData.map)
        XCTAssertEqual(img.width, 48 * 32); XCTAssertEqual(img.height, 32 * 32)
    }

    func testDeterministic() {
        let map = PlazaMapData.map, p = map.spawn
        let a = pixels(PlazaTileArt.tileImage(at: p, in: map))
        let b = pixels(PlazaTileArt.tileImage(at: p, in: map))
        XCTAssertEqual(a.count, 32 * 32 * 4)
        XCTAssertEqual(a, b)
    }

    func testPathEdgeDiffersFromInterior() throws {
        // 가운데(1,1)만 왼쪽 이웃이 풀이다. 보드와 쉼터는 지도 검증을 통과시키려고 아래 줄에 둔다.
        let map = try PlazaMap(rows: ["PPP", ".PP", "PPP", "NS."])
        let px = pixels(PlazaTileArt.tileImage(at: TilePoint(x: 1, y: 1), in: map))
        XCTAssertEqual(px.count, 32 * 32 * 4)
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * 32 + x) * 4..<(y * 32 + x) * 4 + 3]) }
        let edge = rgb(0, 10)
        // 왼쪽 끝 열은 모두 같은 테두리색이고, 가운데 열과 다르다
        for y in 0..<32 {
            XCTAssertEqual(rgb(0, y), edge, "y=\(y)")
            XCTAssertNotEqual(rgb(0, y), rgb(16, y), "y=\(y)")
        }
        // 이웃이 길인 오른쪽 끝 열에는 테두리색이 없다
        XCTAssertFalse((0..<32).contains { rgb(31, $0) == edge })
    }

    func testEveryTileKindIsOpaque() throws {
        let map = try PlazaMap(rows: [".,fPS", "WTbFN"])
        for y in 0..<map.height {
            for x in 0..<map.width {
                let px = pixels(PlazaTileArt.tileImage(at: TilePoint(x: x, y: y), in: map))
                XCTAssertEqual(px.count, 32 * 32 * 4)
                for i in stride(from: 3, to: px.count, by: 4) {
                    XCTAssertEqual(px[i], 255, "tile (\(x),\(y)) pixel \(i / 4)")
                }
            }
        }
    }

    func testSameKindDiffersByPosition() throws {
        let map = try PlazaMap(rows: ["..", "NS"])
        let a = pixels(PlazaTileArt.tileImage(at: TilePoint(x: 0, y: 0), in: map))
        let b = pixels(PlazaTileArt.tileImage(at: TilePoint(x: 1, y: 0), in: map))
        XCTAssertNotEqual(a, b)
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
