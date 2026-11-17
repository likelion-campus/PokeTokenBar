import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaWeatherTests {

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        var d = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(d[0]), Int(d[1]), Int(d[2]), Int(d[3]))
    }

    func testPhotoDrawsTheParticles() throws {
        let snowy = scene(at: snowDay)
        run(snowy, seconds: 1)
        let input = try XCTUnwrap(snowy.photoInput())
        let withSnow = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        var bareInput = input
        bareInput.weather = []
        let without = try XCTUnwrap(PlazaPhotoRenderer.renderCG(bareInput))
        let flake = try XCTUnwrap(plusFlake(input))
        let at = centerPixel(flake, input: input)
        let drawn = pixel(withSnow, at.x, at.y), bare = pixel(without, at.x, at.y)
        XCTAssertGreaterThan(drawn.r, 0xF0)
        XCTAssertGreaterThan(drawn.g, 0xF0)
        XCTAssertGreaterThan(drawn.b, 0xF0)
        XCTAssertNotEqual(drawn.g, bare.g, "the grass underneath is covered")
        // 입자 한 칸은 월드 픽셀 하나(사진 4x4)로 또렷하다: 칸 안쪽 네 모퉁이가 모두 같은 색.
        let x0 = at.x - input.pixelsPerWorld / 2, y0 = at.y - input.pixelsPerWorld / 2
        let corners = [(0, 0), (3, 0), (0, 3), (3, 3)].map { pixel(withSnow, x0 + $0.0, y0 + $0.1) }
        XCTAssertTrue(corners.allSatisfy { $0 == corners[0] })
    }

    func testPhotoTintsTheParticlesLikeTheMap() throws {
        let night = date(2026, 12, 1, 23, 0)
        let day = night
        let s = scene(at: day)
        run(s, seconds: 1)
        var input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.tint, PlazaDaylight.night)
        let tinted = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        let flake = try XCTUnwrap(plusFlake(input))
        let at = centerPixel(flake, input: input)
        let p = pixel(tinted, at.x, at.y)
        XCTAssertEqual(Double(p.r), 246 * PlazaDaylight.night.red, accuracy: 3)
        XCTAssertEqual(Double(p.b), 255 * PlazaDaylight.night.blue, accuracy: 3)
        XCTAssertLessThan(p.r, p.b, "night snow is blue, not white")
        input.tint = .none
        XCTAssertGreaterThan(pixel(try XCTUnwrap(PlazaPhotoRenderer.renderCG(input)), at.x, at.y).r, 0xF0)
    }

    /// A particle covering the whole photo is painted over the map and characters but never over name plates.
    func testParticlesAreDrawnUnderNamePlates() throws {
        let s = scene(at: snowDay)
        let red = { () -> CGImage in
            let ctx = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
            return ctx.makeImage()!
        }()
        s.setCharacter(PlazaCharacterFrames(front: [PlazaFrame(image: PlazaImage(cgImage: red), delay: 0.1)], back: [PlazaFrame(image: PlazaImage(cgImage: red), delay: 0.1)]))
        s.update(0)
        var input = try XCTUnwrap(s.photoInput())
        input.weather = []
        let base = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        let blanket = PlazaWeatherArt.images(.snow)[2]   // 흰 한 칸
        input.weather = [PlazaPhotoParticle(image: blanket, origin: input.visibleRect.origin, size: input.visibleRect.size)]
        let covered = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        var plateOnTop = 0, whites = 0
        for y in stride(from: 0, to: base.height, by: 2) {
            for x in stride(from: 0, to: base.width, by: 2) {
                let c = pixel(covered, x, y)
                if c.r > 0xF0 && c.g > 0xF0 && c.b > 0xF0 { whites += 1 } else { plateOnTop += 1 }
            }
        }
        XCTAssertGreaterThan(plateOnTop, 20, "the name plate shows through an all-white blanket, so it is drawn after it")
        XCTAssertGreaterThan(whites, 1000, "while the map and character are under it")
    }
}
