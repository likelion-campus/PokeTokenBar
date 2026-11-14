import XCTest
@testable import PokeTokenBar

/// Layout rules of the text art on the headless stub graphics (deterministic monospace metrics), so they run on every OS.
/// Mac font assertions and pixels stay in `PlazaNamePlateTests`, `PlazaChatTests` and `PlazaTextArtParityTests`.
final class PlazaTextArtLayoutTests: XCTestCase {
    /// The stub graphics, remembering the canvases it handed out.
    private final class Recording: PlazaGraphics, @unchecked Sendable {
        private let inner = PlazaStubGraphics(log: { _ in })
        private(set) var canvases: [PlazaStubCanvas] = []
        var text: any PlazaTextEngine { inner.text }
        func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
            let canvas = inner.makeCanvas(width: width, height: height, colorSpace: colorSpace)
            if let stub = canvas as? PlazaStubCanvas { canvases.append(stub) }
            return canvas
        }
        func assetURL(_ name: String, ext: String) -> URL? { inner.assetURL(name, ext: ext) }
        func decodeImage(at url: URL) -> PlazaImage? { inner.decodeImage(at: url) }
        func decodeImage(_ data: Data) -> PlazaImage? { inner.decodeImage(data) }
        func decodeImageFrames(at url: URL) -> [PlazaImage] { inner.decodeImageFrames(at: url) }
        func encodePNG(_ image: PlazaImage) -> Data? { inner.encodePNG(image) }
    }

    private let white = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The y of the text position of the recorded `line "<text>" at x y` call.
    private func lineY(_ canvas: PlazaStubCanvas, _ text: String) throws -> Double {
        let call = try XCTUnwrap(canvas.calls.last { $0.hasPrefix("line \"\(text)\" at ") }, text)
        return try XCTUnwrap(Double(call.split(separator: " ").last ?? ""))
    }

    func testTitleAddsHeightAboveAndLeavesTheNameWhereItWas() throws {
        let plainGraphics = Recording(), titledGraphics = Recording()
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "Name", color: white, scale: 2, graphics: plainGraphics))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "Name", title: "Shy", color: white, scale: 2, graphics: titledGraphics))
        XCTAssertGreaterThan(titled.height, plain.height)
        XCTAssertEqual(titled.width, plain.width, "the title is narrower than the name")
        // The plate is anchored at its bottom: the name keeps its y and the title sits above it.
        let nameY = try lineY(try XCTUnwrap(plainGraphics.canvases.last), "Name")
        XCTAssertEqual(try lineY(try XCTUnwrap(titledGraphics.canvases.last), "Name"), nameY)
        XCTAssertGreaterThan(try lineY(try XCTUnwrap(titledGraphics.canvases.last), "Shy"), nameY)
    }

    func testAWideNameIsCutToTheWidthLimit() throws {
        for scale: CGFloat in [1, 2, 3] {
            let graphics = Recording()
            let image = try XCTUnwrap(PlazaNamePlate.image(text: String(repeating: "W", count: 400), title: "Shy", color: white,
                                                           scale: scale, graphics: graphics))
            XCTAssertLessThanOrEqual(image.width, PlazaNamePlate.maxPixelWidth, "scale \(scale)")
            XCTAssertGreaterThan(image.width, PlazaNamePlate.maxPixelWidth / 2, "scale \(scale): cut, not emptied")
            XCTAssertTrue(try XCTUnwrap(graphics.canvases.last).calls.contains { $0.contains("…\" at ") }, "an ellipsis ends the cut name")
        }
        let graphics = Recording()
        let empty = try XCTUnwrap(PlazaNamePlate.image(text: "", color: white, scale: 2, graphics: graphics))
        XCTAssertEqual(empty.width, Int((2 * PlazaNamePlate.pad).rounded(.up)) * 2)
    }

    func testChatBubbleGrowsWithTheTextAndStopsAtItsLimit() throws {
        let graphics = Recording()
        let short = try XCTUnwrap(PlazaChatBubble.image(text: "안녕", scale: 2, graphics: graphics))
        let long = try XCTUnwrap(PlazaChatBubble.image(text: String(repeating: "가", count: 400), scale: 2, graphics: graphics))
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertGreaterThan(long.height, short.height)
        let max = PlazaChatBubble.maxSize
        XCTAssertLessThanOrEqual(CGFloat(long.width), max.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(long.height), max.height * 2)
        // Text beyond the last line is dropped, not squeezed in.
        let line = String(repeating: "가", count: 60)
        XCTAssertEqual(PlazaChatBubble.drawnLength(of: line, graphics: graphics), line.utf16.count)
        let tooLong = String(repeating: "가", count: 400)
        XCTAssertLessThan(PlazaChatBubble.drawnLength(of: tooLong, graphics: graphics), tooLong.utf16.count)
    }

    func testEmoteArtHasItsGridSizeAtEveryScale() {
        let graphics = Recording()
        for kind in TeamEmoteKind.allCases {
            for scale: CGFloat in [1, 2, 3] {
                for large in [false, true] {
                    let image = PlazaEmoteArt.image(kind, scale: scale, large: large, graphics: graphics)
                    let size = PlazaEmoteArt.size(large: large)
                    XCTAssertEqual(CGFloat(image.width), (size.width * scale).rounded(), "\(kind) @\(scale)")
                    XCTAssertEqual(CGFloat(image.height), (size.height * scale).rounded(), "\(kind) @\(scale)")
                }
            }
        }
        XCTAssertEqual(CGFloat(PlazaEmoteArt.impactImage(scale: 2, graphics: graphics).width), PlazaEmoteArt.impactSize.width * 2)
        XCTAssertEqual(CGFloat(PlazaEmoteArt.dustImage(scale: 2, graphics: graphics).width), PlazaEmoteArt.dustSize.width * 2)
        XCTAssertEqual(CGFloat(PlazaEmoteArt.sparkImage(scale: 2, graphics: graphics).width), PlazaEmoteArt.sparkSize.width * 2)
        for kind in ItemKind.allCases {
            XCTAssertEqual(CGFloat(PlazaEmoteArt.itemImage(kind, scale: 2, graphics: graphics).width), PlazaEmoteArt.itemSize(kind).width * 2)
        }
    }
}
