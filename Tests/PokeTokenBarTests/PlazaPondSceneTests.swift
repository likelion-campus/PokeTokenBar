import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// Swimmers and divers in the plaza scene, on the real map: x32-37 y17-19 is water, (31,18) shore, (30,18) land.
/// Sprites are 32x48 (72 world px at x1.5).
@MainActor
final class PlazaPondSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let leftKey: UInt16 = 123
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene(start: TilePoint, pondVisuals: Bool = true) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: pondVisuals)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.setCharacter(frames())
        return s
    }

    private func frames() -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, _ tile: TilePoint?, diving: Bool = false, away: Bool = false) -> PlazaSceneMember {
        var m = PlazaSceneMember(memberID: id, nickname: id, isAway: away, tile: tile, facing: .down, isWalking: false)
        m.isDiving = diving
        return m
    }

    private func add(_ s: PlazaScene, _ id: String, _ tile: TilePoint?, diving: Bool = false, away: Bool = false) {
        s.applyMembers([member(id, tile, diving: diving, away: away)])
        s.setMemberFrames(id, frames())
    }

    @discardableResult
    private func run(_ s: PlazaScene, _ seconds: TimeInterval, from start: TimeInterval = 0) -> TimeInterval {
        var t = start
        s.update(t)
        while t < start + seconds - 1e-9 { t += 1.0 / 30; s.update(t) }
        return t
    }

    func testSwimmersShowOnlyTheirTop() throws {
        let s = scene(start: p(20, 22))
        add(s, "a", p(34, 18))
        run(s, 0.1)
        let h = try XCTUnwrap(s.memberVisibleHeight("a"))
        XCTAssertEqual(h, 72 * 0.45, accuracy: 1)
        XCTAssertEqual(s.memberSwimRingVisible("a"), true)
        XCTAssertEqual(s.memberShadowOpacity("a"), 0)
        s.applyMembers([member("a", p(30, 18))])
        run(s, 3, from: 0.1)
        XCTAssertEqual(s.memberTiles["a"], p(30, 18))
        XCTAssertEqual(s.memberVisibleHeight("a"), 72)
        XCTAssertEqual(s.memberSwimRingVisible("a"), false)
        XCTAssertGreaterThan(try XCTUnwrap(s.memberShadowOpacity("a")), 0)
    }

    func testPlungeStaysUncutUntilItLandsInTheWater() {
        let s = scene(start: p(20, 22))
        add(s, "a", p(31, 18))
        var t = run(s, 0.1)
        XCTAssertEqual(s.memberVisibleHeight("a"), 72)
        s.applyMembers([member("a", p(32, 18))])
        t = run(s, 0.04, from: t)
        XCTAssertEqual(s.memberVisibleHeight("a"), 72, "mid-step from land")
        XCTAssertEqual(s.memberSwimRingVisible("a"), false)
        run(s, 0.5, from: t)
        XCTAssertEqual(s.memberTiles["a"], p(32, 18))
        XCTAssertEqual(s.memberVisibleHeight("a") ?? 0, 72 * 0.45, accuracy: 1)
        XCTAssertEqual(s.memberSwimRingVisible("a"), true)
    }

    func testClimbingOutIsUncutFromTheStepStart() {
        let s = scene(start: p(32, 18))
        var t = run(s, 0.1)
        XCTAssertEqual(s.myVisibleHeight, 72 * 0.45, accuracy: 1)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        t = run(s, 0.05, from: t)
        s.handleKeyUp(keyCode: leftKey)
        XCTAssertTrue(s.walker.isWalking)
        XCTAssertEqual(s.myVisibleHeight, 72, "mid-step out of the water")
    }

    func testMeSwimmingIsCutToo() {
        let s = scene(start: p(33, 18))
        run(s, 0.1)
        XCTAssertEqual(s.myVisibleHeight, 72 * 0.45, accuracy: 1)
        XCTAssertEqual(s.myShadowOpacity, 0)
    }

    func testDivingHidesAndTimesOut() {
        let s = scene(start: p(33, 18))
        var calls: [Bool] = []
        s.onDivingChange = { calls.append($0) }
        var t = run(s, 0.1)
        XCTAssertEqual(s.myOpacity, 1)
        s.setDiving(true)
        XCTAssertTrue(s.isDiving)
        t = run(s, 0.3, from: t)
        XCTAssertEqual(s.myOpacity, 0.4, accuracy: 0.001)
        t = run(s, 5.3, from: t)   // 5.7 s of diving
        XCTAssertTrue(s.isDiving)
        run(s, 0.5, from: t)       // 6.2 s
        XCTAssertFalse(s.isDiving)
        XCTAssertEqual(calls, [false])
    }

    func testWaterTypeDivesLonger() {
        let s = scene(start: p(33, 18))
        s.diveLimit = 15
        var calls: [Bool] = []
        s.onDivingChange = { calls.append($0) }
        var t = run(s, 0.1)
        s.setDiving(true)
        t = run(s, 6.1, from: t)
        XCTAssertTrue(s.isDiving)
        XCTAssertEqual(calls, [])
        run(s, 9, from: t)
        XCTAssertFalse(s.isDiving)
        XCTAssertEqual(calls, [false])
    }

    func testLeavingTheWaterEndsTheDive() {
        let s = scene(start: p(32, 18))
        var calls: [Bool] = []
        s.onDivingChange = { calls.append($0) }
        var t = run(s, 0.1)
        s.setDiving(true)
        t = run(s, 0.5, from: t)
        XCTAssertTrue(s.isDiving)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        s.handleKeyUp(keyCode: leftKey)
        t = run(s, 0.5, from: t)
        XCTAssertEqual(s.walker.tile, p(31, 18))
        XCTAssertFalse(s.isDiving)
        XCTAssertEqual(calls, [false])
        run(s, 0.5, from: t)
        XCTAssertEqual(s.myOpacity, 1)
    }

    func testSetDivingIsQuietAndNeedsWater() {
        let land = scene(start: p(30, 18))
        land.setDiving(true)
        XCTAssertFalse(land.isDiving, "no dive on land")
        let s = scene(start: p(33, 18))
        var calls = 0
        s.onDivingChange = { _ in calls += 1 }
        s.setDiving(true)
        s.setDiving(false)
        XCTAssertFalse(s.isDiving)
        XCTAssertEqual(calls, 0, "controller-initiated changes do not call back")
    }

    func testTeammateDivingFollowsPresence() throws {
        let s = scene(start: p(20, 22))
        add(s, "a", p(34, 18))
        var t = run(s, 0.1)
        func relativeTop() throws -> CGFloat {
            try XCTUnwrap(s.memberNamePlateTop("a")) + 2 * XCTUnwrap(s.memberFoot("a")).y
        }
        let surfaceTop = try relativeTop()
        s.applyMembers([member("a", p(34, 18), diving: true)])
        t = run(s, 0.3, from: t)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        XCTAssertEqual(s.memberIsDiving("a"), true)
        XCTAssertLessThan(try relativeTop(), surfaceTop, "the name plate drops onto the water")
        s.applyMembers([member("a", p(34, 18), diving: false)])
        t = run(s, 0.3, from: t)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertEqual(s.memberIsDiving("a"), false)

        // Away: wandering the shelter, never shown as a diver.
        s.applyMembers([member("a", nil, diving: true, away: true)])
        t = run(s, 0.5, from: t)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertEqual(s.memberIsDiving("a"), false)

        // Presence says diving but the displayed position is still on land: stays visible.
        s.applyMembers([member("a", p(30, 18), diving: true)])
        run(s, 0.05, from: t)
        s.applyMembers([member("a", p(30, 18), diving: true)])
        XCTAssertEqual(s.memberOpacity("a"), 1)
    }

    func testBackgroundHiddenShowsDiversAndRestores() throws {
        let s = scene(start: p(33, 18))
        add(s, "a", p(34, 18), diving: true)
        var t = run(s, 0.1)
        s.setDiving(true)
        t = run(s, 0.4, from: t)
        XCTAssertEqual(s.myOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        let layer = try XCTUnwrap(s.pondLayer)
        layer.splash(at: p(34, 18), big: true)
        XCTAssertGreaterThan(layer.dropletCount, 0)
        s.setBackgroundHidden(true)
        XCTAssertEqual(s.myOpacity, 1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertEqual(s.myVisibleHeight, 72, "no swim cut while the background is hidden")
        XCTAssertEqual(s.memberVisibleHeight("a"), 72)
        XCTAssertEqual(layer.dropletCount + layer.ringCount + layer.pendingCount, 0)
        t = run(s, 0.3, from: t)
        XCTAssertEqual(s.myOpacity, 1)
        XCTAssertTrue(s.isDiving, "the dive state survives")
        XCTAssertTrue(s.isMeInWater)
        s.setBackgroundHidden(false)
        XCTAssertEqual(s.myOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(s.memberOpacity("a"), 0)
        XCTAssertEqual(s.myVisibleHeight, 72 * 0.45, accuracy: 1)
    }

    func testWithoutPondVisualsNothingIsCut() {
        let s = scene(start: p(33, 18), pondVisuals: false)
        add(s, "a", p(34, 18), diving: true)
        var t = run(s, 0.1)
        s.setDiving(true)
        t = run(s, 0.4, from: t)
        XCTAssertNil(s.pondLayer)
        XCTAssertTrue(s.isDiving, "the state is kept")
        XCTAssertEqual(s.myVisibleHeight, 72)
        XCTAssertEqual(s.myOpacity, 1)
        XCTAssertEqual(s.memberVisibleHeight("a"), 72)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertEqual(s.memberSwimRingVisible("a"), false)
    }

    // MARK: - Z plunge, splashes, wet, bubbles

    private let rightKey: UInt16 = 124

    private func at(_ id: String, _ tile: TilePoint, stage: Int = 1, diving: Bool = false) -> PlazaSceneMember {
        var m = member(id, tile, diving: diving)
        m.evolutionStage = stage
        return m
    }

    private func addAll(_ s: PlazaScene, _ members: [PlazaSceneMember]) {
        s.applyMembers(members)
        for m in members { s.setMemberFrames(m.memberID, frames()) }
    }

    func testPlungeSplashesBigAndWetsByStage() throws {
        let s = scene(start: p(31, 18))
        s.myEvolutionStage = 3
        addAll(s, [at("near", p(29, 18)), at("edge", p(30, 20)), at("far", p(28, 18))])   // distance 3, 3, 4 from (32,18)
        s.face(.right)
        var t = run(s, 0.1)
        XCTAssertEqual(s.pondAction(canMove: true), .plunge(.right))
        s.plunge(.right)
        let layer = try XCTUnwrap(s.pondLayer)
        t = run(s, 0.2, from: t)
        XCTAssertEqual(layer.dropletCount, 0, "the splash waits for the landing")
        XCTAssertEqual(s.isWet(memberID: "near"), false)
        run(s, 0.2, from: t)
        XCTAssertTrue(s.isMeInWater)
        XCTAssertEqual(layer.dropletCount, 10)
        XCTAssertGreaterThanOrEqual(layer.ringCount, 1)
        XCTAssertEqual(s.isWet(memberID: "near"), true)
        XCTAssertEqual(s.isWet(memberID: "edge"), true)
        XCTAssertEqual(s.isWet(memberID: "far"), false)
        XCTAssertEqual(s.isWet(memberID: nil), false, "the splasher stays dry")
    }

    func testShoreJumpSplashesSmall() throws {
        let s = scene(start: p(31, 18))
        addAll(s, [at("near", p(31, 19)), at("far", p(30, 18))])   // distance 1 and 2 from (32,18)
        s.face(.down)
        var t = run(s, 0.1)
        XCTAssertEqual(s.pondAction(canMove: true), .shoreJump)
        s.playJump(memberID: nil)
        let layer = try XCTUnwrap(s.pondLayer)
        t = run(s, 0.2, from: t)
        XCTAssertEqual(layer.dropletCount, 0)
        run(s, 0.2, from: t)
        XCTAssertEqual(layer.dropletCount, 4)
        XCTAssertEqual(layer.ringCount, 1)
        XCTAssertEqual(s.isWet(memberID: "near"), true)
        XCTAssertEqual(s.isWet(memberID: "far"), false)
    }

    func testTeammateShoreJumpSplashesToo() throws {
        let s = scene(start: p(20, 22))
        addAll(s, [at("a", p(31, 18)), at("b", p(31, 19))])
        var t = run(s, 0.1)
        s.playJump(memberID: "a")
        t = run(s, 0.5, from: t)
        let layer = try XCTUnwrap(s.pondLayer)
        XCTAssertGreaterThan(layer.dropletCount, 0)
        XCTAssertEqual(s.isWet(memberID: "b"), true)
        XCTAssertEqual(s.isWet(memberID: "a"), false)
    }

    func testSurfacingSplashesButLeavingTheWaterDoesNot() throws {
        let s = scene(start: p(33, 18))
        s.myEvolutionStage = 2
        addAll(s, [at("a", p(31, 18))])   // distance 2 from (33,18)
        var t = run(s, 0.1)
        let layer = try XCTUnwrap(s.pondLayer)
        s.setDiving(true)
        t = run(s, 0.8, from: t)
        XCTAssertEqual(layer.dropletCount, 0, "diving itself makes no splash")
        s.setDiving(false)
        XCTAssertEqual(layer.dropletCount, 10)
        XCTAssertEqual(s.isWet(memberID: "a"), true)

        // Timing out surfaces in place with a splash too.
        t = run(s, 3, from: t)
        XCTAssertEqual(layer.dropletCount, 0)
        s.setDiving(true)
        t = run(s, 6.2, from: t)
        XCTAssertFalse(s.isDiving)
        XCTAssertGreaterThan(layer.dropletCount + layer.ringCount, 0, "the timeout surfaces with a splash")

        // Climbing out while diving makes none.
        let out = scene(start: p(32, 18))
        out.myEvolutionStage = 3
        let outLayer = try XCTUnwrap(out.pondLayer)
        var u = run(out, 0.1)
        out.setDiving(true)
        u = run(out, 0.5, from: u)
        out.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        out.handleKeyUp(keyCode: leftKey)
        var peak = 0
        for _ in 0..<30 { u += 1.0 / 30; out.update(u); peak = max(peak, outLayer.dropletCount + outLayer.ringCount + outLayer.pendingCount) }
        XCTAssertEqual(out.walker.tile, p(31, 18))
        XCTAssertFalse(out.isDiving)
        XCTAssertEqual(peak, 0)
    }

    func testTeammateSurfacingSplashesWithTheirStage() throws {
        let s = scene(start: p(20, 22))
        addAll(s, [at("a", p(34, 18), stage: 2, diving: true), at("in", p(34, 20)), at("out", p(34, 21))])   // distance 2 and 3
        var t = run(s, 0.3)
        let layer = try XCTUnwrap(s.pondLayer)
        XCTAssertEqual(layer.dropletCount, 0)
        s.applyMembers([at("a", p(34, 18), stage: 2), at("in", p(34, 20)), at("out", p(34, 21))])
        t = run(s, 0.1, from: t)
        XCTAssertEqual(layer.dropletCount, 10)
        XCTAssertEqual(s.isWet(memberID: "in"), true)
        XCTAssertEqual(s.isWet(memberID: "out"), false)
        XCTAssertEqual(s.isWet(memberID: "a"), false)
    }

    func testTeammateClimbingOutWhileSurfacingMakesNoSplash() throws {
        let s = scene(start: p(20, 22))
        addAll(s, [at("a", p(32, 18), stage: 3, diving: true), at("b", p(31, 19))])
        var t = run(s, 0.3)
        let layer = try XCTUnwrap(s.pondLayer)
        // Their presence now reports land and no dive; my copy of them still lags on the water.
        s.applyMembers([at("a", p(31, 18), stage: 3), at("b", p(31, 19))])
        var peak = 0
        for _ in 0..<3 { t += 1.0 / 30; s.update(t); peak = max(peak, layer.dropletCount + layer.pendingCount) }
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(s.isWet(memberID: "b"), false)
    }

    func testDiversBlowBubbles() throws {
        let s = scene(start: p(33, 18))
        addAll(s, [at("a", p(35, 18), diving: true)])
        var t = run(s, 0.1)
        let layer = try XCTUnwrap(s.pondLayer)
        s.setDiving(true)
        var peak = 0
        for _ in 0..<30 { t += 1.0 / 30; s.update(t); peak = max(peak, layer.bubbleCount) }
        XCTAssertGreaterThanOrEqual(peak, 2)
        s.setDiving(false)
        t = run(s, 1.5, from: t)
        // Only the teammate keeps blowing now; with a single diver at most two bubbles overlap.
        XCTAssertLessThanOrEqual(layer.bubbleCount, 2)
        s.applyMembers([at("a", p(35, 18))])
        t = run(s, 1, from: t)
        XCTAssertEqual(layer.bubbleCount, 0, "surfaced swimmers blow none")
    }

    func testWetDoesNotClearAChatBubble() {
        let s = scene(start: p(31, 18))
        addAll(s, [at("a", p(31, 19))])
        s.face(.down)
        var t = run(s, 0.1)
        s.showChat(memberID: "a", text: "hello")
        s.playJump(memberID: nil)
        t = run(s, 0.5, from: t)
        XCTAssertEqual(s.isWet(memberID: "a"), true)
        XCTAssertEqual(s.shownChat(memberID: "a"), "hello")
        run(s, 2.5, from: t)
        XCTAssertEqual(s.isWet(memberID: "a"), false, "the drop lasts two seconds")
    }

    func testPlungeIsBlockedBySwimmerAndRepeatedZ() throws {
        let s = scene(start: p(31, 18))
        addAll(s, [at("swimmer", p(32, 18))])
        s.face(.right)
        var t = run(s, 0.1)
        XCTAssertEqual(s.pondAction(canMove: true), .shoreJump)
        s.applyMembers([at("swimmer", p(35, 18))])
        t = run(s, 0.1, from: t)
        XCTAssertEqual(s.pondAction(canMove: true), .plunge(.right))
        XCTAssertEqual(s.pondAction(canMove: false), .shoreJump)
        s.plunge(.right)
        t = run(s, 0.1, from: t)
        XCTAssertTrue(s.walker.isWalking)
        s.plunge(.right)   // a second Z in the middle of the plunge step
        run(s, 1, from: t)
        XCTAssertEqual(s.walker.tile, p(32, 18), "one tile only")
    }

    func testPlungingWhileWalkingToAMemberStopsTheWalk() {
        let s = scene(start: p(31, 18))
        addAll(s, [at("far", p(20, 22))])
        s.face(.right)
        var t = run(s, 0.1)
        XCTAssertTrue(s.walk(toMember: "far"))
        s.plunge(.right)
        t = run(s, 0.8, from: t)
        XCTAssertNil(s.walkingToMember)
        XCTAssertTrue(s.isMeInWater)
        XCTAssertEqual(s.walker.tile, p(32, 18))
    }

    func testNoParticlesOrWetWithoutPondVisualsOrWithTheBackgroundHidden() throws {
        let plain = scene(start: p(31, 18), pondVisuals: false)
        addAll(plain, [at("a", p(31, 19))])
        plain.face(.right)
        var t = run(plain, 0.1)
        plain.plunge(.right)
        t = run(plain, 0.6, from: t)
        XCTAssertTrue(plain.isMeInWater)
        XCTAssertEqual(plain.isWet(memberID: "a"), false)
        plain.myEvolutionStage = 3
        plain.setDiving(true)
        plain.setDiving(false)   // a surfacing splash would reach the neighbours
        XCTAssertEqual(plain.isWet(memberID: "a"), false)

        let hidden = scene(start: p(31, 18))
        addAll(hidden, [at("a", p(31, 19))])
        hidden.face(.right)
        hidden.setBackgroundHidden(true)
        let layer = try XCTUnwrap(hidden.pondLayer)
        var u = run(hidden, 0.1)
        hidden.plunge(.right)
        var peak = 0
        for _ in 0..<20 { u += 1.0 / 30; hidden.update(u); peak = max(peak, layer.dropletCount + layer.ringCount + layer.pendingCount) }
        XCTAssertTrue(hidden.isMeInWater)
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(hidden.isWet(memberID: "a"), false)
        hidden.setDiving(true)
        u = run(hidden, 1, from: u)
        XCTAssertEqual(layer.bubbleCount, 0)
    }
}
