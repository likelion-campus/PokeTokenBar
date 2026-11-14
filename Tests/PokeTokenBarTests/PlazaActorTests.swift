import XCTest
@testable import PokeTokenBar

/// The actor on the shared node tree, on every OS: where its nodes go, that detaching leaves nothing behind, and the
/// swim crop. (The SpriteKit side: `SpriteKitMirrorParityTests` and the render harness.)
@MainActor
final class PlazaActorTests: XCTestCase {
    private func frames(width: Int = 20, height: Int = 30) -> PlazaCharacterFrames {
        let image = characterTestImage(width: width, height: height, opaque: [(2, 2), (width - 3, height - 3)])
        return PlazaCharacterFrames(front: [PlazaFrame(image: image, delay: 0.1)], back: [PlazaFrame(image: image, delay: 0.1)])
    }

    private let context = PlazaActorContext(worldHeight: 400, cameraPosition: CGPoint(x: 100, y: 300), zoom: 2, backing: 2,
                                            viewport: CGSize(width: 400, height: 300))

    func testAttachPutsTheNodesInTheWorldAndTheCameraInDrawOrder() async {
        let world = PlazaNode(), camera = PlazaCameraNode()
        let before = PlazaSprite()
        world.addChild(before)
        let actor = PlazaActor(name: "a", color: PlazaNameColor.palette[0])
        actor.attach(world: world, camera: camera)
        XCTAssertTrue(world.children.dropFirst().elementsEqual(actor.worldNodes, by: ===), "appended after what was there")
        XCTAssertTrue(camera.children.elementsEqual(actor.cameraNodes, by: ===))
        let w = actor.worldNodes
        XCTAssertEqual(w.map { "\(type(of: $0))" }, ["PlazaSprite", "PlazaSprite", "PlazaSprite", "PlazaCropNode", "PlazaSprite"])
        XCTAssertEqual(w.map(\.zPosition), [0.5, 1, 0, 0, 0], "the shadow under the character; the rest is placed per frame")
        XCTAssertEqual((w[0] as? PlazaSprite)?.anchorPoint, .zero)
        XCTAssertEqual((w[1] as? PlazaSprite)?.anchorPoint, CGPoint(x: 0.5, y: 0), "the character stands on its foot")
        XCTAssertEqual(w[3].children.count, 1, "the crop holds the submerged ghost")
        XCTAssertEqual(actor.cameraNodes.map(\.zPosition), [10, 11, 11], "name plate, bubble, 💧")
        XCTAssertTrue(w.allSatisfy(\.isHidden), "nothing shows in the world before frames arrive")
    }

    func testDetachTakesEveryNodeOutAndLeavesTheRest() async {
        let world = PlazaNode(), camera = PlazaCameraNode()
        let stays = PlazaActor(name: "stays", color: PlazaNameColor.palette[0])
        let leaves = PlazaActor(name: "leaves", color: PlazaNameColor.palette[1])
        stays.attach(world: world, camera: camera)
        leaves.attach(world: world, camera: camera)
        leaves.setFrames(frames())
        leaves.showChat("bye")
        leaves.showWet()
        leaves.place(foot: CGPoint(x: 100, y: 200), pose: PlazaPose.choice(facing: .right, isWalking: false, clock: 0), in: context,
                     swimSink: 12, waterRect: CGRect(x: 50, y: 150, width: 120, height: 80))
        XCTAssertTrue(leaves.isSubmergedBodyVisible)
        leaves.detach()
        XCTAssertTrue(world.children.elementsEqual(stays.worldNodes, by: ===))
        XCTAssertTrue(camera.children.elementsEqual(stays.cameraNodes, by: ===))
        XCTAssertTrue((leaves.worldNodes + leaves.cameraNodes).allSatisfy { $0.parent == nil })
    }

    func testTheSwimCropClipsToThePondInStoredFloats() async {
        let actor = PlazaActor(name: "a", color: PlazaNameColor.palette[0])
        actor.setFrames(frames())
        let pose = PlazaPose.choice(facing: .down, isWalking: false, clock: 0)
        let pond = CGRect(x: 40.3, y: 150.7, width: 160.1, height: 48.45)
        actor.place(foot: CGPoint(x: 100, y: 200), pose: pose, in: context, swimSink: 12, waterRect: pond)
        XCTAssertEqual(actor.submergedBodyClip, PlazaFloat.stored(pond), "the mask rect, as SpriteKit keeps it")
        let crop = actor.worldNodes[3] as? PlazaCropNode
        XCTAssertEqual(crop?.maskRect, PlazaFloat.stored(pond))
        XCTAssertEqual(actor.submergedBodySize, CGSize(width: 30, height: 12), "the cut-off rows: 8 picture rows x 1.5")
        XCTAssertEqual(actor.submergedBodyTextureRect.height, 8.0 / 30, accuracy: 1e-9)
        let other = CGRect(x: 36.6, y: 146.2, width: 170.9, height: 60.35)
        actor.place(foot: CGPoint(x: 101, y: 200), pose: pose, in: context, swimSink: 12, waterRect: other)
        XCTAssertEqual(actor.submergedBodyClip, PlazaFloat.stored(other), "a new pond moves the mask")
        actor.place(foot: CGPoint(x: 101, y: 200), pose: pose, in: context, swimSink: 12, waterRect: nil)
        XCTAssertNil(actor.submergedBodyClip, "outside a pond nothing is drawn under the water line")
        actor.place(foot: CGPoint(x: 101, y: 200), pose: pose, in: context)
        XCTAssertFalse(actor.isSubmergedBodyVisible)
    }
}
