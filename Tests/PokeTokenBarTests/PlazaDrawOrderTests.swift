import XCTest
@testable import PokeTokenBar

@MainActor
final class PlazaDrawOrderTests: XCTestCase {
    private func sprite(_ name: String, z: CGFloat, size: CGSize = CGSize(width: 10, height: 10)) -> PlazaSprite {
        let s = PlazaSprite(color: .white, size: size)
        s.name = name
        s.zPosition = z
        return s
    }

    private func names(_ items: [PlazaDrawItem]) -> [String] { items.map { $0.sprite.name ?? "?" } }

    func testDrawOrderSumsAncestorZ() async {
        let root = PlazaNode()
        let high = PlazaNode(); high.zPosition = 5
        high.addChild(sprite("under-5", z: 0))
        let low = PlazaNode(); low.zPosition = 1
        low.addChild(sprite("under-1", z: 10))
        root.addChild(high)
        root.addChild(sprite("plain-4", z: 4))
        root.addChild(low)
        let items = PlazaDrawOrder.flatten(root: root, camera: nil)
        XCTAssertEqual(names(items), ["plain-4", "under-5", "under-1"])
        XCTAssertEqual(items.map(\.globalZ), [4, 5, 11])
    }

    /// The daylight tint (camera z 5) lies between characters (z 1–2) and plates (camera z 10), as in the plaza.
    func testCameraChildrenAreScreenSpaceInTheSameZOrder() async {
        let root = PlazaNode()
        let camera = PlazaCameraNode()
        camera.position = CGPoint(x: 300, y: 200)
        camera.setScale(0.5)
        root.addChild(sprite("character", z: 1.5))
        root.addChild(camera)
        camera.addChild(sprite("plate", z: 10))
        camera.addChild(sprite("daylight", z: 5))
        root.addChild(sprite("map", z: 0))
        let items = PlazaDrawOrder.flatten(root: root, camera: camera)
        XCTAssertEqual(names(items), ["map", "character", "daylight", "plate"])
        XCTAssertEqual(items.map(\.isScreenSpace), [false, false, true, true])
        let plate = items[3]
        XCTAssertEqual(plate.transform.apply(CGPoint(x: 0.5, y: 0.5)), .zero, "screen items are placed relative to the camera, not moved by it")
        XCTAssertEqual(plate.transform.apply(CGPoint(x: 1, y: 1)), CGPoint(x: 5, y: 5), "nor scaled by it")
    }

    func testCropSubtreeIsOneUnit() async {
        let root = PlazaNode()
        let crop = PlazaCropNode()
        crop.zPosition = 1
        crop.position = CGPoint(x: 100, y: 0)
        crop.maskRect = CGRect(x: -4, y: 0, width: 8, height: 6)
        crop.addChild(sprite("in-crop-10", z: 10))
        crop.addChild(sprite("in-crop-2", z: 2))
        root.addChild(crop)
        root.addChild(sprite("sibling-5", z: 5))
        root.addChild(sprite("sibling-0", z: 0))
        let items = PlazaDrawOrder.flatten(root: root, camera: nil)
        XCTAssertEqual(names(items), ["sibling-0", "in-crop-2", "in-crop-10", "sibling-5"],
                       "the crop's subtree draws as one unit at the crop's z (1), sorted inside")
        XCTAssertEqual(items[1].clip, CGRect(x: 96, y: 0, width: 8, height: 6), "the mask in the item's space")
        XCTAssertNil(items[0].clip)
        crop.maskRect = nil
        XCTAssertNil(PlazaDrawOrder.flatten(root: root, camera: nil)[1].clip)
    }

    func testTiesFallBackToTreeOrder() async {
        let root = PlazaNode()
        let group = PlazaNode()
        group.addChild(sprite("b", z: 2))
        root.addChild(sprite("a", z: 2))
        root.addChild(group)
        root.addChild(sprite("c", z: 2))
        root.addChild(sprite("first", z: 1))
        let items = PlazaDrawOrder.flatten(root: root, camera: nil)
        XCTAssertEqual(names(items), ["first", "a", "b", "c"], "equal z: depth-first tree order (SpriteKit leaves it unspecified)")
        let tied = items.dropFirst().map(\.treeIndex)
        XCTAssertEqual(tied, tied.sorted())
    }

    func testHiddenSubtreesAreSkippedAndAlphaMultiplies() async {
        let root = PlazaNode()
        let hidden = PlazaNode(); hidden.isHidden = true
        hidden.addChild(sprite("gone", z: 0))
        let faded = PlazaNode(); faded.alpha = 0.5
        let s = sprite("half", z: 0); s.alpha = 0.5
        faded.addChild(s)
        let clear = sprite("clear", z: 0); clear.alpha = 0
        for n in [hidden, faded, clear] { root.addChild(n) }
        let items = PlazaDrawOrder.flatten(root: root, camera: nil)
        XCTAssertEqual(names(items), ["half", "clear"], "hidden subtrees are skipped; alpha 0 is still listed")
        XCTAssertEqual(items[0].alpha, 0.25)
    }

    func testTransformMapsTheUnitSquare() async {
        let root = PlazaNode()
        let s = sprite("s", z: 0, size: CGSize(width: 10, height: 20))
        s.anchorPoint = CGPoint(x: 0.5, y: 0)
        s.position = CGPoint(x: 100, y: 50)
        s.xScale = -1
        root.addChild(s)
        let t = PlazaDrawOrder.flatten(root: root, camera: nil)[0].transform
        XCTAssertEqual(t.apply(.zero), CGPoint(x: 105, y: 50), "a flip mirrors around the anchor")
        XCTAssertEqual(t.apply(CGPoint(x: 1, y: 1)), CGPoint(x: 95, y: 70))
        let turned = PlazaNode()
        turned.zRotation = .pi / 2
        turned.position = CGPoint(x: 10, y: 0)
        let r = sprite("r", z: 0, size: CGSize(width: 4, height: 2))
        r.anchorPoint = .zero
        turned.addChild(r)
        let tr = PlazaDrawOrder.flatten(root: turned, camera: nil)[0].transform
        let p = tr.apply(CGPoint(x: 1, y: 0))   // the sprite's right edge: (4, 0) turned a quarter, then moved
        XCTAssertEqual(p.x, 10, accuracy: 1e-5)   // the 32-bit quarter turn
        XCTAssertEqual(p.y, 4, accuracy: 1e-5)
    }
}
