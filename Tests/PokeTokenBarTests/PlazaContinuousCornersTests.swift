import XCTest
@testable import PokeTokenBar

/// `PlazaContinuousCorners` reproduces SwiftUI's `.continuous` rounded rectangles. The golden holds what SwiftUI made on
/// the Mac for rectangles 4 … 400 wide, radii 0 … 30 (and radii above half a side), uniform and per corner; the Mac
/// test reads SwiftUI directly.
final class PlazaContinuousCornersTests: XCTestCase {
    /// The element lists' largest coordinate difference; infinity when the shapes differ.
    static func distance(_ a: [PlazaCurveElement], _ b: [PlazaCurveElement]) -> Double {
        guard a.count == b.count else { return .infinity }
        func points(_ e: PlazaCurveElement) -> [CGPoint] {
            switch e {
            case .move(let p), .line(let p): [p]
            case .curve(let p, let c1, let c2): [p, c1, c2]
            case .close: []
            }
        }
        var worst = 0.0
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.move, .move), (.line, .line), (.curve, .curve), (.close, .close):
                for (p, q) in zip(points(x), points(y)) { worst = max(worst, Double(abs(p.x - q.x)), Double(abs(p.y - q.y))) }
            default: return .infinity
            }
        }
        return worst
    }

    /// `true` where both legs of every corner start at exactly the radius (the corner is squeezed by the rectangle) or
    /// at 1.528665 times it (it is not): there the arithmetic is the same as SwiftUI's to the last bit (the golden's
    /// tolerance is 1e-9). Between, SwiftUI's single-precision intermediates differ by a `Float` step (see
    /// `PlazaContinuousCorners`). Only decided for one radius (uniform rectangles).
    static func exactRegime(_ rect: CGRect, _ radii: [Double]) -> Bool {
        guard radii.count == 1 else { return false }
        let w = Double(rect.width) / 2, h = Double(rect.height) / 2
        let re = min(radii[0], w, h)
        if re <= 0 { return true }
        return [w / re, h / re].allSatisfy { $0 <= 1.0000001 || $0 >= 1.528665 }
    }

    func testEveryGoldenCase() throws {
        let golden = try PlazaParityGoldens.load(PlazaCornersGolden.self, "corners.json")
        XCTAssertEqual(golden.cases.count, PlazaCornersGolden.roundedRects.count * PlazaCornersGolden.roundedRadii.count
            + PlazaCornersGolden.unevenRects.count * PlazaCornersGolden.unevenRadii.count)
        var exact = 0, float = 0
        for c in golden.cases {
            let rect = CGRect(x: c.rect[0], y: c.rect[1], width: c.rect[2], height: c.rect[3])
            let mine: [PlazaCurveElement]
            if c.kind == "rounded" {
                mine = PlazaContinuousCorners.roundedRect(rect, radius: CGFloat(c.radii[0]))
            } else {
                mine = PlazaContinuousCorners.unevenRoundedRect(rect, radii: PlazaCornerRadii(topLeading: CGFloat(c.radii[0]), bottomLeading: CGFloat(c.radii[1]),
                                                                                             bottomTrailing: CGFloat(c.radii[2]), topTrailing: CGFloat(c.radii[3])))
            }
            let d = Self.distance(mine, PlazaCornersGolden.unflatten(c.elements))
            let label = "\(c.kind) \(c.rect) radii \(c.radii)"
            if c.kind == "rounded" && Self.exactRegime(rect, c.radii) {
                exact += 1
                XCTAssertLessThanOrEqual(d, 1e-9, label)
            } else {
                float += 1
                XCTAssertLessThanOrEqual(d, 3e-5, "\(label): within SwiftUI's single-precision step")
            }
        }
        XCTAssertGreaterThan(exact, 30)
        XCTAssertGreaterThan(float, 10)
    }

    func testShapesOfTheSimpleCases() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 60)
        // radius 0 is the plain rectangle
        XCTAssertEqual(PlazaContinuousCorners.roundedRect(r, radius: 0), [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 100, y: 0)), .line(CGPoint(x: 100, y: 60)),
                                                                          .line(CGPoint(x: 0, y: 60)), .close])
        // a corner is three curves; four corners, four lines between them, the move and the close
        let rounded = PlazaContinuousCorners.roundedRect(r, radius: 10)
        XCTAssertEqual(rounded.count, 1 + 4 * 4 + 1)
        XCTAssertEqual(rounded.first, .move(CGPoint(x: 100, y: 30)))
        // the curve starts 1.528665 radii before the corner
        if case .line(let p) = rounded[1] { XCTAssertEqual(Double(p.y), 60 - 15.28665, accuracy: 1e-5) } else { XCTFail("first element after the move is a line") }
        // uneven: the shape's top is maxY, so a top corner's curve ends at maxY
        let uneven = PlazaContinuousCorners.unevenRoundedRect(r, radii: PlazaCornerRadii(topLeading: 10, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0))
        XCTAssertTrue(uneven.contains { if case .curve(let p, _, _) = $0 { return abs(p.x - 15.28665) < 1e-5 && abs(p.y - 60) < 1e-9 } else { return false } })
    }
}
