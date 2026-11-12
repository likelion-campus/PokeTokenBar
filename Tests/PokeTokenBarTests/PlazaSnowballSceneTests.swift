import XCTest
import AppKit
import CoreGraphics
@testable import PokeTokenBar

/// Snowballs in the scene: the pooled flight layer, the burst, the landing callback and the V key.
@MainActor
final class PlazaSnowballSceneTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene(start: TilePoint = TilePoint(x: 14, y: 12)) -> PlazaScene {
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
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
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

    func testABallFliesATileATenthAndLandsOnce() {
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

    func testAHitShowsTheImpactStarAndTheThrowerLunges() {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        s.playSnowball(by: "a", shot: hitShot) {}
        s.update(0.05)   // the lunge starts at 0 and grows with the first frame
        XCTAssertNotEqual(s.lungeOffset(memberID: "a"), .zero)
        run(s, 0.5, from: 0.05)
        XCTAssertEqual(s.impactCount, 1)
    }

    func testAMissInTheWaterSplashesInsteadOfBursting() {
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

    func testAPausedSceneDrawsNothingAndLandsAtOnce() {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        s.isPaused = true
        let before = s.children.count
        var landed = 0
        s.playSnowball(by: "a", shot: hitShot) { landed += 1 }
        XCTAssertEqual(landed, 1)
        XCTAssertEqual(s.snowballSpriteCount, 0)
        XCTAssertEqual(s.impactCount, 0)
        XCTAssertEqual(s.children.count, before)
    }

    func testPausingMidFlightLandsEveryBallAtOnce() {
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

    func testFlightsBeyondTheCapLandAtOnce() {
        let s = scene()
        addAll(s, [member("a", p(10, 12))])
        s.update(0)
        var landed = 0
        for _ in 0..<(PlazaSnowballLayer.maxFlights + 5) { s.playSnowball(by: "a", shot: hitShot) { landed += 1 } }
        XCTAssertEqual(s.snowballFlightCount, PlazaSnowballLayer.maxFlights)
        XCTAssertEqual(landed, 5)
    }

    func testNodesAreReused() {
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

    func testVIsTheSnowballKeyOutsidePhotoModeAndOverlays() {
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

    func testSnowballTargetsSkipDivers() {
        let s = scene()
        addAll(s, [member("d", p(13, 14), diving: true), member("s", p(12, 14))])
        s.update(0)
        XCTAssertNil(s.snowballTargets["d"])
        XCTAssertNotNil(s.snowballTargets["s"])
    }
}
