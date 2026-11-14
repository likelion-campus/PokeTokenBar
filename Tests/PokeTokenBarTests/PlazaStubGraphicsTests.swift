import XCTest
@testable import PokeTokenBar

private final class LineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class PlazaStubGraphicsTests: XCTestCase {
    func testStubCanvasRecordsCallsAndReturnsATransparentImageOfTheSize() throws {
        let graphics = PlazaStubGraphics(log: { _ in })
        let canvas = try XCTUnwrap(graphics.makeCanvas(width: 7, height: 3, colorSpace: .deviceRGB) as? PlazaStubCanvas)
        XCTAssertNil(graphics.makeCanvas(width: 0, height: 3, colorSpace: .sRGB), "like CGContext, no empty canvas")
        XCTAssertEqual([canvas.width, canvas.height], [7, 3])
        canvas.saveState()
        canvas.scale(x: 2, y: 2)
        canvas.setFillColor(.white)
        canvas.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
        canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: .black))
        canvas.setShadow(nil)
        let line = graphics.text.line("ab", font: .plaza(.body))
        canvas.draw(line, at: CGPoint(x: 1, y: 2))
        canvas.draw(graphics.text.paragraph("hi", font: .plaza(.small), alignment: .center), in: CGRect(x: 0, y: 0, width: 7, height: 3))
        canvas.withPixels { bytes, bytesPerRow in
            XCTAssertEqual(bytesPerRow, 28)
            bytes[0] = 255   // a scratch buffer: the image stays transparent
        }
        canvas.restoreState()
        let image = try XCTUnwrap(canvas.makeImage())
        XCTAssertEqual(canvas.calls, [
            "saveState", "scale 2.0 2.0", "fillColor (1.0, 1.0, 1.0, 1.0)", "fill (0.0, 0.0, 3.0, 1.0)",
            "shadow 0.0 -2.0 4.0 (0.0, 0.0, 0.0, 1.0)", "shadow off", "line \"ab\" at 1.0 2.0",
            "paragraph \"hi\" (0.0, 0.0, 7.0, 3.0)", "withPixels",
            "restoreState", "makeImage",
        ])
        XCTAssertEqual([image.width, image.height], [7, 3])
        XCTAssertEqual(image.pixels, { var b = PlazaBitmap(width: 7, height: 3); b.colorSpace = .deviceRGB; return b }())
    }

    func testStubTextIsMonospace() {
        let text = PlazaStubTextEngine()
        let line = text.line("나ab🔥", font: .plaza(.body))   // 4 Characters at 15 pt
        XCTAssertEqual(line.width, 4 * 0.6 * 15, accuracy: 1e-9)
        XCTAssertEqual(line.ascent, 0.8 * 15, accuracy: 1e-9)
        XCTAssertEqual(line.descent, 0.2 * 15, accuracy: 1e-9)
        XCTAssertEqual(line.leading, 0)
        XCTAssertEqual(text.metrics(.system(size: 10, weight: .bold)), PlazaFontMetrics(ascender: 8, descender: -2, leading: 0))
        XCTAssertEqual(text.line("x", font: .emoji(size: 12)).width, 0.6 * 12, accuracy: 1e-9)
        XCTAssertEqual(text.line("x", font: .plaza(.small)).width, 0.6 * 12, accuracy: 1e-9)

        // Truncation keeps what fits next to the ellipsis; a line that fits comes back as it is.
        let ellipsis = text.line("…", font: .plaza(.body))   // 9 pt
        let long = text.line("abcdefghij", font: .plaza(.body))   // 90 pt
        XCTAssertTrue(text.truncated(long, width: 100, ellipsis: ellipsis) === long)
        let cut = text.truncated(long, width: 40, ellipsis: ellipsis)   // 31 pt left: 3 characters
        XCTAssertEqual(cut?.width ?? -1, 4 * 9, accuracy: 1e-9)
        XCTAssertNil(text.truncated(long, width: 5, ellipsis: ellipsis))

        // Paragraphs break between characters: 10 per line at 6 pt each in 60 pt, one line is 10 pt.
        let p = text.paragraph(String(repeating: "가", count: 25), font: .system(size: 10, weight: .regular), alignment: .center)
        XCTAssertEqual(p.suggestedSize(limit: CGSize(width: 60, height: 100)), CGSize(width: 60, height: 30))
        XCTAssertEqual(p.suggestedSize(limit: CGSize(width: 60, height: 25)), CGSize(width: 60, height: 20))
        XCTAssertEqual(p.visibleLength(in: CGSize(width: 60, height: 25)), 20)
        XCTAssertEqual(p.suggestedSize(limit: CGSize(width: 60, height: 5)), .zero, "not even one line fits")
        XCTAssertEqual(p.visibleLength(in: CGSize(width: 60, height: 5)), 0)
        XCTAssertEqual(text.paragraph("🔥🔥", font: .emoji(size: 10), alignment: .natural).visibleLength(in: CGSize(width: 100, height: 10)), 4,
                       "UTF-16 units")
    }

    func testStubDecodersAreUnavailableAndLogOnce() {
        let log = LineCount()
        let graphics = PlazaStubGraphics(log: { log.add($0) })
        let url = URL(fileURLWithPath: "/nonexistent/plaza-tiles.png")
        let image = PlazaImage(bitmap: PlazaBitmap(width: 1, height: 1))
        for _ in 0..<2 {
            XCTAssertNil(graphics.assetURL("plaza-tiles", ext: "png"))
            XCTAssertNil(graphics.decodeImage(at: url))
            XCTAssertNil(graphics.decodeImage(Data([0x89, 0x50, 0x4E, 0x47])))
            XCTAssertEqual(graphics.decodeImageFrames(at: url).count, 0)
            XCTAssertNil(graphics.encodePNG(image))
        }
        XCTAssertEqual(log.all, ["Plaza stub: bundled assets and image codecs unavailable"])
    }
}
