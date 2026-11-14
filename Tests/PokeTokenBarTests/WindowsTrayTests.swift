#if os(Windows)
import WinSDK
import XCTest
@testable import PokeTokenBar

final class WindowsTrayTests: XCTestCase {
    func testPNGDecodesToTheRightSizeAndAlpha() throws {
        let image = try XCTUnwrap(WinIcon.decode(png: WinIcon.fixturePNG))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 4)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(image.pixels[(y * 4 + x) * 4..<(y * 4 + x) * 4 + 4]) }  // B, G, R, A
        XCTAssertEqual(pixel(0, 0), [0, 0, 255, 255], "top-left red, opaque")
        XCTAssertEqual(pixel(3, 0), [0, 255, 0, 128], "top-right green, straight alpha 128")
        XCTAssertEqual(pixel(0, 3), [255, 0, 0, 255], "bottom-left blue")
        XCTAssertEqual(pixel(3, 3), [0, 255, 255, 64], "bottom-right yellow, alpha 64")
        XCTAssertEqual(pixel(1, 1)[3], 0, "inside is transparent")
        XCTAssertNil(WinIcon.decode(png: Data("not a png".utf8)))
    }

    func testIconMakesAnHICON() throws {
        let icon = try XCTUnwrap(WinIcon(png: WinIcon.fixturePNG, size: 16))
        var info = ICONINFO()
        XCTAssertNotEqual(GetIconInfo(icon.handle, &info), 0)
        defer { DeleteObject(info.hbmColor); DeleteObject(info.hbmMask) }
        var bitmap = BITMAP()
        XCTAssertGreaterThan(GetObjectW(info.hbmColor, Int32(MemoryLayout<BITMAP>.size), &bitmap), 0)
        XCTAssertEqual(bitmap.bmWidth, 16)
        XCTAssertEqual(bitmap.bmHeight, 16)
        XCTAssertNil(WinIcon(png: Data("nope".utf8), size: 16))
    }
}
#endif
