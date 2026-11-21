import XCTest
@testable import PokeTokenBar

/// The hot spring's steam: the node-free field, then the pooled layer inside the real scene.
@MainActor
final class PlazaSteamLayerTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private var springTiles: [TilePoint] { PlazaHotSpring.tiles(in: map) }

    // MARK: The field

    func testAWispRisesAndThinsOverItsLife() async {
        XCTAssertEqual(PlazaSteamField.frame(age: 0), 0)
        XCTAssertEqual(PlazaSteamField.frame(age: 0.49), 0)
        XCTAssertEqual(PlazaSteamField.frame(age: 0.5), 1)
        XCTAssertEqual(PlazaSteamField.frame(age: 2.99), 5)
        XCTAssertEqual(PlazaSteamField.frame(age: 4), 5)
        XCTAssertEqual(PlazaSteamField.alpha(age: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.alpha(age: PlazaSteam.peakAt), PlazaSteam.peakAlpha, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.alpha(age: (PlazaSteam.peakAt + PlazaSteam.life) / 2), 0.3, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.alpha(age: PlazaSteam.life), 0, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.lift(age: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.lift(age: 1.5), 12, accuracy: 1e-12)
        XCTAssertEqual(PlazaSteamField.lift(age: 3), 24, accuracy: 1e-12)
    }

    func testTheFieldIsPrewarmedAndKeepsAboutSix() async {
        var field = PlazaSteamField(tiles: springTiles)
        XCTAssertTrue((5...7).contains(field.wisps.count), "\(field.wisps.count)")
        var sum = 0, peak = 0
        for _ in 0..<600 {
            field.advance(by: 1.0 / 60)
            sum += field.wisps.count
            peak = max(peak, field.wisps.count)
        }
        let mean = Double(sum) / 600
        XCTAssertTrue((5.5...6.5).contains(mean), "\(mean)")
        XCTAssertLessThanOrEqual(peak, PlazaSteam.maxWisps)
    }

    func testWispsSpawnOnlyOverSpringTiles() async {
        var field = PlazaSteamField(tiles: springTiles)
        var seen = Set<[Double]>()
        func note() { for w in field.wisps where w.age < 0.1 { seen.insert([Double(w.x), Double(w.y)]) } }
        note()
        for _ in 0..<600 { field.advance(by: 1.0 / 60); note() }
        XCTAssertGreaterThan(seen.count, 5)
        for s in seen {
            XCTAssertTrue(s[0] >= 1024 && s[0] < 1248 && s[1] >= 448 && s[1] < 672, "\(s)")
        }
    }

    func testTheSameSeedGivesTheSameSteam() async {
        var a = PlazaSteamField(tiles: springTiles), b = PlazaSteamField(tiles: springTiles)
        XCTAssertEqual(a.wisps, b.wisps)
        for _ in 0..<100 { a.advance(by: 0.04); b.advance(by: 0.04) }
        XCTAssertEqual(a.wisps, b.wisps)
        let other = PlazaSteamField(tiles: springTiles, seed: 7)
        XCTAssertNotEqual(other.wisps, PlazaSteamField(tiles: springTiles).wisps)
    }

    // MARK: The layer in the scene (the real map, the bundled frames)

    private func scene(start: TilePoint, zoom: Int = 2) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: zoom, nickname: "me", pondVisuals: true)
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        return s
    }

    private func run(_ s: PlazaScene, frames: Int, from start: Int = 0) {
        for i in 0..<frames { s.update(Double(start + i) / 60) }
    }

    func testThePoolIsMadeOnceAndNeverGrows() async throws {
        let s = scene(start: p(35, 17))
        let layer = try XCTUnwrap(s.steamLayer)
        XCTAssertEqual(s.steamNodeCount, 9, "a root and eight sprites")
        s.update(0)   // the scene makes its own lazy nodes (name plates, ...) on the first frame; the steam makes none
        let rootChildren = s.root.children.count
        var shownMost = 0
        for i in 1..<1000 {
            s.update(Double(i) / 60)
            shownMost = max(shownMost, layer.shownSpriteCount)
            XCTAssertLessThanOrEqual(layer.shownSpriteCount, PlazaSteam.maxWisps)
        }
        XCTAssertGreaterThan(shownMost, 0, "steam was drawn")
        XCTAssertEqual(s.steamNodeCount, 9)
        XCTAssertEqual(s.root.children.count, rootChildren)
    }

    func testAPausedSceneMovesNoWispAndMakesNoNode() async throws {
        let s = scene(start: p(35, 17))
        run(s, frames: 30)
        XCTAssertTrue(s.isSteamShown)
        let wisps = s.steamWisps, nodes = s.steamNodeCount, rootChildren = s.root.children.count
        s.isPaused = true
        // a paused stage delivers no frames; the entry points that still run must neither advance nor create
        s.setBackgroundHidden(true)
        s.setBackgroundHidden(false)
        s.size = CGSize(width: 900, height: 700)
        s.zoom = 3
        s.zoom = 2
        XCTAssertEqual(s.steamWisps, wisps)
        XCTAssertEqual(s.steamNodeCount, nodes)
        XCTAssertEqual(s.root.children.count, rootChildren)
    }

    func testAnOffscreenSpringIsNeitherAdvancedNorTouched() async throws {
        let s = scene(start: p(19, 10))
        s.update(0)
        XCTAssertFalse(s.isSteamShown, "the spring is not in view")
        let states = s.steamSpriteStates, wisps = s.steamWisps
        run(s, frames: 600, from: 1)
        XCTAssertFalse(s.isSteamShown)
        XCTAssertEqual(s.steamSpriteStates, states, "no sprite property was written")
        XCTAssertEqual(s.steamWisps, wisps, "the field did not advance")
        // zooming out brings the spring into view (one tile of margin counts)
        s.zoom = 1
        run(s, frames: 30, from: 700)
        XCTAssertTrue(s.isSteamShown)
        XCTAssertNotEqual(s.steamWisps, wisps, "the field advances again once the spring is in view")
    }

    func testALayerWithoutFramesNeverShowsOrWritesAnything() async {
        let layer = PlazaSteamLayer(springTiles: springTiles, worldHeight: map.pixelSize.height, frames: [])
        let states = layer.spriteStates
        layer.update(dt: 1.0 / 60, visible: CGRect(x: 0, y: 0, width: 2000, height: 1200), isHidden: false, step: 0.5)
        XCTAssertFalse(layer.isShown)
        XCTAssertEqual(layer.spriteStates, states)
        XCTAssertEqual(layer.photoParticles(worldHeight: 1024).count, 0)
    }

    func testTheMarginIsOneTile() async throws {
        let frames = try XCTUnwrap(PlazaScene.steamFrames.isEmpty ? nil : PlazaScene.steamFrames)
        let layer = PlazaSteamLayer(springTiles: springTiles, worldHeight: map.pixelSize.height, frames: frames)
        // the spring spans y 448..<672. Its margin box starts at y 416, and a wisp rises 24 px over its life (`PlazaSteam.rise`), so a
        // wisp's tip can reach y 392: the box starts there. A view that only touches it shows nothing; one pixel more shows the layer.
        layer.update(dt: 1.0 / 60, visible: CGRect(x: 1000, y: 0, width: 300, height: 392), isHidden: false, step: 0.5)
        XCTAssertTrue(layer.root.isHidden)
        layer.update(dt: 1.0 / 60, visible: CGRect(x: 1000, y: 0, width: 300, height: 393), isHidden: false, step: 0.5)
        XCTAssertFalse(layer.root.isHidden)
    }

    func testHidingTheBackgroundHidesTheSteam() async throws {
        let s = scene(start: p(35, 17))
        run(s, frames: 30)
        XCTAssertTrue(s.isSteamShown)
        s.setBackgroundHidden(true)
        XCTAssertFalse(s.isSteamShown, "gone at once")
        XCTAssertEqual(s.photoInput()?.weather.count, 0)
        s.setBackgroundHidden(false)
        run(s, frames: 2, from: 40)
        XCTAssertTrue(s.isSteamShown)
    }

    func testSteamSitsAboveCharactersAndBelowTheDaylightMultiply() async throws {
        let s = scene(start: p(35, 17))
        let steam = try XCTUnwrap(s.steamLayer).root.zPosition
        XCTAssertEqual(steam, PlazaSteam.z, accuracy: 1e-6)   // the node keeps a Float
        XCTAssertGreaterThan(steam, 2.5, "characters are 1...2, droplets 2.5")
        XCTAssertLessThan(steam, s.weatherLayer.root.zPosition)
        XCTAssertLessThan(steam, 5, "the daylight multiply")
    }

    func testThePhotoCarriesTheWispsAtTheirAlpha() async throws {
        let s = scene(start: p(35, 17))
        run(s, frames: 60)
        let layer = try XCTUnwrap(s.steamLayer)
        let shown = layer.shownSpriteAlphas
        XCTAssertFalse(shown.isEmpty)
        let photo = try XCTUnwrap(s.photoInput()).weather.map(\.alpha)
        for a in shown { XCTAssertTrue(photo.contains { abs($0 - a) < 1e-9 }, "alpha \(a)") }
        XCTAssertGreaterThanOrEqual(photo.count, shown.count)
    }
}
