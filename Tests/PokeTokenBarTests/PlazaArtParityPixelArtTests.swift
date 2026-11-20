import CoreGraphics
import XCTest
@testable import PokeTokenBar

/// Legacy oracles (D5) for the pixel-only art and the character frames of Track A Task 4: the converted builders give
/// the Mac the very bytes the old builders gave it, over the real bundled sheets and every season, snow and cell kind.
@MainActor
final class PlazaArtParityPixelArtTests: XCTestCase {
    private let seasons: [PlazaSeason] = [.summer, .spring, .autumn, .winter]

    private func cg(_ image: CGImage?, _ what: String = "bundled sheet") throws -> CGImage { try XCTUnwrap(image, what) }

    /// Like `PlazaArtParity.assertIdentical`, for a legacy image that `CGContext.makeImage()` made: its rows may be padded
    /// (`bytesPerRow: 0`; the new bitmap is packed) and its `shouldInterpolate` is true (the bitmap-built image says false).
    /// SpriteKit textures here use nearest filtering and ignore both; the render compare is the end-to-end check.
    /// Everything else in the format must match and every visible pixel must be equal.
    private func assertSamePixels(_ legacy: CGImage, _ new: PlazaImage, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let n = new.cgImage
        func format(_ i: CGImage) -> String {
            PlazaArtParity.describe(i).replacingOccurrences(of: " bpr \(i.bytesPerRow)", with: "")
                .replacingOccurrences(of: " interpolate \(i.shouldInterpolate)", with: "")
        }
        XCTAssertEqual(format(legacy), format(n), "\(label): image format differs", file: file, line: line)
        XCTAssertEqual(n.bytesPerRow, n.width * 4, "\(label): packed rows", file: file, line: line)
        guard let a = legacy.dataProvider?.data as Data?, let b = n.dataProvider?.data as Data? else {
            return XCTFail("\(label): no bytes", file: file, line: line)
        }
        let la = Array(a), lb = Array(b)
        var differing = 0
        var first: String?
        for y in 0..<legacy.height {
            for x in 0..<(legacy.width * 4) {
                let p = la[y * legacy.bytesPerRow + x], q = lb[y * n.bytesPerRow + x]
                if p != q {
                    differing += 1
                    if first == nil { first = "pixel (\(x / 4), \(y)) channel \(x % 4): legacy \(p), new \(q)" }
                }
            }
        }
        XCTAssertEqual(differing, 0, "\(label): \(first ?? "")", file: file, line: line)
        // Padding bytes are not part of the image; the render compare shows SpriteKit does not see them.
    }

    // MARK: Tile map

    func testTileMapIsByteIdentical() throws {
        let sheetCG = try cg(PlazaResources.tileSheet()), sheet = PlazaImage(cgImage: sheetCG)
        let grassCG = try cg(PlazaResources.tallGrassSheet())
        let legacyGrass = try XCTUnwrap(LegacyPlazaTallGrassArt(sheet: grassCG))
        let newGrass = try XCTUnwrap(PlazaTallGrassArt(sheet: PlazaImage(cgImage: grassCG)))
        let map = PlazaMapData.map
        PlazaArtParity.assertIdentical(LegacyPlazaTileArt.mapImage(map, sheet: sheetCG),
                                       PlazaTileArt.mapImage(map, sheet: sheet), "map without tall grass")
        PlazaArtParity.assertIdentical(LegacyPlazaTileArt.mapImage(map, sheet: sheetCG, tallGrass: legacyGrass),
                                       PlazaTileArt.mapImage(map, sheet: sheet, tallGrass: newGrass), "map with tall grass")
        PlazaArtParity.assertIdentical(LegacyPlazaTileArt.plainGrassImage(map), PlazaTileArt.plainGrassImage(map), "plain grass")
        let small = try PlazaMap(rows: ["TTg...", "TT.NN.", "wwwNN.", "..S..f"])
        PlazaArtParity.assertIdentical(LegacyPlazaTileArt.mapImage(small, sheet: sheetCG, tallGrass: legacyGrass),
                                       PlazaTileArt.mapImage(small, sheet: sheet, tallGrass: newGrass), "small map")
        PlazaArtParity.assertIdentical(LegacyPlazaTileArt.plainGrassImage(small), PlazaTileArt.plainGrassImage(small), "small plain grass")
    }

    // MARK: Season sheets

    func testSeasonSheetsAreByteIdentical() throws {
        let tilesCG = try cg(PlazaResources.tileSheet()), tiles = PlazaImage(cgImage: tilesCG)
        let grassCG = try cg(PlazaResources.tallGrassSheet()), grass = PlazaImage(cgImage: grassCG)
        let map = PlazaMapData.map
        for season in seasons {
            let legacyTiles = LegacyPlazaSeasonSheet.tiles(tilesCG, season: season)
            let newTiles = PlazaSeasonSheet.tiles(tiles, season: season)
            PlazaArtParity.assertIdentical(legacyTiles, newTiles, "tiles \(season)")
            let legacyGrass = LegacyPlazaSeasonSheet.tallGrass(grassCG, season: season)
            let newGrass = PlazaSeasonSheet.tallGrass(grass, season: season)
            PlazaArtParity.assertIdentical(legacyGrass, newGrass, "tall grass \(season)")
            if season == .summer || season == .spring {
                if season == .summer { XCTAssertTrue(newTiles === tiles, "summer tiles are the original") }
                XCTAssertTrue(newGrass === grass, "\(season) tall grass is the original")
            }
            // The map and the tall-grass art built from the recoloured sheets (what the controller's season looks do).
            let legacyArt = try XCTUnwrap(LegacyPlazaTallGrassArt(sheet: legacyGrass))
            let newArt = try XCTUnwrap(PlazaTallGrassArt(sheet: newGrass))
            PlazaArtParity.assertIdentical(LegacyPlazaTileArt.mapImage(map, sheet: legacyTiles, tallGrass: legacyArt),
                                           PlazaTileArt.mapImage(map, sheet: newTiles, tallGrass: newArt), "map \(season)")
            assertGrassArt(legacyArt, newArt, "\(season)")
        }
        // Snow, directly (the tallGrass/tiles of PlazaSnowSheet) and through `recolored` with a custom piece list.
        PlazaArtParity.assertIdentical(LegacyPlazaSnowSheet.tiles(tilesCG), PlazaSnowSheet.tiles(tiles), "snow tiles")
        PlazaArtParity.assertIdentical(LegacyPlazaSnowSheet.tallGrass(grassCG), PlazaSnowSheet.tallGrass(grass), "snow tall grass")
        let pieces: [PlazaSnowSheet.Piece] = [(PlazaSnowSheet.groundColors, [(0, 9), (1, 9)]), (PlazaSnowSheet.signColors, [(34, 2)])]
        PlazaArtParity.assertIdentical(LegacyPlazaSnowSheet.recolored(tilesCG, pieces: pieces),
                                       PlazaSnowSheet.recolored(tiles, pieces: pieces), "recoloured pieces")
    }

    private func assertGrassArt(_ legacy: LegacyPlazaTallGrassArt, _ new: PlazaTallGrassArt, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for c in 0...2 {
            for r in 0...2 {
                let s = PlazaTallGrassSlice(col: c, row: r)
                PlazaArtParity.assertIdentical(legacy.tile(s), new.tile(s), "\(label) tile \(c),\(r)", file: file, line: line)
                PlazaArtParity.assertIdentical(legacy.front(s), new.front(s), "\(label) front \(c),\(r)", file: file, line: line)
                PlazaArtParity.assertIdentical(legacy.top(s), new.top(s), "\(label) top \(c),\(r)", file: file, line: line)
            }
        }
        XCTAssertEqual(legacy.leaves.count, new.leaves.count, file: file, line: line)
        for (i, leaf) in legacy.leaves.enumerated() {
            PlazaArtParity.assertIdentical(leaf, new.leaves[i], "\(label) leaf \(i)", file: file, line: line)
        }
    }

    func testTallGrassArtIsByteIdentical() throws {
        let grassCG = try cg(PlazaResources.tallGrassSheet())
        let legacy = try XCTUnwrap(LegacyPlazaTallGrassArt(sheet: grassCG))
        let new = try XCTUnwrap(PlazaTallGrassArt(sheet: PlazaImage(cgImage: grassCG)))
        assertGrassArt(legacy, new, "bundled")
        XCTAssertNil(LegacyPlazaTallGrassArt(sheet: LegacyPlazaCharacterArt.placeholder()))
        XCTAssertNil(PlazaTallGrassArt(sheet: PlazaImage(cgImage: LegacyPlazaCharacterArt.placeholder())))
    }

    // MARK: Nest, weather, ice, campfire, fireworks, light

    func testNestWeatherIceCampfireFireworkLightArtAreByteIdentical() throws {
        // Nest: the whole nest and the front rim.
        PlazaArtParity.assertIdentical(LegacyPlazaNestArt.image(), PlazaNestArt.image(), "nest")
        PlazaArtParity.assertIdentical(LegacyPlazaNestArt.frontImage(), PlazaNestArt.frontImage(), "nest front")

        // Weather: every kind (rows of 3, 2, 1 and 5 cells wide get padded rows from CGContext).
        for kind in PlazaWeather.Kind.allCases {
            let legacy = LegacyPlazaWeatherArt.images(kind), new = PlazaWeatherArt.images(kind)
            XCTAssertEqual(legacy.count, new.count, "\(kind)")
            for (i, image) in legacy.enumerated() { assertSamePixels(image, new[i], "weather \(kind) \(i)") }
        }
        // The snowball pieces, every season, the balloon in summer.
        let balloon = try cg(PlazaResources.waterBalloon())
        for season in seasons {
            let legacy = LegacyPlazaSnowballArt.pieces(season, balloon: balloon)
            let new = PlazaSnowballArt.pieces(season, balloon: PlazaImage(cgImage: balloon))
            XCTAssertEqual(legacy.map(\.scale), new.map(\.scale), "\(season)")
            for (i, piece) in legacy.enumerated() {
                if season == .summer && i == 0 { XCTAssertTrue(new[i].image.cgImage === balloon, "the balloon itself"); continue }
                assertSamePixels(piece.image, new[i].image, "snowball \(season) piece \(i)")
            }
        }

        // Fireworks: every shape and colour.
        var glyphs: [PlazaFireworkGlyph] = []
        for color in PlazaFireworkColor.allCases {
            for shape in [PlazaFireworkGlyph.Shape.spark, .plus, .dot, .ember(0), .ember(1), .ember(2), .ember(5)] {
                glyphs.append(PlazaFireworkGlyph(shape: shape, color: color))
            }
        }
        for g in glyphs { assertSamePixels(LegacyPlazaFireworkArt.image(g), PlazaFireworkArt.image(g), "firework \(g)") }

        // Campfire light: the campfire's twelve phases and the fireworks' radii, three tints, three colours, two levels.
        let tints = [PlazaDaylight.Tint.none, PlazaDaylight.night, PlazaDaylight.Tint(red: 0.7, green: 0.62, blue: 0.55)]
        var radii = (0..<PlazaCampfire.frameCount).map { PlazaCampfireLight.radii(phase: $0) }
        radii.append(PlazaFireworks.lightRadii)
        let colors = [PlazaCampfireLight.warm] + PlazaFireworkColor.allCases.map(\.light)
        for tint in tints {
            for r in radii {
                for color in colors {
                    for level in [1.0, 0.4] {
                        PlazaArtParity.assertIdentical(LegacyPlazaCharacterArt.lightImage(tint: tint, radii: r, color: color, level: level),
                                                       PlazaCampfireLightArt.image(tint: tint, radii: r, color: color, level: level),
                                                       "light \(tint) \(r) \(level)")
                    }
                }
            }
        }
        PlazaArtParity.assertIdentical(LegacyPlazaCharacterArt.lightImage(tint: .none, radii: PlazaCampfireLight.radii),
                                       PlazaCampfireLightArt.image(tint: .none, radii: PlazaCampfireLight.radii), "light defaults")
    }

    func testCampfireArtIsByteIdentical() {
        // Every state and phase at the app's scale, and the smaller scales the tests use.
        for state in [PlazaCampfireArt.State.ready, .lit, .ended] {
            let old: LegacyPlazaCampfireArt.State = state == .ready ? .ready : state == .lit ? .lit : .ended
            for phase in 0..<PlazaCampfire.frameCount {
                for scale in [8, 1, 2, 3] where scale == 8 || phase % 4 == 0 {
                    assertSamePixels(LegacyPlazaCampfireArt.image(old, phase: phase, scale: scale),
                                     PlazaCampfireArt.image(state, phase: phase, scale: scale),
                                     "campfire \(state) \(phase) @\(scale)")
                }
            }
            let legacy = LegacyPlazaCampfireArt.frames(old), new = PlazaCampfireArt.frames(state)
            XCTAssertEqual(legacy.count, new.count)
            for (i, image) in legacy.enumerated() { assertSamePixels(image, new[i], "frames \(state) \(i)") }
        }
    }

    /// CoreGraphics' fill of a colour with alpha onto a transparent premultiplied buffer is `(c * a + 127) / 255`
    /// for every colour and alpha: the formula the campfire's translucent smoke relies on.
    func testPremultiplyFormulaMatchesCoreGraphicsForEveryColourAndAlpha() {
        var bad = 0
        for a in 0...255 {
            for c in 0...255 {
                let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(srgbRed: CGFloat(c) / 255, green: CGFloat(c) / 255, blue: CGFloat(c) / 255, alpha: CGFloat(a) / 255))
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
                if Int(p[0]) != (c * a + 127) / 255 || Int(p[3]) != a { bad += 1 }
            }
        }
        XCTAssertEqual(bad, 0)
    }

    func testIceArtIsByteIdentical() throws {
        let bundle = PlazaResources.resourceBundle()
        let gloss = try cg(PlazaResources.iceGlossSheet(in: bundle)), cracks = try cg(PlazaResources.iceCrackSheet(in: bundle))
        let frames = PlazaResources.iceShatterFrames(in: bundle)
        XCTAssertGreaterThanOrEqual(frames.count, 4)
        let legacyGloss = LegacyPlazaIceArt.gloss(fromSheet: gloss), newGloss = PlazaIceArt.gloss(fromSheet: PlazaImage(cgImage: gloss))
        PlazaArtParity.assertIdentical(legacyGloss, newGloss, "gloss")
        let legacyCracks = LegacyPlazaIceArt.cracks(fromSheet: cracks), newCracks = PlazaIceArt.cracks(fromSheet: PlazaImage(cgImage: cracks))
        XCTAssertEqual(legacyCracks.count, newCracks.count)
        for (i, c) in legacyCracks.enumerated() { PlazaArtParity.assertIdentical(c, newCracks[i], "crack \(i)") }
        let legacyShards = LegacyPlazaIceArt.shards(fromFrames: frames)
        let newShards = PlazaIceArt.shards(fromFrames: frames.map(PlazaImage.init(cgImage:)))
        XCTAssertEqual(legacyShards.count, newShards.count)
        for (i, s) in legacyShards.enumerated() { PlazaArtParity.assertIdentical(s, newShards[i], "shard \(i)") }
        XCTAssertEqual(PlazaIceArt.shards(fromFrames: Array(frames.prefix(3)).map(PlazaImage.init(cgImage:))).count, 0)
        // load(): the same pieces.
        let loaded = PlazaIceArt.load(), legacyLoaded = LegacyPlazaIceArt.load()
        XCTAssertEqual(loaded.cracks.count, legacyLoaded.cracks.count)
        XCTAssertEqual(loaded.shards.count, legacyLoaded.shards.count)

        // The overlays over the snow map, with the gloss and without it, for every pond of the real map.
        let tilesCG = try cg(PlazaResources.tileSheet()), grassCG = try cg(PlazaResources.tallGrassSheet())
        let legacyMap = LegacyPlazaTileArt.mapImage(PlazaMapData.map, sheet: LegacyPlazaSnowSheet.tiles(tilesCG),
                                                    tallGrass: LegacyPlazaTallGrassArt(sheet: LegacyPlazaSnowSheet.tallGrass(grassCG)))
        let newMap = PlazaImage(cgImage: legacyMap)
        let ponds = PlazaIce.ponds(in: PlazaMapData.map)
        XCTAssertEqual(ponds.count, 3)
        for pond in ponds {
            PlazaArtParity.assertIdentical(LegacyPlazaIceArt.overlay(mapImage: legacyMap, pond: pond, gloss: legacyGloss),
                                           PlazaIceArt.overlay(mapImage: newMap, pond: pond, gloss: newGloss), "overlay \(pond.anchor)")
            PlazaArtParity.assertIdentical(LegacyPlazaIceArt.overlay(mapImage: legacyMap, pond: pond, gloss: nil),
                                           PlazaIceArt.overlay(mapImage: newMap, pond: pond, gloss: nil), "overlay \(pond.anchor) no gloss")
        }
        // The summer map as well (the outside colours differ), and the same through the new builder's own snow map.
        let summerCG = LegacyPlazaTileArt.mapImage(PlazaMapData.map, sheet: tilesCG)
        for pond in ponds {
            PlazaArtParity.assertIdentical(LegacyPlazaIceArt.overlay(mapImage: summerCG, pond: pond, gloss: legacyGloss),
                                           PlazaIceArt.overlay(mapImage: PlazaImage(cgImage: summerCG), pond: pond, gloss: newGloss),
                                           "summer overlay \(pond.anchor)")
        }
    }

    /// The tile map built from a recoloured (bitmap) sheet reads `pixels`; for a bitmap those are its raw bytes. Pin that
    /// they equal a CoreGraphics draw of its `cgImage`, for both alpha layouts (noneSkipLast with the usual 255 padding).
    func testBitmapPixelsEqualACoreGraphicsDrawOfItsCGImage() {
        for layout in [PlazaAlphaLayout.premultipliedLast, .noneSkipLast] {
            let image = PlazaImage(bitmap: PlazaTestImages.patterned(width: 37, height: 23, alpha: layout))
            let drawn = CGImagePayload(image.cgImage).pixels()
            XCTAssertEqual(image.pixels.bytes, drawn.bytes, "\(layout)")
        }
    }

    // MARK: Character frames

    func testPlaceholderIsByteIdentical() async throws {
        let frames = await PlazaCharacterLoader(fetcher: EmptyFetcher()).frames(for: .init(speciesID: 25, isShiny: false))
        XCTAssertTrue(frames.isPlaceholder)
        let image = try XCTUnwrap(frames.front.first?.image)
        PlazaArtParity.assertIdentical(LegacyPlazaCharacterArt.placeholder(), image, "placeholder")
        // The device-gray fill really lands on 158 per channel (sRGB 0.55 would be 140): the canvas fill is the gray one.
        let px = image.pixels
        XCTAssertEqual(px[8, 8], PlazaRGBA(r: 158, g: 158, b: 158, a: 255))
        XCTAssertEqual(px[0, 0], PlazaRGBA(r: 0, g: 0, b: 0, a: 0))
    }

    private struct EmptyFetcher: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
        func egg() async -> PlazaImage? { nil }
    }

    /// Frames as `SpriteLoader` hands them over: native `CGImage`s (the bundled shatter GIF, any cached sprite GIFs, and
    /// synthetic ones with transparent borders). The union crop is the legacy rectangle, the crops are still native
    /// and the very images `CGImage.cropping` makes.
    func testTrimmedFramesKeepTheNativeImages() throws {
        var sets: [(String, [CGImage])] = []
        sets.append(("shatter gif", PlazaResources.iceShatterFrames(in: PlazaResources.resourceBundle())))
        sets.append(("tile sheet", [try cg(PlazaResources.tileSheet())]))
        sets.append(("balloon", [try cg(PlazaResources.waterBalloon())]))
        var synthetic: [CGImage] = []
        for opaque in [[(2, 2)], [(6, 7)], [(4, 4), (9, 1)]] {
            var bitmap = PlazaBitmap(width: 12, height: 10)
            for (x, y) in opaque { bitmap[x, y] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255) }
            synthetic.append(PlazaImage(bitmap: bitmap).cgImage)
        }
        sets.append(("synthetic", synthetic))
        sets.append(("transparent", [PlazaImage(bitmap: PlazaBitmap(width: 6, height: 6)).cgImage]))
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PokeTokenBar/sprites")
        if let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) {
            var taken = 0
            for case let url as URL in files where url.pathExtension == "gif" && taken < 25 {
                guard let data = try? Data(contentsOf: url) else { continue }
                let images = GIFDecoder.frames(from: data).compactMap { $0.image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                if images.isEmpty { continue }
                sets.append((url.lastPathComponent, images))
                taken += 1
            }
        }
        for (name, images) in sets {
            let legacy = LegacyPlazaCharacterArt.trimmed(images)
            let new = PlazaSpriteCrop.trimmed(images.map(PlazaImage.init(cgImage:)))
            XCTAssertEqual(legacy.count, new.count, name)
            for (i, image) in legacy.enumerated() {
                XCTAssertNotNil(new[i].native, "\(name) \(i) stays native")
                XCTAssertNil(new[i].bitmap, "\(name) \(i) stays native")
                PlazaArtParity.assertIdentical(image, new[i], "\(name) frame \(i)")
            }
        }
        // A crop of a native image is the very image CGImage.cropping makes (compared against a second crop).
        let sheet = try cg(PlazaResources.tileSheet())
        let rect = CGRect(x: 16, y: 32, width: 48, height: 32)
        let cropped = try XCTUnwrap(PlazaImage(cgImage: sheet).cropping(to: PlazaPixelRect(x: 16, y: 32, width: 48, height: 32)))
        XCTAssertNotNil(cropped.native)
        PlazaArtParity.assertIdentical(try XCTUnwrap(sheet.cropping(to: rect)), cropped, "crop")
    }
}
