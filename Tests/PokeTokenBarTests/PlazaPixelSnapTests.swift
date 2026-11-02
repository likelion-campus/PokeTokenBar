import XCTest
@testable import PokeTokenBar

final class PlazaPixelSnapTests: XCTestCase {
    /// 값이 기기 픽셀 격자(1 / unit) 위에 있는지.
    private func onGrid(_ v: CGFloat, unit: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let n = v * unit
        XCTAssertEqual(n, n.rounded(), accuracy: 1e-6, "\(v) x \(unit) = \(n) is not a whole device pixel", file: file, line: line)
    }

    func testSpriteLeftEdgeOnGridWithOddDevicePixelWidth() {
        // 31 열 x 1.5 = 46.5 pt. 1x zoom 2 -> 93 device px (odd).
        let width: CGFloat = 31 * 1.5
        for (backing, zoom) in [(CGFloat(1), 2), (1, 1), (1, 3), (2, 1), (2, 3)] {
            for i in 0..<40 {
                let footX = 100 + CGFloat(i) * 0.37
                let cx = PlazaPixelSnap.centerX(footX: footX, width: width, backing: backing, zoom: zoom)
                onGrid(cx - width / 2, unit: backing * CGFloat(zoom))
            }
        }
    }

    func testCenterOnlySnapWouldLeaveHalfPixelEdge() {
        // 결함 재현 기준: 가운데만 맞추면 홀수 폭에서 왼쪽 가장자리가 .5 에 놓인다.
        let width: CGFloat = 46.5
        let centerOnly = PlazaPixelSnap.snap(100.2, backing: 1, zoom: 2)
        let edge = (centerOnly - width / 2) * 2
        XCTAssertNotEqual(edge, edge.rounded(), accuracy: 1e-6)
    }

    func testPlateEdgesOnGridAtOneXWithOddWidth() {
        let viewport = CGSize(width: 960, height: 640)
        let plateWidth: CGFloat = 41
        for i in 0..<40 {
            let p = PlazaPixelSnap.platePosition(footSceneX: 700 + CGFloat(i) * 0.31, topY: 300 + CGFloat(i) * 0.13,
                                                 cameraPos: CGPoint(x: 640, y: 320), plateWidth: plateWidth,
                                                 viewport: viewport, backing: 1, zoom: 2)
            onGrid(p.x - plateWidth / 2 + viewport.width / 2, unit: 1)
            onGrid(p.y + viewport.height / 2, unit: 1)
        }
    }

    func testPlateEdgesOnGridInOddViewport() {
        let viewport = CGSize(width: 961, height: 641)
        let plateWidth: CGFloat = 41
        for i in 0..<40 {
            let p = PlazaPixelSnap.platePosition(footSceneX: 700 + CGFloat(i) * 0.31, topY: 300 + CGFloat(i) * 0.13,
                                                 cameraPos: CGPoint(x: 640, y: 320), plateWidth: plateWidth,
                                                 viewport: viewport, backing: 1, zoom: 2)
            // 뷰포트 왼쪽·아래 모서리 기준 위치가 정수 픽셀이어야 한다.
            onGrid(p.x - plateWidth / 2 + viewport.width / 2, unit: 1)
            onGrid(p.y + viewport.height / 2, unit: 1)
        }
    }

    func testCameraLiftRaisesFocusOnly() {
        let foot = CGPoint(x: 400, y: 500)
        let base = PlazaCamera.focus(for: foot, rightInset: 100, zoom: 2)
        let lifted = PlazaCamera.focus(for: foot, rightInset: 100, zoom: 2, lift: 72)
        XCTAssertEqual(lifted.x, base.x)
        XCTAssertEqual(lifted.y, foot.y - 72)
        XCTAssertEqual(base.y, foot.y, "default lift keeps existing behavior")
    }
}
