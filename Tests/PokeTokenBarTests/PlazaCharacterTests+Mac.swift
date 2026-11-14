import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// The nest checks that read the actor's SpriteKit photo parts (`PlazaActor` is Mac-only until the scene moves).
extension PlazaCharacterTests {
    func testOnlyEggsSitOnANest() async {
        var f = CharacterFakeFetcher()
        f.stillFront = characterTestImage()
        let mon = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: false))
        XCTAssertFalse(mon.isEgg)
        let actor = PlazaActor(name: "a", color: PlazaNameColor.palette[0])
        actor.setFrames(mon)
        XCTAssertFalse(actor.isOnNest)
        var egg = mon
        egg.isEgg = true
        actor.setFrames(egg)
        XCTAssertTrue(actor.isOnNest)
        XCTAssertTrue(actor.groundShadowSize == PlazaNestArt.size)
        let photo = actor.photoActor(foot: CGPoint(x: 100, y: 100), pose: PlazaPose.choice(facing: .down, isWalking: false, clock: 0))
        let bytes = { (i: CGImage?) in i?.dataProvider?.data as Data? }
        XCTAssertEqual(bytes(photo?.shadow), bytes(PlazaNestArt.image().cgImage), "the photo shows the nest too")
        XCTAssertEqual(bytes(photo?.front), bytes(PlazaNestArt.frontImage().cgImage), "and its front rim over the egg")
        let context = PlazaActorContext(worldHeight: 400, cameraPosition: .zero, zoom: 2, backing: 2, viewport: CGSize(width: 400, height: 300))
        actor.place(foot: CGPoint(x: 100, y: 100), pose: PlazaPose.choice(facing: .down, isWalking: false, clock: 0), in: context)
        XCTAssertTrue(actor.nestFrontIsInFront, "the rim is drawn in front of the egg")
        actor.setFrames(mon)
        XCTAssertFalse(actor.isOnNest, "a hatched egg leaves the nest")
        XCTAssertFalse(actor.nestFrontIsInFront)
        XCTAssertNil(actor.photoActor(foot: CGPoint(x: 100, y: 100), pose: PlazaPose.choice(facing: .down, isWalking: false, clock: 0))?.front)
    }
}
