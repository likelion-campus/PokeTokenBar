import XCTest
@testable import PokeTokenBar

@MainActor
final class PlazaFootprintTests: XCTestCase {
    func testMarksStopAtTheCapAndReuseNodes() async {
        let layer = PlazaFootprintLayer(worldHeight: 1000)
        let one = [PlazaSnow.Footprint(center: CGPoint(x: 100, y: 100), alongX: true)]
        for _ in 0..<200 { layer.stamp(one) }
        XCTAssertEqual(layer.count, 160)
        XCTAssertLessThanOrEqual(layer.root.children.count, 160)
        layer.advance(by: 10)
        XCTAssertEqual(layer.count, 0)
        for _ in 0..<160 { layer.stamp(one) }
        XCTAssertLessThanOrEqual(layer.root.children.count, 160)
    }

    func testAMarkAcrossTheStepIsTallAndOneAlongItIsWide() async {
        let layer = PlazaFootprintLayer(worldHeight: 1000)
        layer.stamp([PlazaSnow.Footprint(center: CGPoint(x: 100, y: 100), alongX: true)])
        layer.stamp([PlazaSnow.Footprint(center: CGPoint(x: 200, y: 100), alongX: false)])
        let sizes = layer.root.children.compactMap { ($0 as? PlazaSprite)?.size }
        XCTAssertEqual(sizes, [CGSize(width: PlazaSnow.footprintLength, height: PlazaSnow.footprintWidth),
                               CGSize(width: PlazaSnow.footprintWidth, height: PlazaSnow.footprintLength)])
    }
}
