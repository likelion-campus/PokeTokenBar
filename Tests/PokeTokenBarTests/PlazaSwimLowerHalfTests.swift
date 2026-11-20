import XCTest
@testable import PokeTokenBar

/// A swimmer's cut-off lower half is drawn under the waterline, translucent and tinted, clipped to its pond.
/// The right pond is x32-38, y14-20 (7x7 tiles of 32 world px); sprites are 32x48 (72 world px at x1.5).
@MainActor
final class PlazaSwimLowerHalfTests: XCTestCase {
    private let map = PlazaMapData.map

    private func frames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: PlazaImage(bitmap: PlazaTestImages.solid(width: 32, height: 48, PlazaRGBA(r: 255, g: 0, b: 0, a: 255))), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    func eggFrames() -> PlazaCharacterFrames {
        var f = frames()
        f.isEgg = true
        return f
    }

    func scene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.setCharacter(frames())
        return s
    }

    private func add(_ s: PlazaScene, _ list: [(id: String, tile: TilePoint, diving: Bool)]) {
        s.applyMembers(list.map {
            var m = PlazaSceneMember(memberID: $0.id, nickname: $0.id, isAway: false, tile: $0.tile, facing: .down, isWalking: false)
            m.isDiving = $0.diving
            return m
        })
        for m in list { s.setMemberFrames(m.id, frames()) }
    }

    private func addEgg(_ s: PlazaScene, _ id: String, _ tile: TilePoint) {
        add(s, [(id, tile, false)])
        s.setMemberFrames(id, eggFrames())
    }

    func settle(_ s: PlazaScene) {
        var t: TimeInterval = 0
        s.update(t)
        for _ in 0..<6 { t += 1.0 / 30; s.update(t) }
    }

    /// Scene y is up, so the pond's top row y14 is the highest.
    private var pondClip: CGRect {
        let h = PlazaMapData.map.pixelSize.height
        return CGRect(x: 32 * 32, y: h - 21 * 32, width: 7 * 32, height: 7 * 32)
    }

    func testSwimmerShowsItsLowerHalfTranslucently() async throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("a", TilePoint(x: 34, y: 18), false)])
        settle(s)
        let a = try XCTUnwrap(s.memberActor("a"))
        XCTAssertTrue(a.isSubmergedBodyVisible)
        XCTAssertEqual(a.submergedBodyAlpha, 0.35 * a.characterOpacity, accuracy: 0.001)
        let cut = (72 * 0.55 / 1.5).rounded()   // rows of the 48-row sprite under water
        XCTAssertEqual(a.submergedBodySize, CGSize(width: 48, height: cut * 1.5))
        XCTAssertEqual(a.submergedBodyTextureRect.height, cut / 48, accuracy: 0.001)
        XCTAssertEqual(a.submergedBodyTextureRect.minY, 0, accuracy: 0.001)
    }

    func testLowerHalfIsHiddenOnLandAndWhileDiving() async throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("land", TilePoint(x: 30, y: 18), false), ("dive", TilePoint(x: 35, y: 18), true)])
        settle(s)
        XCTAssertFalse(try XCTUnwrap(s.memberActor("land")).isSubmergedBodyVisible)
        XCTAssertNil(try XCTUnwrap(s.memberActor("land")).submergedBodyClip)
        // a diver fades with its character: the body follows that alpha and is gone once hidden.
        let d = try XCTUnwrap(s.memberActor("dive"))
        XCTAssertEqual(d.submergedBodyAlpha, 0.35 * d.characterOpacity, accuracy: 0.001)
    }

    func testClipIsTheSwimmersPondForMeAndForAMember() async throws {
        let me = scene(start: TilePoint(x: 33, y: 15))
        settle(me)
        XCTAssertEqual(me.myActor.submergedBodyClip, pondClip)
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("a", TilePoint(x: 37, y: 19), false)])
        settle(s)
        XCTAssertEqual(try XCTUnwrap(s.memberActor("a")).submergedBodyClip, pondClip)
        XCTAssertNil(s.myActor.submergedBodyClip, "on land")
    }

    // MARK: photo

    struct Px { let r, g, b: Int }

    // MARK: egg in the water

    private func assertSunkWhole(_ a: PlazaActor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(a.isSubmergedBodyVisible, file: file, line: line)
        XCTAssertEqual(a.submergedBodyTextureRect, CGRect(x: 0, y: 0, width: 1, height: 1), file: file, line: line)
        XCTAssertEqual(a.submergedBodyAlpha, PlazaPondArt.submergedEggAlpha, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.submergedBodySize, CGSize(width: 48, height: 72), file: file, line: line)
        XCTAssertEqual(a.submergedBodyTopY, a.characterY + 72, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.characterOpacity, 0, "the opaque body is gone", file: file, line: line)
        XCTAssertEqual(a.visibleSpriteHeight, 72, file: file, line: line)
        XCTAssertTrue(a.isSwimRingVisible, file: file, line: line)
        XCTAssertEqual(a.swimRingY, a.characterY + 72 - 2, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.nestFrontOpacity, 0, file: file, line: line)
        XCTAssertEqual(a.submergedBodyClip, pondClip, file: file, line: line)
    }

    func testAnEggInTheWaterSinksWholeInPlace() async throws {
        let s = scene(start: TilePoint(x: 33, y: 17))
        s.setCharacter(eggFrames())
        settle(s)
        assertSunkWhole(s.myActor)
        let standing = scene(start: TilePoint(x: 20, y: 22))
        standing.setCharacter(eggFrames())
        settle(standing)
        XCTAssertEqual(s.myActor.namePlatePosition.y, standing.myActor.namePlatePosition.y, accuracy: 0.001, "the plate rides where a standing egg's would")
    }

    func testARemoteEggInTheWaterSinksTheSameWay() async throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        addEgg(s, "a", TilePoint(x: 34, y: 18))
        settle(s)
        assertSunkWhole(try XCTUnwrap(s.memberActor("a")))
    }

    func testASwimmingPokemonKeepsItsHeadAboveWater() async throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("a", TilePoint(x: 34, y: 18), false)])
        settle(s)
        let a = try XCTUnwrap(s.memberActor("a"))
        XCTAssertEqual(a.visibleSpriteHeight, 72 * 0.45, accuracy: 1)
        XCTAssertEqual(a.characterOpacity, 1)
        XCTAssertEqual(a.swimRingY, a.characterY, accuracy: 0.001, "the ring is at the foot")
    }

    func testAnEggLeavingTheWaterStandsOnItsNestAgain() async throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        addEgg(s, "a", TilePoint(x: 34, y: 18))
        settle(s)
        s.applyMembers([PlazaSceneMember(memberID: "a", nickname: "a", isAway: false, tile: TilePoint(x: 30, y: 18), facing: .down, isWalking: false)])
        var t: TimeInterval = 1
        for _ in 0..<90 { t += 1.0 / 30; s.update(t) }
        let a = try XCTUnwrap(s.memberActor("a"))
        XCTAssertFalse(a.isSubmergedBodyVisible)
        XCTAssertFalse(a.isSwimRingVisible)
        XCTAssertEqual(a.characterOpacity, 1)
        XCTAssertEqual(a.visibleSpriteHeight, 72)
        XCTAssertTrue(a.nestFrontIsInFront)
        XCTAssertEqual(a.nestFrontOpacity, 1)
        XCTAssertEqual(a.shadowOpacity, 1)
    }

    func testASunkEggInThePondsTopRowSinksDeeperInsteadOfBeingCut() async throws {
        let s = scene(start: TilePoint(x: 33, y: 14))
        s.setCharacter(eggFrames())
        settle(s)
        let a = s.myActor
        let clip = try XCTUnwrap(a.submergedBodyClip)
        XCTAssertEqual(a.submergedBodyTopY, clip.maxY, accuracy: 0.001, "the top rests on the pond's top edge")
        XCTAssertLessThan(a.submergedBodyTopY, a.characterY + 72, "it sank deeper than a mid-pond egg")
        XCTAssertEqual(a.submergedBodySize, CGSize(width: 48, height: 72), "the whole egg is still there")
        XCTAssertEqual(a.swimRingY, a.submergedBodyTopY - 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(a.swimRingY, clip.maxY, "the ring is not on the bank")
    }

    func testAJumpingSunkEggStaysSunk() async throws {
        let s = scene(start: TilePoint(x: 33, y: 16))
        s.setCharacter(eggFrames())
        settle(s)
        let top = s.myActor.submergedBodyTopY, ring = s.myActor.swimRingY
        s.playJump(memberID: nil)
        var t: TimeInterval = 1
        var lifted = false
        for _ in 0..<12 {
            t += 1.0 / 30; s.update(t)
            lifted = lifted || s.myActor.characterY > top - 72 + 0.5
            XCTAssertEqual(s.myActor.submergedBodyTopY, top, accuracy: 0.001)
            XCTAssertEqual(s.myActor.swimRingY, ring, accuracy: 0.001)
        }
        XCTAssertTrue(lifted, "the jump really lifted the character node")
    }
}
