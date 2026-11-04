import XCTest
@testable import PokeTokenBar

final class PlazaTallGrassMapTests: XCTestCase {
    let rows = PlazaMapData.rows
    let map = PlazaMapData.map

    private func points(of kind: Character, in rows: [String]) -> [TilePoint] {
        var out: [TilePoint] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == kind { out.append(TilePoint(x: x, y: y)) }
        }
        return out
    }

    private func chebyshev(_ a: TilePoint, _ b: TilePoint) -> Int { max(abs(a.x - b.x), abs(a.y - b.y)) }

    /// g 칸의 4방향 연결 덩어리.
    private func patches() -> [[TilePoint]] {
        var remaining = Set(points(of: "g", in: rows))
        var result: [[TilePoint]] = []
        while let start = remaining.first {
            remaining.remove(start)
            var patch = [start]
            var queue = [start]
            while let p = queue.popLast() {
                for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let n = TilePoint(x: p.x + d.0, y: p.y + d.1)
                    if remaining.remove(n) != nil { patch.append(n); queue.append(n) }
                }
            }
            result.append(patch)
        }
        return result
    }

    func testTallGrassIsWalkable() {
        XCTAssertEqual(PlazaTile(rawValue: "g"), .tallGrass)
        XCTAssertTrue(PlazaTile.tallGrass.isWalkable)
    }

    /// 풀숲은 걸을 수 있어서 아이템 후보를 바꾸지 않는다: g를 풀밭으로 바꾼 지도와 후보가 같다.
    func testTallGrassDoesNotChangeItemCandidates() throws {
        let plain = try PlazaMap(rows: rows.map { $0.replacingOccurrences(of: "g", with: ".") })
        XCTAssertEqual(PlazaItems.candidates(in: map), PlazaItems.candidates(in: plain))
    }

    func testPatchesAreSolidRectanglesAtLeastTwoByTwo() {
        let all = patches()
        XCTAssertEqual(all.count, 8)
        for patch in all {
            let xs = patch.map(\.x), ys = patch.map(\.y)
            let w = xs.max()! - xs.min()! + 1, h = ys.max()! - ys.min()! + 1
            XCTAssertEqual(patch.count, w * h, "덩어리가 꽉 찬 직사각형이 아니다: \(patch[0])")
            XCTAssertGreaterThanOrEqual(w, 2, "\(patch[0])")
            XCTAssertGreaterThanOrEqual(h, 2, "\(patch[0])")
        }
    }

    func testPatchesKeepApartAndClearOfBushesShelterAndBoard() {
        let all = patches()
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                for p in a { for q in b {
                    XCTAssertGreaterThan(chebyshev(p, q), 1, "풀숲끼리 붙음 \(p) \(q)")
                } }
            }
        }
        let grass = all.flatMap { $0 }
        for p in grass {
            for q in points(of: "b", in: rows) { XCTAssertGreaterThan(chebyshev(p, q), 1, "덤불 \(p) \(q)") }
            for kind: Character in ["S", "N", "F"] {
                for q in points(of: kind, in: rows) { XCTAssertGreaterThan(chebyshev(p, q), 2, "\(kind) \(p) \(q)") }
            }
        }
    }

    func testPatchesCoverAboutATenthOfTheOpenGround() {
        var open = 0, grass = 0
        for y in 3..<29 { for x in 3..<45 {
            open += 1
            if rows[y][rows[y].index(rows[y].startIndex, offsetBy: x)] == "g" { grass += 1 }
        } }
        XCTAssertEqual(open, 1092)
        let ratio = Double(grass) / Double(open)
        XCTAssertTrue((0.05...0.12).contains(ratio), "grass \(grass) ratio \(ratio)")
    }
}
