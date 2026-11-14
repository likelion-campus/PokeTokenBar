import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// Pushes at the right pond (x32-38 y14-20 is water): into it, inside it, and out of it. Bushes block (24,15) and (24,16).
@MainActor
final class PlazaTackleWaterTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: PlazaMapData.map, mapImage: PlazaTileArt.plainGrassImage(PlazaMapData.map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true)
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
        let f = [PlazaFrame(image: PlazaImage(cgImage: ctx.makeImage()!), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false)
    }

    private func addAll(_ s: PlazaScene, _ members: [PlazaSceneMember]) {
        s.applyMembers(members)
        for m in members { s.setMemberFrames(m.memberID, frames()) }
    }

    /// Runs the scene and returns the end time and the most splash particles seen on one frame.
    @discardableResult
    private func run(_ s: PlazaScene, _ seconds: TimeInterval, from start: TimeInterval = 0, peak: UnsafeMutablePointer<Int>? = nil) -> TimeInterval {
        var t = start
        s.update(t)
        while t < start + seconds - 1e-9 {
            t += 1.0 / 30
            s.update(t)
            if let peak, let layer = s.pondLayer { peak.pointee = max(peak.pointee, layer.dropletCount) }
        }
        return t
    }

    func testPushFromLandEndsOnTheFirstWaterTileWithABigSplash() {
        let s = scene(start: p(30, 16))
        s.myEvolutionStage = 3
        addAll(s, [member("near", p(31, 14)), member("far", p(27, 16))])   // 3 and 5 tiles from (32,16)
        var peak = 0
        run(s, 0.1)
        s.pushMe(.right, tiles: 3)
        run(s, 2, from: 0.1, peak: &peak)
        XCTAssertEqual(s.walker.tile, p(32, 16), "the push ends in the water even though one tile was left")
        XCTAssertTrue(s.isMeInWater)
        XCTAssertEqual(peak, PlazaPondLayer.bigDroplets, "the fall splashes like a plunge")
        XCTAssertEqual(s.isWet(memberID: "near"), true)
        XCTAssertEqual(s.isWet(memberID: "far"), false)
        XCTAssertEqual(s.isWet(memberID: nil), false, "the faller stays dry")
    }

    func testPushedSwimmerMovesThroughTheWater() {
        let s = scene(start: p(33, 16))
        run(s, 0.1)
        s.pushMe(.right, tiles: 2)
        run(s, 2, from: 0.1)
        XCTAssertEqual(s.walker.tile, p(35, 16))
        XCTAssertTrue(s.isMeInWater)
    }

    func testPushedSwimmerLeavesOntoLandAndStopsBeforeABush() {
        let s = scene(start: p(33, 16))
        run(s, 0.1)
        s.pushMe(.left, tiles: 20)
        run(s, 6, from: 0.1)
        XCTAssertEqual(s.walker.tile, p(25, 16), "out of the pond, across the land, and stopped before the bush at x=24")
        XCTAssertFalse(s.isMeInWater)
        let short = scene(start: p(33, 16))
        run(short, 0.1)
        short.pushMe(.left, tiles: 3)
        run(short, 3, from: 0.1)
        XCTAssertEqual(short.walker.tile, p(30, 16), "out of the water and on for what remained")
    }

    func testPushIntoTheWaterWhileHidden() {
        let s = scene(start: p(30, 16))
        run(s, 0.1)
        s.isPaused = true
        var reported: [TilePoint] = []
        s.onLocalPositionChange = { tile, _, _ in reported.append(tile) }
        s.pushMe(.right, tiles: 3)
        XCTAssertEqual(s.walker.tile, p(32, 16))
        XCTAssertEqual(reported.last, p(32, 16))
        s.isPaused = false
        let swimmer = scene(start: p(33, 16))
        run(swimmer, 0.1)
        swimmer.isPaused = true
        swimmer.pushMe(.right, tiles: 3)
        XCTAssertEqual(swimmer.walker.tile, p(36, 16), "swim steps are slower than the time a land push would allow")
    }

    func testADiverIsNotPushed() {
        let s = scene(start: p(33, 16))
        run(s, 0.1)
        s.setDiving(true)
        XCTAssertTrue(s.isDiving)
        s.pushMe(.right, tiles: 2)
        run(s, 2, from: 0.1)
        XCTAssertEqual(s.walker.tile, p(33, 16))
    }

    func testAnEggPushedIntoTheWaterClimbsOutByItself() {
        let s = scene(start: p(30, 16))
        s.canWalk = false
        var t = run(s, 0.1)
        s.pushMe(.right, tiles: 3)
        t = run(s, 0.2, from: t)
        XCTAssertEqual(s.walker.tile, p(32, 16))
        t = run(s, 1.5, from: t)
        XCTAssertEqual(s.walker.tile, p(31, 16), "back on the nearest shore")
    }

    func testATeammatePushedIntoTheWaterSplashesOnMyScreen() throws {
        let s = scene(start: p(20, 22))
        addAll(s, [member("a", p(31, 16)), member("wet", p(30, 16))])
        var peak = 0
        var t = run(s, 0.1)
        s.applyMembers([member("a", p(32, 16)), member("wet", p(31, 16))])
        t = run(s, 1.5, from: t, peak: &peak)
        XCTAssertEqual(s.memberIsInWater("a"), true)
        XCTAssertEqual(peak, PlazaPondLayer.bigDroplets, "a land to water move splashes whoever made it")
        XCTAssertEqual(s.isWet(memberID: "wet"), true)
    }
}
