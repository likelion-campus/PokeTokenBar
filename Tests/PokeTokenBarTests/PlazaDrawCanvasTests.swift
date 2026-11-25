import XCTest
@testable import PokeTokenBar

final class PlazaDrawCanvasTests: XCTestCase {
    private func setCells(_ c: PlazaDrawCanvas) -> [(x: Int, y: Int)] {
        var out: [(x: Int, y: Int)] = []
        for y in 0..<PlazaDrawCanvas.height {
            for x in 0..<PlazaDrawCanvas.width where c[x, y] != 0 { out.append((x, y)) }
        }
        return out
    }

    func testAThinStrokeSetsExactlyTheCellsOfItsLine() {
        var c = PlazaDrawCanvas()
        XCTAssertTrue(c.stroke(points: [2, 2, 5, 2], color: 3, width: 1))
        for y in 0..<PlazaDrawCanvas.height {
            for x in 0..<PlazaDrawCanvas.width {
                let onLine = y == 2 && (2...5).contains(x)
                XCTAssertEqual(c[x, y], onLine ? 3 : 0, "cell (\(x), \(y))")
            }
        }
    }

    func testAThickDotIsAThreeByThreeBlock() {
        var c = PlazaDrawCanvas()
        XCTAssertTrue(c.stroke(points: [10, 10], color: 1, width: 3))
        for y in 9...11 { for x in 9...11 { XCTAssertEqual(c[x, y], 1, "cell (\(x), \(y))") } }
        XCTAssertEqual(setCells(c).count, 9)
    }

    func testADiagonalIsContinuous() {
        var c = PlazaDrawCanvas()
        XCTAssertTrue(c.stroke(points: [0, 0, 7, 5], color: 2, width: 1))
        let cells = setCells(c)
        XCTAssertEqual(Set(cells.map { $0.x }), Set(0...7), "every column is touched")
        XCTAssertEqual(cells.count, 8, "one cell per step along the long axis")
        // Walk the line in x order: no gap between consecutive cells.
        let ordered = cells.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        for i in 1..<ordered.count {
            XCTAssertLessThanOrEqual(abs(ordered[i].x - ordered[i - 1].x), 1)
            XCTAssertLessThanOrEqual(abs(ordered[i].y - ordered[i - 1].y), 1)
        }
        XCTAssertEqual(c[7, 5], 2)
    }

    func testAReversedSegmentDrawsTheSameCells() {
        var a = PlazaDrawCanvas(), b = PlazaDrawCanvas()
        a.stroke(points: [2, 2, 5, 2], color: 1, width: 1)
        b.stroke(points: [5, 2, 2, 2], color: 1, width: 1)
        XCTAssertEqual(a, b)
        var d1 = PlazaDrawCanvas(), d2 = PlazaDrawCanvas()
        d1.stroke(points: [0, 0, 7, 5], color: 1, width: 1)
        d2.stroke(points: [7, 5, 0, 0], color: 1, width: 1)
        XCTAssertEqual(d1, d2)
    }

    func testABrushAtTheEdgeIsClippedNotWrapped() {
        var c = PlazaDrawCanvas()
        XCTAssertTrue(c.stroke(points: [0, 0], color: 5, width: 5))
        let cells = setCells(c)
        XCTAssertEqual(cells.count, 9)
        XCTAssertTrue(cells.allSatisfy { (0...2).contains($0.x) && (0...2).contains($0.y) })
    }

    func testABadStrokeDrawsNothing() {
        let bad: [(points: [Int], color: Int, width: Int)] = [
            ([1, 2, 3], 1, 1),
            ([], 1, 1),
            ([Int](repeating: 4, count: 130), 1, 1),
            ([96, 0], 1, 1),
            ([0, -1], 1, 1),
            ([5, 5, 6, 64], 1, 1),
            ([5, 5], 9, 1),
            ([5, 5], 1, 2),
            ([5, 5], -1, 1),
            ([5, 5], 1, -1),
        ]
        for b in bad {
            var c = PlazaDrawCanvas()
            XCTAssertFalse(c.stroke(points: b.points, color: b.color, width: b.width), "\(b)")
            XCTAssertEqual(c, PlazaDrawCanvas(), "\(b)")
        }
        var ok = PlazaDrawCanvas()
        XCTAssertTrue(ok.stroke(points: [Int](repeating: 4, count: 128), color: 1, width: 1), "128 values is the limit")
    }

    func testPackingRoundTripsAndIsSmallForAnEmptyCanvas() {
        var c = PlazaDrawCanvas()
        c.stroke(points: [3, 3, 60, 3], color: 1, width: 1)
        c.stroke(points: [10, 20, 40, 50], color: 4, width: 3)
        c.stroke(points: [0, 63, 95, 0], color: 7, width: 5)
        XCTAssertEqual(PlazaDrawCanvas(packed: c.packed()), c)
        XCTAssertLessThanOrEqual(PlazaDrawCanvas().packed().count, 60)
        c.clear()
        XCTAssertEqual(c, PlazaDrawCanvas())
    }

    func testUnpackingRejectsTheWrongSizeAndBadColours() {
        let empty = [UInt8](PlazaDrawCanvas().packed())
        XCTAssertNotNil(PlazaDrawCanvas(packed: Data(empty)))
        var short = empty; short[short.count - 2] -= 1
        XCTAssertNil(PlazaDrawCanvas(packed: Data(short)), "one cell short")
        var long = empty; long[long.count - 2] += 1
        XCTAssertNil(PlazaDrawCanvas(packed: Data(long)), "one cell long")
        XCTAssertNil(PlazaDrawCanvas(packed: Data(empty + [0, 0])), "a count of 0")
        XCTAssertNil(PlazaDrawCanvas(packed: Data(empty + [1])), "an odd length")
        XCTAssertNil(PlazaDrawCanvas(packed: Data()), "empty data")
        let tooLong = Data([UInt8](repeating: 1, count: 2 * PlazaDrawCanvas.width * PlazaDrawCanvas.height + 2))
        XCTAssertNil(PlazaDrawCanvas(packed: tooLong), "longer than any valid run list")
        var badColour = empty; badColour[1] = 9
        XCTAssertNil(PlazaDrawCanvas(packed: Data(badColour)), "colour 9")
    }

    func testTheSameStrokesMakeTheSameCanvasOnEverySystem() {
        var c = PlazaDrawCanvas()
        c.stroke(points: [3, 3, 60, 3], color: 1, width: 1)        // thin line
        c.stroke(points: [10, 20, 40, 50, 80, 10], color: 4, width: 3) // thick line, two slopes
        c.stroke(points: [0, 63, 95, 0], color: 7, width: 1)       // shallow diagonal
        var hash: UInt64 = 0xcbf29ce484222325
        for b in c.cells { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        XCTAssertEqual(hash, 4530018231119120435, "FNV-1a 64 of the cells; the Windows run must produce the same")
    }

    func testTheBitmapUsesThePaletteCellByCell() {
        var c = PlazaDrawCanvas()
        c.stroke(points: [3, 3, 60, 3], color: 6, width: 1)
        var palette: [PlazaRGBA] = []
        for i in 0..<PlazaDrawCanvas.colorCount {
            palette.append(PlazaRGBA(r: UInt8(i * 20), g: UInt8(i * 10 + 1), b: UInt8(255 - i), a: 255))
        }
        let bm = c.bitmap(palette: palette)
        XCTAssertEqual(bm.width, 96)
        XCTAssertEqual(bm.height, 64)
        for (x, y) in [(3, 3), (60, 3), (0, 0), (95, 63)] {
            XCTAssertEqual(bm[x, y], palette[Int(c[x, y])], "(\(x), \(y))")
        }
        XCTAssertEqual(bm[10, 3], palette[6])
    }
}
