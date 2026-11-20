import AppKit
import SpriteKit
import XCTest
@testable import PokeTokenBar

/// What SpriteKit actually does, pinned as asserts. The shared (Windows) node model must copy each rule; each
/// message states the rule. Mac only. The render probes use `PlazaOffscreenRenderer` (no window, no activation).
@MainActor
final class SpriteKitSemanticsTests: XCTestCase {
    func testSpriteSizeIncludesScale() {
        let s = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 20))
        s.xScale = 2; s.yScale = 3
        XCTAssertEqual(s.size, CGSize(width: 20, height: 60), "RULE: SKSpriteNode.size reads back size x |scale| (not the stored base size)")
        XCTAssertEqual(s.frame, CGRect(x: -10, y: -30, width: 20, height: 60), "RULE: frame is the scaled size around the anchor")
        s.setScale(1); s.xScale = -1
        XCTAssertEqual(s.size, CGSize(width: 10, height: 20), "RULE: size uses |scale|: a flip (xScale -1) never makes the width negative")
        XCTAssertEqual(s.frame, CGRect(x: -5, y: -10, width: 10, height: 20), "RULE: a flipped sprite's frame is the same rect as unflipped (centre anchor)")
        s.setScale(2)
        XCTAssertEqual(s.size, CGSize(width: 20, height: 40), "RULE: setScale scales size too")
    }

    func testSettingSizeUnderScaleStoresUnscaled() {
        let s = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 20))
        s.xScale = 2
        s.size = CGSize(width: 30, height: 40)
        XCTAssertEqual(s.size, CGSize(width: 30, height: 40), "RULE: right after the assignment, size reads back what was assigned")
        s.xScale = 1
        XCTAssertEqual(s.size, CGSize(width: 15, height: 40), "RULE: the setter stores assigned / |xScale| (base size); width halves once the scale is reset, height was not scaled")
    }

    func testTextureAssignmentKeepsSize() {
        let s = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 20))
        let t = SKTexture(cgImage: PlazaRenderScenes.image([UInt8](repeating: 255, count: 4 * 4 * 6), width: 4, height: 6))
        s.texture = t
        XCTAssertEqual(s.size, CGSize(width: 10, height: 20), "RULE: assigning .texture keeps the sprite's size")
        XCTAssertEqual(SKSpriteNode(texture: t).size, CGSize(width: 4, height: 6), "RULE: init(texture:) takes the texture's pixel size")
    }

    func testSubRectTextureSize() {
        let t = SKTexture(cgImage: PlazaRenderScenes.image([UInt8](repeating: 255, count: 8 * 8 * 4), width: 8, height: 8))
        let sub = SKTexture(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), in: t)
        XCTAssertEqual(sub.size(), CGSize(width: 4, height: 4), "RULE: SKTexture(rect:in:) size = parent size x unit-rect size")
        XCTAssertEqual(SKSpriteNode(texture: sub).size, CGSize(width: 4, height: 4))
    }

    func testFrameUnderAnchorAndScale() {
        let s = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 20))
        s.position = CGPoint(x: 100, y: 50)
        s.anchorPoint = CGPoint(x: 0.5, y: 0)
        XCTAssertEqual(s.frame, CGRect(x: 95, y: 50, width: 10, height: 20), "RULE: frame.origin = position - anchor x size (y up)")
        s.xScale = -2
        XCTAssertEqual(s.frame, CGRect(x: 90, y: 50, width: 20, height: 20), "RULE: under xScale -2 the frame is positive-width, scaled around position by the anchor")
        s.anchorPoint = CGPoint(x: 0, y: 0); s.xScale = 2; s.yScale = 1
        XCTAssertEqual(s.frame, CGRect(x: 100, y: 50, width: 20, height: 20), "RULE: anchor (0,0) keeps the origin at position under positive scale")
    }

    func testDefaultSpriteColorAndBlend() throws {
        let s = SKSpriteNode(texture: nil)
        let c = try XCTUnwrap(s.color.usingColorSpace(.sRGB))
        XCTAssertEqual([c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent], [1, 1, 1, 0], "RULE: default sprite colour is clear white (1,1,1,0), not black")
        XCTAssertEqual(s.colorBlendFactor, 0, "RULE: default colorBlendFactor is 0")
        XCTAssertEqual(s.blendMode, .alpha, "RULE: default blend mode is alpha")
        XCTAssertEqual(s.size, .zero, "RULE: a texture-less sprite without a size is 0x0")
        XCTAssertEqual(s.alpha, 1)
    }

    func testColorInitializersAgree() throws {
        for v: CGFloat in [0, 0.1, 0.5, 0.8, 1] {
            let a = try XCTUnwrap(SKColor(red: v, green: 1 - v, blue: v / 2, alpha: 0.7).usingColorSpace(.sRGB))
            let b = try XCTUnwrap(SKColor(srgbRed: v, green: 1 - v, blue: v / 2, alpha: 0.7).usingColorSpace(.sRGB))
            XCTAssertEqual([a.redComponent, a.greenComponent, a.blueComponent, a.alphaComponent], [b.redComponent, b.greenComponent, b.blueComponent, b.alphaComponent],
                           "RULE: SKColor(red:) and SKColor(srgbRed:) give identical sRGB components on this Mac (v=\(v)); the shared model may treat them as one")
        }
    }

    // MARK: Render probes

    private final class CountingScene: SKScene {
        var updates: [TimeInterval] = []
        override func update(_ currentTime: TimeInterval) { updates.append(currentTime) }
    }

    func testRendererUpdateDrivesSceneUpdateAndActions() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer())
        let scene = CountingScene(size: CGSize(width: 64, height: 64))
        let node = SKNode()
        scene.addChild(node)
        node.run(.moveBy(x: 100, y: 0, duration: 1))
        for i in 0...30 { r.pass(scene, points: CGSize(width: 64, height: 64), pixels: (64, 64), time: Double(i) / 30) }
        XCTAssertEqual(scene.updates.count, 31, "RULE: SKRenderer.update(atTime:) calls SKScene.update(_:) once per call, so the harness must not call it again")
        XCTAssertEqual(node.position.x, 100, accuracy: 0.5, "RULE: SKRenderer.update(atTime:) runs SKActions against the times it is given (first call sets t0)")
        // time 0 is special: the first call substitutes the wall clock, later (smaller) times are then ignored
        let wall = CountingScene(size: CGSize(width: 64, height: 64))
        let raw = SKRenderer(device: r.device)
        raw.scene = wall
        raw.update(atTime: 0)
        XCTAssertGreaterThan(wall.updates.first ?? 0, 1, "RULE: SKRenderer.update(atTime: 0) as the first call hands scene.update the WALL CLOCK; the harness never starts at 0")
        // resizeFill scenes (PlazaScene) are resized to 0x0 by update(atTime:) before scene.update runs
        let fill = CountingScene(size: CGSize(width: 64, height: 64))
        fill.scaleMode = .resizeFill
        raw.scene = fill
        raw.update(atTime: 5)
        XCTAssertEqual(fill.size, .zero, "RULE: a .resizeFill scene is resized to 0x0 inside SKRenderer.update(atTime:), before scene.update(_:) sees it (the harness sets .fill)")
    }

    private func solid(_ name: String, _ rgb: (UInt8, UInt8, UInt8), size: CGSize, z: CGFloat) -> SKSpriteNode {
        let n = SKSpriteNode(color: NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1), size: size)
        n.name = name; n.zPosition = z
        return n
    }

    /// Renders `scene` and returns the colour at the scene centre as (r,g,b).
    private func centre(_ scene: SKScene, _ r: PlazaOffscreenRenderer) -> (Int, Int, Int) {
        for _ in 0..<6 { r.pass(scene, points: CGSize(width: 64, height: 64), pixels: (64, 64), time: 0) }
        let b = r.bytes()
        let i = (32 * 64 + 32) * 4
        return (Int(b[i + 2]), Int(b[i + 1]), Int(b[i]))
    }

    private func newScene() -> SKScene {
        let s = SKScene(size: CGSize(width: 64, height: 64))
        s.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return s
    }

    func testCameraChildrenSortWithWorldByGlobalZ() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer())
        for cameraZ: CGFloat in [3, 7] {
            let scene = newScene()
            let cam = SKCameraNode()
            scene.addChild(cam); scene.camera = cam
            scene.addChild(solid("world", (255, 0, 0), size: CGSize(width: 40, height: 40), z: 5))
            cam.addChild(solid("camchild", (0, 0, 255), size: CGSize(width: 40, height: 40), z: cameraZ))
            let c = centre(scene, r)
            XCTAssertEqual(c.0 == 255 ? "world" : "camera", cameraZ < 5 ? "world" : "camera",
                           "RULE: camera children sort with the world by GLOBAL z (camera child z=\(cameraZ) vs world z=5); the camera's own z is 0")
        }
    }

    func testCropSubtreeDrawsAtCropZ() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer())
        let scene = newScene()
        let crop = SKCropNode(); crop.zPosition = 1
        crop.maskNode = SKSpriteNode(color: .white, size: CGSize(width: 60, height: 60))
        crop.addChild(solid("incrop", (255, 0, 0), size: CGSize(width: 40, height: 40), z: 10))
        scene.addChild(crop)
        scene.addChild(solid("sibling", (0, 0, 255), size: CGSize(width: 40, height: 40), z: 5))
        let c = centre(scene, r)
        XCTAssertEqual(c.2, 255, "RULE: an SKCropNode subtree is drawn as one unit at the crop node's z (1), so a sibling at z=5 is on top of a crop child at z=10")
        XCTAssertEqual(c.0, 0)
    }

    func testSceneIsPausedNotChangedByPresenting() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer())
        let size = CGSize(width: 64, height: 64)
        let scene = newScene()
        r.pass(scene, points: size, pixels: (64, 64), time: 0)
        XCTAssertFalse(scene.isPaused, "RULE: SKRenderer.scene = scene never changes isPaused")
        let paused = newScene(); paused.isPaused = true
        r.pass(paused, points: size, pixels: (64, 64), time: 0)
        XCTAssertTrue(paused.isPaused, "RULE: a paused scene stays paused under SKRenderer (so a harness never resumes the plaza by rendering it)")
        let view = SKView(frame: CGRect(x: -10000, y: -10000, width: 64, height: 64))   // never in a window, never ordered front
        let pausedScene = newScene(); pausedScene.isPaused = true
        view.presentScene(pausedScene)
        XCTAssertFalse(pausedScene.isPaused, "RULE: SKView.presentScene sets scene.isPaused = false by itself, even for a scene paused before (the plaza's isPaused didSet must expect this)")
        view.isPaused = true
        let next = newScene()
        view.presentScene(next)
        XCTAssertFalse(next.isPaused, "RULE: presenting into a paused view leaves scene.isPaused false (view.isPaused is separate)")
        view.presentScene(nil)
    }

    /// Records, does not assert an order across SpriteKit versions: the observed order is stored in a test attachment-free print
    /// and asserted only for being stable (same input, same output), because the shared model copies "insertion order" only if this holds.
    func testEqualZTieIsRecorded() throws {
        let r = try XCTUnwrap(PlazaOffscreenRenderer())
        var seen: [String] = []
        for order in [["A", "B"], ["B", "A"], ["A", "B"]] {
            let scene = newScene()
            for n in order { scene.addChild(solid(n, n == "A" ? (255, 0, 0) : (0, 0, 255), size: CGSize(width: 40, height: 40), z: 2)) }
            seen.append(centre(scene, r).0 == 255 ? "A" : "B")
        }
        print("TIE equal z under SKRenderer(ignoresSiblingOrder = true): order [A,B] -> \(seen[0]) on top, [B,A] -> \(seen[1]) on top (observed: the LAST added wins)")
        XCTAssertEqual(seen[0], seen[2], "RULE: an exact z tie resolves the same way for the same insertion order (stable)")
        XCTAssertNotEqual(seen[0], seen[1], "RECORDED: under this Mac's SKRenderer a tie follows insertion order (last added on top), even with ignoresSiblingOrder; the app's SKView may differ")
    }
}
