import Metal
import SpriteKit
import XCTest
@testable import PokeTokenBar

/// The five `SKAction` scripts of `PlazaScene` run live under `SKRenderer` next to their `PlazaTweens` twins in the same
/// scene, stepped the way Task 10 will step them (at the end of the scene's `update`, with its clamped dt). Per frame,
/// position, alpha, scale and parent must be bit-equal (the plan's Review Focus 3). Offscreen: no window, no render.
@MainActor
final class PlazaTweenOracleTests: XCTestCase {
    private final class OracleScene: SKScene {
        let tweens: PlazaTweens
        private var lastTime: TimeInterval?
        init(size: CGSize, root: PlazaNode) {
            tweens = PlazaTweens(root: root)
            super.init(size: size)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        var frameIndex = 0
        var onUpdate: ((Int) -> Void)?
        override func update(_ currentTime: TimeInterval) {
            let raw = currentTime - (lastTime ?? currentTime)   // as PlazaScene.update
            lastTime = currentTime
            let dt = raw.isFinite ? min(max(raw, 0), PlazaScene.maxFrameDelta) : 0
            onUpdate?(frameIndex)
            tweens.advance(by: dt)
        }
    }

    private struct World {
        let scene: OracleScene
        let root: PlazaNode
        var raw: [SKSpriteNode] = []
        var shared: [PlazaSprite] = []
    }

    private static let worldHeight: CGFloat = 1536

    private func pair(_ w: inout World, size: CGSize, color: PlazaColor = .white, setUp: (SKSpriteNode, PlazaSprite) -> Void) -> (SKSpriteNode, PlazaSprite) {
        let r = SKSpriteNode(color: color.skColor, size: size)
        let s = PlazaSprite(color: color, size: size)
        setUp(r, s)
        w.scene.addChild(r)
        w.root.addChild(s)
        w.raw.append(r); w.shared.append(s)
        return (r, s)
    }

    // MARK: The five scripts, written as PlazaScene writes them

    private func poof(_ w: inout World) {
        let foot = CGPoint(x: 300.37, y: 210.81)
        for i in 0..<5 {
            let angle = Double(i) / 5 * 2 * .pi
            let dx = cos(angle), dy = sin(angle)
            let (r, s) = pair(&w, size: PlazaEmoteArt.dustSize) { r, s in
                r.position = CGPoint(x: (foot.x + dx * 6).rounded(), y: (Self.worldHeight - foot.y + 3 + dy * 4).rounded())
                s.position = r.position
                r.xScale = dx < 0 ? -1 : 1; s.xScale = r.xScale
                r.zPosition = 1 + foot.y / Self.worldHeight + 0.0002; s.zPosition = 1 + foot.y / Self.worldHeight + 0.0002
            }
            r.run(.sequence([.group([.moveBy(x: dx * 12, y: dy * 8 + 3, duration: 0.45), .fadeOut(withDuration: 0.45)]), .removeFromParent()]))
            w.scene.tweens.run(.sequence([.group([.moveBy(dx: dx * 12, dy: dy * 8 + 3, duration: 0.45), .fadeOut(duration: 0.45)]), .removeFromParent]), on: s)
        }
    }

    private func jumpDust(_ w: inout World, foot: CGPoint = CGPoint(x: 512.25, y: 640.6)) {
        for side in [-1.0, 1.0] {
            let (r, s) = pair(&w, size: PlazaEmoteArt.dustSize) { r, s in
                r.position = CGPoint(x: (foot.x + side * 6).rounded(), y: (Self.worldHeight - foot.y + 3).rounded()); s.position = r.position
                r.xScale = side; s.xScale = side
                r.zPosition = 1 + foot.y / Self.worldHeight + 0.0002; s.zPosition = 1 + foot.y / Self.worldHeight + 0.0002
            }
            r.run(.sequence([.group([.moveBy(x: side * 10, y: 3, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
            w.scene.tweens.run(.sequence([.group([.moveBy(dx: side * 10, dy: 3, duration: 0.35), .fadeOut(duration: 0.35)]), .removeFromParent]), on: s)
        }
    }

    private func impact(_ w: inout World) {
        let (r, s) = pair(&w, size: PlazaEmoteArt.impactSize) { r, s in
            r.position = CGPoint(x: 777, y: 401); s.position = r.position
            r.zPosition = 20; s.zPosition = 20
            r.setScale(0.6); s.setScale(0.6)
        }
        r.run(.sequence([.group([.scale(to: 1.4, duration: 0.14), .sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.22)])]),
                         .removeFromParent()]))
        w.scene.tweens.run(.sequence([.group([.scaleTo(1.4, duration: 0.14), .sequence([.wait(0.12), .fadeOut(duration: 0.22)])]),
                                      .removeFromParent]), on: s)
    }

    private func shutter(_ w: inout World) {
        let (r, s) = pair(&w, size: CGSize(width: 640, height: 480)) { r, s in
            r.alpha = 0.7; s.alpha = 0.7
            r.zPosition = 100; s.zPosition = 100
        }
        r.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
        w.scene.tweens.run(.sequence([.fadeOut(duration: 0.2), .removeFromParent]), on: s)
    }

    // MARK: Driver

    private enum Start { case betweenFrames, insideUpdate }

    /// Runs `script` from `startFrame` over `times`; `events[f]` runs ahead of frame f (other code: removals, pauses).
    /// Returns the node-frames compared.
    private func compare(_ name: String, times: [TimeInterval], startFrame: Int, start: Start,
                         events: [Int: (inout World) -> Void] = [:], expectEnded: Bool = true,
                         script: @escaping (inout World) -> Void) throws -> Int {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = SKRenderer(device: device)
        let root = PlazaNode()
        let scene = OracleScene(size: CGSize(width: 640, height: 480), root: root)
        renderer.scene = scene
        root.mountInSpriteKit(scene)
        var world = World(scene: scene, root: root)
        if start == .insideUpdate {
            scene.onUpdate = { f in if f == startFrame { script(&world) } }
        }
        var compared = 0
        for (f, t) in times.enumerated() {
            scene.frameIndex = f
            if start == .betweenFrames && f == startFrame { script(&world) }
            events[f]?(&world)
            renderer.update(atTime: t)
            XCTAssertEqual(world.raw.count, world.shared.count, "\(name) frame \(f): the scripts made different numbers of nodes")
            for (i, (r, s)) in zip(world.raw, world.shared).enumerated() {
                let label = "\(name) frame \(f) node \(i)"
                XCTAssertEqual(r.parent == nil, s.parent == nil, "\(label): parent")
                guard r.parent != nil, s.parent != nil else { continue }   // the last moveBy step lands in the removal frame
                let b = PlazaMirrorParity.bits
                XCTAssertEqual([b(r.position.x), b(r.position.y)], [b(s.position.x), b(s.position.y)],
                               "\(label): position \(r.position) vs \(s.position)")
                XCTAssertEqual(b(r.alpha), b(s.alpha), "\(label): alpha \(r.alpha) vs \(s.alpha)")
                XCTAssertEqual([b(r.xScale), b(r.yScale)], [b(s.xScale), b(s.yScale)], "\(label): scale")
                XCTAssertEqual(PlazaMirrorParity.differences(s), [], "\(label): mirror")
                compared += 1
            }
        }
        if expectEnded {
            XCTAssertTrue(world.raw.allSatisfy { $0.parent == nil }, "\(name): every SKAction script ended")
            XCTAssertEqual(scene.tweens.count, 0, "\(name): every tween ended")
        }
        return compared
    }

    private static let regular = (0..<48).map { 1000 + Double($0) / 60 }
    private static let largeBase = (0..<48).map { 123_456.789 + Double($0) / 60 }   // CACurrentMediaTime-like
    private static let irregular: [TimeInterval] = {
        var rng = PlazaSplitMix64(seed: 0x0DDB_A11)
        var t = 1000.25, out: [TimeInterval] = []
        for _ in 0..<60 { out.append(t); t += 0.008 + 0.022 * rng.unit() }
        return out
    }()

    private func runAll(_ name: String, _ script: @escaping (inout World) -> Void) throws {
        var total = 0
        for (label, times) in [("regular", Self.regular), ("large-base", Self.largeBase), ("irregular", Self.irregular)] {
            for (start, frame) in [(Start.betweenFrames, 3), (.insideUpdate, 5)] {
                total += try compare("\(name) \(label) \(start)", times: times, startFrame: frame, start: start, script: script)
            }
        }
        print("ORACLE: \(name): \(total) node-frames bit-equal")
        XCTAssertGreaterThan(total, 50)
    }

    func testDittoPoofMatchesItsAction() throws { try runAll("poof", poof) }
    func testJumpDustMatchesItsAction() throws { try runAll("jump-dust") { self.jumpDust(&$0) } }
    func testTackleImpactMatchesItsAction() throws { try runAll("impact", impact) }
    func testShutterMatchesItsAction() throws { try runAll("shutter", shutter) }

    /// Other code removes the dust mid-flight (one node comes back later): SpriteKit stops a node's actions while it is
    /// out of the scene and, when it returns, evaluates them at the scene clock; the tweens do the same.
    func testANodeRemovedMidTweenMatchesItsAction() throws {
        var total = 0
        for (label, times) in [("regular", Self.regular), ("irregular", Self.irregular)] {
            let events: [Int: (inout World) -> Void] = [
                9: { w in for i in 0..<2 { w.raw[i].removeFromParent(); w.shared[i].removeFromParent() } },
                15: { w in w.scene.addChild(w.raw[0]); w.root.addChild(w.shared[0]) },
            ]
            total += try compare("removed \(label)", times: times, startFrame: 3, start: .betweenFrames, events: events, expectEnded: false) { w in
                self.jumpDust(&w)
            }
        }
        print("ORACLE: removed mid-tween: \(total) node-frames bit-equal")
    }

    /// A tween on a mounted root moves the root itself, as an action on the SpriteKit node would.
    func testATweenOnAMountedRootMatchesItsAction() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = SKRenderer(device: device)
        let root = PlazaNode()
        let scene = OracleScene(size: CGSize(width: 640, height: 480), root: root)
        renderer.scene = scene
        root.position = CGPoint(x: 33.3, y: 7.7)
        root.mountInSpriteKit(scene)
        let raw = SKNode()
        raw.position = CGPoint(x: 33.3, y: 7.7)
        scene.addChild(raw)
        var compared = 0
        for (f, t) in Self.irregular.enumerated() {
            if f == 3 {
                raw.run(.group([.moveBy(x: 10, y: 3, duration: 0.35), .fadeOut(withDuration: 0.35)]))
                scene.tweens.run(.group([.moveBy(dx: 10, dy: 3, duration: 0.35), .fadeOut(duration: 0.35)]), on: root)
            }
            renderer.update(atTime: t)
            let b = PlazaMirrorParity.bits
            XCTAssertEqual([b(raw.position.x), b(raw.position.y), b(raw.alpha)], [b(root.position.x), b(root.position.y), b(root.alpha)], "frame \(f)")
            XCTAssertEqual(PlazaMirrorParity.differences(root), [], "frame \(f): mirror")
            compared += 1
        }
        XCTAssertEqual(root.alpha, 0)
    }

    /// A second photo while the flash is still fading: the old flash leaves (its fade stops), a new one starts.
    func testAShutterReplacingARunningOneMatches() throws {
        var total = 0
        for (label, times) in [("regular", Self.regular), ("irregular", Self.irregular)] {
            let events: [Int: (inout World) -> Void] = [7: { w in
                w.raw[0].removeFromParent(); w.shared[0].removeFromParent()   // playShutterFlash: shutterNode?.removeFromParent()
                self.shutter(&w)
            }]
            total += try compare("shutter twice \(label)", times: times, startFrame: 3, start: .betweenFrames, events: events, expectEnded: false) { w in
                self.shutter(&w)
            }
        }
        print("ORACLE: shutter replaced: \(total) node-frames bit-equal")
    }

    /// Pause mid-tween (the window is hidden: SpriteKit stops calling `update` and evaluating actions). On resume
    /// SpriteKit's actions jump to the scene clock, as if never paused; the tweens resume where they stopped, moved by one
    /// clamped frame (`maxFrameDelta`), because the scene's own dt is clamped. Both behaviours are pinned here; the plaza
    /// starts no effect while paused (plan D4).
    func testPauseMidTweenIsPinned() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        func makeWorld() -> (SKRenderer, World) {
            let renderer = SKRenderer(device: device)
            let root = PlazaNode()
            let scene = OracleScene(size: CGSize(width: 640, height: 480), root: root)
            renderer.scene = scene
            root.mountInSpriteKit(scene)
            return (renderer, World(scene: scene, root: root))
        }
        let (pausedRenderer, pausedWorld) = makeWorld()
        let (plainRenderer, plainWorld) = makeWorld()
        var paused = pausedWorld, plain = plainWorld
        // the tweens' own twin, stepped by hand with the dt the paused scene hands them
        let twinRoot = PlazaNode()
        let twins = PlazaTweens(root: twinRoot)
        var twinNodes: [PlazaSprite] = []
        let times = Self.regular
        var lastTime: TimeInterval?
        var frozen: [[UInt64]] = []
        for (f, t) in times.enumerated() {
            if f == 3 {
                jumpDust(&paused)
                jumpDust(&plain)
                for s in paused.shared {
                    let n = PlazaSprite(color: .white, size: s.size)
                    n.position = s.position; n.xScale = s.xScale; n.zPosition = s.zPosition
                    twinRoot.addChild(n)
                    twinNodes.append(n)
                    twins.run(.sequence([.group([.moveBy(dx: n.xScale * 10, dy: 3, duration: 0.35), .fadeOut(duration: 0.35)]), .removeFromParent]), on: n)
                }
            }
            if f == 8 { paused.scene.isPaused = true }
            if f == 20 { paused.scene.isPaused = false }
            pausedRenderer.update(atTime: t)
            plainRenderer.update(atTime: t)
            if !(8..<20).contains(f) {   // the paused scene gets no update, so the twin gets no step either
                let raw = t - (lastTime ?? t)
                lastTime = t
                twins.advance(by: min(max(raw, 0), PlazaScene.maxFrameDelta))
            }
            let b = PlazaMirrorParity.bits
            if f == 7 { frozen = paused.raw.map { [b($0.position.x), b($0.alpha)] } }
            for i in 0..<paused.raw.count where paused.raw[i].parent != nil && plain.raw[i].parent != nil {
                if (8..<20).contains(f) {
                    XCTAssertEqual([b(paused.raw[i].position.x), b(paused.raw[i].alpha)], frozen[i], "frame \(f): a paused scene's action does not run")
                } else {
                    // progress follows the scene clock: the fade is bit-equal to the never-paused run; the move (incremental)
                    // took one large step instead of twelve small ones, so it rounds differently in the last bits
                    XCTAssertEqual(b(paused.raw[i].alpha), b(plain.raw[i].alpha), "frame \(f): on resume SpriteKit's fade is where the scene clock says")
                    XCTAssertEqual(paused.raw[i].position.x, plain.raw[i].position.x, accuracy: 1e-4, "frame \(f): and so is its move")
                }
            }
            for i in 0..<paused.shared.count where paused.shared[i].parent != nil {
                XCTAssertEqual([b(paused.shared[i].position.x), b(paused.shared[i].alpha)], [b(twinNodes[i].position.x), b(twinNodes[i].alpha)],
                               "frame \(f): the tween resumes where it stopped")
            }
            if f == 21 {
                XCTAssertNotEqual(paused.raw[0].alpha, paused.shared[0].alpha, "after the pause the two differ (the pin means something)")
            }
        }
    }

    /// The delayed landing puff: a scene-level wait then a block that starts jump dust; the block runs in the same frame
    /// and the dust it starts takes its first step in that frame on both sides.
    func testDelayedCallMatchesItsAction() throws {
        var total = 0
        for (label, times) in [("regular", Self.regular), ("large-base", Self.largeBase), ("irregular", Self.irregular)] {
            var skFrame: Int?, sharedFrame: Int?
            var sceneRef: OracleScene?
            total += try compare("delayed \(label)", times: times, startFrame: 2, start: .betweenFrames) { w in
                sceneRef = w.scene
                w.scene.run(.sequence([.wait(forDuration: PlazaActor.jumpDuration), .run { skFrame = sceneRef?.frameIndex }]))
                w.scene.tweens.run(.sequence([.wait(PlazaActor.jumpDuration), .call { sharedFrame = sceneRef?.frameIndex }]), on: nil)
            }
            XCTAssertNotNil(skFrame, label)
            XCTAssertEqual(skFrame, sharedFrame, "\(label): the delayed call runs in the same frame")
        }
        // the dust started by the call: started inside an SKAction block / a PlazaTweens call, compared frame by frame
        for (label, times) in [("regular", Self.regular), ("irregular", Self.irregular)] {
            total += try comparePuff(label, times: times)
        }
        print("ORACLE: delayed call: \(total) node-frames bit-equal")
    }

    /// Like `compare`, but the dust nodes are made inside the delayed block (SpriteKit) and the delayed call (tweens).
    private func comparePuff(_ label: String, times: [TimeInterval]) throws -> Int {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = SKRenderer(device: device)
        let root = PlazaNode()
        let scene = OracleScene(size: CGSize(width: 640, height: 480), root: root)
        renderer.scene = scene
        root.mountInSpriteKit(scene)
        var raw: [SKSpriteNode] = [], shared: [PlazaSprite] = []
        let foot = CGPoint(x: 512.25, y: 640.6)
        func dustSK() {
            for side in [-1.0, 1.0] {
                let n = SKSpriteNode(color: .white, size: PlazaEmoteArt.dustSize)
                n.position = CGPoint(x: (foot.x + side * 6).rounded(), y: (Self.worldHeight - foot.y + 3).rounded())
                n.xScale = side
                scene.addChild(n)
                n.run(.sequence([.group([.moveBy(x: side * 10, y: 3, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
                raw.append(n)
            }
        }
        func dustShared() {
            for side in [-1.0, 1.0] {
                let n = PlazaSprite(color: .white, size: PlazaEmoteArt.dustSize)
                n.position = CGPoint(x: (foot.x + side * 6).rounded(), y: (Self.worldHeight - foot.y + 3).rounded())
                n.xScale = side
                root.addChild(n)
                scene.tweens.run(.sequence([.group([.moveBy(dx: side * 10, dy: 3, duration: 0.35), .fadeOut(duration: 0.35)]), .removeFromParent]), on: n)
                shared.append(n)
            }
        }
        var compared = 0
        for (f, t) in times.enumerated() {
            scene.frameIndex = f
            if f == 2 {
                scene.run(.sequence([.wait(forDuration: PlazaActor.jumpDuration), .run { dustSK() }]))
                scene.tweens.run(.sequence([.wait(PlazaActor.jumpDuration), .call { dustShared() }]), on: nil)
            }
            renderer.update(atTime: t)
            XCTAssertEqual(raw.count, shared.count, "puff \(label) frame \(f): dust made in different frames")
            for (r, s) in zip(raw, shared) {
                XCTAssertEqual(r.parent == nil, s.parent == nil, "puff \(label) frame \(f): parent")
                guard r.parent != nil, s.parent != nil else { continue }
                let b = PlazaMirrorParity.bits
                XCTAssertEqual([b(r.position.x), b(r.position.y), b(r.alpha)], [b(s.position.x), b(s.position.y), b(s.alpha)],
                               "puff \(label) frame \(f): \(r.position) \(r.alpha) vs \(s.position) \(s.alpha)")
                compared += 1
            }
        }
        XCTAssertEqual(raw.count, 2)
        return compared
    }
}
