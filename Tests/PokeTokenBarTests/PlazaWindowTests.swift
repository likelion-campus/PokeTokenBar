import XCTest
import AppKit
@testable import PokeTokenBar

private final class SeenIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return ids }
}

private struct RecordingFetcher: PlazaSpriteFetching {
    let seen = SeenIDs()
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        seen.add(speciesID); return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor final class PlazaWindowTests: XCTestCase {
    private var suites: [String] = []

    private func defaults() -> UserDefaults {
        let name = "plaza.test.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    /// 갈 수 있는 이웃 칸 방향 하나(키코드, dx, dy).
    private func walkableKey(from start: TilePoint) -> (UInt16, Int, Int)? {
        let map = PlazaMapData.map
        let options: [(UInt16, Int, Int)] = [(124, 1, 0), (123, -1, 0), (125, 0, 1), (126, 0, -1)]
        return options.first { map.isWalkable(.init(x: start.x + $0.1, y: start.y + $0.2)) }
    }

    private func controller(_ d: UserDefaults,
                            fetcher: PlazaSpriteFetching = RecordingFetcher(),
                            nickname: @escaping () -> String = { "tester" },
                            subject: @escaping () -> CompanionStore.RepresentativeSubject = { .init(speciesID: 25, isShiny: false) },
                            myEntry: @escaping () -> PlazaRosterEntry? = { nil }
    ) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: d),
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: nickname, subject: subject, myRosterEntry: myEntry)
    }

    /// 장면 update를 시각을 늘려 가며 부른다.
    private func run(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testInvalidSavedTileFallsBackToSpawn() {
        let p = PlazaPreferences(defaults: defaults()), map = PlazaMapData.map
        XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        p.saveLastTile(.init(x: 0, y: 0)); XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        p.saveLastTile(.init(x: 999, y: 3)); XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        let ok = map.shelterTiles.last!; p.saveLastTile(ok); XCTAssertEqual(p.lastTile(validIn: map), ok)
    }

    func testZoomIsClampedAndPersisted() {
        let d = defaults(); let p = PlazaPreferences(defaults: d)
        XCTAssertEqual(p.zoom, 2); p.zoom = 7
        XCTAssertEqual(PlazaPreferences(defaults: d).zoom, 3)
    }

    func testClosingReleasesSceneAndSavesTile() {
        let d = defaults(); let map = PlazaMapData.map
        let c = controller(d)
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        let start = scene.walker.tile
        // 위·아래·좌·우 중 갈 수 있는 방향 하나를 찾는다.
        let options: [(UInt16, Int, Int)] = [(124, 1, 0), (123, -1, 0), (125, 0, 1), (126, 0, -1)]
        guard let (key, dx, dy) = options.first(where: { map.isWalkable(.init(x: start.x + $0.1, y: start.y + $0.2)) }) else {
            return XCTFail("no walkable neighbour")
        }
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        run(scene, seconds: 1)
        let expected = TilePoint(x: start.x + dx, y: start.y + dy)
        XCTAssertEqual(scene.walker.tile, expected)
        c.handleClose()
        XCTAssertNil(c.scene)
        XCTAssertEqual(PlazaPreferences(defaults: d).lastTile(validIn: map), expected)
    }

    func testResignKeyReleasesHeldKeys() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        c.handleResignKey()
        run(scene, seconds: 1)
        XCTAssertFalse(scene.walker.isWalking)
        XCTAssertLessThanOrEqual(abs(scene.walker.tile.x - start.x) + abs(scene.walker.tile.y - start.y), 1)
    }

    func testRefreshCharacterLoadsCurrentSubject() async {
        let fetcher = RecordingFetcher()
        var current = CompanionStore.RepresentativeSubject(speciesID: 25, isShiny: false)
        let c = controller(defaults(), fetcher: fetcher, subject: { current })
        c.prepareScene()
        await c.refreshCharacter()
        current = .init(speciesID: 150, isShiny: false)
        await c.refreshCharacter()
        XCTAssertEqual(fetcher.seen.all.last, 150)
        XCTAssertTrue(fetcher.seen.all.contains(25))
    }

    func testRefreshCharacterWithoutSceneDoesNothing() async {
        let fetcher = RecordingFetcher()
        let c = controller(defaults(), fetcher: fetcher)
        await c.refreshCharacter()
        XCTAssertTrue(fetcher.seen.all.isEmpty)
    }

    func testShadowStaysOnGroundWhileBobbing() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene, let (key, _, _) = walkableKey(from: scene.walker.tile) else { return XCTFail("setup") }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = PlazaFrame(image: ctx.makeImage()!, delay: 1)
        scene.setCharacter(PlazaCharacterFrames(front: [frame], back: [frame]))
        XCTAssertEqual(scene.groundShadowSize.width, 64)
        XCTAssertEqual(scene.groundShadowSize.height, 20)
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        var t = 0.0
        scene.update(t)
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for _ in 0..<45 {
            t += 1.0 / 30; scene.update(t)
            minY = min(minY, scene.characterY); maxY = max(maxY, scene.characterY)
            // The shadow never moves with the bob: its bottom edge sits centred on the foot y (bottom edge = height / 2 below the foot).
            let h = CGFloat(scene.groundShadowSize.height)
            let expected = PlazaMapData.map.pixelSize.height - scene.walker.footPoint.y - h / 2
            XCTAssertEqual(scene.groundShadowY, expected, accuracy: 0.51)
        }
        XCTAssertGreaterThan(maxY - minY, 0.5, "the character y must vary across frames while walking")
    }

    func testRefreshNicknameUpdatesScene() {
        var name = "first"
        let c = controller(defaults(), nickname: { name })
        c.prepareScene()
        XCTAssertEqual(c.scene?.nickname, "first")
        name = "second"
        c.refreshNickname()
        XCTAssertEqual(c.scene?.nickname, "second")
    }

    func testArrowRepeatIsIgnored() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: true)
        run(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, start)
        XCTAssertFalse(scene.walker.isWalking)
    }

    func testZoomKeysChangeZoomAndNotify() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        var seen: [Int] = []
        scene.onZoomChange = { seen.append($0) }
        scene.handleKeyDown(keyCode: 27, characters: "-", isRepeat: false)
        XCTAssertEqual(scene.zoom, 1)
        scene.handleKeyDown(keyCode: 27, characters: "-", isRepeat: false)   // 이미 최소
        scene.handleKeyDown(keyCode: 24, characters: "=", isRepeat: false)
        scene.handleKeyDown(keyCode: 24, characters: "+", isRepeat: false)
        scene.handleKeyDown(keyCode: 24, characters: "+", isRepeat: false)   // 이미 최대
        XCTAssertEqual(scene.zoom, 3)
        XCTAssertEqual(seen, [1, 2, 3])
    }

    func testZoomChangeIsPersistedThroughController() {
        let d = defaults()
        let c = controller(d)
        c.prepareScene()
        c.scene?.handleKeyDown(keyCode: 27, characters: "-", isRepeat: false)
        XCTAssertEqual(PlazaPreferences(defaults: d).zoom, 1)
    }

    func testHugeFrameDeltaIsClamped() {
        let map = PlazaMapData.map
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        let start = scene.walker.tile
        let options: [(UInt16, Int, Int)] = [(124, 1, 0), (123, -1, 0), (125, 0, 1), (126, 0, -1)]
        guard let (key, _, _) = options.first(where: { map.isWalkable(.init(x: start.x + $0.1, y: start.y + $0.2)) }) else {
            return XCTFail("no walkable neighbour")
        }
        scene.update(0)
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        scene.update(10_000)   // 잠자기 뒤 같은 큰 간격: 0.1초로 줄어 한 칸(0.2초)을 다 못 간다.
        XCTAssertTrue(scene.walker.isWalking)
    }

    func testUnhandledKeysAreSwallowedWithoutClose() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        var closes = 0
        scene.onCloseRequest = { closes += 1 }
        let zoom = scene.zoom, tile = scene.walker.tile
        XCTAssertEqual(scene.handleKeyDown(keyCode: 49, characters: " ", isRepeat: false), .swallowed)
        XCTAssertEqual(scene.handleKeyDown(keyCode: 18, characters: "1", isRepeat: false), .swallowed)
        XCTAssertEqual(scene.handleKeyDown(keyCode: 13, characters: "w", isRepeat: false), .swallowed)
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(scene.zoom, zoom)
        XCTAssertEqual(scene.walker.tile, tile)
        XCTAssertFalse(scene.walker.isWalking)
    }

    func testCmdWAndEscapeRequestClose() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        var closes = 0
        scene.onCloseRequest = { closes += 1 }
        XCTAssertEqual(scene.handleKeyDown(keyCode: 13, characters: "w", isRepeat: false, modifiers: .command), .closeRequested)
        XCTAssertEqual(scene.handleKeyDown(keyCode: 53, characters: "\u{1b}", isRepeat: false), .closeRequested)
        XCTAssertEqual(closes, 2)
    }

    func testCommandArrowDoesNotStartWalking() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene, let (key, _, _) = walkableKey(from: scene.walker.tile) else { return XCTFail("setup") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false, modifiers: .command)
        run(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, start)
        XCTAssertFalse(scene.walker.isWalking)
    }

    func testCommandHeldDuringUpdateStopsWalking() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene, let (key, _, _) = walkableKey(from: scene.walker.tile) else { return XCTFail("setup") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.currentModifiers = { .command }
        run(scene, seconds: 2)
        XCTAssertFalse(scene.walker.isWalking)
        XCTAssertLessThanOrEqual(abs(scene.walker.tile.x - start.x) + abs(scene.walker.tile.y - start.y), 1)
    }

    func testPersistStateSavesTileWithoutTearingDown() {
        let d = defaults()
        let c = controller(d)
        c.prepareScene()
        guard let scene = c.scene, let (key, dx, dy) = walkableKey(from: scene.walker.tile) else { return XCTFail("setup") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        run(scene, seconds: 1)
        c.persistState()
        XCTAssertNotNil(c.scene)
        XCTAssertEqual(PlazaPreferences(defaults: d).lastTile(validIn: PlazaMapData.map),
                       TilePoint(x: start.x + dx, y: start.y + dy))
    }

    func testSetRenderingPausesAndResumesScene() {
        let c = controller(defaults())
        c.setRendering(visible: false)   // 장면이 없어도 안전
        c.prepareScene()
        c.setRendering(visible: false)
        XCTAssertEqual(c.scene?.isPaused, true)
        c.setRendering(visible: true)
        XCTAssertEqual(c.scene?.isPaused, false)
    }

    @MainActor private final class FakeRenderLoop: PlazaPausableView { var isPaused = false }

    func testHidingPausesTheViewToo() {
        let c = controller(defaults())
        let loop = FakeRenderLoop()
        c.prepareScene()
        c.renderLoop = loop
        c.setRendering(visible: false)
        XCTAssertTrue(loop.isPaused)
        XCTAssertEqual(c.scene?.isPaused, true)
        c.setRendering(visible: true)
        XCTAssertFalse(loop.isPaused)
        XCTAssertEqual(c.scene?.isPaused, false)
    }

    func testCharacterDrawnAtOnePointFiveScale() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        XCTAssertEqual(PlazaScene.characterScale, 1.5)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = PlazaFrame(image: ctx.makeImage()!, delay: 1)
        scene.setCharacter(PlazaCharacterFrames(front: [frame], back: [frame]))
        XCTAssertEqual(scene.characterSize, CGSize(width: 60, height: 45))
        // Odd sizes keep the exact 1.5x factor (no rounding distortion).
        let odd = CGContext(data: nil, width: 41, height: 31, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let oddFrame = PlazaFrame(image: odd.makeImage()!, delay: 1)
        scene.setCharacter(PlazaCharacterFrames(front: [oddFrame], back: [oddFrame]))
        XCTAssertEqual(scene.characterSize, CGSize(width: 61.5, height: 46.5))
    }

    func testSetRenderingTogglesRosterAnimation() {
        let c = controller(defaults())
        XCTAssertTrue(c.rosterIsAnimating)
        c.prepareScene()
        c.setRendering(visible: false)
        XCTAssertFalse(c.rosterIsAnimating)
        c.setRendering(visible: true)
        XCTAssertTrue(c.rosterIsAnimating)
    }

    func testRosterLifecyclePrepareFillsMeAndCloseClears() {
        let me = PlazaRosterEntry(id: "me", nickname: "나", speciesID: 25, speciesName: "x", gender: nil,
                                  isShiny: false, presence: .online, isMe: true)
        let c = controller(defaults(), myEntry: { me })
        XCTAssertTrue(c.rosterEntries.isEmpty)
        c.prepareScene()
        XCTAssertEqual(c.rosterEntries, [me])
        c.handleClose()
        XCTAssertTrue(c.rosterEntries.isEmpty)
        c.refreshRoster()   // 닫힌 뒤에는 다시 채우지 않는다
        XCTAssertTrue(c.rosterEntries.isEmpty)
    }

    func testEmptyNicknameHidesNamePlate() {
        var name = ""
        let c = controller(defaults(), nickname: { name })
        c.prepareScene()
        XCTAssertEqual(c.scene?.isNamePlateVisible, false)
        name = "tester"
        c.refreshNickname()
        XCTAssertEqual(c.scene?.isNamePlateVisible, true)
        name = ""
        c.refreshNickname()
        XCTAssertEqual(c.scene?.isNamePlateVisible, false)
    }

    func testRosterHostingViewPassesInputThrough() {
        let view = PlazaRosterHostingView(rootView: PlazaRosterView(model: PlazaRosterModel()))
        XCTAssertNil(view.hitTest(NSPoint(x: 5, y: 5)))
        XCTAssertFalse(view.acceptsFirstResponder)
    }
}
