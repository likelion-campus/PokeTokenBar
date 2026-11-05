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
}
