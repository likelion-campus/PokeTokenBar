import XCTest
import AppKit
import SwiftUI
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
    nonisolated(unsafe) private var suites: [String] = []

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
                            myEntry: @escaping () -> PlazaRosterEntry? = { nil },
                            memberID: @escaping () -> String = { "member-1" }
    ) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: d),
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: nickname, memberID: memberID, subject: subject, myRosterEntry: myEntry)
    }

    /// 장면 update를 시각을 늘려 가며 부른다.
    private func run(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testEggCannotWalk() {
        let c = controller(defaults(), subject: { .init(speciesID: nil, isShiny: false) })
        c.prepareScene()
        guard let scene = c.scene, let (key, _, _) = walkableKey(from: scene.walker.tile) else { return XCTFail("no scene") }
        let start = scene.walker.tile
        XCTAssertFalse(scene.canWalk)
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        run(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, start)
        XCTAssertFalse(scene.walker.isWalking)
        XCTAssertEqual(scene.walker.facing, .down)
    }

    func testHatchedCharacterCanWalkAgain() async {
        var current = CompanionStore.RepresentativeSubject(speciesID: nil, isShiny: false)
        let c = controller(defaults(), subject: { current })
        c.prepareScene()
        guard let scene = c.scene, let (key, dx, dy) = walkableKey(from: scene.walker.tile) else { return XCTFail("no scene") }
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)   // tap while an egg
        current = .init(speciesID: 25, isShiny: false)
        await c.refreshCharacter()
        XCTAssertTrue(scene.canWalk)
        run(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, start, "a tap pressed while an egg must not fire after hatching")
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        run(scene, seconds: 1, from: 10)
        XCTAssertEqual(scene.walker.tile, TilePoint(x: start.x + dx, y: start.y + dy))
    }

    func testBecomingAnEggStopsAfterCurrentStep() async {
        var current = CompanionStore.RepresentativeSubject(speciesID: 25, isShiny: false)
        let c = controller(defaults(), subject: { current })
        c.prepareScene()
        guard let scene = c.scene, let (key, _, _) = walkableKey(from: scene.walker.tile) else { return XCTFail("no scene") }
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        var t = 0.0
        scene.update(t); t += 1.0 / 30; scene.update(t)
        XCTAssertTrue(scene.walker.isWalking)
        let target = scene.walker.tile
        current = .init(speciesID: nil, isShiny: false)
        await c.refreshCharacter()
        XCTAssertFalse(scene.canWalk)
        run(scene, seconds: 1, from: t)
        XCTAssertEqual(scene.walker.tile, target)
        XCTAssertFalse(scene.walker.isWalking)
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

    func testRosterCapacityUsesTheRestoredWindowHeight() {
        let name = "PlazaWindowTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let rect = { (height: CGFloat) in NSRect(x: 100, y: 100, width: 960, height: height) }
        NSWindow(contentRect: rect(320), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            .saveFrame(usingName: name)
        let w = NSWindow(contentRect: rect(640), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let model = PlazaRosterModel()
        PlazaWindowController.restoreFrame(w, into: model, autosaveName: name)
        XCTAssertEqual(w.contentView?.bounds.height, 320, "the fixture must restore the saved size")
        XCTAssertEqual(model.capacity, PlazaRoster.capacity(forHeight: 320))
        XCTAssertNotEqual(model.capacity, PlazaRoster.capacity(forHeight: 640), "the fixture must tell the sizes apart")
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
        XCTAssertEqual(scene.groundShadowSize.width, 54)
        XCTAssertEqual(scene.groundShadowSize.height, 17)
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        var t = 0.0
        scene.update(t)
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for _ in 0..<45 {
            t += 1.0 / 30; scene.update(t)
            minY = min(minY, scene.characterY); maxY = max(maxY, scene.characterY)
            // The shadow never moves with the bob: its bottom edge sits centred round(h * 0.12) above the foot y.
            let h = CGFloat(scene.groundShadowSize.height)
            let expected = PlazaMapData.map.pixelSize.height - (scene.walker.footPoint.y - (h * 0.12).rounded()) - h / 2
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

    private func blankFrames(width: Int, height: Int) -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = PlazaFrame(image: ctx.makeImage()!, delay: 1)
        return PlazaCharacterFrames(front: [frame], back: [frame])
    }

    private func assertWhole(_ v: CGFloat, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        // SpriteKit stores positions as Float, so thirds of a pixel come back slightly off. A real defect is off by 0.5.
        XCTAssertEqual(v, v.rounded(), accuracy: 0.01, "\(label) = \(v) is not on the device grid", file: file, line: line)
    }

    /// 1x display, odd window, odd sprite and plate widths: every edge must land on a device pixel.
    func testLayoutPutsEdgesOnDeviceGridOnOneXDisplay() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        scene.backingOverride = 1
        scene.size = CGSize(width: 961, height: 641)
        scene.zoom = 2
        scene.setCharacter(blankFrames(width: 41, height: 31))
        let halfW = scene.size.width / 2, halfH = scene.size.height / 2
        let width = scene.characterSize.width
        for name in ["a", "ab", "abc", "abcd", "abcde"] {
            scene.setNickname(name)
            assertWhole((scene.characterX - width / 2) * 2, "sprite left edge")
            assertWhole((scene.cameraPosition.x - halfW / 2) * 2, "camera left edge")
            assertWhole((scene.cameraPosition.y - halfH / 2) * 2, "camera bottom edge")
            let plate = scene.namePlatePosition
            assertWhole(plate.x - scene.namePlateWidth / 2 + halfW, "plate left edge")
            assertWhole(plate.y + halfH, "plate bottom edge")
        }
    }

    /// Retina zoom 3 also gives an odd device width (61.5 x 6 = 369).
    func testLayoutSnapsOddSpriteAtRetinaZoomThree() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        scene.backingOverride = 2
        scene.zoom = 3
        scene.setCharacter(blankFrames(width: 41, height: 31))
        assertWhole((scene.characterX - scene.characterSize.width / 2) * 6, "sprite left edge")
    }

    /// The camera looks above the feet by half the front sprite, so a big Pokémon keeps its head on screen.
    /// The camera used to centre the character in the part beside the roster, so it sat left of centre.
    func testWideViewCentersMyCharacter() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        scene.size = CGSize(width: 1200, height: 640)
        scene.setCharacter(blankFrames(width: 40, height: 40))
        let walker = scene.walker.footPoint
        scene.size = CGSize(width: 1200, height: 640)
        let screenX = (walker.x - scene.cameraPosition.x) * CGFloat(scene.zoom) + scene.size.width / 2
        XCTAssertEqual(screenX, 600, accuracy: 1)
    }

    func testWindowTitleCarriesTheTeamName() {
        var name: String? = "개발팀"
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                      loader: PlazaCharacterLoader(fetcher: RecordingFetcher()),
                                      nickname: { "tester" }, memberID: { "member-1" },
                                      subject: { .init(speciesID: 25, isShiny: false) }, teamName: { name })
        XCTAssertEqual(c.title, "팀 광장 · 개발팀")
        name = "디자인팀"
        XCTAssertEqual(c.title, "팀 광장 · 디자인팀", "a rename or a team switch shows on the next refresh")
        name = nil
        XCTAssertEqual(c.title, "팀 광장")
    }

    /// With the background hidden the minimap is a dim, see-through panel; the dots stay as they are.
    func testMinimapDimsWhenTheBackgroundIsHidden() throws {
        let map = NSImage(size: NSSize(width: 48, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.43, green: 0.73, blue: 0.33, alpha: 1).setFill(); rect.fill(); return true
        }
        func meanAlpha(hidden: Bool) throws -> Double {
            let background = PlazaBackgroundModel()
            background.isHidden = hidden
            let view = PlazaMinimapView(model: PlazaMinimapModel(), background: background, mapImage: map,
                                        worldSize: PlazaMapData.map.pixelSize)
            let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Double(stride(from: 3, to: px.count, by: 4).reduce(0) { $0 + Int(px[$1]) }) / Double(px.count / 4) / 255
        }
        let shown = try meanAlpha(hidden: false), dimmed = try meanAlpha(hidden: true)
        XCTAssertGreaterThan(shown, 0.9, "opaque while the map is shown")
        XCTAssertLessThan(dimmed, 0.7, "see-through while the background is hidden")
    }

    func testBackgroundToggleHidesTheMapAndIsRemembered() {
        let d = defaults()
        let c = controller(d)
        c.prepareScene()
        XCTAssertFalse(c.scene!.isBackgroundHidden)
        c.toggleBackground()
        XCTAssertTrue(c.scene!.isBackgroundHidden)
        XCTAssertTrue(c.isBackgroundHidden)
        XCTAssertEqual(c.scene!.backgroundColor.alphaComponent, 0)
        let reopened = controller(d)
        reopened.prepareScene()
        XCTAssertTrue(reopened.scene!.isBackgroundHidden, "the choice is kept")
        reopened.toggleBackground()
        XCTAssertFalse(reopened.scene!.isBackgroundHidden)
        XCTAssertEqual(reopened.scene!.backgroundColor.alphaComponent, 1)
    }

    func testCameraLooksAboveFeetForBigSprite() {
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("scene missing") }
        let before = scene.cameraPosition.y
        scene.setCharacter(blankFrames(width: 96, height: 96))
        XCTAssertEqual(scene.cameraPosition.y - before, 72, accuracy: 0.5)   // 96 x 1.5 / 2
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

    /// The roster takes clicks so a teammate can be chosen, but never the keyboard.
    func testRosterTakesClicksButNotKeys() {
        let model = PlazaRosterModel()
        model.entries = [PlazaRosterEntry(id: "m", nickname: "민수", speciesID: 25, speciesName: "피카츄", gender: nil,
                                          isShiny: false, presence: .online, isMe: false)]
        let view = PlazaRosterHostingView(rootView: PlazaRosterView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: PlazaRosterMetrics.width, height: 120)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.hitTest(NSPoint(x: 100, y: 60)))
        XCTAssertFalse(view.acceptsFirstResponder)
    }
}
