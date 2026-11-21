import XCTest
@testable import PokeTokenBar

final class PlazaHotSpringTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    /// The v2.5.635 map: every `'h'` turned back to `'w'`.
    private var old: PlazaMap { try! PlazaMap(rows: PlazaMapData.rows.map { $0.replacingOccurrences(of: "h", with: "w") }) }

    func testTheRightPondIsTheHotSpring() {
        XCTAssertEqual(PlazaTile(rawValue: "h"), .hotSpring)
        XCTAssertFalse(PlazaTile.hotSpring.isWalkable)
        let tiles = PlazaHotSpring.tiles(in: map)
        XCTAssertEqual(tiles.count, 49)
        XCTAssertEqual(tiles, (14...20).flatMap { y in (32...38).map { x in p(x, y) } })
        for t in tiles {
            XCTAssertTrue(map.isWater(t), "\(t)")
            XCTAssertTrue(map.isHotSpring(t), "\(t)")
        }
        XCTAssertFalse(map.isHotSpring(p(31, 17)))
        XCTAssertFalse(map.isHotSpring(p(5, 13)))
        XCTAssertFalse(map.isHotSpring(p(-1, 0)))
        XCTAssertTrue(map.isWater(p(5, 13)))
        XCTAssertEqual(PlazaHotSpring.tiles(in: old), [])
        for y in 0..<old.height { for x in 0..<old.width { XCTAssertFalse(old.isHotSpring(p(x, y))) } }
    }

    /// Sweep A: every rule that asks about the tile answers as it did for the pond the spring replaced.
    func testTheSpringAnswersLikeThePondItReplaced() {
        let old = self.old
        for y in -1...32 { for x in -1...48 {
            let t = p(x, y)
            XCTAssertEqual(map.isWalkable(t), old.isWalkable(t), "isWalkable \(t)")
            XCTAssertEqual(map.isWater(t), old.isWater(t), "isWater \(t)")
            XCTAssertEqual(PlazaSnow.isSnowGround(t, in: map), PlazaSnow.isSnowGround(t, in: old), "snow ground \(t)")
            XCTAssertEqual(PlazaSnowball.blocksBall(t, in: map), PlazaSnowball.blocksBall(t, in: old), "blocksBall \(t)")
            XCTAssertEqual(PlazaDitto.isGround(t, in: map), PlazaDitto.isGround(t, in: old), "Ditto ground \(t)")
            XCTAssertEqual(PlazaPond.shore(at: t, isWater: map.isWater), PlazaPond.shore(at: t, isWater: old.isWater), "shore \(t)")
        } }
        // a step into and out of the spring, and along its bank
        for y in 13...21 { for x in 31...39 {
            for d in PlazaDirection.allCases {
                let a = p(x, y), b = PlazaWalker.offset(a, d)
                XCTAssertEqual(PlazaSnow.footprints(from: a, to: b, map: map).count,
                               PlazaSnow.footprints(from: a, to: b, map: old).count, "footprints \(a)->\(b)")
            }
        } }
        XCTAssertEqual(PlazaItems.openTiles(in: map), PlazaItems.openTiles(in: old))
        XCTAssertEqual(map.spawn, old.spawn)
        XCTAssertEqual(map.boardTile, old.boardTile)
        XCTAssertEqual(map.shelterTiles, old.shelterTiles)
        XCTAssertEqual(map.campfireTiles, old.campfireTiles)
        XCTAssertEqual(PlazaPathfinder.path(from: p(31, 13), toNextTo: p(39, 21), map: map),
                       PlazaPathfinder.path(from: p(31, 13), toNextTo: p(39, 21), map: old))
        // The only things allowed to differ: isHotSpring, the freezing ponds and the lily pads (see PlazaIceTests, PlazaTileArtTests).
        XCTAssertEqual(PlazaIce.ponds(in: old).count, 3)
        XCTAssertEqual(PlazaIce.ponds(in: map).count, 2)
    }
}
