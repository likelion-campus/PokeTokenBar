import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// Tall grass in the plaza scene: Pokémon hide, name plates stay, and the grass rustles as they move.
/// Patch A covers x 5-11, y 5-8; (7,10), (4,6), (5,9) and (20,20) are open ground.
@MainActor
final class PlazaTallGrassSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let rightKey: UInt16 = 124
    private let upKey: UInt16 = 126

    private func art() throws -> PlazaTallGrassArt {
        try XCTUnwrap(PlazaTallGrassArt.load(), "the tall grass art ships with the app")
    }

    private func scene(start: TilePoint, tallGrass: PlazaTallGrassArt?, zoom: Int = 2) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: zoom,
                           nickname: "me", tallGrass: tallGrass)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        return s
    }

    /// 32x48 image: 72 world px tall at x1.5, taller than the 30 px the hidden plate sits at.
    private func frames(egg: Bool = false) -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
        var result = PlazaCharacterFrames(front: f, back: f)
        result.isEgg = egg
        return result
    }

    private func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false)
    }

    private func sceneWithMember(at tile: TilePoint, tallGrass: PlazaTallGrassArt?, egg: Bool = false, zoom: Int = 2) -> PlazaScene {
        let s = scene(start: TilePoint(x: 20, y: 22), tallGrass: tallGrass, zoom: zoom)
        s.setCharacter(frames())
        s.applyMembers([member("a", tile)])
        s.setMemberFrames("a", frames(egg: egg))
        return s
    }

    @discardableResult
    private func step(_ s: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0,
                      each: (() -> Void)? = nil) -> TimeInterval {
        var t = start
        s.update(t)
        while t < start + seconds - 1e-9 {
            t += 1.0 / 30
            s.update(t)
            each?()
        }
        return t
    }

    func testATeammateInTheGrassIsHiddenButTheirNameStays() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art())
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        XCTAssertEqual(s.memberNamePlateVisible("a"), true, "the hidden teammate's name plate stays on screen")
        func relativeTop() throws -> CGFloat {   // plate top above the foot, so moving the teammate does not count
            try XCTUnwrap(s.memberNamePlateTop("a")) + 2 * XCTUnwrap(s.memberFoot("a")).y
        }
        let hiddenTop = try relativeTop()
        s.applyMembers([member("a", TilePoint(x: 7, y: 10))])
        s.setMemberFrames("a", frames())
        step(s, seconds: 1, from: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertGreaterThan(try relativeTop(), hiddenTop)
    }

    func testATeammateFadesAcrossAStepIntoTheGrass() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 4), tallGrass: try art())   // (7,4) is open ground, (7,5) grass
        var t = step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        s.applyMembers([member("a", TilePoint(x: 7, y: 5))])
        var samples: [CGFloat] = []
        t = step(s, seconds: 0.4, from: t) { samples.append(s.memberOpacity("a") ?? -1) }
        XCTAssertTrue(samples.contains { (0.05...0.95).contains($0) }, "\(samples)")
        XCTAssertEqual(s.memberOpacity("a"), 0)
    }

    func testIWalkInAndFadeToFortyPercent() throws {
        let s = scene(start: TilePoint(x: 4, y: 6), tallGrass: try art())
        s.setCharacter(frames())
        var t = step(s, seconds: 0.1)
        XCTAssertEqual(s.myOpacity, 1)
        s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        var samples: [CGFloat] = []
        t = step(s, seconds: 0.12, from: t) { samples.append(s.myOpacity) }
        s.handleKeyUp(keyCode: rightKey)
        // A fade, not a jump: some frame lands well inside the step, clear of both ends (Float32 storage cannot fake this).
        XCTAssertTrue(samples.contains { (0.45...0.95).contains($0) }, "\(samples)")
        step(s, seconds: 1, from: t)
        XCTAssertEqual(s.walker.tile, TilePoint(x: 5, y: 6))
        XCTAssertEqual(s.myOpacity, 0.4, accuracy: 0.001)
    }

    func testStepsIntoGrassRustleTheWayIGo() throws {
        let a = try art()
        var s = scene(start: TilePoint(x: 4, y: 6), tallGrass: a)
        s.setCharacter(frames())
        var t = step(s, seconds: 0.1)
        s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        step(s, seconds: 1.0 / 30, from: t)
        var rustles = try XCTUnwrap(s.tallGrassLayer).activeRustles
        XCTAssertTrue(rustles.contains { $0.tile == TilePoint(x: 5, y: 6) && $0.kind == .sway(1) && $0.strong }, "\(rustles)")

        s = scene(start: TilePoint(x: 5, y: 9), tallGrass: a)
        s.setCharacter(frames())
        t = step(s, seconds: 0.1)
        s.handleKeyDown(keyCode: upKey, characters: nil, isRepeat: false)
        step(s, seconds: 1.0 / 30, from: t)
        rustles = try XCTUnwrap(s.tallGrassLayer).activeRustles
        XCTAssertTrue(rustles.contains { $0.tile == TilePoint(x: 5, y: 8) && $0.kind == .bounce && $0.strong }, "\(rustles)")
    }

    func testAStillHiddenTeammateTwitches() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art())
        let layer = try XCTUnwrap(s.tallGrassLayer)
        var twitches = 0
        var t = step(s, seconds: 1.8) {
            if layer.activeRustles.contains(where: { $0.tile == TilePoint(x: 7, y: 6) && !$0.strong && $0.kind != .bounce }) { twitches += 1 }
        }
        XCTAssertGreaterThan(twitches, 0)

        t = step(s, seconds: 1.5, from: t)   // the first twitch is over; 1.6 s of the next interval has built up, so a missing reset would fire inside the walk
        // The timer restarts whenever the teammate moves, so a walk right after waiting stays quiet.
        s.applyMembers([member("a", TilePoint(x: 7, y: 7))])
        var walkingTwitch = false
        step(s, seconds: 0.25, from: t) {
            if layer.activeRustles.contains(where: { $0.kind != .bounce && !$0.strong }) { walkingTwitch = true }
        }
        XCTAssertFalse(walkingTwitch)
    }

    func testTheIdleTwitchAlternatesSides() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art())
        let layer = try XCTUnwrap(s.tallGrassLayer)
        var kinds: [PlazaRustleKind] = []
        var wasOn = false
        step(s, seconds: 3.6) {
            let on = layer.activeRustles.first { $0.tile == TilePoint(x: 7, y: 6) && !$0.strong && $0.kind != .bounce }
            if let on, !wasOn { kinds.append(on.kind) }
            wasOn = on != nil
        }
        XCTAssertEqual(kinds, [.sway(1), .sway(-1)])
    }

    /// Driven only through playJump and update: the landing bounce rides the scene clock, not an action.
    private func jump(from tile: TilePoint, grass: PlazaTallGrassArt) -> (opacityAt18: CGFloat, opacityAt50: CGFloat, bounced: [TimeInterval]) {
        let s = scene(start: tile, tallGrass: grass)
        s.setCharacter(frames())
        var t = step(s, seconds: 0.1)
        s.playJump(memberID: nil)
        let layer = s.tallGrassLayer!
        let start = t
        var at18: CGFloat = -1, at50: CGFloat = -1
        var bounced: [TimeInterval] = []
        while t < start + 0.52 {
            t += 1.0 / 30
            s.update(t)
            let e = t - start
            if abs(e - 0.18) < 1.0 / 60 { at18 = s.myOpacity }
            if abs(e - 0.5) < 1.0 / 60 { at50 = s.myOpacity }
            if layer.activeRustles.contains(where: { $0.tile == tile && $0.kind == .bounce && !$0.strong }) { bounced.append(e) }
        }
        return (at18, at50, bounced)
    }

    func testAJumpInGrassPopsOutThenLandsWithABounce() throws {
        let r = jump(from: TilePoint(x: 6, y: 6), grass: try art())
        XCTAssertEqual(r.opacityAt18, 1, accuracy: 0.001)
        XCTAssertEqual(r.opacityAt50, 0.4, accuracy: 0.001)
        let first = try XCTUnwrap(r.bounced.first, "no landing bounce")
        XCTAssertGreaterThanOrEqual(first, 0.33)
        XCTAssertLessThanOrEqual(first, 0.46)
    }

    func testALandingOnOpenGroundDoesNotRustle() throws {
        let r = jump(from: TilePoint(x: 4, y: 6), grass: try art())
        XCTAssertTrue(r.bounced.isEmpty)
    }

    func testHidingTheBackgroundShowsEveryone() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art())
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        s.setBackgroundHidden(true)
        step(s, seconds: 2, from: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertTrue(try XCTUnwrap(s.tallGrassLayer).activeRustles.isEmpty)
    }

    func testWithoutTheArtNobodyHides() {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: nil)
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertNil(s.tallGrassLayer)
    }

    func testATeammateSnappedIntoGrassHidesWithoutARustle() throws {
        let s = sceneWithMember(at: TilePoint(x: 20, y: 20), tallGrass: try art())
        let t = step(s, seconds: 0.1)
        s.applyMembers([member("a", TilePoint(x: 7, y: 6))])
        step(s, seconds: 0.1, from: t)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        XCTAssertTrue(try XCTUnwrap(s.tallGrassLayer).activeRustles.isEmpty)
    }

    func testAnEggInTheGrassHidesWithItsNest() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art(), egg: true)
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        XCTAssertEqual(s.memberNestFrontOpacity("a"), 0)
        XCTAssertEqual(s.memberShadowOpacity("a"), 0, "the nest back is the shadow node")
    }

    func testAHiddenTeammatesShadowIsHiddenAndMineStaysAtFortyPercent() throws {
        let a = try art()
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: a)
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberShadowOpacity("a"), 0)
        let mine = scene(start: TilePoint(x: 6, y: 6), tallGrass: a)
        mine.setCharacter(frames())
        step(mine, seconds: 0.1)
        XCTAssertEqual(mine.myShadowOpacity, 0.4, accuracy: 0.001)
    }

    /// My plate top above my foot, in world px.
    private func myPlateHeight(_ s: PlazaScene) -> CGFloat {
        s.myNamePlateTop / CGFloat(s.zoom) + s.cameraPosition.y - (map.pixelSize.height - s.myFootPoint.y)
    }

    func testMyNameTagStaysOnMyHeadInTheGrass() throws {
        let a = try art()
        let hidden = scene(start: TilePoint(x: 6, y: 6), tallGrass: a)
        let open = scene(start: TilePoint(x: 7, y: 10), tallGrass: a)
        for s in [hidden, open] {
            s.setCharacter(frames())
            step(s, seconds: 0.1)
        }
        XCTAssertEqual(hidden.myOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(myPlateHeight(hidden), myPlateHeight(open), accuracy: 1)
    }

    func testMySparkleStaysAboveMyHeadInTheGrass() throws {
        let s = scene(start: TilePoint(x: 6, y: 6), tallGrass: try art())
        s.setCharacter(frames())
        step(s, seconds: 0.1)
        s.playSparkle(memberID: nil)
        let center = try XCTUnwrap(s.sparkleCenter)
        XCTAssertEqual(center.y, map.pixelSize.height - s.myFootPoint.y + max(s.characterSize.height, 24) * 0.6, accuracy: 1)
    }

    func testTheTallGrassBandsShareOneTexturePerSlice() throws {
        let layer = try XCTUnwrap(scene(start: TilePoint(x: 20, y: 22), tallGrass: try art()).tallGrassLayer)
        XCTAssertGreaterThan(layer.bandCount, 9)
        XCTAssertLessThanOrEqual(layer.distinctBandTextureCount, 9)
    }

    func testTheHiddenNameSitsOnTheGrassAtEveryZoom() throws {
        let a = try art()
        for zoom in [1, 3] {
            for backing: CGFloat in [1, 2] {
                let hidden = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: a, zoom: zoom)
                hidden.backingOverride = backing
                let visible = sceneWithMember(at: TilePoint(x: 7, y: 10), tallGrass: a, zoom: zoom)
                visible.backingOverride = backing
                step(hidden, seconds: 0.1)
                step(visible, seconds: 0.1)
                let drop = try XCTUnwrap(visible.memberNamePlateTop("a")) - XCTUnwrap(hidden.memberNamePlateTop("a"))
                // Tile (7,10) is 4 tiles below (7,6); the camera follows me, so compare in world terms via the foot offset.
                let footDelta = CGFloat(zoom) * (try XCTUnwrap(visible.memberFoot("a")).y - XCTUnwrap(hidden.memberFoot("a")).y)
                let expected = CGFloat(zoom) * (72 - PlazaTallGrass.hiddenPlateLift)
                XCTAssertEqual(drop + footDelta, expected, accuracy: 1, "zoom \(zoom) backing \(backing)")
            }
        }
    }

    func testAHiddenTeammatesSparkleBurstsAtTheirName() throws {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: try art())
        step(s, seconds: 0.1)
        s.playSparkle(memberID: "a")
        let foot = try XCTUnwrap(s.memberFoot("a"))
        let center = try XCTUnwrap(s.sparkleCenter)
        XCTAssertEqual(center.y, map.pixelSize.height - foot.y + PlazaTallGrass.hiddenPlateLift, accuracy: 1)
    }
}
