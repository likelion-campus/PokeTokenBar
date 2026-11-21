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

    /// The first proposal's east-bank prop, (37,5)-(38,6), is a gravestone (cross and inscription). Every prop is a rock.
    func testEveryPropIsARockAndNoneIsTheGravestone() throws {
        XCTAssertEqual(PlazaHotSpring.props.map { [$0.col, $0.row, $0.cols, $0.rows] },
                       [[12, 10, 1, 1], [14, 10, 1, 1], [11, 7, 2, 2], [4, 1, 2, 2], [7, 5, 1, 1], [10, 5, 1, 1]])
        // The rock pair's own grass tufts follow the ground like the other bank stones.
        for c in [(4, 2), (5, 2)] {   // the cells of the pair that carry the tufts
            XCTAssertTrue(PlazaHotSpring.bankStoneCells.contains { $0.col == c.0 && $0.row == c.1 }, "\(c)")
        }
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()).pixels.bytes
        // No cool grey body in any prop cell: the gravestone's body is #9AA3B0-like (blue above red), the rocks are brown.
        let width = try XCTUnwrap(PlatformPlaza.tileSheet()).width
        for p in PlazaHotSpring.props where !p.inWater {
            for y in (p.row * 16)..<((p.row + p.rows) * 16) { for x in (p.col * 16)..<((p.col + p.cols) * 16) {
                let i = (y * width + x) * 4
                guard sheet[i + 3] == 255, sheet[i + 1] != 0xCA, sheet[i + 1] != 0x8E else { continue }
                XCTAssertFalse(sheet[i + 2] > sheet[i] + 8, "a cool grey pixel in prop \(p) at \(x),\(y)")
            } }
        }
    }

    /// The drag rules (PR 3) ask only `isWalkable`: the spring answers like the pond it replaced, so a slide stops before it.
    func testTheDragRulesAnswerAtTheSpringAsAtTheOldPond() {
        let old = self.old
        XCTAssertEqual(PlazaDrag.slide(victim: p(35, 12), puller: p(35, 10), direction: .down, pushTiles: 3, isOpen: { self.map.isWalkable($0) }), 1,
                       "the slide stops on the bank before (35,14)")
        for y in 10...24 { for x in 28...42 { for d in PlazaDirection.allCases { for k in 1...3 {
            let v = p(x, y)
            XCTAssertEqual(PlazaDrag.slide(victim: v, puller: p(x, y + 2), direction: d, pushTiles: k, isOpen: { self.map.isWalkable($0) }),
                           PlazaDrag.slide(victim: v, puller: p(x, y + 2), direction: d, pushTiles: k, isOpen: { old.isWalkable($0) }), "\(v) \(d) \(k)")
            XCTAssertEqual(PlazaDrag.stepBack(from: v, direction: d, stage: k, isOpen: { self.map.isWalkable($0) }),
                           PlazaDrag.stepBack(from: v, direction: d, stage: k, isOpen: { old.isWalkable($0) }), "\(v) \(d) \(k)")
        } } } }
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

    /// The flush is baked into the body's own picture: a plain lerp of every opaque pixel toward `flushColor`, in a few steps.
    func testTheLerpedFrameMovesEveryColourTowardRed() {
        XCTAssertEqual(PlazaHotSpring.flushSteps, 6)
        XCTAssertEqual(PlazaHotSpring.flushStep(forBlend: 0), 0)
        XCTAssertEqual(PlazaHotSpring.flushStep(forBlend: PlazaHotSpring.flushBlend), 6)
        XCTAssertEqual(PlazaHotSpring.flushStep(forBlend: PlazaHotSpring.flushBlend / 2), 3)
        XCTAssertEqual(PlazaHotSpring.flushStep(forBlend: 5), 6, "never above the last step")
        XCTAssertEqual(PlazaHotSpring.flushStep(forBlend: 0.01), 0, "a tiny level rounds to the plain frame")
        XCTAssertEqual(PlazaHotSpring.flushAmount(step: 0), 0)
        XCTAssertEqual(PlazaHotSpring.flushAmount(step: 6), PlazaHotSpring.flushBlend, accuracy: 1e-9)
        var bitmap = PlazaBitmap(width: 4, height: 1)
        bitmap[0, 0] = PlazaRGBA(r: 255, g: 255, b: 255, a: 255)
        bitmap[1, 0] = PlazaRGBA(r: 0, g: 0, b: 255, a: 255)
        bitmap[2, 0] = PlazaRGBA(r: 50, g: 50, b: 50, a: 128)   // premultiplied half alpha; pixel 3 stays transparent
        let image = PlazaImage(bitmap: bitmap)
        XCTAssertTrue(PlazaHotSpring.flushLerped(image, step: 0) === image, "step 0 is the plain frame itself")
        let out = PlazaHotSpring.flushLerped(image, step: 6).pixels.bytes
        // white -> (241,176,167); blue -> (101,36,167): a lerp, so blue moves toward red instead of going dark
        for (got, want) in zip(out[0..<3], [241.0, 176, 167]) { XCTAssertEqual(Double(got), want, accuracy: 1) }
        for (got, want) in zip(out[4..<7], [101.0, 36, 167]) { XCTAssertEqual(Double(got), want, accuracy: 1) }
        XCTAssertEqual(out[3], 255)
        XCTAssertEqual(Array(out[12..<16]), [0, 0, 0, 0], "transparent stays transparent")
        // premultiplied half alpha: rgb' = rgb * (1 - a) + red * alpha * a
        XCTAssertEqual(Double(out[8]), 50 * 0.55 + 224 * (128.0 / 255) * 0.45, accuracy: 1)
        XCTAssertEqual(out[11], 128, "alpha is kept")
    }

    // MARK: - The soak clock and the flush fade

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testFlushedAtExactlyThreeMinutes() {
        var soak = PlazaSoak()
        XCTAssertTrue(soak.update(inSpring: true, now: t0))
        XCTAssertFalse(soak.isFlushed(now: t0 + 179.9))
        XCTAssertTrue(soak.isFlushed(now: t0 + 180))
        XCTAssertEqual(soak.deadline, t0 + 180)
        XCTAssertNil(PlazaSoak().deadline)
        XCTAssertFalse(PlazaSoak().isFlushed(now: t0 + 9_999))
    }

    func testLeavingAt179RestartsTheCount() {
        var soak = PlazaSoak()
        _ = soak.update(inSpring: true, now: t0)
        XCTAssertTrue(soak.update(inSpring: false, now: t0 + 179))
        XCTAssertNil(soak.since)
        XCTAssertFalse(soak.update(inSpring: false, now: t0 + 179.5), "staying out changes nothing")
        XCTAssertTrue(soak.update(inSpring: true, now: t0 + 180))
        XCTAssertFalse(soak.isFlushed(now: t0 + 359.9))
        XCTAssertTrue(soak.isFlushed(now: t0 + 360))
    }

    func testStayingInDoesNotRestart() {
        var soak = PlazaSoak()
        _ = soak.update(inSpring: true, now: t0)
        XCTAssertFalse(soak.update(inSpring: true, now: t0 + 10))
        XCTAssertEqual(soak.since, t0)
    }

    func testAClockThatWentBackRestartsTheSoak() {
        var soak = PlazaSoak()
        _ = soak.update(inSpring: true, now: t0)
        XCTAssertTrue(soak.update(inSpring: true, now: t0 - 3600))
        XCTAssertEqual(soak.since, t0 - 3600)
        XCTAssertFalse(soak.isFlushed(now: t0 - 3600 + 179))
    }

    func testTheRedRisesInTwoSecondsAndFadesOverAMinute() {
        var fade = PlazaFlushFade(on: false, now: t0)
        fade.set(true, now: t0)
        XCTAssertEqual(fade.level(at: t0), 0, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 2), 1, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 50), 1, accuracy: 1e-9, "never above 1")
        XCTAssertEqual(fade.blend(at: t0 + 2), 0.45, accuracy: 1e-9)
        fade.set(false, now: t0 + 2)
        XCTAssertEqual(fade.level(at: t0 + 2), 1, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 32), 0.5, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 62), 0, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: t0 + 600), 0, accuracy: 1e-9, "never below 0")
    }

    func testALateJoinerSeesTheRedAtOnce() {
        XCTAssertEqual(PlazaFlushFade(on: true, now: t0).level(at: t0), 1, accuracy: 1e-9)
        XCTAssertEqual(PlazaFlushFade(on: false, now: t0).level(at: t0), 0, accuracy: 1e-9)
    }

    func testTurningBackMidFadeStartsFromTheCurrentLevel() {
        let T = t0
        var fade = PlazaFlushFade(on: true, now: T - 100)
        fade.set(false, now: T)
        fade.set(true, now: T + 30)
        XCTAssertEqual(fade.level(at: T + 30), 0.5, accuracy: 1e-9)
        XCTAssertEqual(fade.level(at: T + 31), 1, accuracy: 1e-9)
        var same = fade
        same.set(true, now: T + 40)
        XCTAssertEqual(same, fade, "no change, no restart")
    }

    func testAClockThatWentBackHoldsTheLevel() {
        let T = t0
        var fade = PlazaFlushFade(on: true, now: T - 100)
        fade.set(false, now: T)
        XCTAssertEqual(fade.level(at: T - 100), 1, accuracy: 1e-9)
    }
}
