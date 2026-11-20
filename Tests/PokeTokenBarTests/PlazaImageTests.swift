import XCTest
@testable import PokeTokenBar

final class PlazaImageTests: XCTestCase {
    func testImageFromBitmapReportsItsPixels() {
        let b = PlazaTestImages.patterned(width: 5, height: 4)
        let image = PlazaImage(bitmap: b)
        XCTAssertEqual([image.width, image.height], [5, 4])
        XCTAssertEqual(image.bitmap, b)
        XCTAssertNil(image.native)
        XCTAssertEqual(image.pixels, b)
    }

    func testCroppingABitmapImageKeepsPixels() throws {
        let b = PlazaTestImages.patterned(width: 6, height: 5)
        let image = PlazaImage(bitmap: b)
        let crop = try XCTUnwrap(image.cropping(to: PlazaPixelRect(x: 1, y: 2, width: 4, height: 2)))
        XCTAssertEqual([crop.width, crop.height], [4, 2])
        XCTAssertEqual(crop.bitmap, b.cropped(to: PlazaPixelRect(x: 1, y: 2, width: 4, height: 2)))
        XCTAssertEqual(crop.pixels[0, 0], b[1, 2])
        XCTAssertNil(image.cropping(to: PlazaPixelRect(x: 6, y: 0, width: 2, height: 2)), "nothing left: nil like CGImage")
        XCTAssertNil(image.cropping(to: PlazaPixelRect(x: 0, y: 0, width: 0, height: 3)))
    }

    /// A native image keeps its own form: pixels are asked once and cached, crops stay native.
    func testNativeImageIsKeptAndItsPixelsAreReadOnce() throws {
        let b = PlazaTestImages.patterned(width: 4, height: 4)
        let native = PlazaTestImages.FakeNative(b)
        let image = PlazaImage(native: native)
        XCTAssertNil(image.bitmap)
        XCTAssertTrue(image.native === native)
        XCTAssertEqual([image.width, image.height], [4, 4])
        XCTAssertEqual(native.pixelCalls, 0, "nothing is drawn until someone reads pixels")
        XCTAssertEqual(image.pixels, b)
        XCTAssertEqual(image.pixels, b)
        XCTAssertEqual(native.pixelCalls, 1)
        let crop = try XCTUnwrap(image.cropping(to: PlazaPixelRect(x: 1, y: 1, width: 2, height: 3)))
        XCTAssertNil(crop.bitmap)
        XCTAssertTrue(crop.native is PlazaTestImages.FakeNative)
        XCTAssertEqual(crop.pixels, b.cropped(to: PlazaPixelRect(x: 1, y: 1, width: 2, height: 3)))
        XCTAssertNil(image.cropping(to: PlazaPixelRect(x: 9, y: 9, width: 1, height: 1)))
    }

    func testBackendCacheHoldsWhatTheBackendStores() {
        let image = PlazaImage(bitmap: PlazaBitmap(width: 1, height: 1))
        XCTAssertNil(image.backendCache)
        let token = NSObject()
        image.backendCache = token
        XCTAssertTrue(image.backendCache === token)
    }
}
