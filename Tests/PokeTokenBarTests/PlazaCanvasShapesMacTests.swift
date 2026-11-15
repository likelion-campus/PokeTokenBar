import XCTest
@testable import PokeTokenBar

/// The Mac's side of `PlazaCanvasShapes`: writes (`PTB_PLAZA_GOLDENS_WRITE=1`) and re-checks `Tests/PlazaParityGoldens/canvas-shapes/*.png`.
///
///     PTB_PLAZA_GOLDENS_WRITE=1 swift test --filter PlazaCanvasShapesMacTests
@MainActor
final class PlazaCanvasShapesMacTests: XCTestCase {
    private let graphics = PlatformPlaza.graphics

    func testShapesGoldensHoldOnThisMac() throws {
        let writing = ProcessInfo.processInfo.environment["PTB_PLAZA_GOLDENS_WRITE"] == "1"
        if writing { try FileManager.default.createDirectory(at: PlazaParityGoldens.url("canvas-shapes"), withIntermediateDirectories: true) }
        for shape in PlazaCanvasShapes.cases {
            let image = try XCTUnwrap(PlazaCanvasShapes.render(shape, graphics: graphics), shape.name)
            let url = PlazaParityGoldens.url("canvas-shapes/\(shape.name).png")
            if writing {
                try XCTUnwrap(graphics.encodePNG(image)).write(to: url)
            } else {
                let golden = try XCTUnwrap(graphics.decodeImage(Data(contentsOf: url)), shape.name).pixels
                XCTAssertEqual(image.pixels, golden, "canvas-shapes/\(shape.name) changed: CoreGraphics moved, or regenerate with PTB_PLAZA_GOLDENS_WRITE=1")
            }
        }
    }
}
