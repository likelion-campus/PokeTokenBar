import XCTest
@testable import PokeTokenBar

final class PlazaPondMapTests: XCTestCase {
    let map = PlazaMapData.map

    /// v2.5.616 map (1cc0340), before the pond.
    static let legacyRows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTT..........................................TTT",
        "TTT..f.........b......SNNS........ggggg......TTT",
        "TTT..ggggggg..........SNNSf.......ggggg.f....TTT",
        "TTT..ggggggg.f...f...SSSSSS.......ggggg......TTT",
        "TTT..ggggggg.........SSSSSS...b.f............TTT",
        "TTT..ggggggg.................................TTT",
        "TTT.....f..........f............f....f.......TTT",
        "TTT..........................ggg.......b.....TTT",
        "TTT.f........................ggg.............TTT",
        "TTT..................................f.f.....TTT",
        "TTT.......b.........................f......f.TTT",
        "TTT.....................................ggg..TTT",
        "TTT.f..gg..............FF........f......ggg..TTT",
        "TTT....gg.f...f........FF................f...TTT",
        "TTT............b..................f..........TTT",
        "TTT............................f...f.........TTT",
        "TTT........b.................................TTT",
        "TTT........f..................f..............TTT",
        "TTT............f.......................f.....TTT",
        "TTT.ggggg.........f..............b...f....b..TTT",
        "TTT.ggggg........f.....f...f.................TTT",
        "TTT.ggggg................ggggggg.............TTT",
        "TTT.ggggg.......gg.......ggggggg.............TTT",
        "TTT.............gg.......ggggggg......ff.....TTT",
        "TTT...................f..ggggggg.............TTT",
        "TTT..........................................TTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    ]

    /// itemLayoutRows at 1cc0340.
    static let legacyItemLayout: [String] = [
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

    private func points(_ rows: [String], where match: (Character) -> Bool) -> Set<TilePoint> {
        var out = Set<TilePoint>()
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where match(ch) { out.insert(TilePoint(x: x, y: y)) }
        }
        return out
    }

    private var water: Set<TilePoint> { points(PlazaMapData.rows) { $0 == "w" } }

    private var shoreLand: Set<TilePoint> {
        var out = Set<TilePoint>()
        for p in water {
            for dy in -1...1 { for dx in -1...1 {
                let q = TilePoint(x: p.x + dx, y: p.y + dy)
                if !map.isWater(q) { out.insert(q) }
            } }
        }
        return out
    }

    private func chebyshev(_ a: TilePoint, _ b: TilePoint) -> Int { max(abs(a.x - b.x), abs(a.y - b.y)) }

    func testPondIsBlockedWater() {
        XCTAssertEqual(PlazaTile(rawValue: "w"), .pond)
        XCTAssertFalse(PlazaTile.pond.isWalkable)
        XCTAssertTrue(map.isWater(TilePoint(x: 32, y: 17)))
        XCTAssertFalse(map.isWater(TilePoint(x: 31, y: 17)))
        XCTAssertFalse(map.isWater(TilePoint(x: -1, y: 0)))
    }

    private static let pondRects: [(xs: ClosedRange<Int>, ys: ClosedRange<Int>)] = [
        (5...14, 13...15), (32...38, 14...20), (20...22, 24...26)]

    private func rectTiles(_ r: (xs: ClosedRange<Int>, ys: ClosedRange<Int>)) -> Set<TilePoint> {
        var out = Set<TilePoint>()
        for y in r.ys { for x in r.xs { out.insert(TilePoint(x: x, y: y)) } }
        return out
    }

    func testPondMatchesTheSpec() {
        let rects = Self.pondRects.map(rectTiles)
        XCTAssertEqual(rects.map(\.count), [30, 49, 9])
        XCTAssertEqual(water, rects.reduce(into: Set<TilePoint>()) { $0.formUnion($1) })
        XCTAssertEqual(water.count, 88)
    }

    func testPondsAreThreeSeparateRectangles() {
        // Flood-fill the 8-connected water components: exactly three, each one a full rectangle.
        var left = water
        var boxes: [(xs: ClosedRange<Int>, ys: ClosedRange<Int>, count: Int)] = []
        while let seed = left.first {
            var comp = Set<TilePoint>(), stack = [seed]
            while let p = stack.popLast() {
                guard left.remove(p) != nil else { continue }
                comp.insert(p)
                for dy in -1...1 { for dx in -1...1 { stack.append(TilePoint(x: p.x + dx, y: p.y + dy)) } }
            }
            let xs = comp.map(\.x), ys = comp.map(\.y)
            let box = (xs: xs.min()!...xs.max()!, ys: ys.min()!...ys.max()!, count: comp.count)
            XCTAssertEqual(box.count, box.xs.count * box.ys.count, "pond at \(box.xs) x \(box.ys) is not a full rectangle")
            boxes.append(box)
        }
        XCTAssertEqual(boxes.count, 3)
        for r in Self.pondRects {
            XCTAssertTrue(boxes.contains { $0.xs == r.xs && $0.ys == r.ys }, "missing pond \(r)")
        }
        // Plain rectangles have no inner corners: every shore tile is a drawable edge or outer corner.
        for p in shoreLand {
            XCTAssertNotEqual(PlazaPond.shore(at: p, isWater: map.isWater), .unsupported, "\(p)")
        }
    }

    func testOnlyOpenGroundChanged() {
        // The reshape also cleared the 2x2 tall grass at (7...8, 15...16) and moved the bush (10,13) to (6,19);
        // apart from those, only open ground may have turned to water.
        var old = Self.legacyRows
        func set(_ x: Int, _ y: Int, _ c: Character) {
            var row = Array(old[y]); row[x] = c; old[y] = String(row)
        }
        for y in 15...16 { for x in 7...8 { set(x, y, ".") } }
        set(10, 13, "."); set(6, 19, "b")
        let new = PlazaMapData.rows
        XCTAssertEqual(old.count, new.count)
        for (y, (o, n)) in zip(old, new).enumerated() {
            for (x, (a, b)) in zip(o, n).enumerated() where a != b {
                XCTAssertEqual(b, "w", "changed to non-water at (\(x),\(y))")
                XCTAssertTrue(a == "." || a == "f", "water replaced \(a) at (\(x),\(y))")
            }
        }
        XCTAssertEqual(shoreLand.count, 78)
        for p in shoreLand {
            let ch = old[p.y][old[p.y].index(old[p.y].startIndex, offsetBy: p.x)]
            XCTAssertTrue(ch == "." || ch == "f", "shore \(p) was \(ch)")
        }
    }

    func testEveryShoreTileIsDrawable() {
        for p in shoreLand {
            XCTAssertNotEqual(PlazaPond.shore(at: p, isWater: map.isWater), .unsupported, "\(p)")
        }
    }

    func testPondKeepsItsDistance() {
        let area = water.union(shoreLand)
        for p in area {
            for y in 0..<map.height { for x in 0..<map.width {
                let q = TilePoint(x: x, y: y)
                let need: Int
                switch map.tile(at: q) {
                case .bush, .tallGrass, .shelter, .board, .campfire: need = 1   // the shore ring itself is clear
                default: continue
                }
                XCTAssertGreaterThanOrEqual(chebyshev(p, q), need, "\(p) vs \(q) \(map.tile(at: q))")
            } }
        }
    }

    func testItemsOnThePondAreHidden() {
        let open = PlazaItems.openTiles(in: map)
        for p in water { XCTAssertFalse(open.contains(p), "\(p)") }
        XCTAssertEqual(PlazaMapData.itemLayoutRows, Self.legacyItemLayout)
    }
}
