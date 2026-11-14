import AppKit
import SpriteKit
import XCTest
@testable import PokeTokenBar

/// Compares SpriteKit nodes property by property, bit for bit (the plan's Review Focus 2: the shared tree and SpriteKit
/// must never disagree while tests read the shared tree).
@MainActor
enum PlazaMirrorParity {
    static func bits(_ v: CGFloat) -> UInt64 { Double(v).bitPattern }

    private static func colour(_ c: SKColor) -> [UInt64] {
        [bits(c.redComponent), bits(c.greenComponent), bits(c.blueComponent), bits(c.alphaComponent)]
    }

    /// `PlazaSprite.frame` reproduces SpriteKit's 1/1000 rounding except at some half-thousandths (documented there).
    static func framesAgree(_ a: CGRect, _ b: CGRect) -> Bool {
        zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]).allSatisfy { abs($0 - $1) <= 0.0011 }
    }

    private static func describe(_ n: SKNode) -> String {
        "\(type(of: n)) \(n.name ?? "-") p=\(n.position) z=\(n.zPosition) a=\(n.alpha) h=\(n.isHidden) sc=\(n.xScale),\(n.yScale) rot=\(n.zRotation)"
            + ((n as? SKSpriteNode).map { " size=\($0.size) anchor=\($0.anchorPoint) cbf=\($0.colorBlendFactor) blend=\($0.blendMode.rawValue)" } ?? "")
    }

    /// Two SpriteKit trees with the same shape and every value equal. `sameTexture` decides whether two textures are
    /// the same (identity mapping between the two worlds).
    static func treeDifferences(_ a: SKNode, _ b: SKNode, path: String = "", sameTexture: (SKTexture, SKTexture) -> Bool) -> [String] {
        var out: [String] = []
        let here = path + "/" + (a.name ?? "\(type(of: a))")
        func check(_ ok: Bool, _ what: String) { if !ok { out.append("\(here): \(what) — \(describe(a)) | \(describe(b))") } }
        check(type(of: a) == type(of: b), "class")
        check(a.name == b.name, "name")
        check(bits(a.position.x) == bits(b.position.x) && bits(a.position.y) == bits(b.position.y), "position")
        check(bits(a.zPosition) == bits(b.zPosition), "zPosition")
        check(bits(a.alpha) == bits(b.alpha), "alpha")
        check(a.isHidden == b.isHidden, "isHidden")
        check(bits(a.xScale) == bits(b.xScale) && bits(a.yScale) == bits(b.yScale), "scale")
        check(bits(a.zRotation) == bits(b.zRotation), "zRotation")
        if let sa = a as? SKSpriteNode, let sb = b as? SKSpriteNode {
            check(bits(sa.size.width) == bits(sb.size.width) && bits(sa.size.height) == bits(sb.size.height), "size")
            let fa = sa.frame, fb = sb.frame
            check([fa.minX, fa.minY, fa.width, fa.height].map(bits) == [fb.minX, fb.minY, fb.width, fb.height].map(bits), "frame")
            check(bits(sa.anchorPoint.x) == bits(sb.anchorPoint.x) && bits(sa.anchorPoint.y) == bits(sb.anchorPoint.y), "anchorPoint")
            check(colour(sa.color) == colour(sb.color), "color")
            check(bits(sa.colorBlendFactor) == bits(sb.colorBlendFactor), "colorBlendFactor")
            check(sa.blendMode == sb.blendMode, "blendMode")
            switch (sa.texture, sb.texture) {
            case (nil, nil): break
            case let (ta?, tb?):
                check(sameTexture(ta, tb), "texture identity")
                check(ta.textureRect() == tb.textureRect() && ta.size() == tb.size(), "texture rect/size")
                check(ta.filteringMode == .nearest && tb.filteringMode == .nearest, "texture filtering")
            default: check(false, "texture nil-ness")
            }
        }
        if let ca = a as? SKCropNode, let cb = b as? SKCropNode {
            switch (ca.maskNode as? SKSpriteNode, cb.maskNode as? SKSpriteNode) {
            case (nil, nil): check(ca.maskNode == nil && cb.maskNode == nil, "mask kind")
            case let (ma?, mb?): out += treeDifferences(ma, mb, path: here + "/mask", sameTexture: { _, _ in false })
            default: check(false, "mask nil-ness")
            }
        }
        check(a.children.count == b.children.count, "children count \(a.children.count) vs \(b.children.count)")
        for (ca, cb) in zip(a.children, b.children) { out += treeDifferences(ca, cb, path: here, sameTexture: sameTexture) }
        return out
    }

    /// A shared subtree against its own SpriteKit copy: same shape, the SpriteKit value of every property is the shared
    /// one, textures are the shared textures' own `SKTexture`s. Run by the render harness after every capture.
    static func differences(_ node: PlazaNode, path: String = "") -> [String] {
        let here = path + "/" + (node.name ?? "\(type(of: node))")
        guard let sk = node.skNode else { return ["\(here): no SpriteKit copy"] }
        var out: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { out.append("\(here): \(what) — shared vs \(describe(sk))") } }
        check(sk.name == node.name, "name")
        check(bits(sk.position.x) == bits(node.position.x) && bits(sk.position.y) == bits(node.position.y), "position")
        check(bits(sk.zPosition) == bits(node.zPosition), "zPosition")
        check(bits(sk.alpha) == bits(node.alpha), "alpha")
        check(sk.isHidden == node.isHidden, "isHidden")
        check(bits(sk.xScale) == bits(node.xScale) && bits(sk.yScale) == bits(node.yScale), "scale")
        check(bits(sk.zRotation) == bits(node.zRotation), "zRotation")
        switch node {
        case let s as PlazaSprite:
            guard let sp = sk as? SKSpriteNode else { return out + ["\(here): not an SKSpriteNode"] }
            check(bits(sp.size.width) == bits(s.size.width) && bits(sp.size.height) == bits(s.size.height), "size")
            check(bits(sp.anchorPoint.x) == bits(s.anchorPoint.x) && bits(sp.anchorPoint.y) == bits(s.anchorPoint.y), "anchorPoint")
            check(colour(sp.color) == [s.color.red, s.color.green, s.color.blue, s.color.alpha].map { CGFloat($0) }.map(bits), "color")
            check(bits(sp.colorBlendFactor) == bits(s.colorBlendFactor), "colorBlendFactor")
            check(sp.blendMode == SpriteKitBackend.blendMode(s.blendMode), "blendMode")
            check(sp.texture === s.texture?.nativeCache, "texture")
            if s.zRotation == 0 { check(framesAgree(sp.frame, s.frame), "frame \(sp.frame) vs \(s.frame)") }
        case let c as PlazaCropNode:
            guard let crop = sk as? SKCropNode else { return out + ["\(here): not an SKCropNode"] }
            if let r = c.maskRect, let m = crop.maskNode as? SKSpriteNode {
                check([m.position.x, m.position.y, m.size.width, m.size.height].map(bits) == [r.minX, r.minY, r.width, r.height].map(bits), "mask rect")
                check(m.anchorPoint == .zero && colour(m.color) == [1, 1, 1, 1].map { bits(CGFloat($0)) }, "mask sprite")
            } else {
                check(c.maskRect == nil && crop.maskNode == nil, "mask nil-ness")
            }
        case is PlazaCameraNode: check(sk is SKCameraNode, "class")
        default: check(type(of: sk) == SKNode.self, "class")
        }
        check(sk.children.count == node.children.count, "children count \(sk.children.count) vs \(node.children.count)")
        for (i, child) in node.children.enumerated() {
            check(i < sk.children.count && child.skNode === sk.children[i], "child \(i) is not its own copy")
            out += differences(child, path: here)
        }
        return out
    }
}

@MainActor
final class SpriteKitMirrorParityTests: XCTestCase {
    private enum Kind { case node, sprite, spriteTexture, spriteColor, crop, camera }

    /// The two worlds side by side: index i is the same logical node.
    private struct Worlds {
        var shared: [PlazaNode] = []
        var raw: [SKNode] = []
        var rawMasks: [ObjectIdentifier: SKSpriteNode] = [:]
    }

    private func isAncestor(_ a: PlazaNode, of b: PlazaNode) -> Bool {
        var n: PlazaNode? = b
        while let x = n { if x === a { return true }; n = x.parent }
        return false
    }

    /// Seeded random node operations applied to shared nodes (whose SpriteKit copies the backend keeps) and, the same
    /// way, to SpriteKit nodes built by hand as the plaza built them; the two SpriteKit trees must stay equal, and every
    /// shared value must read back what the hand-built SpriteKit node reads.
    func testRandomOperationsLeaveTheSameSpriteKitTree() {
        var rng = PlazaSplitMix64(seed: 0x7_1E57_AB1E)
        func unit() -> Double { rng.unit() }
        func int(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        func value(_ lo: Double, _ hi: Double) -> CGFloat { CGFloat(lo + (hi - lo) * unit()) }
        func scale() -> CGFloat { [1, -1, 2, -2, 0.6, 0, 1.7, -0.5, 1.4, value(-3, 3)][int(10)] }

        // textures: three images, their full textures and a few cuts (nested cuts too), each with its hand-built twin
        let images = [PlazaImage(bitmap: PlazaTestImages.patterned(width: 4, height: 6)),
                      PlazaImage(bitmap: PlazaTestImages.patterned(width: 9, height: 7)),
                      PlazaImage(bitmap: PlazaTestImages.solid(width: 3, height: 3, PlazaRGBA(r: 9, g: 99, b: 199, a: 255)))]
        var textures: [PlazaTexture] = []
        var rawTextures: [SKTexture] = []
        for image in images {
            let t = PlazaTexture(image)
            let raw = SKTexture(cgImage: image.cgImage)
            raw.filteringMode = .nearest
            textures.append(t); rawTextures.append(raw)
            for rect in [CGRect(x: 0, y: 0.5, width: 1, height: 0.5), CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3)] {
                let cut = PlazaTexture(rect: rect, in: t)
                let rawCut = SKTexture(rect: rect, in: raw)
                rawCut.filteringMode = .nearest
                textures.append(cut); rawTextures.append(rawCut)
                let nested = PlazaTexture(rect: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.3), in: cut)
                let rawNested = SKTexture(rect: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.3), in: rawCut)
                rawNested.filteringMode = .nearest
                textures.append(nested); rawTextures.append(rawNested)
            }
        }
        for (t, raw) in zip(textures, rawTextures) {
            XCTAssertEqual(t.pixelSize, raw.size(), "pixelSize is SKTexture.size()")
        }
        func sameTexture(_ a: SKTexture, _ b: SKTexture) -> Bool {
            guard let i = textures.firstIndex(where: { $0.nativeCache === a }) else { return false }
            return rawTextures[i] === b
        }

        var w = Worlds()
        var frames = 0, exactFrames = 0
        let sharedRoot = PlazaNode(), rawRoot = SKNode()
        let containerA = SKNode(), containerB = SKNode()
        w.shared.append(sharedRoot); w.raw.append(rawRoot)
        containerB.addChild(rawRoot)
        var mounted = false
        var ops = 0
        var mostMounted = 0

        func create() {
            switch [Kind.node, .sprite, .spriteTexture, .spriteColor, .sprite, .spriteTexture, .crop, .camera][int(8)] {
            case .node: w.shared.append(PlazaNode()); w.raw.append(SKNode())
            case .sprite: w.shared.append(PlazaSprite()); w.raw.append(SKSpriteNode())
            case .spriteTexture:
                let size = CGSize(width: value(0, 40), height: value(0, 40))
                let i = int(textures.count + 1)
                w.shared.append(PlazaSprite(texture: i < textures.count ? textures[i] : nil, size: size))
                w.raw.append(SKSpriteNode(texture: i < textures.count ? rawTextures[i] : nil, size: size))
            case .spriteColor:
                let c = PlazaColor(srgbRed: unit(), green: unit(), blue: unit(), alpha: unit())
                let size = CGSize(width: value(0, 40), height: value(0, 40))
                w.shared.append(PlazaSprite(color: c, size: size)); w.raw.append(SKSpriteNode(color: c.skColor, size: size))
            case .crop: w.shared.append(PlazaCropNode()); w.raw.append(SKCropNode())
            case .camera: w.shared.append(PlazaCameraNode()); w.raw.append(SKCameraNode())
            }
        }

        func setMask(_ i: Int, _ r: CGRect?) {
            (w.shared[i] as! PlazaCropNode).maskRect = r
            let crop = w.raw[i] as! SKCropNode
            guard let r else { crop.maskNode = nil; return }
            let mask = w.rawMasks[ObjectIdentifier(crop)] ?? {
                let m = SKSpriteNode(color: .white, size: .zero)   // what PlazaActor builds for its ghost crop
                m.anchorPoint = .zero
                w.rawMasks[ObjectIdentifier(crop)] = m
                return m
            }()
            mask.position = r.origin
            mask.size = r.size
            crop.maskNode = mask
        }

        var history: [Int: [String]] = [:]   // per node, for the failure message
        func setProperty(_ i: Int) {
            let s = w.shared[i], r = w.raw[i]
            defer { history[i, default: []].append("op \(ops): sc \(r.xScale),\(r.yScale) size \((r as? SKSpriteNode)?.size ?? .zero) tex \((r as? SKSpriteNode)?.texture?.size() ?? .zero)") }
            switch int(s is PlazaSprite ? 16 : (s is PlazaCropNode ? 11 : 10)) {
            case 0: let v = int(4) == 0 ? nil : "n\(int(5))"; s.name = v; r.name = v
            case 1: let v = CGPoint(x: value(-600, 600), y: value(-600, 600)); s.position = v; r.position = v
            case 2: let v = value(-5, 20); s.zPosition = v; r.zPosition = v
            case 3: let v = value(-0.2, 1.5); s.alpha = v; r.alpha = v
            case 4, 5: let v = int(2) == 0; s.isHidden = v; r.isHidden = v   // pooled hide/show
            case 6: let v = scale(); s.xScale = v; r.xScale = v
            case 7: let v = scale(); s.yScale = v; r.yScale = v
            case 8: let v = scale(); s.setScale(v); r.setScale(v)
            case 9: let v = value(-7, 7); s.zRotation = v; r.zRotation = v
            case 10 where s is PlazaCropNode: setMask(i, int(4) == 0 ? nil : CGRect(x: value(-50, 50), y: value(-50, 50), width: value(0, 80), height: value(0, 80)))
            default:
                let sp = s as! PlazaSprite, rp = r as! SKSpriteNode
                switch int(6) {
                case 0:
                    let t = int(textures.count + 1)
                    sp.texture = t < textures.count ? textures[t] : nil
                    rp.texture = t < textures.count ? rawTextures[t] : nil
                case 1: let v = CGSize(width: value(0, 120), height: value(0, 120)); sp.size = v; rp.size = v   // under any scale
                case 2: let v = CGPoint(x: value(0, 1), y: value(0, 1)); sp.anchorPoint = v; rp.anchorPoint = v
                case 3: let c = PlazaColor(srgbRed: unit(), green: unit(), blue: unit(), alpha: unit()); sp.color = c; rp.color = c.skColor
                case 4: let v = value(0, 1); sp.colorBlendFactor = v; rp.colorBlendFactor = v
                default:
                    let m = [PlazaBlendMode.alpha, .multiply, .multiplyX2][int(3)]
                    sp.blendMode = m; rp.blendMode = SpriteKitBackend.blendMode(m)
                }
            }
        }

        func readBack(_ i: Int) -> [String] {
            let s = w.shared[i], r = w.raw[i]
            var bad: [String] = []
            let b = PlazaMirrorParity.bits
            if b(s.position.x) != b(r.position.x) || b(s.position.y) != b(r.position.y) { bad.append("position") }
            if b(s.zPosition) != b(r.zPosition) { bad.append("z") }
            if b(s.alpha) != b(r.alpha) { bad.append("alpha") }
            if b(s.xScale) != b(r.xScale) || b(s.yScale) != b(r.yScale) { bad.append("scale") }
            if b(s.zRotation) != b(r.zRotation) { bad.append("rotation") }
            if s.isHidden != r.isHidden || s.name != r.name { bad.append("hidden/name") }
            if let sp = s as? PlazaSprite, let rp = r as? SKSpriteNode {
                if b(sp.size.width) != b(rp.size.width) || b(sp.size.height) != b(rp.size.height) { bad.append("size \(sp.size) vs \(rp.size)") }
                if b(sp.anchorPoint.x) != b(rp.anchorPoint.x) || b(sp.anchorPoint.y) != b(rp.anchorPoint.y) { bad.append("anchor") }
                if [sp.color.red, sp.color.green, sp.color.blue, sp.color.alpha].map({ CGFloat($0) }).map(b)
                    != [rp.color.redComponent, rp.color.greenComponent, rp.color.blueComponent, rp.color.alphaComponent].map(b) { bad.append("color") }
                if b(sp.colorBlendFactor) != b(rp.colorBlendFactor) { bad.append("cbf") }
                if rp.zRotation == 0 {
                    frames += 1
                    let fa = sp.frame, fb = rp.frame
                    if [fa.minX, fa.minY, fa.width, fa.height].map(b) == [fb.minX, fb.minY, fb.width, fb.height].map(b) { exactFrames += 1 }
                    if !PlazaMirrorParity.framesAgree(fa, fb) { bad.append("frame \(fa) vs \(fb)") }
                }
            }
            if let c = s as? PlazaCropNode, let rc = r as? SKCropNode {
                if let m = c.maskRect, let rm = rc.maskNode as? SKSpriteNode {
                    if [m.minX, m.minY, m.width, m.height].map(b) != [rm.position.x, rm.position.y, rm.size.width, rm.size.height].map(b) { bad.append("maskRect") }
                } else if (c.maskRect == nil) != (rc.maskNode == nil) { bad.append("mask nil-ness") }
            }
            return bad.map { "node \(i) (\(type(of: s))): \($0)" }
        }

        for _ in 0..<12 { create() }
        while ops < 2_000 {
            ops += 1
            switch int(20) {
            case 0, 1: create()
            case 2, 3, 4:   // add (to a mounted or to a detached parent: materialize-on-attach both ways)
                let free = (1..<w.shared.count).filter { w.shared[$0].parent == nil }
                guard let c = free.isEmpty ? nil : free[int(free.count)] else { continue }
                let parents = (0..<w.shared.count).filter { !isAncestor(w.shared[c], of: w.shared[$0]) }
                let p = parents[int(parents.count)]
                w.shared[p].addChild(w.shared[c]); w.raw[p].addChild(w.raw[c])
            case 5:   // remove; it may come back later (re-add)
                let attached = (1..<w.shared.count).filter { w.shared[$0].parent != nil }
                guard !attached.isEmpty else { continue }
                let c = attached[int(attached.count)]
                w.shared[c].removeFromParent(); w.raw[c].removeFromParent()
            case 6:
                if int(10) == 0 { let p = int(w.shared.count); w.shared[p].removeAllChildren(); w.raw[p].removeAllChildren() }
            case 7:
                if !mounted, ops > 300 { sharedRoot.mountInSpriteKit(containerA); mounted = true }   // a built tree, mounted late
            default:
                setProperty(int(w.shared.count))
            }
            for i in 0..<w.shared.count {
                let bad = readBack(i)
                if !bad.isEmpty { XCTFail("op \(ops): \(bad.joined(separator: "; "))\n" + (history[i] ?? []).suffix(8).joined(separator: "\n")); return }
            }
            if mounted {
                guard let a = sharedRoot.skNode else { XCTFail("mounted root has no copy"); return }
                let diff = PlazaMirrorParity.treeDifferences(a, rawRoot, sameTexture: sameTexture)
                if !diff.isEmpty { XCTFail("op \(ops): SpriteKit trees differ:\n" + diff.prefix(5).joined(separator: "\n")); return }
                let own = PlazaMirrorParity.differences(sharedRoot)
                if !own.isEmpty { XCTFail("op \(ops): shared tree and its copy differ:\n" + own.prefix(5).joined(separator: "\n")); return }
                mostMounted = max(mostMounted, sharedRoot.descendantCount)
            }
        }
        XCTAssertTrue(mounted)
        XCTAssertGreaterThan(mostMounted, 20, "the mounted tree grew (the operations did something)")
        print("PARITY: \(ops) operations, \(w.shared.count) nodes, up to \(mostMounted) mounted; frames bit-equal \(exactFrames) of \(frames)")
        XCTAssertGreaterThan(Double(exactFrames), 0.95 * Double(frames), "frame is bit-equal but for half-thousandths")
    }

    /// The pond layer's tree and its SpriteKit copy agree through splashes, bubbles, hiding and reuse, whether it was
    /// mounted before the nodes were made or after.
    func testMountedLayerMatchesItsMirror() throws {
        let tile = TilePoint(x: 5, y: 8)
        for mountFirst in [true, false] {
            let scene = SKScene(size: CGSize(width: 64, height: 64))
            let layer = PlazaPondLayer()
            if mountFirst { layer.root.mountInSpriteKit(scene) }
            layer.splash(at: tile, big: true)
            layer.bubble(at: tile)
            layer.update(dt: 0.1)
            if !mountFirst { layer.root.mountInSpriteKit(scene) }
            for step in 0..<40 {
                if step % 9 == 0 { layer.splash(at: tile, big: step % 2 == 0) }
                if step % 4 == 0 { layer.bubble(at: tile) }
                if step == 20 { layer.setHidden(true) }
                if step == 24 { layer.setHidden(false) }
                layer.update(dt: 1.0 / 60)
                XCTAssertEqual(PlazaMirrorParity.differences(layer.root), [], "step \(step), mounted first: \(mountFirst)")
            }
            XCTAssertTrue(scene.children.first === layer.root.skNode)
            XCTAssertGreaterThan(layer.root.children.count, 10)
        }
    }

    /// Risk R1: what a write costs through `PlazaSprite` and its mirror against the same write straight to an
    /// `SKSpriteNode`. 2,000 writes per frame (400 sprites x 5 properties), 3,000 frames. Two mixes: every write a new
    /// value (the worst case: compare and call on top of SpriteKit's own write), and one write in five new (a layout
    /// pass that sets everything every frame). `PTB_PLAZA_WRITECOST_OUT=<file>` appends the result line.
    func testWriteThroughCost() throws {
        guard let out = PlazaRenderEnv.value("PTB_PLAZA_WRITECOST_OUT") else { throw XCTSkip("PTB_PLAZA_WRITECOST_OUT not set") }
        let frames = 3_000, count = 400
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }
        var line = ""
        for (label, everyFrame) in [("all-new", true), ("one-in-five", false)] {
            var best = (direct: Double.infinity, shared: Double.infinity)
            for _ in 0..<3 {
                let scene = SKScene(size: CGSize(width: 64, height: 64))
                let direct = (0..<count).map { _ in SKSpriteNode() }
                direct.forEach(scene.addChild)
                let root = PlazaNode()
                root.mountInSpriteKit(scene)
                let shared = (0..<count).map { _ in PlazaSprite() }
                shared.forEach(root.addChild)
                let d = ms(clock.measure {
                    for f in 0..<frames {
                        let v = CGFloat(f)
                        for (i, n) in direct.enumerated() {
                            let k = v + CGFloat(i)
                            n.position = CGPoint(x: k, y: k)
                            n.alpha = everyFrame ? k / 9000 : 1
                            n.zPosition = everyFrame ? k : 2
                            n.isHidden = everyFrame ? f % 2 == 0 : false
                            n.size = everyFrame ? CGSize(width: k, height: k) : CGSize(width: 6, height: 6)
                        }
                    }
                })
                let s = ms(clock.measure {
                    for f in 0..<frames {
                        let v = CGFloat(f)
                        for (i, n) in shared.enumerated() {
                            let k = v + CGFloat(i)
                            n.position = CGPoint(x: k, y: k)
                            n.alpha = everyFrame ? k / 9000 : 1
                            n.zPosition = everyFrame ? k : 2
                            n.isHidden = everyFrame ? f % 2 == 0 : false
                            n.size = everyFrame ? CGSize(width: k, height: k) : CGSize(width: 6, height: 6)
                        }
                    }
                })
                best = (min(best.direct, d), min(best.shared, s))
                XCTAssertEqual(PlazaMirrorParity.differences(root).count, 0)
            }
            line += String(format: "%@ direct %.1f ms shared %.1f ms ratio %.3f  ", label, best.direct, best.shared, best.shared / best.direct)
        }
        print("WRITECOST: " + line)
        let url = URL(fileURLWithPath: out)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
