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

    func testPondMatchesTheSpec() {
        var expected = Set<TilePoint>()
        for y in 17...19 { for x in 32...37 { expected.insert(TilePoint(x: x, y: y)) } }
        for y in 15...16 { for x in 35...37 { expected.insert(TilePoint(x: x, y: y)) } }
        XCTAssertEqual(expected.count, 24)
        XCTAssertEqual(water, expected)
    }

    func testOnlyOpenGroundChanged() {
        let old = Self.legacyRows, new = PlazaMapData.rows
        XCTAssertEqual(old.count, new.count)
        for (y, (o, n)) in zip(old, new).enumerated() {
            for (x, (a, b)) in zip(o, n).enumerated() where a != b {
                XCTAssertEqual(b, "w", "changed to non-water at (\(x),\(y))")
                XCTAssertTrue(a == "." || a == "f", "water replaced \(a) at (\(x),\(y))")
            }
        }
        XCTAssertEqual(shoreLand.count, 26)
        for p in shoreLand {
            let ch = Self.legacyRows[p.y][Self.legacyRows[p.y].index(Self.legacyRows[p.y].startIndex, offsetBy: p.x)]
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
                case .bush, .tallGrass: need = 2
                case .shelter, .board, .campfire: need = 3
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
