import XCTest
@testable import PokeTokenBar

final class PlazaPhotoFrameTests: XCTestCase {
    private let world = CGSize(width: 1536, height: 1024)

    func testFrameIsTheWindowLessItsInsets() {
        let l = PlazaPhotoFrame.layout(center: .init(x: 768, y: 512), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(l?.frame, CGRect(x: 540, y: 369, width: 456, height: 286))
        XCTAssertEqual(l?.visible, CGRect(x: 528, y: 357, width: 480, height: 320))
        XCTAssertEqual(l?.center, CGPoint(x: 768, y: 512))
    }

    func testFrameStaysOnTheMapAndReportsTheClampedCentre() {
        let vp = CGSize(width: 960, height: 640)
        let lo = PlazaPhotoFrame.layout(center: .init(x: -500, y: -500), viewport: vp, zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(lo?.frame.origin, .zero)
        XCTAssertEqual(lo?.center, CGPoint(x: 228, y: 143))
        let hi = PlazaPhotoFrame.layout(center: .init(x: 5000, y: 5000), viewport: vp, zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(hi?.frame.maxX, 1536)
        XCTAssertEqual(hi?.frame.maxY, 1024)
        XCTAssertEqual(hi?.center, CGPoint(x: 1308, y: 881))
    }

    func testFrameBiggerThanTheMapCentresTheMap() {
        let l = PlazaPhotoFrame.layout(center: .init(x: 100, y: 100), viewport: .init(width: 2000, height: 1200), zoom: 1, backingScale: 2, world: world)
        XCTAssertEqual(l?.frame, CGRect(x: -208, y: -54, width: 1952, height: 1132))
        XCTAssertEqual(l?.center, CGPoint(x: 768, y: 512))
    }

    func testOriginsLandOnDevicePixels() throws {
        for zoom in 1...3 {
            let l = try XCTUnwrap(PlazaPhotoFrame.layout(center: .init(x: 700.37, y: 400.11), viewport: .init(width: 961, height: 641), zoom: zoom, backingScale: 2, world: world))
            let scale = CGFloat(zoom) * 2
            for v in [l.frame.minX, l.frame.minY, l.visible.minX, l.visible.minY] {
                XCTAssertEqual(v * scale, (v * scale).rounded(), accuracy: 1e-9)
            }
        }
    }

    func testNoFrameWhenTheWindowIsSmallerThanTheInsets() {
        for vp in [CGSize(width: 40, height: 200), CGSize(width: 200, height: 60), .zero] {
            XCTAssertNil(PlazaPhotoFrame.layout(center: .zero, viewport: vp, zoom: 2, backingScale: 2, world: world))
        }
    }
}
