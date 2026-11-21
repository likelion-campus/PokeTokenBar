import XCTest
@testable import PokeTokenBar

/// Body size classes (spec 6): the thresholds, the body tiles and the touch rule.
@MainActor
final class PlazaBodySizeTests: XCTestCase {
    private func frames(front: (Int, Int), back: (Int, Int)? = nil, egg: Bool = false, placeholder: Bool = false) -> PlazaCharacterFrames {
        func img(_ s: (Int, Int)) -> PlazaImage {
            PlazaImage(bitmap: PlazaTestImages.solid(width: s.0, height: s.1, PlazaRGBA(r: 255, g: 0, b: 0, a: 255)))
        }
        let b = back ?? front
        var f = PlazaCharacterFrames(front: [PlazaFrame(image: img(front), delay: 0.1)], back: [PlazaFrame(image: img(b), delay: 0.1)])
        f.isEgg = egg
        f.isPlaceholder = placeholder
        return f
    }

    func testTheTunablesAreTheSpecsStartingValues() {
        XCTAssertEqual(PlazaBodySize.class2From, 80)
        XCTAssertEqual(PlazaBodySize.class3From, 120)
        XCTAssertEqual(PlazaBodySize.spans.map { [$0.w, $0.h] }, [[0, 0], [1, 1], [1, 2]])
        XCTAssertEqual(PlazaBodySize.classes, 1...3)
    }

    func testTheClassBoundariesAreEightyAndOneTwentyWorldPixels() {
        XCTAssertEqual([79, 79.99, 80, 119, 119.99, 120].map { PlazaBodySize.size(longSide: $0) }, [1, 1, 2, 2, 2, 3])
        XCTAssertEqual([75, 57, 112, 112, 123, 153, 154].map { PlazaBodySize.size(longSide: $0) }, [1, 1, 2, 2, 3, 3, 3])
    }

    func testTheClassIsTheCroppedFrontsLongSideTimesOneAndAHalf() {
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (53, 10))), 1)
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (54, 10))), 2)
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (10, 54))), 2)
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (79, 40))), 2)
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (80, 40))), 3)
        XCTAssertEqual(PlazaBodySize.size(of: frames(front: (50, 40), back: (120, 120))), 1)
    }

    func testAnEggOrThePlaceholderHasNoClass() {
        XCTAssertNil(PlazaBodySize.size(of: frames(front: (80, 80), egg: true)))
        XCTAssertNil(PlazaBodySize.size(of: frames(front: (80, 80), placeholder: true)))
    }

    func testReceivedSizesStayWithinOneToThreeAndOneIsNotSent() {
        XCTAssertEqual([nil, 0, -1, 1, 2, 3, 4, 999].map { PlazaBodySize.clamped($0) }, [1, 1, 1, 1, 2, 3, 3, 3])
        XCTAssertEqual([1, 2, 3].map { PlazaBodySize.sent($0) }, [nil, 2, 3])
    }

    private func covered(_ b: PlazaBody) -> Set<TilePoint> {
        var s = Set<TilePoint>()
        for x in 0...10 { for y in 0...10 where b.covers(TilePoint(x: x, y: y)) { s.insert(TilePoint(x: x, y: y)) } }
        return s
    }

    func testABodyGrowsUpAndSidewaysButNeverBelowTheFoot() {
        let foot = TilePoint(x: 5, y: 5)
        func block(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Set<TilePoint> {
            Set(xs.flatMap { x in ys.map { TilePoint(x: x, y: $0) } })
        }
        XCTAssertEqual(covered(PlazaBody(foot: foot, size: 1)), [foot])
        XCTAssertEqual(covered(PlazaBody(foot: foot, size: 2)), block(4...6, 4...5))
        XCTAssertEqual(covered(PlazaBody(foot: foot, size: 3)), block(4...6, 3...5))
        for c in 1...3 { XCTAssertFalse(PlazaBody(foot: foot, size: c).covers(TilePoint(x: 5, y: 6))) }
    }

    func testBodiesTouchWhenTwoTilesMeetOrSitSideBySide() {
        func b(_ x: Int, _ y: Int, _ c: Int) -> PlazaBody { PlazaBody(foot: TilePoint(x: x, y: y), size: c) }
        let me1 = b(5, 5, 1)
        XCTAssertEqual([b(5, 5, 1), b(6, 5, 1), b(6, 6, 1), b(7, 5, 1)].map { me1.touches($0) }, [true, true, false, false])
        let me3 = b(5, 5, 3)
        XCTAssertEqual([b(5, 8, 3), b(5, 9, 3), b(5, 2, 3), b(5, 1, 3)].map { me3.touches($0) }, [true, false, true, false])
        XCTAssertTrue(b(6, 6, 2).touches(b(5, 5, 1)))
    }

    func testTouchingIsSymmetric() {
        var rng = PlazaSplitMix64(seed: 0xB0D1)
        func r(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        for _ in 0..<5000 {
            let a = PlazaBody(foot: TilePoint(x: r(11) - 5, y: r(11) - 5), size: r(3) + 1)
            let b = PlazaBody(foot: TilePoint(x: r(11) - 5, y: r(11) - 5), size: r(3) + 1)
            XCTAssertEqual(a.touches(b), b.touches(a))
        }
    }
}
