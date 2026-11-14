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

/// What `testActorPlacementMatchesTheLegacyActor` drives and reads; `PlazaActor` and `LegacyPlazaActor` both have it.
@MainActor
protocol PlazaActorUnderTest: AnyObject {
    func setFrames(_ f: PlazaCharacterFrames)
    func setName(_ name: String, color: PlazaColor)
    func setTitle(_ title: String?)
    func showEmote(_ kind: TeamEmoteKind)
    func showChat(_ text: String)
    func showWet()
    func jump()
    func lunge(toward d: PlazaDirection)
    func wobble()
    func startDance(_ style: PlazaDance.Style, offset: TimeInterval, length: TimeInterval)
    func stopDance()
    func takeFinishedDance() -> Bool
    func animate(by dt: TimeInterval, useBack: Bool)
    func place(foot: CGPoint, pose: PlazaSpriteChoice, in context: PlazaActorContext, concealment: CGFloat, isMe: Bool,
               swimSink: CGFloat, waterRect: CGRect?)
    func photoActor(foot rawFoot: CGPoint, pose: PlazaSpriteChoice, waterClip: CGRect?) -> PlazaPhotoActor?
    var isWet: Bool { get }
    var emoteKind: TeamEmoteKind? { get }
    var chatText: String? { get }
    var name: String { get }
    var title: String? { get }
    var nameColor: PlazaColor { get }
    var wobbleTilt: CGFloat { get }
    var isDancing: Bool { get }
    var isBubbleShown: Bool { get }
    var dancePose: PlazaDancePose { get }
    var jumpLift: CGFloat { get }
    var lungeOffset: CGPoint { get }
    var concealment: CGFloat { get }
    var isMeForConcealment: Bool { get }
    var cameraLift: CGFloat { get }
    var groundShadowSize: (width: Int, height: Int) { get }
    var isOnNest: Bool { get }
    var nestFrontIsInFront: Bool { get }
    var groundShadowY: CGFloat { get }
    var characterX: CGFloat { get }
    var characterY: CGFloat { get }
    var characterZ: CGFloat { get }
    var characterOpacity: CGFloat { get }
    var nestFrontOpacity: CGFloat { get }
    var shadowOpacity: CGFloat { get }
    var visibleSpriteHeight: CGFloat { get }
    var isSubmergedBodyVisible: Bool { get }
    var submergedBodyAlpha: CGFloat { get }
    var submergedBodyTopY: CGFloat { get }
    var submergedBodySize: CGSize { get }
    var submergedBodyTextureRect: CGRect { get }
    var submergedBodyClip: CGRect? { get }
    var isSwimRingVisible: Bool { get }
    var swimRingY: CGFloat { get }
    var fullSpriteHeight: CGFloat { get }
    var characterSize: CGSize { get }
    var namePlatePosition: CGPoint { get }
    var namePlateWidth: CGFloat { get }
    var namePlateTop: CGFloat { get }
    var emoteFrame: CGRect? { get }
    var isNamePlateVisible: Bool { get }
}
extension PlazaActor: PlazaActorUnderTest {}
extension LegacyPlazaActor: PlazaActorUnderTest {}

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

    /// What one differential run found: the first difference (nil: none) and how much it exercised.
    struct FuzzResult { var failure: String?; var operations = 0; var nodes = 0; var mostMounted = 0; var frames = 0; var exactFrames = 0; var rootMoves = 0; var detachedChecks = 0 }

    /// Seeded random node operations applied to shared nodes (whose SpriteKit copies the backend keeps) and, the same
    /// way, to SpriteKit nodes built by hand as the plaza built them; the two SpriteKit trees must stay equal, and every
    /// shared value must read back what the hand-built SpriteKit node reads. Two roots are mounted late, then unmounted,
    /// remounted and moved under each other (the bridge's mount and remove paths).
    func testRandomOperationsLeaveTheSameSpriteKitTree() {
        let r = runFuzz(seed: 0x7_1E57_AB1E, operations: 2_000)
        XCTAssertNil(r.failure, r.failure ?? "")
        XCTAssertGreaterThan(r.mostMounted, 20, "the mounted trees grew (the operations did something)")
        XCTAssertGreaterThan(r.rootMoves, 10, "roots were unmounted, remounted and moved")
        XCTAssertGreaterThan(Double(r.exactFrames), 0.95 * Double(r.frames), "frame is bit-equal but for half-thousandths")
        XCTAssertGreaterThan(r.detachedChecks, 1_000, "detached subtrees with copies were compared")
        print("PARITY: \(r.operations) operations, \(r.nodes) nodes, up to \(r.mostMounted) mounted, \(r.rootMoves) root moves, \(r.detachedChecks) detached-copy checks; frames bit-equal \(r.exactFrames) of \(r.frames)")
    }

    func runFuzz(seed: UInt64, operations: Int) -> FuzzResult {
        var result = FuzzResult()
        var rng = PlazaSplitMix64(seed: seed)
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
        for (i, (t, raw)) in zip(textures, rawTextures).enumerated() where t.pixelSize != raw.size() {
            result.failure = "texture \(i): pixelSize \(t.pixelSize) is not SKTexture.size() \(raw.size())"
            return result
        }
        func sameTexture(_ a: SKTexture, _ b: SKTexture) -> Bool {
            guard let i = textures.firstIndex(where: { $0.nativeCache === a }) else { return false }
            return rawTextures[i] === b
        }

        var w = Worlds()
        var frames = 0, exactFrames = 0
        // nodes 0 and 1 are roots: mounted straight into SpriteKit (`containerA`), as the bridge mounts layers
        for _ in 0..<2 { w.shared.append(PlazaNode()); w.raw.append(SKNode()) }
        let containerA = SKNode(), containerB = SKNode()
        var mountedRoots = [false, false]   // the root's copy is a direct child of containerA
        var ops = 0
        var mostMounted = 0
        func mount(_ r: Int) { w.shared[r].mountInSpriteKit(containerA); containerB.addChild(w.raw[r]); mountedRoots[r] = true }
        func unmount(_ r: Int) { w.shared[r].removeFromParent(); w.raw[r].removeFromParent(); mountedRoots[r] = false }

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
        while ops < operations {
            ops += 1
            switch int(20) {
            case 0, 1: create()
            case 2, 3, 4:   // add (to a mounted or to a detached parent: materialize-on-attach both ways)
                let free = (2..<w.shared.count).filter { w.shared[$0].parent == nil }
                guard let c = free.isEmpty ? nil : free[int(free.count)] else { continue }
                let parents = (0..<w.shared.count).filter { !isAncestor(w.shared[c], of: w.shared[$0]) }
                let p = parents[int(parents.count)]
                w.shared[p].addChild(w.shared[c]); w.raw[p].addChild(w.raw[c])
            case 5:   // remove; it may come back later (re-add)
                let attached = (2..<w.shared.count).filter { w.shared[$0].parent != nil }
                guard !attached.isEmpty else { continue }
                let c = attached[int(attached.count)]
                w.shared[c].removeFromParent(); w.raw[c].removeFromParent()
            case 6:
                if int(10) == 0 { let p = int(w.shared.count); w.shared[p].removeAllChildren(); w.raw[p].removeAllChildren() }
            case 7 where ops > 300:   // the roots: built first, mounted late, then unmounted, remounted, moved
                if !mountedRoots[0] && !mountedRoots[1] && result.rootMoves == 0 { mount(0); mount(1); result.rootMoves += 1; break }
                let r = int(2), other = 1 - r
                result.rootMoves += 1
                if w.shared[r].parent != nil {   // under the other root: take it out and mount it again
                    w.shared[r].removeFromParent(); w.raw[r].removeFromParent(); mount(r)
                } else if !mountedRoots[r] {
                    mount(r)
                } else if int(2) == 0 {
                    unmount(r)
                } else if !isAncestor(w.shared[r], of: w.shared[other]) {   // move under the other root (mirrored or not)
                    unmount(r)
                    w.shared[other].addChild(w.shared[r]); w.raw[other].addChild(w.raw[r])
                }
            default:
                setProperty(int(w.shared.count))
            }
            func fail(_ message: String) -> FuzzResult {
                result.failure = "op \(ops): " + message
                result.operations = ops
                return result
            }
            for i in 0..<w.shared.count {
                let bad = readBack(i)
                if !bad.isEmpty { return fail(bad.joined(separator: "; ") + "\n" + (history[i] ?? []).suffix(8).joined(separator: "\n")) }
            }
            let diff = PlazaMirrorParity.treeDifferences(containerA, containerB, sameTexture: sameTexture)
            if !diff.isEmpty { return fail("SpriteKit trees differ:\n" + diff.prefix(5).joined(separator: "\n")) }
            for r in 0..<2 where mountedRoots[r] {
                let own = PlazaMirrorParity.differences(w.shared[r])
                if !own.isEmpty { return fail("root \(r) and its copy differ:\n" + own.prefix(5).joined(separator: "\n")) }
            }
            // detached subtrees that keep their copies (removed, or never mounted since): compared before they come back
            for i in 0..<w.shared.count where w.shared[i].parent == nil && !(i < 2 && mountedRoots[i]) {
                guard let copy = w.shared[i].skNode else { continue }
                if copy.parent != nil { return fail("node \(i) is detached but its copy is still in a SpriteKit tree") }
                let d = PlazaMirrorParity.treeDifferences(copy, w.raw[i], sameTexture: sameTexture)
                    + PlazaMirrorParity.differences(w.shared[i])
                if !d.isEmpty { return fail("detached node \(i) and its copy differ:\n" + d.prefix(5).joined(separator: "\n")) }
                result.detachedChecks += 1
            }
            mostMounted = max(mostMounted, (0..<2).filter { mountedRoots[$0] }.reduce(0) { $0 + w.shared[$1].descendantCount })
        }
        result.operations = ops
        result.nodes = w.shared.count
        result.mostMounted = mostMounted
        result.frames = frames
        result.exactFrames = exactFrames
        return result
    }

    /// Every write-through, switched off in turn (debug builds only), must make the differential test fail: proof that
    /// the operation mix exercises every mirrored property and both tree operations.
    func testEveryMissedWriteIsNoticed() throws {
        #if DEBUG
        var caught: [String] = []
        for write in SpriteKitMirrorFaults.Write.allCases {
            SpriteKitMirrorFaults.dropped = [write]
            let r = runFuzz(seed: 0x7_1E57_AB1E, operations: 2_000)
            SpriteKitMirrorFaults.dropped = []
            XCTAssertNotNil(r.failure, "a missed \(write) write went unnoticed")
            if let f = r.failure { caught.append("\(write) at \(f.prefix(while: { $0 != ":" }))") }
        }
        print("FAULTS caught: " + caught.joined(separator: ", "))
        #else
        throw XCTSkip("the write-through fault switches exist in debug builds only")
        #endif
    }

    /// Releasing a mounted root without `removeFromParent()` leaves its copy drawn, as releasing the reference to an
    /// `SKNode` layer did (SpriteKit owns what is in its tree); a detached node's copy goes with the node.
    func testReleasingASharedNodeLeavesWhatSpriteKitOwns() {
        let scene = SKScene(size: CGSize(width: 64, height: 64))
        weak var sharedRoot: PlazaNode?
        weak var rootCopy: SKNode?
        weak var detachedCopy: SKNode?
        autoreleasepool {
            let root = PlazaNode()
            let s = PlazaSprite(color: .white, size: CGSize(width: 4, height: 4))
            s.position = CGPoint(x: 3, y: 4)
            root.addChild(s)
            root.mountInSpriteKit(scene)
            let gone = PlazaSprite()
            root.addChild(gone)
            detachedCopy = gone.skNode
            gone.removeFromParent()
            sharedRoot = root
            rootCopy = root.skNode
        }
        XCTAssertNil(sharedRoot, "SpriteKit keeps no shared node alive")
        XCTAssertNil(detachedCopy, "a detached node's copy goes with the node")
        XCTAssertTrue(rootCopy?.parent === scene, "the mounted copy stays in the scene")
        XCTAssertEqual(rootCopy?.children.count, 1)
        XCTAssertEqual(rootCopy?.children.first?.position, CGPoint(x: 3, y: 4), "as it was last written")
    }

    /// The camera's copy is an `SKCameraNode` and works as the scene's camera: the same pixels as a hand-built camera,
    /// before and after it moves and zooms.
    func testTheCameraCopyWorksAsTheScenesCamera() throws {
        let rendererA = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        let rendererB = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        let red = PlazaColor(srgbRed: 1, green: 0, blue: 0), blue = PlazaColor(srgbRed: 0, green: 0, blue: 1)
        let a = SKScene(size: CGSize(width: 64, height: 64)), b = SKScene(size: CGSize(width: 64, height: 64))
        let root = PlazaNode()
        let world = PlazaSprite(color: red, size: CGSize(width: 20, height: 20))
        world.position = CGPoint(x: 40, y: 30); world.zPosition = 1
        let camera = PlazaCameraNode()
        camera.position = CGPoint(x: 40, y: 30)
        let hud = PlazaSprite(color: blue, size: CGSize(width: 8, height: 8))
        hud.position = CGPoint(x: -20, y: -20); hud.zPosition = 5
        camera.addChild(hud)
        root.addChild(world); root.addChild(camera)
        root.mountInSpriteKit(a)
        a.camera = camera.skNode as? SKCameraNode
        XCTAssertNotNil(a.camera, "the camera's copy is an SKCameraNode")
        let rawWorld = SKSpriteNode(color: red.skColor, size: CGSize(width: 20, height: 20))
        rawWorld.position = CGPoint(x: 40, y: 30); rawWorld.zPosition = 1
        let rawCamera = SKCameraNode()
        rawCamera.position = CGPoint(x: 40, y: 30)
        let rawHud = SKSpriteNode(color: blue.skColor, size: CGSize(width: 8, height: 8))
        rawHud.position = CGPoint(x: -20, y: -20); rawHud.zPosition = 5
        rawCamera.addChild(rawHud)
        let rawRoot = SKNode()
        rawRoot.addChild(rawWorld); rawRoot.addChild(rawCamera)
        b.addChild(rawRoot)
        b.camera = rawCamera
        func render() -> ([UInt8], [UInt8]) {
            for _ in 0..<6 {
                rendererA.pass(a, points: a.size, pixels: (64, 64), time: 0)
                rendererB.pass(b, points: b.size, pixels: (64, 64), time: 0)
            }
            return (rendererA.bytes(), rendererB.bytes())
        }
        var (pa, pb) = render()
        XCTAssertEqual(pa, pb, "same pixels as a hand-built camera")
        XCTAssertTrue(stride(from: 0, to: pa.count, by: 4).contains { pa[$0] == 255 && pa[$0 + 2] == 0 }, "the screen-space sprite is drawn")
        XCTAssertTrue(stride(from: 0, to: pa.count, by: 4).contains { pa[$0 + 2] == 255 && pa[$0] == 0 }, "the world sprite is drawn")
        camera.position = CGPoint(x: 30, y: 20); camera.setScale(0.5)
        rawCamera.position = CGPoint(x: 30, y: 20); rawCamera.setScale(0.5)
        (pa, pb) = render()
        XCTAssertEqual(pa, pb, "and after the camera moves and zooms")
        XCTAssertEqual(PlazaMirrorParity.differences(root), [])
    }

    /// The bridge (Tasks 7–9): a root mounted straight into SpriteKit can be taken out again, mounted again and moved
    /// under a mounted shared parent; each time the SpriteKit tree follows.
    func testAMountedRootRemovedFromItsParentIsGoneFromTheSpriteKitTree() {
        let scene = SKScene(size: CGSize(width: 64, height: 64))
        let root = PlazaNode(), child = PlazaSprite(color: .white, size: CGSize(width: 4, height: 4))
        root.addChild(child)
        root.mountInSpriteKit(scene)
        XCTAssertTrue(root.skNode?.parent === scene)
        root.removeFromParent()
        XCTAssertNil(root.skNode?.parent, "a mounted root removed from its parent is gone from the SpriteKit tree")
        XCTAssertTrue(scene.children.isEmpty)
        guard root.skNode?.parent == nil else { return }   // mounting again would raise in SpriteKit
        root.mountInSpriteKit(scene)
        XCTAssertTrue(root.skNode?.parent === scene, "a removed root mounts again")
        let other = PlazaNode()
        other.mountInSpriteKit(scene)
        root.removeFromParent()
        other.addChild(root)
        XCTAssertTrue(root.skNode?.parent === other.skNode, "a removed root moves under a mounted shared parent")
        XCTAssertEqual(scene.children.count, 1)
        XCTAssertEqual(PlazaMirrorParity.differences(other), [])
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

    /// Task 9: the actor on the shared node tree, mounted through the bridge, leaves the same SpriteKit nodes with the same
    /// values as the SpriteKit actor before it (`LegacyPlazaActor`), frame by frame, through every state it draws:
    /// walking and turning (flip, back), every dance style (tilt, squash, lift, flip, side step), jump, lunge, wobble, a
    /// swim in and between two ponds and outside one (cut, ghost crop, ring), an egg on its nest and sunk, tall-grass
    /// concealment (mine and a teammate's), wet, emotes, wide and short chat bubbles, name and title changes, an empty name,
    /// backing 1 and 2, an odd viewport and two form changes. Textures must be shared exactly where the old ones were
    /// (a one-to-one map between the two worlds' textures), and every accessor and photo value must be bit-equal.
    func testActorPlacementMatchesTheLegacyActor() {
        let legacyWorld = SKNode(), legacyCamera = SKCameraNode()
        let world = SKNode(), camera = SKCameraNode()
        let a = LegacyPlazaActor(name: "Ash", color: PlazaNameColor.palette[2])
        let b = PlazaActor(name: "Ash", color: PlazaNameColor.palette[2])
        a.attach(world: legacyWorld, camera: legacyCamera)
        b.attach(world: world, camera: camera)
        let actors: [any PlazaActorUnderTest] = [a, b]
        func all(_ body: (any PlazaActorUnderTest) -> Void) { actors.forEach(body) }

        // a one-to-one map legacy texture <-> new texture, made on first sight when the pictures are equal; every texture
        // seen is kept so a freed one's address cannot come back as another texture
        var forward: [ObjectIdentifier: SKTexture] = [:], backward: [ObjectIdentifier: SKTexture] = [:], kept: [SKTexture] = []
        func picture(_ t: SKTexture) -> Data? { let i = t.cgImage(); return (i.dataProvider?.data as Data?).map { Data("\(i.width)x\(i.height)".utf8) + $0 } }
        func same(_ x: SKTexture, _ y: SKTexture) -> Bool {
            if let m = forward[ObjectIdentifier(x)] { return m === y }
            guard backward[ObjectIdentifier(y)] == nil, picture(x) == picture(y) else { return false }
            forward[ObjectIdentifier(x)] = y; backward[ObjectIdentifier(y)] = x; kept += [x, y]
            return true
        }

        let normal = Self.oddFrames(), egg = PlazaRenderScenes.frames(.egg), other = PlazaRenderScenes.frames(.brock)
        let pond = CGRect(x: 40.3, y: 300.7, width: 160.1, height: 48.45), pond2 = CGRect(x: 36.6, y: 296.2, width: 170.9, height: 60.35)
        let palette = PlazaNameColor.palette
        let styles = PlazaDance.Style.allCases
        var facing = PlazaDirection.down, walking = false, foot = CGPoint(x: 120.25, y: 400.5)
        var swim = false, water: CGRect?, concealment: CGFloat = 0, isMe = false, backing: CGFloat = 2
        var viewport = CGSize(width: 640, height: 480)
        var checkedPhotos = 0, swimFrames = 0, flippedFrames = 0, tiltedFrames = 0
        for f in 0..<540 {
            switch f {
            case 0: all { $0.setFrames(normal); $0.setTitle("Brave") }
            case 6: all { $0.showEmote(.heart) }
            case 20: facing = .right; walking = true
            case 24: all { $0.showChat("hello there, a bubble wide enough to be pushed back in") }
            case 40: all { $0.jump() }
            case 55: all { $0.lunge(toward: .left) }; facing = .up
            case 66: all { $0.showChat("ok") }
            case 70: walking = false; facing = .down
            case 280: all { $0.stopDance() }
            case 290: swim = true; water = pond; walking = true; facing = .left
            case 300: all { $0.showWet() }
            case 315: water = pond2
            case 330: water = nil
            case 340: water = pond; facing = .right
            case 350: swim = false; water = nil; walking = false
            case 360: concealment = 0.5
            case 370: isMe = true
            case 380: concealment = 1; isMe = false
            case 390: concealment = 0
            case 395: all { $0.setName("", color: palette[3]) }
            case 405: all { $0.setName("Misty", color: palette[4]); $0.setTitle(nil) }
            case 410: backing = 1; viewport = CGSize(width: 641, height: 481)
            case 420: all { $0.setFrames(egg) }
            case 430: all { $0.wobble() }
            case 450: swim = true; water = pond
            case 470: water = pond2
            case 480: swim = false; water = nil
            case 490: all { $0.setFrames(other) }; backing = 2; viewport = CGSize(width: 640, height: 480)
            case 500: all { $0.wobble(); $0.jump() }; facing = .left; walking = true
            case 520: all { $0.startDance(.twirl, offset: 0, length: 0.5) }
            default: break
            }
            if f >= 70, f < 280, (f - 70) % 30 == 0 { all { $0.startDance(styles[(f - 70) / 30 % styles.count], offset: 0.05, length: PlazaDance.round) } }
            if walking { foot.x += facing == .left ? -0.73 : 0.61; foot.y += 0.17 }
            let pose = PlazaPose.choice(facing: facing, isWalking: walking, clock: Double(f) / 60)
            all { $0.animate(by: 1.0 / 60, useBack: pose.useBack) }
            XCTAssertEqual(a.takeFinishedDance(), b.takeFinishedDance(), "frame \(f): dance end")
            let sink = swim ? PlazaPond.swimSink(spriteHeight: b.fullSpriteHeight) : 0
            let context = PlazaActorContext(worldHeight: 1024, cameraPosition: CGPoint(x: foot.x + 13.5, y: 1024 - foot.y + 20.25),
                                            zoom: 2, backing: backing, viewport: viewport)
            all { $0.place(foot: foot, pose: pose, in: context, concealment: concealment, isMe: isMe, swimSink: sink, waterRect: water) }

            var diffs = PlazaMirrorParity.treeDifferences(legacyWorld, world, sameTexture: same)
                + PlazaMirrorParity.treeDifferences(legacyCamera, camera, sameTexture: same)
                + (b.worldNodes + b.cameraNodes).flatMap { PlazaMirrorParity.differences($0) }
            for (x, y) in zip(Self.readings(a), Self.readings(b)) where x != y { diffs.append("accessor \(x) | \(y)") }
            if f % 9 == 0 {
                let pa = a.photoActor(foot: foot, pose: pose, waterClip: water), pb = b.photoActor(foot: foot, pose: pose, waterClip: water)
                if Self.photoReadings(pa) != Self.photoReadings(pb) {
                    diffs.append("photo \(Self.photoReadings(pa)) | \(Self.photoReadings(pb))")
                }
                checkedPhotos += 1
            }
            guard diffs.isEmpty else { return XCTFail("frame \(f):\n" + diffs.prefix(6).joined(separator: "\n")) }
            if b.isSubmergedBodyVisible { swimFrames += 1 }
            if world.children[1].xScale < 0 { flippedFrames += 1 }
            if world.children[1].zRotation != 0 { tiltedFrames += 1 }
        }
        XCTAssertGreaterThan(swimFrames, 50, "the ghost crop was drawn")
        XCTAssertGreaterThan(flippedFrames, 20, "the picture was flipped")
        XCTAssertGreaterThan(tiltedFrames, 20, "the picture was tilted")
        XCTAssertGreaterThan(checkedPhotos, 50)
        XCTAssertGreaterThan(forward.count, 20, "textures were compared")
        print("ACTOR PARITY: 540 frames, \(forward.count) textures mapped, \(swimFrames) swim frames, \(checkedPhotos) photo checks")
    }

    /// Three front and two back frames of an odd size (27x33), so the picture lands on half pixels.
    private static func oddFrames() -> PlazaCharacterFrames {
        func image(_ seed: Int) -> PlazaImage {
            let (w, h) = (27, 33)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            for y in 2..<h { for x in 1..<(w - 1) where (x * 7 + y * 3 + seed) % 5 != 0 {
                let i = (y * w + x) * 4
                px[i] = UInt8((x * 9 + seed * 40) % 256); px[i + 1] = UInt8((y * 7) % 256); px[i + 2] = UInt8((seed * 60) % 256); px[i + 3] = 255
            } }
            return PlazaImage(cgImage: PlazaRenderScenes.image(px, width: w, height: h))
        }
        return PlazaCharacterFrames(front: (0..<3).map { PlazaFrame(image: image($0), delay: 0.05) },
                                    back: (3..<5).map { PlazaFrame(image: image($0), delay: 0.07) })
    }

    /// Every accessor of an actor as exact text (Double descriptions round-trip).
    private static func readings(_ x: any PlazaActorUnderTest) -> [String] {
        ["isWet \(x.isWet)", "emoteKind \(String(describing: x.emoteKind))", "chatText \(String(describing: x.chatText))",
         "name \(x.name)", "title \(String(describing: x.title))", "nameColor \(x.nameColor)", "wobbleTilt \(x.wobbleTilt)",
         "isDancing \(x.isDancing)", "isBubbleShown \(x.isBubbleShown)", "dancePose \(x.dancePose)", "jumpLift \(x.jumpLift)",
         "lungeOffset \(x.lungeOffset)", "concealment \(x.concealment) \(x.isMeForConcealment)", "cameraLift \(x.cameraLift)",
         "groundShadowSize \(x.groundShadowSize)", "isOnNest \(x.isOnNest)", "nestFrontIsInFront \(x.nestFrontIsInFront)",
         "groundShadowY \(x.groundShadowY)", "character \(x.characterX) \(x.characterY) \(x.characterZ) \(x.characterSize)",
         "opacity \(x.characterOpacity) \(x.nestFrontOpacity) \(x.shadowOpacity)", "visibleSpriteHeight \(x.visibleSpriteHeight)",
         "submerged \(x.isSubmergedBodyVisible) \(x.submergedBodyAlpha) \(x.submergedBodyTopY) \(x.submergedBodySize)",
         "submergedBodyTextureRect \(x.submergedBodyTextureRect)", "submergedBodyClip \(String(describing: x.submergedBodyClip))",
         "swimRing \(x.isSwimRingVisible) \(x.swimRingY)", "fullSpriteHeight \(x.fullSpriteHeight)",
         "plate \(x.namePlatePosition) \(x.namePlateWidth) \(x.namePlateTop) \(x.isNamePlateVisible)",
         "emoteFrame \(String(describing: x.emoteFrame))"]
    }

    private static func photoReadings(_ p: PlazaPhotoActor?) -> [String] {
        guard let p else { return ["no photo"] }
        func picture(_ i: PlazaImage?) -> String {
            guard let c = i?.cgImage else { return "nil" }
            return "\(c.width)x\(c.height) \(c.bitmapInfo.rawValue) \(c.colorSpace?.name.map { $0 as String } ?? "-") \(PlazaRenderRun.hex(Array((c.dataProvider?.data as Data?) ?? Data())))"
        }
        return ["image \(ObjectIdentifier(p.image.cgImage))", "shadow \(picture(p.shadow))", "front \(picture(p.front))",
                "plate \(picture(p.plate))", "bubble \(picture(p.bubble))",
                "flipped \(p.flipped) foot \(p.foot) bob \(p.bob) scale \(p.scale) shadowRect \(p.shadowRect)",
                "opacity \(p.opacity) plateBaseY \(String(describing: p.plateBaseY)) sink \(p.sink) waterClip \(String(describing: p.waterClip))",
                "eggSunk \(p.eggSunk) lift \(p.lift) squash \(p.squash) tilt \(p.tilt)"]
    }

    /// The defect the Task 7 review predicted: a member who leaves, and the Ditto when it goes, must take every node of
    /// its actor out of the SpriteKit tree, not only out of the shared one. Through the scene's own calls.
    func testADetachedActorIsGoneFromTheSpriteKitTree() throws {
        let s = PlazaRenderScenes.stage()
        s.put([PlazaRenderScenes.member("ash", "Ash", 21, 10), PlazaRenderScenes.member("swim", "Swim", 9, 14)],
              looks: ["ash": .ash, "swim": .misty])
        s.scene.applyDitto(PlazaDittoShown(tile: TilePoint(x: 17, y: 10), facing: .down, isWalking: false, isRunning: false,
                                           name: "Ditto", nameColor: PlazaNameColor.palette[1], title: nil, isDecoy: false))
        s.scene.setMemberFrames(PlazaDitto.sceneKey, PlazaRenderScenes.frames(.ditto))
        s.scene.showChat(memberID: "swim", text: "bye")
        s.scene.memberActor("ash")?.showWet()
        for f in 0..<6 { s.scene.update(Double(f) / 60) }
        let camera = try XCTUnwrap(s.scene.camera)
        let leaving = ["ash", "swim", PlazaDitto.sceneKey].compactMap { s.scene.memberActor($0) }
        XCTAssertEqual(leaving.count, 3)
        XCTAssertTrue(try XCTUnwrap(s.scene.memberActor("swim")).isSubmergedBodyVisible, "the swimmer's ghost crop is drawn")
        let world = leaving.flatMap(\.worldNodes), hud = leaving.flatMap(\.cameraNodes)
        XCTAssertTrue(world.allSatisfy { $0.skNode?.parent === s.scene } && hud.allSatisfy { $0.skNode?.parent === camera }, "mounted while present")
        let (sceneCount, cameraCount) = (s.scene.children.count, camera.children.count)

        s.put([])
        s.scene.applyDitto(nil)
        for node in world + hud {
            XCTAssertNil(node.skNode?.parent, "\(type(of: node)) left the SpriteKit tree")
            XCTAssertNil(node.parent)
        }
        XCTAssertEqual(s.scene.children.count, sceneCount - world.count)
        XCTAssertEqual(camera.children.count, cameraCount - hud.count)
        for f in 6..<12 { s.scene.update(Double(f) / 60) }
        XCTAssertTrue((world + hud).allSatisfy { $0.skNode?.parent == nil }, "and stay out while the scene runs")
        XCTAssertTrue(s.scene.myActor.worldNodes.allSatisfy { $0.skNode?.parent === s.scene }, "my actor stays")
        XCTAssertEqual(PlazaRenderHarness.actorMountDifferences(of: s.scene), [])
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
