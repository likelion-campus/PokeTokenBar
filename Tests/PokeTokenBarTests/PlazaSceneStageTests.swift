import XCTest
@testable import PokeTokenBar

/// The scene on a stage, on every OS (Track A Task 10): the tree it builds under the stage root, what it forwards to the
/// stage, the pause work a platform can trigger, and the effects that were `SKAction`s. Headless stage only; the
/// SpriteKit side is `PlazaSpriteKitStageTests` (Mac).
@MainActor
final class PlazaSceneStageTests: XCTestCase {
    private let map = PlazaMapData.map

    private func scene(_ stage: PlazaHeadlessStage = PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나", stage: stage)
        s.currentModifiers = { [] }
        return s
    }

    private func frames() -> PlazaCharacterFrames {
        let image = characterTestImage(width: 20, height: 30, opaque: [(2, 2), (17, 27)])
        return PlazaCharacterFrames(front: [PlazaFrame(image: image, delay: 0.1)], back: [PlazaFrame(image: image, delay: 0.1)])
    }

    /// Frame `k` of a run at 60 fps on a clock that starts at 1000 s (as SpriteKit's clock is far from 0).
    private func time(_ k: Int) -> TimeInterval { 1000 + Double(k) / 60 }

    /// The order SpriteKit drew in when the scene was the `SKScene` (exact z ties draw in tree order): map, campfire
    /// pit and light, weather, fireworks, footprints, snowballs, camera, then my five world nodes; in the camera my plate,
    /// bubble and 💧, then the daylight tint. Teammates append theirs at the end.
    func testTheSceneBuildsItsTreeOnTheStageRootInTodaysOrder() async throws {
        let stage = PlazaHeadlessStage(size: CGSize(width: 960, height: 640))
        let s = scene(stage)
        XCTAssertTrue(s.root === stage.root)
        XCTAssertTrue(stage.delegate === s, "the stage reports frames, sizes, keys and pauses to the scene")
        let kids = stage.root.children
        XCTAssertEqual(kids.count, 13)
        let mapNode = try XCTUnwrap(kids[0] as? PlazaSprite)
        XCTAssertEqual(mapNode.anchorPoint, .zero)
        XCTAssertEqual(mapNode.size, map.pixelSize)
        XCTAssertTrue(mapNode.texture?.image === s.shownMapImage)
        let pit = try XCTUnwrap(kids[1] as? PlazaSprite), light = try XCTUnwrap(kids[2] as? PlazaSprite)
        XCTAssertEqual(pit.anchorPoint, CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(s.campfireZ, pit.zPosition)
        XCTAssertEqual(light.blendMode, .multiplyX2)
        XCTAssertEqual(light.zPosition, 6)
        XCTAssertTrue(kids[3] === s.weatherLayer.root && kids[4] === s.fireworkLayer.root)
        XCTAssertTrue(kids[5] === s.footprintLayer.root && kids[6] === s.snowballLayer.root)
        let camera = try XCTUnwrap(kids[7] as? PlazaCameraNode)
        XCTAssertTrue(stage.camera === camera, "the stage draws through the scene's camera")
        XCTAssertTrue(Array(kids[8...]).elementsEqual(s.myActor.worldNodes, by: ===), "my world nodes right after the camera")
        XCTAssertTrue(camera.children.dropLast().elementsEqual(s.myActor.cameraNodes, by: ===), "my plate, bubble and 💧 before the tint")
        let tint = try XCTUnwrap(camera.children.last as? PlazaSprite)
        XCTAssertEqual(tint.blendMode, .multiply)
        XCTAssertEqual(tint.zPosition, 5)
        XCTAssertEqual(tint.colorBlendFactor, 1)

        let m = PlazaSceneMember(memberID: "a", nickname: "A", isAway: false, tile: TilePoint(x: map.spawn.x + 2, y: map.spawn.y),
                                 facing: .down, isWalking: false)
        s.applyMembers([m])
        let theirs = try XCTUnwrap(s.memberActor("a"))
        XCTAssertTrue(Array(stage.root.children[13...]).elementsEqual(theirs.worldNodes, by: ===), "a teammate appends at the end")
        XCTAssertTrue(Array(camera.children[4...]).elementsEqual(theirs.cameraNodes, by: ===), "after the tint")
        s.applyMembers([])
        XCTAssertEqual(stage.root.children.count, 13)
        XCTAssertEqual(camera.children.count, 4)
    }

    /// A headless stage has no frame clock: nothing calls `update`, so a hidden (or headless) plaza does no frame work.
    func testAHeadlessPlazaGetsNoFrames() async throws {
        let s = scene()
        s.playJump(memberID: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(s.updateCount, 0)
        XCTAssertNil(s.lastFrameTime)
        XCTAssertEqual(s.dustCount, 2, "nothing stepped the dust")
    }

    /// `isPaused` lives on the stage. The pause work (dances end, ice and snowballs land) runs once when the scene pauses
    /// itself and when the platform pauses it (`stagePausedChanged`), and not when it is resumed.
    func testThePlatformsPauseRunsTheScenesPauseWork() async throws {
        let stage = PlazaHeadlessStage(size: CGSize(width: 960, height: 640))
        let s = scene(stage)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        s.now = { date }   // a new dance round needs a beat since the last one
        s.setCharacter(frames())
        s.update(time(0))
        s.handleKeyDown(keyCode: PlazaKeyCode.d, characters: "d", isRepeat: false)
        XCTAssertTrue(s.isDancing(memberID: nil))
        stage.isPaused = true
        stage.delegate?.stagePausedChanged(true)   // what SpriteKit's own pause reports
        XCTAssertTrue(s.isPaused)
        XCTAssertFalse(s.isDancing(memberID: nil), "a pause by the platform ends the dance, as the didSet did")
        stage.isPaused = false
        stage.delegate?.stagePausedChanged(false)
        XCTAssertFalse(s.isPaused)
        date += 10
        s.handleKeyDown(keyCode: PlazaKeyCode.d, characters: "d", isRepeat: false)
        XCTAssertTrue(s.isDancing(memberID: nil))
        stage.delegate?.stagePausedChanged(false)
        XCTAssertTrue(s.isDancing(memberID: nil), "a resume does no pause work")
        s.isPaused = true
        XCTAssertTrue(stage.isPaused, "the scene's own pause goes to the stage")
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    /// The five `SKAction` scripts now run as tweens stepped at the end of `update` with the frame time, so they expire
    /// without a view (they never ran in view-less tests before). Frames follow SpriteKit's rules (`PlazaTweenOracleTests`):
    /// a step is done once its time passes its 32-bit duration; the first step is at the frame after the effect started.
    func testTweensReplaceTheFiveActions() async throws {
        let s = scene()
        s.update(time(0))
        s.playJump(memberID: nil)
        var dust: [Int] = []
        for k in 1...50 { s.update(time(k)); dust.append(s.dustCount) }
        // started before frame 1: first step at frame 1, done after 0.35 s (frame 22); the landing puff waits 0.36 s
        // (frame 23) and its dust lasts 0.35 s again (frame 44)
        XCTAssertEqual(dust[0..<21].allSatisfy { $0 == 2 }, true, "\(dust)")
        XCTAssertEqual(dust[21], 0, "\(dust)")
        XCTAssertEqual(dust[22], 2, "the delayed landing puff: \(dust)")
        XCTAssertEqual(dust[42], 2, "\(dust)")
        XCTAssertEqual(dust[43], 0, "\(dust)")

        let t = scene()
        t.update(time(0))
        t.playTackle(by: nil, on: nil, direction: .right)
        t.playShutterFlash()
        var impact: [Int] = [], shutter: [Bool] = []
        for k in 1...30 { t.update(time(k)); impact.append(t.impactCount); shutter.append(t.isShutterFlashing) }
        XCTAssertEqual(impact.firstIndex(of: 0), 21, "the impact lasts 0.34 s: \(impact)")
        XCTAssertEqual(shutter.firstIndex(of: false), 13, "the shutter fades for 0.2 s: \(shutter)")

        let d = scene()
        d.applyDitto(PlazaDittoShown(tile: TilePoint(x: map.spawn.x + 2, y: map.spawn.y), facing: .down, isWalking: false,
                                     isRunning: false, name: "Ditto", nameColor: PlazaNameColor.palette[1], title: nil, isDecoy: false))
        d.update(time(0))
        d.playDittoPoof()
        var poof: [Int] = []
        for k in 1...30 { d.update(time(k)); poof.append(d.dustCount) }
        XCTAssertEqual(poof[0], 5)
        XCTAssertEqual(poof.firstIndex(of: 0), 27, "the poof lasts 0.45 s: \(poof)")
    }

    /// `size`, `backgroundColor` and the camera's numbers go through the stage. A size the platform sets lays the scene
    /// out again; without a window the backing scale is 2, as it was without a view.
    func testSizeBackgroundAndCameraGoThroughTheStage() async throws {
        let stage = PlazaHeadlessStage(size: CGSize(width: 960, height: 640))
        let s = scene(stage)
        XCTAssertEqual(stage.backgroundColor, PlazaColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1))
        s.setBackgroundHidden(true)
        XCTAssertEqual(stage.backgroundColor, .clear)
        s.setBackgroundHidden(false)
        XCTAssertEqual(stage.backgroundColor.alpha, 1)

        let twin = scene()
        twin.backingOverride = 2
        for size in [CGSize(width: 960, height: 640), CGSize(width: 641, height: 481), CGSize(width: 600, height: 372)] {
            for zoom in [1, 2, 3] {
                stage.size = size   // the platform resizing its view
                twin.size = size
                s.zoom = zoom
                twin.zoom = zoom
                XCTAssertEqual(s.size, size)
                XCTAssertEqual(s.visibleWorldRect, twin.visibleWorldRect, "\(size) zoom \(zoom): no window means backing 2")
                XCTAssertEqual(s.cameraPosition, twin.cameraPosition)
                let z = CGFloat(zoom), foot = s.myFootPoint, world = map.pixelSize
                let focus = PlazaCamera.focus(for: foot, viewportWidth: size.width, rightInset: PlazaRosterMetrics.coveredWidth,
                                              characterHalfWidth: s.characterSize.width * z / 2, zoom: zoom, lift: s.myActor.cameraLift)
                let rect = PlazaCamera.visibleRect(focus: focus, viewport: size, zoom: zoom, backingScale: 2, world: world,
                                                   rightInset: PlazaRosterMetrics.coveredWidth)
                XCTAssertEqual(s.visibleWorldRect, rect, "\(size) zoom \(zoom)")
                XCTAssertEqual(s.cameraPosition, PlazaFloat.stored(CGPoint(x: rect.midX, y: world.height - rect.midY)))
            }
        }
        s.backingOverride = 1
        twin.backingOverride = 1
        stage.size = CGSize(width: 777, height: 555)
        twin.size = CGSize(width: 777, height: 555)
        XCTAssertEqual(s.visibleWorldRect, twin.visibleWorldRect, "the override still wins over the stage")
    }
}
