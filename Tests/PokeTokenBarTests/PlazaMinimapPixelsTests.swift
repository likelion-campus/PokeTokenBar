import XCTest
@testable import PokeTokenBar

/// The minimap's pixel pass (box-filter downscale, tint, saturation) over a `PlazaBitmap`: pure Swift, the same on both OSes.
@MainActor final class PlazaMinimapPixelsTests: XCTestCase {
    private func bitmap(_ w: Int, _ h: Int, _ f: (Int, Int) -> PlazaRGBA) -> PlazaBitmap {
        var b = PlazaBitmap(width: w, height: h)
        for y in 0..<h { for x in 0..<w { b[x, y] = f(x, y) } }
        return b
    }

    func testABoxFilterAveragesEachBlock() async {
        let src = bitmap(4, 4) { x, y in PlazaRGBA(r: UInt8((x / 2) * 100 + (y / 2) * 50 + (x % 2) * 10), g: 0, b: 0, a: 255) }
        let out = PlazaMinimapPixels.downscaled(src, width: 2, height: 2)
        XCTAssertEqual(out[0, 0].r, 5)
        XCTAssertEqual(out[1, 0].r, 105)
        XCTAssertEqual(out[0, 1].r, 55)
        XCTAssertEqual(out[1, 1].r, 155)
        XCTAssertEqual(out[0, 0].a, 255)
    }

    func testAnUnevenRatioKeepsFlatColoursAndTheMean() async {
        let flat = bitmap(37, 23) { _, _ in PlazaRGBA(r: 12, g: 200, b: 77, a: 255) }
        let out = PlazaMinimapPixels.downscaled(flat, width: 10, height: 7)
        for y in 0..<7 { for x in 0..<10 { XCTAssertEqual(out[x, y], PlazaRGBA(r: 12, g: 200, b: 77, a: 255)) } }
        // A half-and-half image, cut in the middle of a destination pixel, averages that pixel.
        let halves = bitmap(3, 1) { x, _ in x < 1 ? PlazaRGBA(r: 0, g: 0, b: 0, a: 255) : PlazaRGBA(r: 255, g: 255, b: 255, a: 255) }
        XCTAssertEqual(PlazaMinimapPixels.downscaled(halves, width: 2, height: 1)[0, 0].r, 85, "1 black + 0.5 white pixel of 1.5")
    }

    func testTintMultipliesAndSaturationPullsTowardLuma() async {
        let px = bitmap(1, 1) { _, _ in PlazaRGBA(r: 200, g: 100, b: 50, a: 255) }
        let tinted = PlazaMinimapPixels.tinted(px, tint: PlazaDaylight.Tint(red: 0.5, green: 1, blue: 0.2), saturation: 1)
        XCTAssertEqual(tinted[0, 0], PlazaRGBA(r: 100, g: 100, b: 10, a: 255))
        let grey = PlazaMinimapPixels.tinted(px, tint: .none, saturation: 0)[0, 0]
        XCTAssertEqual(grey.r, grey.g)
        XCTAssertEqual(grey.g, grey.b)
        XCTAssertEqual(Double(grey.r), 0.2126 * 200 + 0.7152 * 100 + 0.0722 * 50, accuracy: 1)
        XCTAssertEqual(PlazaMinimapPixels.tinted(px, tint: .none, saturation: 1)[0, 0], px[0, 0], "daytime changes nothing")
    }
}
