import XCTest
import CoreGraphics
@testable import PokeTokenBar

extension PlazaSwimLowerHalfTests {

    private func solid(_ w: Int, _ h: Int, r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let o = (y * img.width + x) * 4   // CGContext rows are top-down in the buffer when drawn this way
        return Px(r: Int(d[o]), g: Int(d[o + 1]), b: Int(d[o + 2]))
    }

    /// World 128x128 of plain blue "water"; the pond is the top 64 rows. Swimmer foot at world y=`footY`.
    private func render(footY: CGFloat) throws -> CGImage {
        var a = PlazaPhotoActor(image: PlazaImage(cgImage: solid(32, 48)), flipped: false, foot: CGPoint(x: 64, y: footY), scale: 1.5,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        a.sink = 39.6
        a.waterClip = CGRect(x: 0, y: 0, width: 128, height: 64)
        let input = PlazaPhotoInput(mapImage: PlazaImage(cgImage: solid(128, 128, r: 0, g: 0.5, b: 0.7)), visibleRect: CGRect(x: 0, y: 0, width: 128, height: 128),
                                    pixelsPerWorld: 2, actors: [a])
        return try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
    }

    func testPhotoDrawsTheSubmergedBodyInsideThePond() throws {
        let img = try render(footY: 40)   // foot at photo row 80; the body reaches ~row 80+79
        let p = pixel(img, 64 * 2, 80 + 6)
        XCTAssertGreaterThan(p.r, 40, "the red body shows through the water just under the waterline")
        XCTAssertLessThan(p.r, 200, "but translucent, not opaque red")
    }

    func testPhotoClipsTheSubmergedBodyAtThePondEdge() throws {
        let img = try render(footY: 60)   // foot at row 120; the pond ends at row 128
        let inside = pixel(img, 64 * 2, 120 + 4)
        let below = pixel(img, 64 * 2, 128 + 4)
        let plain = pixel(img, 8, 128 + 4)   // same row, beside the swimmer
        XCTAssertGreaterThan(inside.r, 40)
        XCTAssertEqual(below.r, plain.r, "nothing past the pond's bottom edge")
    }

    func testAPhotoOfAnEggInTheWaterShowsItSunk() throws {
        let s = scene(start: TilePoint(x: 33, y: 15))
        s.setCharacter(eggFrames())
        settle(s)
        let input = try XCTUnwrap(s.photoInput())
        let a = try XCTUnwrap(input.actors.first)
        XCTAssertNotNil(a.waterClip)
        XCTAssertTrue(a.eggSunk)
        XCTAssertEqual(a.sink, 0, "the whole egg stands in place")
        XCTAssertNil(a.front)
        // Pixels: world 128x128 of blue water; the egg stands on foot y=100 in a pond covering the whole picture.
        var e = PlazaPhotoActor(image: PlazaImage(cgImage: solid(32, 48)), flipped: false, foot: CGPoint(x: 64, y: 100), scale: 1.5,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        e.eggSunk = true
        e.waterClip = CGRect(x: 0, y: 0, width: 128, height: 128)
        let pic = PlazaPhotoInput(mapImage: PlazaImage(cgImage: solid(128, 128, r: 0, g: 0.5, b: 0.7)), visibleRect: CGRect(x: 0, y: 0, width: 128, height: 128),
                                  pixelsPerWorld: 2, actors: [e])
        let img = try XCTUnwrap(PlazaPhotoRenderer.renderCG(pic))
        let top = pixel(img, 64 * 2, (100 - 72 + 4) * 2)   // just under the egg's top
        let foot = pixel(img, 64 * 2, (100 - 4) * 2)
        XCTAssertGreaterThan(top.r, 40, "the egg shows through the water at its top")
        XCTAssertLessThan(top.r, 200, "translucent, no opaque top part")
        XCTAssertEqual(foot.r, top.r, "the whole egg is drawn alike")
    }

    func testPhotoClipsASunkEggToThePondAndKeepsItWholeAtTheTopEdge() throws {
        // Pond = world rows 40..128. The egg (72 tall, foot 100) would top out at 28, above the pond: it sinks to row 40 whole.
        var e = PlazaPhotoActor(image: PlazaImage(cgImage: solid(32, 48)), flipped: false, foot: CGPoint(x: 64, y: 100), scale: 1.5,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        e.eggSunk = true
        e.waterClip = CGRect(x: 50, y: 40, width: 48, height: 88)
        let pic = PlazaPhotoInput(mapImage: PlazaImage(cgImage: solid(128, 128, r: 0, g: 0.5, b: 0.7)), visibleRect: CGRect(x: 0, y: 0, width: 128, height: 128),
                                  pixelsPerWorld: 2, actors: [e])
        let img = try XCTUnwrap(PlazaPhotoRenderer.renderCG(pic))
        let plain = pixel(img, 8, 60 * 2)
        XCTAssertEqual(pixel(img, 64 * 2, 36 * 2).r, plain.r, "nothing above the pond's top edge")
        XCTAssertGreaterThan(pixel(img, 64 * 2, 44 * 2).r, plain.r + 20, "the egg's top is just inside the pond")
        XCTAssertGreaterThan(pixel(img, 64 * 2, 108 * 2).r, plain.r + 20, "sunk below its foot line: the egg is whole, not cut")
        XCTAssertEqual(pixel(img, 44 * 2, 80 * 2).r, plain.r, "the egg spans x40-88 but the clip starts at 50")
        XCTAssertGreaterThan(pixel(img, 60 * 2, 80 * 2).r, plain.r + 20)
    }
}
