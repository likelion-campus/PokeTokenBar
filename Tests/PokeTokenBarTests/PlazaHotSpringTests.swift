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

    // MARK: Props and colours

    func testThePropsSitOnTheirTilesAndChangeNoWalking() {
        let props = PlazaHotSpring.props(in: map)
        XCTAssertEqual(props, PlazaHotSpring.props)
        XCTAssertEqual(props.count, 6)
        XCTAssertEqual(props.map(\.at), [p(32, 16), p(36, 14), p(37, 19), p(39, 16), p(31, 21), p(39, 13)])
        for prop in props {
            for dy in 0..<prop.rows { for dx in 0..<prop.cols {
                let t = p(prop.at.x + dx, prop.at.y + dy)
                if prop.inWater {
                    XCTAssertTrue(map.isHotSpring(t), "\(prop) \(t)")
                } else {
                    XCTAssertTrue(map.isWalkable(t), "\(prop) \(t) is open ground")
                    XCTAssertFalse(map.isWater(t))
                }
            } }
        }
        XCTAssertEqual(props.filter(\.inWater).map { [$0.col, $0.row] }, [[12, 10], [14, 10], [11, 7]])
        XCTAssertEqual(PlazaHotSpring.props(in: old), [], "no spring, no stones")
        let b = PlazaHotSpring.artBounds(in: map)
        XCTAssertEqual([b?.minX, b?.minY, b?.maxX, b?.maxY], [31, 13, 40, 21])
        XCTAssertNil(PlazaHotSpring.artBounds(in: old))
        XCTAssertTrue(PlazaHotSpring.usesSpringWater(p(31, 13), in: map))
        XCTAssertTrue(PlazaHotSpring.usesSpringWater(p(39, 21), in: map))
        XCTAssertFalse(PlazaHotSpring.usesSpringWater(p(30, 17), in: map))
        XCTAssertFalse(PlazaHotSpring.usesSpringWater(p(8, 14), in: map))
    }

    /// All or nothing: a map with the spring where one stone's tiles do not fit gets no stones at all.
    func testAStoneThatDoesNotFitDropsEveryStone() throws {
        func rows(_ x: Int, _ y: Int, _ c: Character) -> PlazaMap {
            var r = PlazaMapData.rows
            var row = Array(r[y]); row[x] = c; r[y] = String(row)
            return try! PlazaMap(rows: r)
        }
        XCTAssertEqual(PlazaHotSpring.props(in: map).count, 6)
        XCTAssertEqual(PlazaHotSpring.props(in: rows(39, 16, "b")), [], "a bank stone on a bush")
        XCTAssertEqual(PlazaHotSpring.props(in: rows(40, 17, "w")), [], "a bank stone on water")
        XCTAssertEqual(PlazaHotSpring.props(in: rows(32, 16, "w")), [], "a water stone on a plain pond tile")
        XCTAssertEqual(PlazaHotSpring.props(in: rows(38, 20, ".")).count, 0, "a water stone on land (the spring still has tiles)")
        let bad = rows(39, 16, "b")
        XCTAssertEqual(PlazaHotSpring.artBounds(in: bad)?.maxX, 39, "no stones, so the ring alone: x 31...39")
    }

    private func sheet() throws -> PlazaImage { try XCTUnwrap(PlatformPlaza.tileSheet()) }

    func testTheSpringSheetSwapsOnlyTheWaterColours() throws {
        let original = try sheet()
        let spring = PlazaHotSpring.sheet(original)
        XCTAssertEqual([spring.width, spring.height], [original.width, original.height])
        let o = original.pixels.bytes, s = spring.pixels.bytes
        func rgb(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) }
        let cells = [PlazaTileArt.waterCell] + PlazaPond.shoreCells + PlazaHotSpring.waterPropCells
        func inside(_ x: Int, _ y: Int) -> Bool { cells.contains { $0.col == x / 16 && $0.row == y / 16 } }
        for y in 0..<original.height { for x in 0..<original.width {
            let i = (y * original.width + x) * 4
            if inside(x, y) {
                if s[i + 3] == 255 { XCTAssertNil(PlazaHotSpring.waterColors[rgb(s, i)], "(\(x),\(y)) keeps a water colour") }
                if o[i + 3] == 255, let to = PlazaHotSpring.waterColors[rgb(o, i)] { XCTAssertEqual(rgb(s, i), to, "(\(x),\(y))") }
            } else {
                XCTAssertEqual(Array(s[i..<i + 4]), Array(o[i..<i + 4]), "(\(x),\(y)) is outside the swapped cells")
            }
        } }
        let (wc, wr) = (PlazaTileArt.waterCell.col, PlazaTileArt.waterCell.row)
        for y in 0..<16 { for x in 0..<16 {
            let i = ((wr * 16 + y) * original.width + wc * 16 + x) * 4
            XCTAssertEqual(rgb(s, i), 0x4FA8A0); XCTAssertEqual(s[i + 3], 255)
        } }
    }

    func testRecolouredEffectsKeepTheirShapes() {
        for art in [PlazaPondArt.swimRing(), PlazaPondArt.droplet(), PlazaPondArt.bubble(), PlazaPondArt.ring(radius: 9)] {
            let new = PlazaHotSpring.recolored(art)
            let a = art.pixels.bytes, b = new.pixels.bytes
            XCTAssertEqual([new.width, new.height], [art.width, art.height])
            for i in stride(from: 3, to: a.count, by: 4) { XCTAssertEqual(a[i], b[i]) }
            for i in stride(from: 0, to: a.count, by: 4) where a[i + 3] == 255 {
                let from = UInt32(a[i]) << 16 | UInt32(a[i + 1]) << 8 | UInt32(a[i + 2])
                let to = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
                XCTAssertEqual(to, PlazaHotSpring.waterColors[from] ?? from)
            }
        }
        let ring = PlazaHotSpring.recolored(PlazaPondArt.swimRing()).pixels.bytes
        XCTAssertTrue(stride(from: 0, to: ring.count, by: 4).contains { ring[$0] == 0x74 && ring[$0 + 1] == 0xC0 && ring[$0 + 2] == 0xB6 })
    }

    func testTheTintIsTheSharedRenderersFormula() {
        var bitmap = PlazaBitmap(width: 2, height: 1)
        bitmap[0, 0] = PlazaRGBA(r: 255, g: 255, b: 255, a: 255)
        let out = PlazaHotSpring.tinted(PlazaImage(bitmap: bitmap), blend: 0.45).pixels.bytes
        XCTAssertEqual(Double(out[0]), 241, accuracy: 1)
        XCTAssertEqual(Double(out[1]), 176, accuracy: 1)
        XCTAssertEqual(Double(out[2]), 167, accuracy: 1)
        XCTAssertEqual(out[3], 255)
        XCTAssertEqual(Array(out[4..<8]), [0, 0, 0, 0], "transparent stays transparent")
    }
}
