import XCTest
@testable import PokeTokenBar

final class PlazaEggCropTests: XCTestCase {
    private func image(_ w: Int, _ h: Int, opaque: [(Int, Int)], alpha: UInt8 = 255) -> PlazaImage {
        var bitmap = PlazaBitmap(width: w, height: h)
        for (x, y) in opaque { bitmap[x, y] = PlazaRGBA(r: alpha, g: 0, b: 0, a: alpha) }
        return PlazaImage(bitmap: bitmap)
    }

    private func block(x: Int, y: Int, w: Int, h: Int) -> [(Int, Int)] {
        (y..<y + h).flatMap { row in (x..<x + w).map { ($0, row) } }
    }

    func testTallEggIsCutToACentredSquareOnTheLongerSide() {
        // 28x30 egg in a 96x96 canvas at (34, 33): side 30, widened by one pixel each way... (30-28)/2 = 1.
        let cropped = PlazaEggCrop.square(image(96, 96, opaque: block(x: 34, y: 33, w: 28, h: 30)))
        XCTAssertEqual(cropped.width, 30)
        XCTAssertEqual(cropped.height, 30)
        // Column 0 is the pixel left of the egg (transparent), the egg starts at column 1.
        XCTAssertEqual(cropped.pixels[0, 5].a, 0)
        XCTAssertEqual(cropped.pixels[1, 5].a, 255)
        XCTAssertEqual(cropped.pixels[28, 5].a, 255)
        XCTAssertEqual(cropped.pixels[29, 5].a, 0)
    }

    func testBoxNearACornerIsKeptInsideTheImage() {
        let cropped = PlazaEggCrop.square(image(20, 20, opaque: block(x: 0, y: 0, w: 4, h: 10)))
        XCTAssertEqual(cropped.width, 10)
        XCTAssertEqual(cropped.height, 10)
        XCTAssertEqual(cropped.pixels[0, 0].a, 255)
    }

    func testSideNeverExceedsTheShorterImageSide() {
        let cropped = PlazaEggCrop.square(image(40, 10, opaque: block(x: 2, y: 0, w: 30, h: 10)))
        XCTAssertEqual(cropped.width, 10)
        XCTAssertEqual(cropped.height, 10)
    }

    func testAlphaThresholdIsAByteOfThree() {
        let faint = PlazaEggCrop.square(image(10, 10, opaque: [(5, 5)], alpha: 2))
        XCTAssertEqual(faint.width, 10, "alpha 2/255 is not above 0.01: nothing opaque, the image is unchanged")
        let enough = PlazaEggCrop.square(image(10, 10, opaque: [(5, 5)], alpha: 3))
        XCTAssertEqual(enough.width, 1)
        XCTAssertEqual(enough.pixels[0, 0].a, 3)
    }

    func testNothingOpaqueReturnsTheSameImage() {
        let empty = image(8, 8, opaque: [])
        XCTAssertTrue(PlazaEggCrop.square(empty) === empty)
    }
}
