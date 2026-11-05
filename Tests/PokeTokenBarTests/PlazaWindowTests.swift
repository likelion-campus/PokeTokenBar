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

    /// The first arrow key with `count` walkable tiles in a row from `start`.
    private func clearRun(from start: TilePoint, count: Int) -> UInt16? {
        let map = PlazaMapData.map
        let options: [(UInt16, Int, Int)] = [(124, 1, 0), (123, -1, 0), (125, 0, 1), (126, 0, -1)]
        return options.first { o in (1...count).allSatisfy { map.isWalkable(.init(x: start.x + o.1 * $0, y: start.y + o.2 * $0)) } }?.0
    }

    /// Holding Shift while walking runs: twice the tiles in the same time. Without Shift it walks.
    func testShiftHeldDuringUpdateRuns() {
        func walked(_ modifiers: NSEvent.ModifierFlags) -> (tiles: Int, ran: Bool) {
            let c = controller(defaults())
            c.prepareScene()
            guard let scene = c.scene, let key = clearRun(from: scene.walker.tile, count: 6) else { XCTFail("setup"); return (0, false) }
            let start = scene.walker.tile
            scene.currentModifiers = { modifiers }
            scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false, modifiers: modifiers)
            var ran = false, t: TimeInterval = 0
            scene.update(t)
            while t < 0.3 { t += 1.0 / 60; scene.update(t); ran = ran || scene.walker.isRunning }
            return (abs(scene.walker.tile.x - start.x) + abs(scene.walker.tile.y - start.y), ran)
        }
        let walk = walked([]), run = walked(.shift)
        XCTAssertFalse(walk.ran)
        XCTAssertTrue(run.ran)
        XCTAssertGreaterThanOrEqual(run.tiles, walk.tiles * 2 - 1, "running \(run.tiles) vs walking \(walk.tiles)")
        XCTAssertGreaterThan(run.tiles, walk.tiles)
    }

    /// A frame can never cover two tiles, even a slow one while running, so every tile I pass is reported and
    /// teammates never see me jump two tiles. The frame cap stays below the running step for that.
    func testASlowFrameWhileRunningReportsEveryTile() {
        XCTAssertLessThan(PlazaScene.maxFrameDelta, PlazaWalker.runStepDuration)
        let c = controller(defaults())
        c.prepareScene()
        guard let scene = c.scene, let key = clearRun(from: scene.walker.tile, count: 6) else { return XCTFail("setup") }
        var reported = [scene.walker.tile]
        scene.onLocalPositionChange = { tile, _, _ in if tile != reported.last { reported.append(tile) } }
        scene.currentModifiers = { .shift }
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false, modifiers: .shift)
        var t: TimeInterval = 0
        scene.update(t)
        for _ in 0..<5 { t += 0.1; scene.update(t) }   // stalled frames, each longer than a running step
        XCTAssertGreaterThan(reported.count, 3, "it ran")
        for (a, b) in zip(reported, reported.dropFirst()) {
            XCTAssertEqual(abs(a.x - b.x) + abs(a.y - b.y), 1, "\(a) to \(b) skips a tile")
        }
    }

    /// Folding the shortcut guide is remembered the next time the plaza opens.
    func testShortcutGuideFoldIsRemembered() {
        let d = defaults()
        let c = controller(d)
        c.prepareScene()
        XCTAssertFalse(c.areShortcutsFolded, "open the first time")
        c.toggleShortcuts()
        XCTAssertTrue(c.areShortcutsFolded)
        let again = controller(d)
        again.prepareScene()
        XCTAssertTrue(again.areShortcutsFolded)
        again.toggleShortcuts()
        XCTAssertFalse(PlazaPreferences(defaults: d).areShortcutsFolded, "unfolding is remembered too")
    }

    /// Pausing and resuming leave a state line in the log, with the scene's update count, so a frozen plaza can be
    /// told apart: paused while visible, or running but not updating.
    func testPausingAndResumingLeaveStateLines() {
        let c = controller(defaults())
        c.prepareScene()
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        guard let scene = c.scene else { return XCTFail("setup") }
        scene.update(0); scene.update(1.0 / 60)
        c.setRendering(visible: false)
        c.setRendering(visible: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("plaza rendering visible=false:"), lines[0])
        XCTAssertTrue(lines[0].contains("scenePaused=true"), lines[0])
        XCTAssertTrue(lines[0].contains("updates=2"), lines[0])
        XCTAssertTrue(lines[1].contains("scenePaused=false"), lines[1])
    }

    /// If SpriteKit keeps calling update with a frame clock that does not move, nobody moves while the update count
    /// still grows. That leaves a line when it starts and one when the clock moves again, and closing the window (how
    /// people recover) leaves the state at that moment.
    func testAStalledFrameClockAndClosingLeaveStateLines() {
        let c = controller(defaults())
        c.prepareScene()
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        guard let scene = c.scene else { return XCTFail("setup") }
        for _ in 0..<(PlazaScene.stalledFramesForLog * 2) { scene.update(10) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("plaza frame clock stalled:"), lines[0])
        XCTAssertTrue(lines[0].contains("updates=\(PlazaScene.stalledFramesForLog) t=10.00"), lines[0])
        scene.update(10 + 1.0 / 60)
        scene.update(10 + 2.0 / 60)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("plaza frame clock resumed:"), lines[1])
        c.handleClose()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].hasPrefix("plaza closing:"), lines[2])
        XCTAssertTrue(lines[2].contains("updates=\(PlazaScene.stalledFramesForLog * 2 + 2) t=10.03"), lines[2])
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

    /// Remembers every pause and resume, as SpriteKit's own view would receive them.
    @MainActor private final class RecordingRenderLoop: PlazaPausableView {
        var sets: [Bool] = []
        var isPaused = false { didSet { sets.append(isPaused) } }
    }

    /// Each watchdog second waits here until the test lets it go.
    @MainActor private final class CheckGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }
        func sleep() async { await withCheckedContinuation { waiting.append($0) } }
        func tick() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    /// SpriteKit sometimes leaves its frame signal off after the view is resumed: the view says it is not paused, but
    /// update is never called and nobody moves until the window is hidden and shown again. A second with rendering on
    /// and no update pauses and resumes the view to restart it, and says so in the log, then says when it moves again.
    func testAStalledRenderLoopIsWokenAndLogged() {
        let c = controller(defaults())
        c.prepareScene()
        let loop = RecordingRenderLoop()
        c.renderLoop = loop
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        guard let scene = c.scene else { return XCTFail("setup") }
        scene.update(0)
        c.checkRendering()                  // first look
        scene.update(1.0 / 60)
        c.checkRendering()                  // it ran
        XCTAssertEqual(loop.sets, [])
        c.checkRendering()                  // a second without a single update
        XCTAssertEqual(loop.sets, [true, false], "paused and resumed to restart SpriteKit's frames")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("plaza render loop stalled, kick 1:"), lines[0])
        scene.update(2.0 / 60)
        c.checkRendering()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("plaza render loop resumed after 1 kick(s):"), lines[1])
        scene.update(3.0 / 60)
        c.checkRendering()
        XCTAssertEqual(lines.count, 2, "running normally leaves nothing")
        XCTAssertEqual(loop.sets, [true, false])
    }

    /// A plaza we paused ourselves (hidden) is left alone, and the first look after resuming only takes the count.
    func testAPausedPlazaIsNotWoken() {
        let c = controller(defaults())
        c.prepareScene()
        let loop = RecordingRenderLoop()
        c.renderLoop = loop
        c.checkRendering()
        c.setRendering(visible: false)
        c.checkRendering()
        c.checkRendering()
        XCTAssertEqual(loop.sets, [true])
        c.setRendering(visible: true)
        c.checkRendering()
        XCTAssertEqual(loop.sets, [true, false], "no wake-up right after resuming")
    }

    /// A plaza that stays stuck keeps being woken every second, but the log gets only the first three and every 60th.
    func testAStuckPlazaLogsOnlyNowAndThen() {
        let c = controller(defaults())
        c.prepareScene()
        let loop = RecordingRenderLoop()
        c.renderLoop = loop
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        c.checkRendering()
        for _ in 0..<60 { c.checkRendering() }
        XCTAssertEqual(loop.sets.count, 120)
        XCTAssertEqual(lines.map { $0.components(separatedBy: ":")[0] },
                       ["plaza render loop stalled, kick 1", "plaza render loop stalled, kick 2",
                        "plaza render loop stalled, kick 3", "plaza render loop stalled, kick 60"])
    }

    /// A reopened plaza has a new scene, so the watchdog forgets the last look: the first one only takes the count.
    func testAReopenedPlazaStartsWatchingAfresh() {
        let c = controller(defaults())
        c.prepareScene()
        c.renderLoop = RecordingRenderLoop()
        c.checkRendering()
        c.checkRendering()                  // stuck before closing: one kick
        c.handleClose()
        c.prepareScene()
        let loop = RecordingRenderLoop()
        c.renderLoop = loop
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        c.startRenderWatchdog()
        c.checkRendering()
        XCTAssertEqual(loop.sets, [], "the new scene has not had a second yet")
        XCTAssertEqual(lines, [])
        c.handleClose()
    }

    /// The watchdog looks once a second while the plaza is open and stops when it closes.
    func testTheWatchdogLooksEverySecondUntilClosed() async {
        let gate = CheckGate()
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                      loader: PlazaCharacterLoader(fetcher: RecordingFetcher()),
                                      nickname: { "tester" }, memberID: { "member-1" },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      renderCheckSleep: { _ in await gate.sleep() })
        c.prepareScene()
        let loop = RecordingRenderLoop()
        c.renderLoop = loop
        c.startRenderWatchdog()
        await settle { gate.count == 1 }
        gate.tick()                         // first look
        await settle { gate.count == 1 }
        gate.tick()                         // no update since: wake it
        await settle { loop.sets == [true, false] && gate.count == 1 }
        XCTAssertEqual(loop.sets, [true, false])
        c.handleClose()
        gate.tick()
        await settle { gate.count == 1 }
        XCTAssertEqual(gate.count, 0, "closed: no more looks")
    }

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
        let d = defaults()
        PlazaPreferences(defaults: d).saveLastTile(TilePoint(x: 23, y: 14))   // 쉼터는 지도 위쪽 끝이라 카메라가 막힌다: 가운데에서 시작
        let c = controller(d)
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

    /// Each status reads and looks different, and a roster with all three lays out one row per teammate.
    func testRosterShowsThreeDistinctStatuses() {
        let badges = [PlazaPresence.online, .idle, .asleep].map(\.badge)
        XCTAssertEqual(badges.map(\.text), ["접속", "자리비움", "잠"])
        XCTAssertEqual(Set(badges.map(\.color)).count, 3)
        func entry(_ id: String, _ p: PlazaPresence, me: Bool = false) -> PlazaRosterEntry {
            PlazaRosterEntry(id: id, nickname: id, speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false,
                             presence: p, isMe: me)
        }
        let model = PlazaRosterModel()
        let view = PlazaRosterHostingView(rootView: PlazaRosterView(model: model))
        model.entries = [entry("me", .online, me: true)]
        let one = view.fittingSize.height
        model.entries = [entry("me", .idle, me: true), entry("a", .online), entry("b", .idle), entry("c", .asleep)]
        view.layoutSubtreeIfNeeded()
        let slot = PlazaRosterMetrics.slotHeight + PlazaRosterMetrics.slotSpacing
        XCTAssertEqual(view.fittingSize.height - one, 3 * slot, accuracy: 1)
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

    // MARK: - Pond: Z routing, tackle and menu rules, dive limit

    private struct PondNode {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        let received: PondReceived
    }
    @MainActor private final class PondReceived { var emotes: [TeamEmote] = [] }
    private static let pondMon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    private let zKey: UInt16 = 6, cKey: UInt16 = 8

    private func pondNode(_ name: String, code: TeamCode) -> PondNode {
        let suite = "plaza.pond.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaWindowTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = pondHub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pondMon, dex: []) })
        session.updateCharacter(Self.pondMon)
        session.applySettings()
        let received = PondReceived()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return PondNode(settings: settings, session: session, transport: transport, received: received)
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", line: line)
    }

    /// 나와 팀원 하나를 잇고, 나는 (31,18)에서 물(오른쪽)을 보고 선다. 시계는 `now`가 정한다.
    private func pondPair(mate: TilePoint? = nil, types: @escaping (Int) async -> [String]? = { _ in nil },
                          subject: @escaping () -> CompanionStore.RepresentativeSubject = { .init(speciesID: 25, isShiny: false) },
                          retrySleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) })
        async -> (me: PondNode, other: PondNode, c: PlazaWindowController) {
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let me = pondNode("나", code: code), other = pondNode("민수", code: code)
        let prefs = PlazaPreferences(defaults: defaults())
        prefs.saveLastTile(TilePoint(x: 31, y: 18))
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: RecordingFetcher()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: subject,
                                      pokemonTypes: types,
                                      session: me.session, clock: { [unowned self] in pondNow },
                                      spriteRetrySleep: retrySleep)
        c.prepareScene()
        pondHub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        if let mate {
            other.session.updatePlazaPosition(inPlaza: true, tile: mate, facing: .down, isWalking: false)
            await waitUntil { c.scene?.memberTiles[other.settings.memberID] == mate }
        }
        c.scene!.face(.right)
        return (me, other, c)
    }
    private var pondNow: Date {
        get { pondClock.now }
        set { pondClock.now = newValue }
    }
    private let pondClock = PondClock()
    private let pondHub = FakeTransportHub()
    @MainActor private final class PondClock { var now = Date(timeIntervalSince1970: 1_700_000_000) }

    private func pondKey(_ scene: PlazaScene, _ code: UInt16) {
        scene.handleKeyDown(keyCode: code, characters: "", isRepeat: false)
    }

    /// 첨벙 걸음이 끝나 물에 내려앉도록 장면을 돌린다.
    private func settle(_ scene: PlazaScene, _ t: inout TimeInterval, seconds: TimeInterval = 0.6) {
        let end = t + seconds
        while t < end { t += 1.0 / 30; scene.update(t) }
    }

    private func jumps(_ n: PondNode) -> Int { n.received.emotes.filter { $0.kind == .jump }.count }

    func testZRoutesToPlungeDiveAndSurface() async {
        let (me, other, c) = await pondPair()
        let scene = c.scene!, id = me.settings.memberID
        var t: TimeInterval = 0
        scene.update(t)
        pondKey(scene, zKey)
        await waitUntil { jumps(other) == 1 }
        settle(scene, &t, seconds: 0.1)
        // 0.36초 안에 다시 누르면 아무것도 보내지 않는다.
        pondNow = pondNow.addingTimeInterval(0.2)
        pondKey(scene, zKey)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(jumps(other), 1, "a second Z inside 0.36s sends no second jump")
        XCTAssertFalse(scene.isDiving)
        XCTAssertNotEqual(other.session.members[id]?.isDiving, true)
        settle(scene, &t)
        XCTAssertTrue(scene.isMeInWater, "plunged into the water")
        pondNow = pondNow.addingTimeInterval(1)
        pondKey(scene, zKey)
        XCTAssertTrue(scene.isDiving)
        await waitUntil { other.session.members[id]?.isDiving == true }
        pondNow = pondNow.addingTimeInterval(1)
        pondKey(scene, zKey)
        XCTAssertFalse(scene.isDiving)
        await waitUntil { other.session.members[id]?.isDiving != true }
        XCTAssertEqual(jumps(other), 1, "diving and surfacing send no jump")
        c.handleClose()
    }

    func testClosingThePlazaWhileDivingClearsIt() async {
        let (me, other, c) = await pondPair()
        let scene = c.scene!, id = me.settings.memberID
        var t: TimeInterval = 0
        scene.update(t)
        pondKey(scene, zKey)
        settle(scene, &t)
        pondNow = pondNow.addingTimeInterval(1)
        pondKey(scene, zKey)
        await waitUntil { other.session.members[id]?.isDiving == true }
        c.handleClose()
        await waitUntil { other.session.members[id]?.isDiving != true }
    }

    /// Climbing out of a dive: the land tile must go out before the cleared flag. A receiver reading "water tile, not
    /// diving" would play a surfacing splash that never happened.
    func testClimbingOutOfADiveSendsTheLandTileFirst() async {
        let (me, other, c) = await pondPair()
        let scene = c.scene!, id = me.settings.memberID, map = PlazaMapData.map
        var t: TimeInterval = 0
        scene.update(t)
        pondKey(scene, zKey)
        settle(scene, &t)
        pondNow = pondNow.addingTimeInterval(1)
        pondKey(scene, zKey)
        await waitUntil { other.session.members[id]?.isDiving == true }
        pondKey(scene, 123)   // left, out of the water
        settle(scene, &t, seconds: 0.5)
        scene.handleKeyUp(keyCode: 123)
        XCTAssertFalse(scene.isMeInWater)
        XCTAssertFalse(scene.isDiving)
        await waitUntil { other.session.members[id]?.isDiving != true }
        let presences = me.transport.sent.compactMap { sent -> TeamPresence? in
            if case .presence(let p) = sent.message { return p }
            return nil
        }
        guard let diveStart = presences.firstIndex(where: { $0.isDiving == true }) else { return XCTFail("no dive sent") }
        let after = presences[diveStart...].filter { $0.isDiving != true }
        XCTAssertFalse(after.isEmpty)
        for presence in after {
            XCTAssertFalse(presence.tile.map { map.isWater($0) } ?? false,
                           "a presence that clears the dive must not carry a water tile: \(String(describing: presence.tile))")
        }
        c.handleClose()
    }

    func testNoTackleInWater() async {
        // 팀원이 물속: C로 몸통박치기하지 않고 메뉴에도 몸통박치기·따라가기가 없다.
        let water = TilePoint(x: 32, y: 18)
        let (_, swimmer, c1) = await pondPair(mate: water)
        c1.scene!.onTackleKey?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(swimmer.received.emotes.filter { $0.kind == .tackle }.count, 0, "the target is in the water")
        pondKey(c1.scene!, 49)
        guard case .memberMenu(let m1) = c1.overlayContent else { return XCTFail("no menu: \(c1.overlayContent)") }
        XCTAssertEqual(m1.actions, [.greet, .viewCard], "no tackle or follow for a swimmer")
        c1.handleClose()

        // 내가 물속: 땅의 팀원에게도 C가 아무것도 보내지 않고, 메뉴에서 몸통박치기·따라가기가 빠진다.
        let (_, mate, c2) = await pondPair(mate: TilePoint(x: 30, y: 18))
        var t: TimeInterval = 0
        c2.scene!.update(t)
        pondKey(c2.scene!, zKey)
        settle(c2.scene!, &t)
        XCTAssertTrue(c2.scene!.isMeInWater)
        mate.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 31, y: 18), facing: .down, isWalking: false)
        for _ in 0..<400 where c2.scene?.memberTiles[mate.settings.memberID] != TilePoint(x: 31, y: 18) {
            await Task.yield(); settle(c2.scene!, &t, seconds: 0.05)
        }
        settle(c2.scene!, &t, seconds: 0.6)
        XCTAssertEqual(c2.scene?.memberTiles[mate.settings.memberID], TilePoint(x: 31, y: 18))
        c2.scene!.face(.left)
        c2.scene!.onTackleKey?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(mate.received.emotes.filter { $0.kind == .tackle }.count, 0, "I am in the water")
        pondKey(c2.scene!, 49)
        guard case .memberMenu(let m2) = c2.overlayContent else { return XCTFail("no menu: \(c2.overlayContent)") }
        XCTAssertEqual(m2.actions, [.greet, .viewCard], "no tackle or follow while I swim")
        c2.handleClose()

        // 둘 다 땅이면 그대로 보낸다(위 두 확인이 아무것도 안 지키는 테스트가 아님을 보인다).
        let (_, land, c3) = await pondPair(mate: TilePoint(x: 30, y: 18))
        c3.scene!.onTackleKey?()
        await waitUntil { land.received.emotes.contains { $0.kind == .tackle } }
        c3.handleClose()
    }

    func testWaterTypeSetsTheDiveLimit() async {
        var species = 130   // Gyarados
        let (_, _, c) = await pondPair(types: { $0 == 130 ? ["water", "flying"] : ["fire"] },
                                       subject: { .init(speciesID: species, isShiny: false) })
        XCTAssertEqual(c.scene?.diveLimit, PlazaPond.diveLimit)
        await c.refreshCharacter()
        await waitUntil { c.scene?.diveLimit == 15 }
        XCTAssertEqual(c.scene?.diveLimit, 15)
        species = 4   // Charmander
        await c.refreshCharacter()
        await waitUntil { c.scene?.diveLimit == 6 }
        XCTAssertEqual(c.scene?.diveLimit, 6, "a non-water species goes back to the short limit")
        c.handleClose()
    }

    @MainActor private final class Held {
        var typeCalls: [CheckedContinuation<[String]?, Never>] = []
        var retrySleeps: [CheckedContinuation<Void, Never>] = []
        var lookups = 0
    }

    /// The first type lookup hangs; a sprite retry starts meanwhile. The retry's own lookup decides the limit.
    func testSpriteRetryDoesNotLoseTheDiveLimit() async {
        let held = Held()
        let (_, _, c) = await pondPair(
            types: { [held] _ in
                held.lookups += 1
                if held.lookups == 1 { return await withCheckedContinuation { held.typeCalls.append($0) } }
                return ["water"]
            },
            retrySleep: { [held] _ in await withCheckedContinuation { held.retrySleeps.append($0) } })
        await c.refreshCharacter()   // the empty fetcher gives placeholder frames, so a retry waits on the sleep
        await waitUntil { !held.retrySleeps.isEmpty && held.lookups == 1 }
        held.retrySleeps.removeFirst().resume()
        await waitUntil { c.scene?.diveLimit == 15 }
        XCTAssertEqual(c.scene?.diveLimit, 15, "the retry's lookup applied")
        held.typeCalls.removeFirst().resume(returning: nil)   // the stale lookup finally answers
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(c.scene?.diveLimit, 15, "and the stale answer is dropped")
        c.handleClose()
        held.retrySleeps.forEach { $0.resume() }
    }
}
