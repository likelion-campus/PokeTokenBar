import XCTest
import SwiftUI
@testable import PokeTokenBar

@MainActor
final class PlazaPhotoOverlayTests: XCTestCase {
    /// Renders the overlay at 600x320, scale 1, and returns an RGBA reader (premultiplied, y down).
    private func render(photoMode: Bool) throws -> (_ x: Int, _ y: Int) -> [UInt8] {
        let model = PlazaOverlayModel()
        model.isPhotoMode = photoMode
        let r = ImageRenderer(content: PlazaOverlayView(model: model).frame(width: 600, height: 320))
        r.scale = 1
        let image = try XCTUnwrap(r.cgImage)
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 320)
        var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return { x, y in Array(raw[(y * 600 + x) * 4 ..< (y * 600 + x) * 4 + 4]) }
    }

    func testPhotoModeDrawsMarginAndBracketsAroundAClearFrame() throws {
        let px = try render(photoMode: true)
        XCTAssertEqual(px(300, 160)[3], 0, "inside the frame stays clear")
        for (x, y) in [(10, 160), (2, 318)] {
            let p = px(x, y)
            XCTAssertEqual(Int(p[3]), 128, accuracy: 3, "margin at \(x),\(y)")
            XCTAssertEqual(p[0], 0)
        }
        // 프레임은 x 24…576, y 24…276. 위·아래·오른쪽 여백과 프레임의 경계(괄호와 안내 글자를 피한 자리).
        for (x, y) in [(300, 22), (60, 278), (578, 160)] {
            let p = px(x, y)
            XCTAssertEqual(Int(p[3]), 128, accuracy: 3, "margin at \(x),\(y)")
            XCTAssertEqual(p[0], 0)
        }
        for (x, y) in [(300, 26), (60, 274), (574, 160)] {
            XCTAssertEqual(px(x, y)[3], 0, "clear at \(x),\(y)")
        }
        // 왼쪽 위 괄호의 세로 팔: 선(3pt) 한가운데, 모서리에서 10pt 아래.
        let bracket = px(Int(PlazaPhotoFrame.sideInset + PlazaPhotoFrame.bracketWidth / 2 - 0.5),
                         Int(PlazaPhotoFrame.topInset) + 10)
        XCTAssertGreaterThanOrEqual(bracket[3], 250)
        XCTAssertGreaterThanOrEqual(bracket[0], 250)
    }

    func testNothingIsDrawnOutsidePhotoMode() throws {
        XCTAssertEqual(try render(photoMode: false)(10, 160)[3], 0)
    }
}
