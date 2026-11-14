import XCTest
@testable import PokeTokenBar

/// A backend that only records what reaches it (the write-through contract).
@MainActor
final class PlazaRecordingMirror: PlazaNodeMirror {
    private(set) var calls: [String] = []
    override func insertChild(_ child: PlazaNode, at index: Int) {
        calls.append("insert \(index)")
        if child.mirror == nil { child.installMirror(PlazaRecordingMirror()) }
    }
    override func removeFromParent() { calls.append("remove") }
    override func setName(_ v: String?) { calls.append("name \(v ?? "-")") }
    override func setPosition(_ v: CGPoint) { calls.append("position \(v.x),\(v.y)") }
    override func setZPosition(_ v: CGFloat) { calls.append("z \(v)") }
    override func setAlpha(_ v: CGFloat) { calls.append("alpha \(v)") }
    override func setHidden(_ v: Bool) { calls.append("hidden \(v)") }
    override func setScale(x: CGFloat, y: CGFloat) { calls.append("scale \(x),\(y)") }
    override func setZRotation(_ v: CGFloat) { calls.append("rotation \(v)") }
    override func setTexture(_ v: PlazaTexture?) { calls.append(v == nil ? "texture nil" : "texture") }
    override func setSize(_ v: CGSize) { calls.append("size \(v.width)x\(v.height)") }
    override func setAnchorPoint(_ v: CGPoint) { calls.append("anchor \(v.x),\(v.y)") }
    override func setColor(_ v: PlazaColor) { calls.append("color") }
    override func setColorBlendFactor(_ v: CGFloat) { calls.append("factor \(v)") }
    override func setBlendMode(_ v: PlazaBlendMode) { calls.append("blend \(v)") }
    override func setMaskRect(_ v: CGRect?) { calls.append("mask") }
}

@MainActor
final class PlazaNodeTests: XCTestCase {
    private func ids(_ nodes: [PlazaNode]) -> [ObjectIdentifier] { nodes.map(ObjectIdentifier.init) }

    func testAddChildKeepsOrderAndParent() async {
        let root = PlazaNode()
        let a = PlazaNode(), b = PlazaSprite(), c = PlazaCropNode()
        for n in [a, b, c] { root.addChild(n) }
        XCTAssertEqual(ids(root.children), ids([a, b, c]))
        XCTAssertTrue(a.parent === root && b.parent === root && c.parent === root)
        a.removeFromParent()
        root.addChild(a)
        XCTAssertEqual(ids(root.children), ids([b, c, a]), "re-adding appends, as SpriteKit does")
        let leaf = PlazaSprite()
        c.addChild(leaf)
        XCTAssertTrue(leaf.parent === c)
        XCTAssertEqual(root.descendantCount, 4)
        XCTAssertEqual(c.descendantCount, 1)
    }

    func testRemoveFromParentDetaches() async {
        let root = PlazaNode()
        let kids = (0..<4).map { _ in PlazaSprite() }
        kids.forEach(root.addChild)
        kids[1].removeFromParent()
        XCTAssertNil(kids[1].parent)
        XCTAssertEqual(ids(root.children), ids([kids[0], kids[2], kids[3]]))
        kids[1].removeFromParent()   // already out: nothing happens
        XCTAssertEqual(root.children.count, 3)
        for child in root.children where child === kids[2] { child.removeFromParent() }   // children is a copy
        XCTAssertEqual(ids(root.children), ids([kids[0], kids[3]]))
        root.removeAllChildren()
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertTrue(kids.allSatisfy { $0.parent == nil })
        root.addChild(kids[0])   // a removed node can be added again
        XCTAssertTrue(kids[0].parent === root)
    }

    /// The `SpriteKitSemanticsTests` probes and the Task 7 probes, as expectations.
    func testSpriteSizeFollowsTheSpriteKitScaleModel() async {
        let s = PlazaSprite(color: .white, size: CGSize(width: 10, height: 20))
        s.xScale = 2; s.yScale = 3
        XCTAssertEqual(s.size, CGSize(width: 20, height: 60), "size reads the unscaled size times |scale|")
        s.setScale(1); s.xScale = -1
        XCTAssertEqual(s.size, CGSize(width: 10, height: 20), "a flip never makes the width negative")
        s.setScale(2)
        XCTAssertEqual(s.size, CGSize(width: 20, height: 40))

        let t = PlazaSprite(color: .white, size: CGSize(width: 10, height: 20))
        t.xScale = 2
        t.size = CGSize(width: 30, height: 40)
        XCTAssertEqual(t.size, CGSize(width: 30, height: 40), "right after the assignment, size reads what was assigned")
        t.xScale = 1
        XCTAssertEqual(t.size, CGSize(width: 15, height: 40), "the setter stores assigned / scale")
        XCTAssertEqual(t.unscaledSize, CGSize(width: 15, height: 40))

        // SpriteKit divides only by positive scales (probe): under -2 an assigned 30 is stored as 30 and reads 60.
        for (scale, reads, resetReads): (CGFloat, CGFloat, CGFloat) in [(-2, 60, 30), (-0.5, 15, 30), (-1, 30, 30), (0, 0, 30), (0.5, 30, 60)] {
            let n = PlazaSprite()
            n.size = CGSize(width: 10, height: 20)
            n.xScale = scale
            n.size = CGSize(width: 30, height: 20)
            XCTAssertEqual(n.size.width, reads, "scale \(scale)")
            n.xScale = 1
            XCTAssertEqual(n.size.width, resetReads, "scale \(scale), reset")
        }
        let mixed = PlazaSprite()
        mixed.xScale = 2; mixed.yScale = -1
        mixed.size = CGSize(width: 30, height: 30)
        mixed.xScale = 1; mixed.yScale = 1
        XCTAssertEqual(mixed.size, CGSize(width: 30, height: 30), "one non-positive scale: SpriteKit stores both axes as assigned")
        let f = PlazaSprite()
        f.size = CGSize(width: 10, height: 1)
        f.xScale = 0.6
        f.size = CGSize(width: 7, height: 1)
        f.xScale = 1
        XCTAssertEqual(f.size.width, 11.666666030883789, "the unscaled size is Float(7) / Float(0.6), in 32 bits")

        let texture = PlazaTexture(PlazaImage(bitmap: PlazaTestImages.patterned(width: 4, height: 6)))
        let u = PlazaSprite(color: .white, size: CGSize(width: 10, height: 20))
        u.texture = texture
        XCTAssertEqual(u.size, CGSize(width: 10, height: 20), "assigning a texture keeps the size")
        u.texture = nil
        XCTAssertEqual(u.size, CGSize(width: 10, height: 20))
    }

    func testFrameMatchesTheProbe() async {
        let s = PlazaSprite(color: .white, size: CGSize(width: 10, height: 20))
        XCTAssertEqual(s.frame, CGRect(x: -5, y: -10, width: 10, height: 20))
        s.position = CGPoint(x: 100, y: 50)
        s.anchorPoint = CGPoint(x: 0.5, y: 0)
        XCTAssertEqual(s.frame, CGRect(x: 95, y: 50, width: 10, height: 20))
        s.xScale = -2
        XCTAssertEqual(s.frame, CGRect(x: 90, y: 50, width: 20, height: 20))
        s.anchorPoint = .zero; s.xScale = 2; s.yScale = 1
        XCTAssertEqual(s.frame, CGRect(x: 100, y: 50, width: 20, height: 20))
        let flip = PlazaSprite()
        flip.size = CGSize(width: 10, height: 10)
        flip.anchorPoint = .zero
        flip.xScale = -1
        XCTAssertEqual(flip.frame, CGRect(x: -10, y: 0, width: 10, height: 10), "a flip mirrors the anchor")
        let odd = PlazaSprite()
        odd.size = CGSize(width: 10.3, height: 7.7)
        odd.anchorPoint = CGPoint(x: 0.3, y: 0.7)
        odd.position = CGPoint(x: 123.456, y: 78.9)
        odd.xScale = 1.7; odd.yScale = -0.9
        let f = odd.frame
        XCTAssertEqual([f.origin.x, f.origin.y, f.width, f.height],
                       [118.2030029296875, 76.820999145507812, 17.510000228881836, 6.929999828338623], "32-bit arithmetic, as SpriteKit")
        let fine = PlazaSprite()
        fine.size = CGSize(width: 4.5699357986450195, height: 23.80958366394043)
        fine.anchorPoint = .zero
        XCTAssertEqual([fine.frame.width, fine.frame.height], [4.570000171661377, 23.809999465942383],
                       "SpriteKit rounds frame values to 1/1000 (probe)")
        XCTAssertEqual(fine.size.width, 4.5699357986450195, "size itself is not rounded")
    }

    func testValuesAreStoredAs32BitFloats() async {
        let n = PlazaSprite()
        n.position = CGPoint(x: 0.1, y: 1.0 / 3.0)
        n.zPosition = 1 + 123.456 / 1536.0
        n.alpha = 0.3
        n.xScale = 0.6
        n.zRotation = 0.1
        n.anchorPoint = CGPoint(x: 0.3, y: 1.0 / 3.0)
        n.colorBlendFactor = 0.3
        n.size = CGSize(width: 10.1, height: 1.0 / 3.0)
        n.color = PlazaColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        XCTAssertEqual(n.position, CGPoint(x: 0.10000000149011612, y: 0.3333333432674408))
        XCTAssertEqual(n.zPosition, 1.0803749561309814)
        XCTAssertEqual(n.alpha, 0.30000001192092896)
        XCTAssertEqual(n.xScale, 0.60000002384185791)
        XCTAssertEqual(n.zRotation, 0.10000000149011612)
        XCTAssertEqual(n.anchorPoint, CGPoint(x: 0.30000001192092896, y: 0.3333333432674408))
        XCTAssertEqual(n.colorBlendFactor, 0.30000001192092896)
        XCTAssertEqual(n.size.width, 10.100000381469727)
        n.xScale = 1
        XCTAssertEqual(n.size.width, 16.833333969116211)
        XCTAssertEqual([n.color.red, n.color.green, n.color.blue, n.color.alpha],
                       [0.20000000298023224, 0.4000000059604645, 0.6000000238418579, 0.5])
        n.alpha = 1.5
        XCTAssertEqual(n.alpha, 1.5, "alpha is not clamped")
        n.alpha = -0.2
        XCTAssertEqual(n.alpha, -0.20000000298023224)
        n.zRotation = 7
        XCTAssertEqual(n.zRotation, 7, "rotation is not normalised")
        let crop = PlazaCropNode()
        crop.maskRect = CGRect(x: 0.1, y: 2, width: 1.0 / 3.0, height: 4)
        XCTAssertEqual(crop.maskRect, CGRect(x: 0.10000000149011612, y: 2, width: 0.3333333432674408, height: 4))
    }

    func testDefaultsAreSpriteKits() async {
        let s = PlazaSprite()
        XCTAssertEqual(s.color, PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0), "clear white, not black")
        XCTAssertEqual(s.colorBlendFactor, 0)
        XCTAssertEqual(s.blendMode, .alpha)
        XCTAssertEqual(s.size, .zero)
        XCTAssertEqual(s.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(s.alpha, 1)
        XCTAssertFalse(s.isHidden)
        XCTAssertNil(s.texture)
        XCTAssertNil(s.name)
        XCTAssertEqual(PlazaSprite(texture: nil, size: CGSize(width: 3, height: 3)).color, PlazaSprite.defaultColor)
        XCTAssertEqual(PlazaSprite(color: .white, size: .zero).color, .white)
        XCTAssertNil(PlazaCropNode().maskRect)
    }

    func testUnchangedWritesDoNotReachTheMirror() async {
        let s = PlazaSprite()
        let m = PlazaRecordingMirror()
        s.installMirror(m)
        let texture = PlazaTexture(PlazaImage(bitmap: PlazaTestImages.patterned(width: 3, height: 3)))
        for _ in 0..<2 {
            s.position = CGPoint(x: 0.1, y: 2)
            s.zPosition = 2.5
            s.alpha = 0.4
            s.isHidden = true
            s.xScale = -1
            s.yScale = 2
            s.zRotation = 0.3
            s.name = "drop"
            s.texture = texture
            s.size = CGSize(width: 6, height: 6)
            s.anchorPoint = .zero
            s.color = PlazaColor(srgbRed: 0.5, green: 0.5, blue: 0.5)
            s.colorBlendFactor = 0.3
            s.blendMode = .multiply
        }
        XCTAssertEqual(m.calls.count, 14, "the second round changed nothing: \(m.calls)")
        s.position = CGPoint(x: 0.10000000149011612, y: 2)   // the same 32-bit value
        s.setScale(1)
        s.xScale = 1
        s.yScale = 1
        s.size = CGSize(width: 6, height: 6)   // assigned under xScale -1 it was stored as is (6x6): unchanged
        XCTAssertEqual(Array(m.calls.dropFirst(14)), ["scale 1.0,1.0"])
        let crop = PlazaCropNode()
        let cm = PlazaRecordingMirror()
        crop.installMirror(cm)
        crop.maskRect = CGRect(x: 1, y: 2, width: 3, height: 4)
        crop.maskRect = CGRect(x: 1, y: 2, width: 3, height: 4)
        crop.maskRect = nil
        crop.maskRect = nil
        XCTAssertEqual(cm.calls, ["mask", "mask"])
    }

    func testTheMirrorSeesTheTreeChange() async {
        let root = PlazaNode()
        let m = PlazaRecordingMirror()
        root.installMirror(m)
        let a = PlazaSprite(), b = PlazaSprite()
        root.addChild(a)
        root.addChild(b)
        XCTAssertEqual(m.calls, ["insert 0", "insert 1"])
        let am = a.mirror as? PlazaRecordingMirror
        a.removeFromParent()
        XCTAssertEqual(am?.calls, ["remove"])
        XCTAssertTrue(a.mirror === am, "a node keeps its mirror when it leaves the tree")
        let unmounted = PlazaNode()
        unmounted.addChild(PlazaSprite())
        XCTAssertNil(unmounted.children[0].mirror, "no mirror outside a mounted tree")
    }

    func testTexturesAndCuts() async {
        let image = PlazaImage(bitmap: PlazaTestImages.patterned(width: 7, height: 9))
        let full = PlazaTexture(image)
        XCTAssertEqual(full.pixelSize, CGSize(width: 7, height: 9))
        XCTAssertEqual(full.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        let cut = PlazaTexture(rect: CGRect(x: 0, y: 0, width: 1, height: 0.3), in: full)
        XCTAssertEqual(cut.pixelSize.height, 9 * 0.3, "SKTexture.size(): a double product (2.6999999999999997)")
        XCTAssertTrue(cut.image === image && cut.parent === full)
        let half = PlazaTexture(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), in: full)
        let nested = PlazaTexture(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), in: half)
        XCTAssertEqual(nested.pixelSize, CGSize(width: 3.5, height: 4.5), "a cut of a cut is a part of the whole image (probe)")
    }
}
