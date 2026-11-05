import XCTest
import AppKit
@testable import PokeTokenBar

@MainActor
final class PlazaPhotoModeSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let size = CGSize(width: 960, height: 640)
    private let dt = 1.0 / 30

    private func newScene() -> PlazaScene {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: PlazaCampfire.seats[0].tile,
                               zoom: 2, nickname: "나")
        scene.backingOverride = 2
        scene.size = size
        scene.now = { Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12))! }
        scene.update(0)   // 첫 update는 dt 0이라 시계를 먼저 맞춘다
        return scene
    }

    private var clockTime: TimeInterval = 0

    /// 1/30초씩 `seconds`만큼 update를 돌린다.
    private func run(_ scene: PlazaScene, seconds: TimeInterval) {
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n { clockTime += dt; scene.update(clockTime) }
    }

    private func down(_ scene: PlazaScene, _ code: UInt16, _ chars: String? = nil,
                      modifiers: NSEvent.ModifierFlags = []) -> PlazaKeyResult {
        scene.handleKeyDown(keyCode: code, characters: chars, isRepeat: false, modifiers: modifiers)
    }

    private func layoutFor(_ c: CGPoint, zoom: Int = 2) -> PlazaPhotoFrame.Layout? {
        PlazaPhotoFrame.layout(center: c, viewport: size, zoom: zoom, backingScale: 2, world: map.pixelSize)
    }

    override func setUp() { clockTime = 0 }

    func testEnteringKeepsTheViewAndFramesIt() throws {
        let scene = newScene()
        var reports: [Bool] = []
        scene.onPhotoModeChange = { reports.append($0) }
        let before = scene.visibleWorldRect
        scene.enterPhotoMode()
        let c = try XCTUnwrap(scene.photoCenter)
        XCTAssertEqual(c, CGPoint(x: before.midX, y: before.midY))
        let l = try XCTUnwrap(layoutFor(c))
        XCTAssertEqual(scene.photoFrame, l.frame)
        XCTAssertEqual(scene.visibleWorldRect, l.visible)
        XCTAssertEqual(reports, [true])
        scene.enterPhotoMode()
        XCTAssertEqual(reports, [true])
    }

    func testArrowsSlideTheFrameNotMe() throws {
        let scene = newScene()
        scene.enterPhotoMode()
        let tile = scene.walker.tile
        let x0 = try XCTUnwrap(scene.photoCenter).x
        _ = down(scene, 124)
        run(scene, seconds: 0.5)
        XCTAssertEqual(try XCTUnwrap(scene.photoCenter).x - x0, 128, accuracy: 1)
        XCTAssertEqual(scene.walker.tile, tile)
        XCTAssertFalse(scene.walker.isWalking)
        scene.handleKeyUp(keyCode: 124)
        let x1 = try XCTUnwrap(scene.photoCenter).x
        run(scene, seconds: 0.5)
        XCTAssertEqual(try XCTUnwrap(scene.photoCenter).x, x1)
        scene.currentModifiers = { .shift }
        let y0 = try XCTUnwrap(scene.photoCenter).y
        _ = down(scene, 125)
        run(scene, seconds: 0.5)
        XCTAssertEqual(try XCTUnwrap(scene.photoCenter).y - y0, 256, accuracy: 1)
    }

    func testArrowsInPhotoModeNeverCallOnWalkKey() {
        let scene = newScene()
        var walks = 0
        scene.onWalkKey = { walks += 1 }
        scene.enterPhotoMode()
        for code: UInt16 in [123, 124, 125, 126] { _ = down(scene, code) }
        XCTAssertEqual(walks, 0)
        scene.releaseAllKeys()
        scene.exitPhotoMode()
        _ = down(scene, 124)
        XCTAssertEqual(walks, 1)
    }

    func testHoldingAtTheEdgeDoesNotPileUp() throws {
        let scene = newScene()
        scene.enterPhotoMode()
        _ = down(scene, 123)
        run(scene, seconds: 10)
        XCTAssertEqual(try XCTUnwrap(scene.photoFrame).minX, 0)
        scene.handleKeyUp(keyCode: 123)
        _ = down(scene, 124)
        run(scene, seconds: 0.5)
        XCTAssertEqual(try XCTUnwrap(scene.photoFrame).minX, 128, accuracy: 1)
    }

    func testCommandArrowAndReleaseAllStopThePan() throws {
        let scene = newScene()
        scene.enterPhotoMode()
        let c0 = try XCTUnwrap(scene.photoCenter)
        _ = down(scene, 124, modifiers: .command)
        run(scene, seconds: 0.5)
        XCTAssertEqual(scene.photoCenter, c0)
        _ = down(scene, 124)
        scene.releaseAllKeys()
        run(scene, seconds: 0.5)
        XCTAssertEqual(scene.photoCenter, c0)
        _ = down(scene, 124)
        scene.clearInput()
        run(scene, seconds: 0.5)
        XCTAssertEqual(scene.photoCenter, c0)
    }

    func testZoomKeepsTheCentreAndIsNotReported() throws {
        let scene = newScene()
        var zooms: [Int] = []
        scene.onZoomChange = { zooms.append($0) }
        scene.enterPhotoMode()
        let c0 = try XCTUnwrap(scene.photoCenter)
        _ = down(scene, 27, "-")
        XCTAssertEqual(scene.zoom, 1)
        let c1 = try XCTUnwrap(scene.photoCenter)
        XCTAssertEqual(c1.x, c0.x, accuracy: 0.5)
        XCTAssertEqual(c1.y, c0.y, accuracy: 0.5)
        XCTAssertEqual(scene.photoInput()?.visibleRect, scene.photoFrame)
        XCTAssertEqual(zooms, [])
        scene.exitPhotoMode()
        XCTAssertEqual(scene.zoom, 2)
        XCTAssertEqual(zooms, [2])
    }

    func testPhotoInputTakesTheFrame() throws {
        let scene = newScene()
        scene.enterPhotoMode()
        let input = try XCTUnwrap(scene.photoInput())
        XCTAssertEqual(input.visibleRect, scene.photoFrame)
        XCTAssertEqual(input.pixelsPerWorld, 4)
        XCTAssertEqual(input.visibleRect.width * 4, 1824)
        XCTAssertEqual(input.visibleRect.height * 4, 1144)
    }

    func testKeysInPhotoMode() {
        let scene = newScene()
        var c = (photo: 0, interact: 0, chat: 0, tackle: 0, group: 0, jump: 0, greet: 0, emote: 0, close: 0)
        scene.onPhotoKey = { c.photo += 1 }
        scene.onInteractKey = { c.interact += 1 }
        scene.onChatKey = { c.chat += 1 }
        scene.onTackleKey = { c.tackle += 1 }
        scene.onGroupPhotoKey = { c.group += 1 }
        scene.onJumpKey = { c.jump += 1 }
        scene.onGreetKey = { c.greet += 1 }
        scene.onEmoteKey = { _ in c.emote += 1 }
        scene.onCloseRequest = { c.close += 1 }
        scene.enterPhotoMode()
        for code: UInt16 in [49, 35, 36, 8, 5, 6, 7, 18] { XCTAssertEqual(down(scene, code), .swallowed) }
        XCTAssertEqual(c.photo, 2)
        XCTAssertEqual(c.interact, 0)
        XCTAssertEqual(c.chat, 0)
        XCTAssertEqual(c.tackle, 0)
        XCTAssertEqual(c.group, 1)
        XCTAssertEqual(c.jump, 1)
        XCTAssertEqual(c.greet, 1)
        XCTAssertEqual(c.emote, 1)
        XCTAssertEqual(down(scene, 53), .swallowed)
        XCTAssertFalse(scene.isPhotoMode)
        XCTAssertEqual(c.close, 0)
        XCTAssertEqual(down(scene, 53), .closeRequested)
        XCTAssertEqual(c.close, 1)
    }

    func testLeavingPutsTheCameraBackOnMe() {
        let scene = newScene()
        let before = scene.visibleWorldRect
        scene.enterPhotoMode()
        _ = down(scene, 124)
        run(scene, seconds: 1)
        XCTAssertNotEqual(scene.visibleWorldRect, before)
        scene.exitPhotoMode()
        XCTAssertEqual(scene.visibleWorldRect, before)
        XCTAssertNil(scene.photoFrame)
    }
}
