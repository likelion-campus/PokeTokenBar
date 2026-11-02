import XCTest
@testable import PokeTokenBar

final class PlazaCameraTests: XCTestCase {
    let world = CGSize(width: 1536, height: 1024)

    func testCentersOnFocus() {
        let r = PlazaCamera.visibleRect(focus: .init(x: 768, y: 512), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(r, CGRect(x: 528, y: 352, width: 480, height: 320))
    }

    func testClampsAtEdges() {
        let tl = PlazaCamera.visibleRect(focus: .init(x: 10, y: 10), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(tl.origin, .zero)
        let br = PlazaCamera.visibleRect(focus: .init(x: 1530, y: 1020), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(br.maxX, 1536); XCTAssertEqual(br.maxY, 1024)
    }

    func testRightInsetKeepsFootInUncoveredPartAtRightEdge() {
        let inset: CGFloat = 246, zoom = 2
        let foot = CGPoint(x: world.width - 16, y: 512)
        let focus = PlazaCamera.focus(for: foot, viewportWidth: 960, rightInset: inset, characterHalfWidth: 60, zoom: zoom)
        let r = PlazaCamera.visibleRect(focus: focus, viewport: .init(width: 960, height: 640), zoom: zoom,
                                        backingScale: 2, world: world, rightInset: inset)
        let uncoveredMaxX = r.maxX - inset / CGFloat(zoom)
        XCTAssertLessThanOrEqual(foot.x, uncoveredMaxX)
        XCTAssertGreaterThanOrEqual(uncoveredMaxX, world.width, "the map's right edge stays visible beside the roster")
        XCTAssertGreaterThanOrEqual(foot.x, r.minX)
    }

    func testViewportLargerThanMapCentersMap() {
        let r = PlazaCamera.visibleRect(focus: .init(x: 0, y: 0), viewport: .init(width: 4000, height: 3000), zoom: 1, backingScale: 1, world: world)
        XCTAssertEqual(r.midX, 768, accuracy: 0.5); XCTAssertEqual(r.midY, 512, accuracy: 0.5)
    }

    func testOriginSnapsToDevicePixels() {
        for scale in [1.0, 2.0] { for zoom in 1...3 {
            let r = PlazaCamera.visibleRect(focus: .init(x: 700.3, y: 500.77), viewport: .init(width: 801, height: 601), zoom: zoom, backingScale: scale, world: world)
            let step = 1.0 / (Double(zoom) * scale)
            XCTAssertEqual((r.minX / step).rounded(), r.minX / step, accuracy: 1e-6)
            XCTAssertEqual((r.minY / step).rounded(), r.minY / step, accuracy: 1e-6)
        } }
    }

    func testZoomClamp() {
        XCTAssertEqual(PlazaCamera.clampedZoom(0), 1); XCTAssertEqual(PlazaCamera.clampedZoom(9), 3)
    }

    func testWideWindowCentersTheCharacter() {
        let f = PlazaCamera.focus(for: .init(x: 700, y: 50), viewportWidth: 960, rightInset: 246, characterHalfWidth: 60, zoom: 2)
        XCTAssertEqual(f, CGPoint(x: 700, y: 50))
    }

    /// At the minimum width the centre is under the roster, so the character moves left until it clears it.
    func testNarrowWindowMovesTheCharacterClearOfTheRoster() {
        let width: CGFloat = 480, inset: CGFloat = 246, half: CGFloat = 60, zoom = 2
        let foot = CGPoint(x: 700, y: 50)
        let f = PlazaCamera.focus(for: foot, viewportWidth: width, rightInset: inset, characterHalfWidth: half, zoom: zoom)
        let screenX = width / 2 - (f.x - foot.x) * CGFloat(zoom)
        XCTAssertEqual(screenX + half, width - inset, accuracy: 1e-9, "the right edge of the sprite meets the roster")
    }

    func testHugeSpriteInATinyWindowStaysOnScreen() {
        let f = PlazaCamera.focus(for: .init(x: 700, y: 50), viewportWidth: 480, rightInset: 246, characterHalfWidth: 200, zoom: 2)
        let screenX = 240 - (f.x - 700) * 2
        XCTAssertEqual(screenX, 200, accuracy: 1e-9, "the left edge of the sprite stays on screen")
    }
}
