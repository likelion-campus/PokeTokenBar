import XCTest
@testable import PokeTokenBar

final class PlazaTallGrassMapTests: XCTestCase {
    /// 풀숲을 넣기 전 지도(71a24c1). 풀숲이 빈 땅만 바꿨는지, 아이템 후보가 그대로인지 비교하는 기준이다.
    /// 리베이스로 모닥불이 들어오면 그 지도로 다시 옮긴다.
    static let legacyRows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTT..........................................TTT",
        "TTT..f.........b.......f.....................TTT",
        "TTT.....................f.f.............f....TTT",
        "TTT..........f...f...........................TTT",
        "TTT...........................b.f............TTT",
        "TTT.......f..................................TTT",
        "TTT.....f..........f............f....f.......TTT",
        "TTT....................................b.....TTT",
        "TTT.f........................................TTT",
        "TTT..................................f.f.....TTT",
        "TTT.......b.........................f......f.TTT",
        "TTT...................SNNS...................TTT",
        "TTT.f.................SNNS.......f...........TTT",
        "TTT.......f...f......SSSSSS..............f...TTT",
        "TTT............b.....SSSSSS.......f..........TTT",
        "TTT............................f...f.........TTT",
        "TTT........b.................................TTT",
        "TTT........f..................f..............TTT",
        "TTT............f.......................f.....TTT",
        "TTT...............f..............b...f....b..TTT",
        "TTT..............f.....f...f.................TTT",
        "TTT..........................................TTT",
        "TTT..........................................TTT",
        "TTT..............f...........f........ff.....TTT",
        "TTT...................f......................TTT",
        "TTT..........................................TTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    ]

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

    func testOnlyOpenGroundBecameGrass() {
        let old = Self.legacyRows
        XCTAssertEqual(rows.count, old.count)
        for (y, (n, o)) in zip(rows, old).enumerated() {
            XCTAssertEqual(n.count, o.count, "row \(y)")
            for (x, (a, b)) in zip(n, o).enumerated() where a != b {
                XCTAssertEqual(a, "g", "(\(x),\(y)) 바뀐 칸은 풀숲이어야 한다")
                XCTAssertTrue(b == "." || b == "f", "(\(x),\(y)) 풀숲은 풀밭·꽃만 덮는다: \(b)")
            }
        }
    }

    func testItemCandidatesMatchTheMapBeforeTallGrass() throws {
        let legacy = try PlazaMap(rows: Self.legacyRows)
        let before = PlazaItems.candidates(in: legacy)
        XCTAssertEqual(before.count, 1062)
        XCTAssertEqual(PlazaItems.candidates(in: map), before)
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
            // 모닥불 자리 (36–37, 23–24): 아직 지도에 F 가 없어도 2칸 안에 풀숲이 없어야 한다.
            for fx in 36...37 { for fy in 23...24 {
                XCTAssertGreaterThan(chebyshev(p, TilePoint(x: fx, y: fy)), 2, "모닥불 자리 \(p)")
            } }
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
