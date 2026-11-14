import XCTest
@testable import PokeTokenBar

final class PlazaNamePlateTests: XCTestCase {
    let white = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // MARK: - 성격 줄

    let red = PlazaColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    func testAVeryLongNameStaysInsideTheLimitWithATitle() async throws {
        let long = String(repeating: "가", count: 4000)
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: long, title: "수줍은", color: red, scale: 2))
        XCTAssertLessThanOrEqual(titled.width, PlazaNamePlate.maxPixelWidth)
    }
    /// One Character can be thousands of points wide; SpriteKit aborts the process on a texture above 32,768 px.
    func testPlateNeverExceedsTextureBound() async throws {
        let chain = "👨" + String(repeating: "\u{200D}👨", count: 999)
        XCTAssertEqual(chain.count, 1, "precondition: the whole chain is a single Character")
        for scale in [1, 2, 3] as [CGFloat] {
            let image = try XCTUnwrap(PlazaNamePlate.image(text: chain, color: white, scale: scale))
            XCTAssertLessThanOrEqual(image.width, PlazaNamePlate.maxPixelWidth, "scale \(scale)")
            XCTAssertGreaterThan(image.width, 0)
        }
        let wide = String(repeating: "W", count: 400)
        XCTAssertLessThanOrEqual(try XCTUnwrap(PlazaNamePlate.image(text: wide, color: white, scale: 2)).width,
                                 PlazaNamePlate.maxPixelWidth)
    }

    func testWidthGrowsWithTextAndScale() async throws {
        let short = try XCTUnwrap(PlazaNamePlate.image(text: "나", color: white, scale: 2))
        let long = try XCTUnwrap(PlazaNamePlate.image(text: "도토리도토리", color: white, scale: 2))
        XCTAssertGreaterThan(long.width, short.width)
        let oneX = try XCTUnwrap(PlazaNamePlate.image(text: "도토리도토리", color: white, scale: 1))
        XCTAssertLessThanOrEqual(abs(long.width - 2 * oneX.width), 2)
        XCTAssertLessThanOrEqual(abs(long.height - 2 * oneX.height), 2)
    }
}
