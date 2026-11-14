import AppKit
import SpriteKit
import XCTest
@testable import PokeTokenBar

/// The Mac host of the shared scene (Track A Task 10): `SpriteKitStage` and its `PlazaSKScene` must give SpriteKit the
/// scene it had when `PlazaScene` was the `SKScene` (settings, tree, camera, colours) and hand the scene SpriteKit's
/// frames, keys and pauses exactly as SpriteKit gave them to it then. Offscreen only: `SKRenderer` and window-less
/// `SKView`s (one window that is never ordered front, for the backing scale).
@MainActor
final class PlazaSpriteKitStageTests: XCTestCase {
    private let map = PlazaMapData.map

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.currentModifiers = { [] }
        return s
    }

    private func host(_ s: PlazaScene) -> PlazaSKScene { (s.stage as! SpriteKitStage).skScene }

    private func frames() -> PlazaCharacterFrames {
        let image = characterTestImage(width: 20, height: 30, opaque: [(2, 2), (17, 27)])
        return PlazaCharacterFrames(front: [PlazaFrame(image: image, delay: 0.1)], back: [PlazaFrame(image: image, delay: 0.1)])
    }

    private func components(_ c: SKColor) -> [CGFloat] {
        guard let s = c.usingColorSpace(.sRGB) else { return [] }
        return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
    }

    /// What `PlazaScene.init` set on itself as an `SKScene`, now on the host: `.resizeFill`, anchor at the origin, the
    /// 960x640 start size, the forest colour (and clear when the background is hidden) with the same sRGB components as
    /// the old `SKColor(red:)` literal, the camera, and the scene's nodes as the host's own children in order.
    func testTheHostIsTheSKSceneThePlazaWas() throws {
        XCTAssertTrue(PlatformPlaza.makeStage(size: CGSize(width: 10, height: 10)) is SpriteKitStage)
        let s = scene()
        let sk = host(s)
        XCTAssertTrue(s.root.skNode === sk, "the stage root's SpriteKit copy is the SKScene itself")
        XCTAssertEqual(sk.scaleMode, .resizeFill)
        XCTAssertEqual(sk.anchorPoint, .zero)
        XCTAssertEqual(sk.size, CGSize(width: 960, height: 640))
        let old = SKScene(size: CGSize(width: 960, height: 640))   // what PlazaScene set on itself, read back the same way
        old.backgroundColor = SKColor(red: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1)
        XCTAssertEqual(components(sk.backgroundColor), components(old.backgroundColor))
        let camera = try XCTUnwrap(s.root.children.first { $0 is PlazaCameraNode })
        XCTAssertTrue(sk.camera === camera.skNode, "the SKScene draws through the scene's camera")
        XCTAssertNotNil(sk.camera)
        XCTAssertEqual(sk.children.count, s.root.children.count)
        XCTAssertEqual(PlazaMirrorParity.differences(s.root), [])
        XCTAssertEqual(PlazaRenderHarness.actorMountDifferences(of: s), [])
        s.setBackgroundHidden(true)
        old.backgroundColor = .clear
        XCTAssertEqual(components(sk.backgroundColor), components(old.backgroundColor))
        s.size = CGSize(width: 641, height: 481)
        XCTAssertEqual(sk.size, CGSize(width: 641, height: 481))
        XCTAssertEqual(s.visibleWorldRect.width, 641 / 2, accuracy: 1, "the size change laid the scene out (SKScene.didChangeSize)")
    }

    /// Every frame SpriteKit draws reaches the scene once, with SpriteKit's own clock.
    func testEveryFrameReachesTheSceneWithSpriteKitsClock() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        let s = scene()
        let size = CGSize(width: 64, height: 64)
        for k in 0..<30 {
            r.pass(host(s), points: size, pixels: (64, 64), time: Double(k) / 60)
            XCTAssertEqual(s.updateCount, k + 1)
            XCTAssertEqual(s.lastFrameTime, PlazaOffscreenRenderer.clockBase + Double(k) / 60)
        }
    }

    /// The idle rule: a paused plaza gets no `update`, so nothing moves, steps tweens or makes nodes, however long it
    /// stays hidden. On resume the first frame's time is clamped to `maxFrameDelta`, as before: a twin scene that got
    /// one 0.07 s step instead of the pause ends bit for bit where the resumed one does.
    func testAHiddenPlazaGetsNoFrames() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        let s = scene(), twin = scene()
        let size = CGSize(width: 64, height: 64)
        for x in [s, twin] { x.setCharacter(frames()) }
        func frame(_ t: TimeInterval) {
            r.pass(host(s), points: size, pixels: (64, 64), time: t)
            twin.size = size
            twin.update(PlazaOffscreenRenderer.clockBase + t)
        }
        for k in 0..<10 { frame(Double(k) / 60) }
        for x in [s, twin] { x.handleKeyDown(keyCode: PlazaKeyCode.right, characters: nil, isRepeat: false); x.playJump(memberID: nil) }
        for k in 10..<14 { frame(Double(k) / 60) }
        XCTAssertEqual(s.dustCount, 2)
        func dust(_ x: PlazaScene) -> [String] {
            x.children.filter { $0.name == "jump-dust" }.map { "\($0.position) \($0.alpha)" }
        }
        let before = (count: s.updateCount, time: s.lastFrameTime, nodes: s.root.descendantCount, dust: dust(s), foot: s.myFootPoint)

        s.isPaused = true
        for k in 14..<74 { r.pass(host(s), points: size, pixels: (64, 64), time: Double(k) / 60) }
        XCTAssertEqual(s.updateCount, before.count, "60 frames of a hidden plaza: no update")
        XCTAssertEqual(s.lastFrameTime, before.time)
        XCTAssertEqual(s.root.descendantCount, before.nodes, "no node made or removed")
        XCTAssertEqual(dust(s), before.dust, "no tween stepped")
        XCTAssertEqual(s.myFootPoint, before.foot, "nobody walked")

        s.isPaused = false
        r.pass(host(s), points: size, pixels: (64, 64), time: 10)
        twin.update(PlazaOffscreenRenderer.clockBase + 10)   // the twin was never paused: its frame time is clamped the same
        XCTAssertEqual(s.updateCount, before.count + 1)
        XCTAssertEqual(s.lastFrameTime, PlazaOffscreenRenderer.clockBase + 10)
        XCTAssertEqual(dust(s), dust(twin), "the resumed frame is one clamped step, for the tweens too")
        XCTAssertEqual(s.myFootPoint, twin.myFootPoint)
    }

    /// The old scene's `isPaused` override, kept as the oracle: what SpriteKit itself does to a scene's `isPaused`.
    private final class OldStyleScene: SKScene {
        var changes: [Bool] = []
        override var isPaused: Bool { didSet { if isPaused != oldValue { changes.append(isPaused) } } }
    }

    private final class RecordingDelegate: PlazaStageDelegate {
        var paused: [Bool] = []
        var updates = 0
        func stageUpdate(_ currentTime: TimeInterval) { updates += 1 }
        func stageDidChangeSize(from old: CGSize) {}
        func stageKeyDown(_ e: PlazaKeyEvent) {}
        func stageKeyUp(keyCode: UInt16) {}
        func stagePausedChanged(_ paused: Bool) { self.paused.append(paused) }
    }

    /// Every pause change SpriteKit makes by itself (presenting a paused scene unpauses it; the view's pause, if it
    /// reaches the scene) reaches the scene as the old `didSet` saw it; the stage's own writes are not reported back, so
    /// the pause work runs once. With a real scene: a platform pause ends my dance, as the didSet did.
    func testStagePauseFromThePlatformRunsTheSameDidSet() throws {
        let old = OldStyleScene(size: CGSize(width: 64, height: 64))
        let stage = SpriteKitStage(size: CGSize(width: 64, height: 64))
        let recorder = RecordingDelegate()
        stage.delegate = recorder
        old.isPaused = true; old.changes = []
        stage.isPaused = true
        XCTAssertEqual(recorder.paused, [], "the stage's own write is the scene's: not reported back")
        let oldView = SKView(frame: CGRect(x: -10000, y: -10000, width: 64, height: 64))   // never in a window
        let view = SKView(frame: CGRect(x: -10000, y: -10000, width: 64, height: 64))
        oldView.presentScene(old)
        view.presentScene(stage.skScene)
        XCTAssertEqual(old.changes, [false], "probe: presenting unpauses")
        XCTAssertEqual(recorder.paused, old.changes)
        for paused in [true, false, true, false] {
            oldView.isPaused = paused
            view.isPaused = paused
            XCTAssertEqual(recorder.paused, old.changes, "view.isPaused = \(paused)")
        }
        old.changes = []; recorder.paused = []
        old.isPaused = true; stage.skScene.isPaused = true   // SpriteKit (or anything else) writing the scene directly
        XCTAssertEqual(old.changes, [true])
        XCTAssertEqual(recorder.paused, [true])
        oldView.presentScene(nil)
        view.presentScene(nil)
        XCTAssertEqual(recorder.paused, old.changes)

        let s = scene()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        s.now = { date }
        s.setCharacter(frames())
        s.update(1000)
        s.handleKeyDown(keyCode: PlazaKeyCode.d, characters: "d", isRepeat: false)
        XCTAssertTrue(s.isDancing(memberID: nil))
        host(s).isPaused = true
        XCTAssertTrue(s.isPaused)
        XCTAssertFalse(s.isDancing(memberID: nil), "a pause SpriteKit makes ends the dance, as the didSet did")
        let sView = SKView(frame: CGRect(x: -10000, y: -10000, width: 64, height: 64))
        sView.presentScene(host(s))
        XCTAssertFalse(s.isPaused, "presenting unpauses the plaza, as it did")
        date += 10
        s.handleKeyDown(keyCode: PlazaKeyCode.d, characters: "d", isRepeat: false)
        XCTAssertTrue(s.isDancing(memberID: nil))
        sView.isPaused = true
        XCTAssertEqual(s.isDancing(memberID: nil), !s.isPaused, "the view's pause does the didSet's work exactly when it pauses the scene")
        sView.presentScene(nil)
    }

    /// Keys reach the scene through the host as they reached the `SKScene` before: the same calls and callbacks as
    /// `handleKeyDown`/`handleKeyUp` with the event's fields.
    func testKeyEventsReachTheSceneUnchanged() throws {
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], repeats: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars, isARepeat: repeats, keyCode: code))
        }
        let events: [NSEvent] = [
            try key(.keyDown, PlazaKeyCode.right, "\u{F703}", [.numericPad, .function]), try key(.keyDown, PlazaKeyCode.right, "\u{F703}", repeats: true),
            try key(.keyUp, PlazaKeyCode.right, "\u{F703}"), try key(.keyDown, 18, "1"), try key(.keyDown, 18, "1", .option),
            try key(.keyDown, PlazaKeyCode.z, "z"), try key(.keyDown, PlazaKeyCode.z, "z", repeats: true), try key(.keyDown, PlazaKeyCode.space, " "),
            try key(.keyDown, PlazaKeyCode.returnKey, "\r"), try key(.keyDown, 24, "="), try key(.keyDown, 27, "-"),
            try key(.keyDown, PlazaKeyCode.c, "c"), try key(.keyDown, PlazaKeyCode.up, "\u{F700}", .command),
            try key(.keyDown, PlazaKeyCode.escape, "\u{1B}"), try key(.keyDown, PlazaKeyCode.w, "w", .command),
        ]
        func wired(_ s: PlazaScene, _ log: @escaping (String) -> Void) {
            s.onCloseRequest = { log("close") }
            s.onEmoteKey = { log("emote \($0)") }
            s.onJumpKey = { log("jump") }
            s.onInteractKey = { log("interact") }
            s.onChatKey = { log("chat") }
            s.onWalkKey = { log("walk") }
            s.onTackleKey = { log("tackle") }
            s.onZoomChange = { log("zoom \($0)") }
        }
        let viaHost = scene(), direct = scene()
        var a: [String] = [], b: [String] = []
        wired(viaHost) { a.append($0) }
        wired(direct) { b.append($0) }
        for e in events {
            if e.type == .keyDown {
                host(viaHost).keyDown(with: e)
                let k = PlazaKeyEvent(e)
                direct.handleKeyDown(keyCode: k.keyCode, characters: k.characters, isRepeat: k.isRepeat, modifiers: k.modifiers)
            } else {
                host(viaHost).keyUp(with: e)
                direct.handleKeyUp(keyCode: e.keyCode)
            }
            viaHost.update(1000); direct.update(1000)
            XCTAssertEqual(a, b)
            XCTAssertEqual(viaHost.walker.tile, direct.walker.tile)
            XCTAssertEqual(viaHost.walker.isHoldingKey, direct.walker.isHoldingKey)
        }
        XCTAssertEqual(a.first, "walk")
        XCTAssertTrue(a.contains("emote heart") && a.contains("close"), "\(a)")
    }

    /// The backing scale comes from the window the view is in, as `view?.window?.backingScaleFactor` did; without one the
    /// scene uses 2. The window is never ordered front.
    func testTheBackingScaleComesFromTheViewsWindow() throws {
        let s = scene(), twin = scene()
        let stage = try XCTUnwrap(s.stage as? SpriteKitStage)
        XCTAssertNil(stage.backingScale)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.presentScene(stage.skScene)
        XCTAssertNil(stage.backingScale, "a view without a window")
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 640, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertEqual(stage.backingScale, window.backingScaleFactor)
        twin.backingOverride = window.backingScaleFactor
        s.size = CGSize(width: 641, height: 481)
        twin.size = CGSize(width: 641, height: 481)
        s.zoom = 3; twin.zoom = 3
        XCTAssertEqual(s.visibleWorldRect, twin.visibleWorldRect)
        XCTAssertEqual(s.cameraPosition, twin.cameraPosition)
        view.presentScene(nil)
        window.contentView = nil
    }

    /// Review point (Task 9): bridge-mounted actors never went through `PlazaDrawOrder.flatten`. Now that they are in the
    /// stage root, the shared draw order of representative harness scenes must equal SpriteKit's, as far as SpriteKit
    /// defines it: global z (camera children by their own global z), crop subtrees as one unit, exact ties in tree order
    /// (the order the harness nudges ties into). The SpriteKit side is computed from the SKScene's own tree.
    func testTheSharedDrawOrderIsSpriteKitsOrder() throws {
        let names: Set<String> = ["base-noon", "pond-swim", "pond-egg", "campfire-lit-night", "dance", "member-leave", "pond-hop",
                                  "lunges", "fireworks-night", "winter-footprints", "tall-grass", "ditto-poof"]
        let scenes = PlazaRenderScenes.all.filter { names.contains($0.name) }
        XCTAssertEqual(scenes.count, names.count)
        var compared = 0
        for rs in scenes {
            let setup = rs.build()
            let s = setup.scene
            for f in 0...(rs.captures.max() ?? 0) {
                setup.step(f)
                s.update(Double(f) / 60)
                guard rs.captures.contains(f) else { continue }
                let sk = host(s)
                let shared = PlazaDrawOrder.flatten(root: s.root, camera: s.root.children.first { $0 is PlazaCameraNode } as? PlazaCameraNode)
                let expected = Self.spriteKitOrder(sk)
                XCTAssertEqual(shared.count, expected.count, "\(rs.name)@\(f)")
                for (i, (item, want)) in zip(shared, expected).enumerated() {
                    guard item.sprite.skNode === want.node, item.globalZ == want.z, item.isScreenSpace == want.screen else {
                        XCTFail("\(rs.name)@\(f) #\(i): shared \(item.sprite.name ?? "-") z \(item.globalZ) vs SpriteKit \(want.node.name ?? "-") z \(want.z)")
                        break
                    }
                }
                compared += shared.count
            }
        }
        XCTAssertGreaterThan(compared, 1000)
    }

    /// SpriteKit's draw order of the visible sprites under `scene`, from its own tree.
    private static func spriteKitOrder(_ scene: SKScene) -> [(node: SKSpriteNode, z: CGFloat, screen: Bool)] {
        struct Unit { let z: CGFloat; let index: Int; let items: [(node: SKSpriteNode, z: CGFloat, screen: Bool)] }
        var index = 0
        func walk(_ node: SKNode, parentZ: CGFloat, screen: Bool, into units: inout [Unit]) {
            let mine = index
            index += 1
            guard !node.isHidden else { return }
            let z = parentZ + node.zPosition
            let inScreen = screen || node === scene.camera
            if let sprite = node as? SKSpriteNode { units.append(Unit(z: z, index: mine, items: [(sprite, z, inScreen)])) }
            if node is SKCropNode {
                var inner: [Unit] = []
                for child in node.children { walk(child, parentZ: z, screen: inScreen, into: &inner) }
                units.append(Unit(z: z, index: mine, items: sorted(inner)))
            } else {
                for child in node.children { walk(child, parentZ: z, screen: inScreen, into: &units) }
            }
        }
        func sorted(_ u: [Unit]) -> [(node: SKSpriteNode, z: CGFloat, screen: Bool)] {
            u.sorted { $0.z != $1.z ? $0.z < $1.z : $0.index < $1.index }.flatMap(\.items)
        }
        var units: [Unit] = []
        for child in scene.children { walk(child, parentZ: scene.zPosition, screen: false, into: &units) }
        return sorted(units)
    }
}
