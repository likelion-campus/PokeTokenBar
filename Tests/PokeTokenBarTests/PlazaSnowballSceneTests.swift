import XCTest
@testable import PokeTokenBar

/// Snowballs in the scene: the pooled flight layer, the burst, the landing callback and the V key.
@MainActor
final class PlazaSnowballSceneTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene(start: TilePoint = TilePoint(x: 14, y: 12)) -> PlazaScene {
        let s = PlazaScene(map: PlazaMapData.map, mapImage: PlazaTileArt.plainGrassImage(PlazaMapData.map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true)
        pinPlazaClock(s)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.setCharacter(frames())
        return s
    }

    private func frames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: PlazaImage(bitmap: PlazaTestImages.solid(width: 32, height: 48, PlazaRGBA(r: 255, g: 0, b: 0, a: 255))), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, _ tile: TilePoint, diving: Bool = false) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false, isDiving: diving)
    }

    private func addAll(_ s: PlazaScene, _ members: [PlazaSceneMember]) {
        s.applyMembers(members)
        for m in members { s.setMemberFrames(m.memberID, frames()) }
    }

    @discardableResult
    private func run(_ s: PlazaScene, _ seconds: TimeInterval, from start: TimeInterval = 0) -> TimeInterval {
        var t = start
        s.update(t)
        while t < start + seconds - 1e-9 {
            t += 0.05
            s.update(t)
        }
        return t
    }

    private var hitShot: PlazaSnowballShot {
        PlazaSnowballShot(from: p(10, 12), direction: .right, end: .actor(id: nil, tile: p(14, 12)))
    }

    func testABallFliesATileATenthAndLandsOnce() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        var landed = 0
        s.playSnowball(by: "a", shot: hitShot) { landed += 1 }
        run(s, 0.35)
        XCTAssertEqual(landed, 0)
        XCTAssertEqual(s.snowballFlightCount, 1)
        XCTAssertEqual(s.snowballSpriteCount, 2)
        run(s, 0.10, from: 0.35)
        XCTAssertEqual(landed, 1)
        XCTAssertGreaterThanOrEqual(s.snowballSpriteCount, 5)
        run(s, 0.40, from: 0.45)
        XCTAssertEqual(s.snowballFlightCount, 0)
        XCTAssertEqual(s.snowballSpriteCount, 0)
        XCTAssertEqual(landed, 1)
    }

    func testABallAtAMemberWhoLeftStillFliesAndLandsOnce() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        var landed = 0
        let shot = PlazaSnowballShot(from: p(10, 12), direction: .right, end: .actor(id: "gone", tile: p(14, 12)))
        s.playSnowball(by: "a", shot: shot) { landed += 1 }
        run(s, 0.9)
        XCTAssertEqual(landed, 1)
        XCTAssertEqual(s.snowballFlightCount, 0)
    }

    func testAHitShowsTheImpactStarAndTheThrowerLunges() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        s.playSnowball(by: "a", shot: hitShot) {}
        s.update(0.05)   // the lunge starts at 0 and grows with the first frame
        XCTAssertNotEqual(s.lungeOffset(memberID: "a"), .zero)
        run(s, 0.5, from: 0.05)
        XCTAssertEqual(s.impactsShown, 1)
    }

    func testAMissInTheWaterSplashesInsteadOfBursting() async {
        let s = scene(start: p(19, 14))
        addAll(s, [member("w", p(15, 14))])
        s.update(0)
        let shot = PlazaSnowballShot(from: p(19, 14), direction: .left, end: .ground(p(14, 14)))
        s.playSnowball(by: nil, shot: shot) {}
        run(s, 0.5)   // five tiles, landing on the fifth frame
        XCTAssertEqual(s.pondLayer!.dropletCount, PlazaPondLayer.smallDroplets)
        XCTAssertEqual(s.snowballSpriteCount, 0)
        XCTAssertEqual(s.isWet(memberID: "w"), false)
    }

    func testAPausedSceneDrawsNothingAndLandsAtOnce() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        s.isPaused = true
        let before = s.children.count
        var landed = 0
        s.playSnowball(by: "a", shot: hitShot) { landed += 1 }
        XCTAssertEqual(landed, 1)
        XCTAssertEqual(s.snowballSpriteCount, 0)
        XCTAssertEqual(s.impactsShown, 0)
        XCTAssertEqual(s.children.count, before)
    }

    func testABallLandingWhereItsTargetNoLongerStandsShowsNoStar() async {
        let s = scene(start: p(14, 13))   // I stand beside the aimed tile (14,12)
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        s.playSnowball(by: "a", shot: hitShot) {}
        run(s, 0.9)
        XCTAssertEqual(s.impactsShown, 0)
    }

    func testAStarShowsWhenTheBallReachesABigBodyAboveItsFoot() async {
        func star(_ size: Int) -> Int {
            let s = scene()
            addAll(s, [member("a", p(10, 12)), { var g = member("g", p(16, 13)); g.bodySize = size; return g }()])
            s.update(0)
            s.playSnowball(by: "a", shot: PlazaSnowballShot(from: p(10, 12), direction: .right, end: .actor(id: "g", tile: p(15, 12)))) {}
            run(s, 0.9)
            return s.impactsShown
        }
        XCTAssertEqual(star(3), 1)
        XCTAssertEqual(star(1), 0)
        let s = scene(start: p(16, 13))
        addAll(s, [member("a", p(10, 12))])
        s.myBodySize = 3
        s.update(0)
        s.playSnowball(by: "a", shot: PlazaSnowballShot(from: p(10, 12), direction: .right, end: .actor(id: nil, tile: p(15, 12)))) {}
        run(s, 0.9)
        XCTAssertEqual(s.impactsShown, 1)
    }

    /// `update` asks for the interaction target every frame. With nothing moved it must not search again; any change of
    /// my tile, facing or size, or of a member's tile or size, searches once.
    func testTheInteractionTargetIsNotSearchedAgainWhileNothingChanges() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12)), member("b", p(15, 12))])
        s.update(0)
        run(s, 1)
        let settled = s.interactionEvaluations
        run(s, 2, from: 1)
        XCTAssertEqual(s.interactionEvaluations, settled, "two idle seconds (120 frames) search nothing")
        s.myBodySize = 3
        XCTAssertGreaterThan(s.interactionEvaluations, settled, "a new size searches")
        let afterSize = s.interactionEvaluations
        s.face(.up)
        XCTAssertGreaterThan(s.interactionEvaluations, afterSize, "a new facing searches")
        let afterFace = s.interactionEvaluations
        var moved = member("a", p(11, 12)); moved.bodySize = 2
        s.applyMembers([moved, member("b", p(15, 12))])
        XCTAssertGreaterThan(s.interactionEvaluations, afterFace, "a member's new tile and size search")
        let end = run(s, 2, from: 3)   // the member's step to its new tile finishes, searching as the tile changes
        let afterMove = s.interactionEvaluations
        run(s, 2, from: end)
        XCTAssertEqual(s.interactionEvaluations, afterMove, "and then it is idle again")
    }

    func testPausingMidFlightLandsEveryBallAtOnce() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        var landed = 0
        for _ in 0..<3 { s.playSnowball(by: "a", shot: hitShot) { landed += 1 } }
        run(s, 0.15)
        XCTAssertEqual(landed, 0)
        s.isPaused = true
        XCTAssertEqual(landed, 3)
        XCTAssertEqual(s.snowballFlightCount, 0)
        XCTAssertEqual(s.snowballSpriteCount, 0)
    }

    func testFlightsBeyondTheCapLandAtOnce() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        var landed = 0
        for _ in 0..<(PlazaSnowballLayer.maxFlights + 5) { s.playSnowball(by: "a", shot: hitShot) { landed += 1 } }
        XCTAssertEqual(s.snowballFlightCount, PlazaSnowballLayer.maxFlights)
        XCTAssertEqual(landed, 5)
        XCTAssertEqual(s.impactsShown, 0, "a refused flight lands at once without an impact node")
    }

    func testNodesAreReused() async {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        var t = 0.0
        s.update(t)
        for _ in 0..<30 {
            s.playSnowball(by: "a", shot: hitShot) {}
            t = run(s, 1.0, from: t)
        }
        XCTAssertEqual(s.snowballFlightCount, 0)
        XCTAssertLessThanOrEqual(s.snowballNodeCount, 8)
    }

    func testVIsTheSnowballKeyOutsidePhotoModeAndOverlays() async {
        let s = scene()
        var fired = 0
        s.onSnowballKey = { fired += 1 }
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        XCTAssertEqual(fired, 1)
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false, modifiers: [.command])
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: true)
        XCTAssertEqual(fired, 1)
        s.isOverlayOpen = true
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        XCTAssertEqual(fired, 1)
        s.isOverlayOpen = false
        s.enterPhotoMode()
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        XCTAssertEqual(fired, 1)
    }

    func testSnowballTargetsSkipDivers() async {
        let s = scene()
        addAll(s, [member("d", p(13, 14), diving: true), member("s", p(12, 14))])
        s.update(0)
        XCTAssertNil(s.snowballTargets["d"])
        XCTAssertNotNil(s.snowballTargets["s"])
    }
}
