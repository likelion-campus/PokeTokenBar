import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaSnowballTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testAimHitsTheFirstTargetAhead() {
        let a = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(14, 12), "b": p(12, 12)], map: map)
        XCTAssertEqual(a?.end, .actor(id: "b", tile: p(12, 12)))
        XCTAssertEqual(a?.frames, 2)
        let b = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(16, 12)], map: map)
        XCTAssertEqual(b?.end, .ground(p(15, 12)))
        XCTAssertEqual(b?.frames, 5)
        let c = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["x": p(10, 12)], map: map)
        XCTAssertEqual(c?.end, .ground(p(15, 12)))
        let d = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["b": p(12, 12), "a": p(12, 12)], map: map)
        XCTAssertEqual(d?.end, .actor(id: "a", tile: p(12, 12)))
    }

    func testAimStopsBeforeObstaclesAndFliesOverWater() {
        let a = PlazaSnowball.aim(from: p(12, 17), facing: .right, targets: ["m": p(16, 17)], map: map)
        XCTAssertEqual(a?.end, .ground(p(14, 17)))
        let b = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: [:], map: map)
        XCTAssertEqual(b?.end, .ground(p(12, 14)))
        let c = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: ["s": p(13, 14)], map: map)
        XCTAssertEqual(c?.end, .actor(id: "s", tile: p(13, 14)))
    }

    func testFacingAnObstacleOrTheEdgeThrowsNothing() {
        XCTAssertNil(PlazaSnowball.aim(from: p(3, 12), facing: .left, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(44, 12), facing: .right, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(14, 17), facing: .right, targets: [:], map: map))
    }

    func testHitsNeedTheSameLineTheRightWayWithinSix() {
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .left))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(8, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(7, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 11), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(14, 12), target: p(14, 12), direction: .right))
    }

    func testFramesAreTheTileCountFromOneToSix() {
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .down, end: .actor(id: nil, tile: p(0, 9))).frames, 6)
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .right, end: .ground(p(1, 0))).frames, 1)
    }

    func testTheArcStartsAtTheHandPeaksAndEndsOnTheBodyOrTheGround() {
        XCTAssertEqual(PlazaSnowball.height(at: 0, endHeight: 24), 14)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 24), 24)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 0), 0)
        XCTAssertEqual(PlazaSnowball.height(at: 0.5, endHeight: 0), 23)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 0), 14)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 30), 15)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 80), 24)
    }

    func testBurstPiecesSpreadToSixteenAndStayUpOnAMiss() {
        let radius: [CGFloat] = [9, 11, 14, 16], drop: [CGFloat] = [0, 1, 4, 8], glyphs = [1, 0, 1, 2]
        for step in 0..<4 {
            let ground = PlazaSnowball.burstPieces(step: step, onGround: true)
            let air = PlazaSnowball.burstPieces(step: step, onGround: false)
            XCTAssertEqual(ground.count, step == 0 ? 5 : 5)
            XCTAssertEqual(air.count, step == 0 ? 5 : 6)
            if step == 0 {
                for set in [ground, air] {
                    XCTAssertTrue(set.contains { $0.offset == CGVector(dx: 0, dy: 0) && $0.glyph == 0 })
                }
            }
            for piece in air where !(step == 0 && piece.offset == .zero) {
                XCTAssertEqual(piece.glyph, glyphs[step])
                XCTAssertEqual(hypot(piece.offset.dx, piece.offset.dy + drop[step]), radius[step], accuracy: 1e-9)
                XCTAssertLessThanOrEqual(radius[step], 16)
            }
            for piece in ground {
                XCTAssertLessThanOrEqual(abs(piece.offset.dx), 16)
                XCTAssertGreaterThanOrEqual(piece.offset.dy, 0)
            }
        }
    }

    func testShadedGridsAddTheShadeRightAndBelow() {
        XCTAssertEqual(PlazaSnowballArt.shaded([".W.", "WWW", ".W."]), [".Wo.", "WWWo", "oWo.", ".o.."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["WW", "WS"]), ["WWo", "WSo", "oo."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["W"]), ["Wo", "o."])
    }

    func testSnowballArtUsesOnlySnowColours() {
        let allowed: Set<UInt32> = [0xF6FAFF, 0xC6DAF0, 0x8DA3BF]
        let pieces = PlazaSnowballArt.pieces()
        XCTAssertEqual(pieces.count, 3)
        for image in pieces {
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<(w * h) where data[i * 4 + 3] != 0 {
                XCTAssertEqual(data[i * 4 + 3], 255)
                let rgb = UInt32(data[i * 4]) << 16 | UInt32(data[i * 4 + 1]) << 8 | UInt32(data[i * 4 + 2])
                XCTAssertTrue(allowed.contains(rgb), String(rgb, radix: 16))
            }
        }
        let ball = pieces[0]
        XCTAssertEqual(ball.width, 4)
        XCTAssertEqual(ball.height, 4)
        var data = [UInt8](repeating: 0, count: 64)
        let ctx = CGContext(data: &data, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(ball, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let shade = (0..<16).filter { data[$0 * 4 + 3] == 255 && data[$0 * 4] == 0x8D && data[$0 * 4 + 1] == 0xA3 && data[$0 * 4 + 2] == 0xBF }
        XCTAssertEqual(shade.count, 5)
    }
}
