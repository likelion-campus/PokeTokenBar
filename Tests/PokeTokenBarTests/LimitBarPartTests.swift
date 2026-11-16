import XCTest
@testable import PokeTokenBar

/// The limit bar (stage 7 Task 5, D7) drawn through the plaza canvas of the system under test: CoreGraphics on the Mac
/// (the PR images), Direct2D on Windows. The expected pixels are the geometry's own, so the two systems agree within the
/// tolerance, and the Mac's own `markerFraction` is the part's input.
@MainActor
final class LimitBarPartTests: XCTestCase {
    private static let width: CGFloat = 200

    private func model(fill: Double, pace: Double? = nil, dimmed: Bool = false) -> LimitBarPart.Model {
        LimitBarPart.Model(name: "5-hour", percentText: "\(Int(fill))%", fillPercent: fill, tint: .systemBlue, paceMarker: pace,
                           help: "tip", dimmed: dimmed)
    }

    private func bitmap(_ m: LimitBarPart.Model, scale: CGFloat) throws -> (PlazaBitmap, PopoverDrawing) {
        let part = LimitBarPart(m)
        let graphics = PlatformPlaza.graphics
        let size = part.size(width: Self.width, scale: scale, text: graphics.text)
        XCTAssertEqual(size, CGSize(width: Self.width, height: 12))
        let drawing = part.render(scale: scale, graphics: graphics)
        guard case .image(let image, let frame)? = drawing.drawing.layers.first else {
            XCTFail("no image layer")
            throw XCTSkip("no canvas")
        }
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: Self.width, height: 12))
        XCTAssertEqual(image.width, Int(Self.width * scale))
        XCTAssertEqual(image.height, Int(12 * scale))
        return (image.pixels, drawing)
    }

    private func near(_ p: PlazaRGBA, _ r: Int, _ g: Int, _ b: Int, _ a: Int, _ what: String, tolerance: Int = 2,
                      file: StaticString = #filePath, line: UInt = #line) {
        let got = [Int(p.r), Int(p.g), Int(p.b), Int(p.a)], want = [r, g, b, a]
        for i in 0..<4 {
            XCTAssertLessThanOrEqual(abs(got[i] - want[i]), tolerance, "\(what): \(got) vs \(want)", file: file, line: line)
        }
    }

    func testFillTrackAndLineAtScaleOneAndTwo() async throws {
        for scale in [CGFloat(1), 2] {
            let (bits, _) = try bitmap(model(fill: 50), scale: scale)
            func px(_ x: CGFloat, _ y: CGFloat) -> PlazaRGBA { bits[Int(x * scale), Int(y * scale)] }
            near(px(40, 6), 0x00, 0x88, 0xFF, 255, "fill at scale \(scale)")
            near(px(150, 6), 0, 0, 0, 26, "track at scale \(scale)")
            near(px(150, 0.25), 0, 0, 0, 0, "above the track at scale \(scale)")
            near(px(150, 11.5), 0, 0, 0, 0, "below the track at scale \(scale)")
            // the fill ends at half the width: the last full pixel before it and the first one after it
            near(px(98, 6), 0x00, 0x88, 0xFF, 255, "just inside the fill at scale \(scale)")
            near(px(102, 6), 0, 0, 0, 26, "just outside the fill at scale \(scale)")
        }
    }

    func testMarkerIsCentredOnTheTrackAndStaysInsideAtBothEnds() async throws {
        XCTAssertEqual(LimitBarPart.markerRect(fraction: 0, width: Self.width), CGRect(x: 0, y: 1, width: 2.5, height: 10))
        XCTAssertEqual(LimitBarPart.markerRect(fraction: 1, width: Self.width).maxX, Self.width)
        XCTAssertEqual(LimitBarPart.markerRect(fraction: 0.5, width: Self.width).midX, Self.width / 2)
        XCTAssertEqual(LimitBarPart.markerRect(fraction: 7, width: Self.width).maxX, Self.width, "clamped")
        XCTAssertEqual(LimitBarPart.markerRect(fraction: -1, width: Self.width).minX, 0, "clamped")
        XCTAssertEqual(LimitBarPart.trackRect(width: Self.width), CGRect(x: 0, y: 3, width: Self.width, height: 6))
        for scale in [CGFloat(1), 2] {
            // fill 0 so the marker's pixels are over the bare track: black 10 % under black 46.6 % = alpha 0.519
            let alpha = 132
            let (mid, _) = try bitmap(model(fill: 0, pace: 0.5), scale: scale)
            near(mid[Int(100 * scale) - 1, Int(6 * scale)], 0, 0, 0, alpha, "marker centre at scale \(scale)")
            near(mid[Int(90 * scale), Int(6 * scale)], 0, 0, 0, 26, "track beside the marker at scale \(scale)")
            let (low, _) = try bitmap(model(fill: 0, pace: 0), scale: scale)
            near(low[Int(1 * scale), Int(6 * scale)], 0, 0, 0, alpha, "marker at the left end at scale \(scale)")
            near(low[Int(5 * scale), Int(6 * scale)], 0, 0, 0, 26, "nothing right of it at scale \(scale)")
            let (high, _) = try bitmap(model(fill: 0, pace: 1), scale: scale)
            near(high[Int(199 * scale) - 1, Int(6 * scale)], 0, 0, 0, alpha, "marker at the right end at scale \(scale)")
            near(high[Int(190 * scale), Int(6 * scale)], 0, 0, 0, 26, "track left of it at scale \(scale)")
            // above the track the marker stands alone (the Mac's 2 pt overhang)
            near(mid[Int(100 * scale) - 1, Int(2 * scale)], 0, 0, 0, 119, "overhang above the track at scale \(scale)")
        }
    }

    func testPercentIsClampedAndADimmedBarIsHalfOpaque() async throws {
        let (over, _) = try bitmap(model(fill: 140), scale: 1)
        near(over[192, 6], 0x00, 0x88, 0xFF, 255, "a fill past 100 % reaches the end")
        let (none, _) = try bitmap(model(fill: -5), scale: 1)
        near(none[10, 6], 0, 0, 0, 26, "a negative fill draws none")
        let (dim, _) = try bitmap(model(fill: 100, dimmed: true), scale: 1)
        // the track (10 % black) and the fill, each at half opacity: alpha 0.5 + 0.05 x 0.5 = 0.525
        near(dim[100, 6], 0, 68, 128, 134, "half opacity (premultiplied)", tolerance: 3)
        XCTAssertEqual(LimitBarPart.fillWidth(percent: 25, width: 200), 50)
        XCTAssertEqual(LimitBarPart.fillWidth(percent: 140, width: 200), 200)
    }

    func testAccessibleValueTooltipAndChange() async throws {
        let (_, drawing) = try bitmap(model(fill: 42), scale: 1)
        XCTAssertEqual(drawing.drawing.accessibility.map(\.label), ["5-hour 42%"])
        XCTAssertEqual(drawing.drawing.accessibility.first?.role, .staticText)
        XCTAssertEqual(drawing.drawing.tooltips.map(\.text), ["tip"])
        var changes = 0
        let part = LimitBarPart(model(fill: 42))
        part.onChange = { changes += 1 }
        part.update(model(fill: 42))
        XCTAssertEqual(changes, 0, "the same row renders nothing")
        part.update(model(fill: 43))
        XCTAssertEqual(changes, 1)
        var none = model(fill: 1)
        none.help = nil
        let bare = LimitBarPart(none).render(scale: 1, graphics: PlatformPlaza.graphics)
        XCTAssertEqual(bare.drawing.tooltips, [])
    }

    func testTheMacsOwnMarkerFractionFeedsTheBar() async {
        // `LimitRowModel.paceMarker` is `PopoverFormat.markerFraction` (a pinned twin of `LimitProgressBar.markerFraction`):
        // remaining mode flips it, so the bar is given the flipped value and never flips it again.
        XCTAssertEqual(PopoverFormat.markerFraction(pace: 0.25, mode: .used), 0.25)
        XCTAssertEqual(PopoverFormat.markerFraction(pace: 0.25, mode: .remaining), 0.75)
    }
}
