import XCTest
import CoreGraphics
@testable import PokeTokenBar

@MainActor
final class PlazaDittoSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private let key = PlazaDitto.sceneKey

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: p(20, 22), zoom: 2, nickname: "me")
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
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

    private func shown(_ tile: TilePoint = TilePoint(x: 22, y: 22), name: String = "메타몽", title: String? = nil,
                       decoy: Bool = false, color: PlazaColor = PlazaColor(srgbRed: 1, green: 0, blue: 0)) -> PlazaDittoShown {
        PlazaDittoShown(tile: tile, facing: .down, isWalking: false, isRunning: false,
                        name: name, nameColor: color, title: title, isDecoy: decoy)
    }

    func testApplyDittoShowsAndRemovesIt() {
        let s = scene()
        s.applyDitto(shown())
        XCTAssertEqual(s.memberName(key), "메타몽")
        XCTAssertEqual(s.dittoTile, p(22, 22))
        s.applyDitto(nil)
        XCTAssertNil(s.memberName(key))
        XCTAssertNil(s.dittoTile)
    }

    func testMembersUpdateLeavesTheDittoAlone() {
        let s = scene()
        s.applyDitto(shown())
        s.applyMembers([])
        XCTAssertEqual(s.memberName(key), "메타몽")
    }

    func testTheDittoIsNotAMemberTargetButBlocksItsTile() throws {
        let s = scene()
        s.applyDitto(shown())
        XCTAssertNil(s.memberTiles[key])
        XCTAssertTrue(s.occupiedTiles().contains(try XCTUnwrap(s.dittoTile)))
    }

    func testDecoyTileOnlyWhileACopy() {
        let s = scene()
        XCTAssertNil(s.decoyTile)
        s.applyDitto(shown())
        XCTAssertNil(s.decoyTile)
        s.applyDitto(shown(decoy: true))
        XCTAssertEqual(s.decoyTile, p(22, 22))
    }

    func testTheCopyShowsTheGivenNameColourAndTitle() {
        let s = scene()
        let c = PlazaColor(srgbRed: 0, green: 1, blue: 0)
        s.applyDitto(shown(name: "재헌", title: "천진난만한", decoy: true, color: c))
        XCTAssertEqual(s.memberName(key), "재헌")
        XCTAssertEqual(s.memberNameColor(key), c)
        XCTAssertEqual(s.memberTitle(key), "천진난만한")
    }

    func testAFarJumpSnapsAtOnce() throws {
        let s = scene()
        s.applyDitto(shown(p(22, 22)))
        s.applyDitto(shown(p(23, 22)))
        s.applyDitto(shown(p(30, 22)))
        let foot = try XCTUnwrap(s.memberFoot(key))
        s.applyDitto(nil)
        s.applyDitto(shown(p(30, 22)))
        XCTAssertEqual(foot, s.memberFoot(key))
    }

    func testAQueuedTwoStepWalkGlidesInsteadOfSnapping() throws {
        let s = scene()
        s.applyDitto(shown(p(22, 22)))
        let start = try XCTUnwrap(s.memberFoot(key))
        s.applyDitto(shown(p(23, 22)))
        s.applyDitto(shown(p(24, 22)))   // before the first step starts: continues from the queued tile
        XCTAssertEqual(s.memberFoot(key), start)
        s.applyDitto(nil)
        s.applyDitto(shown(p(24, 22)))
        XCTAssertNotEqual(s.memberFoot(key), start)
    }

    /// A dance that arrives while the Ditto is walking waits for it to stop; if it moves on to another tile meanwhile, the
    /// dance (decided for the old tile) is dropped.
    func testAParkedDanceIsDroppedWhenTheDittoMovesOn() {
        let s = scene()
        s.applyDitto(shown(p(22, 22)))
        s.setMemberFrames(key, frames())
        s.applyDitto(shown(p(23, 22)))   // a step
        XCTAssertFalse(s.playDance(memberID: key, style: "spin"), "test precondition: parked while walking")
        s.applyDitto(shown(p(30, 22)))   // snapped far away, standing
        var t: TimeInterval = 100
        for _ in 0..<20 { t += 1.0 / 30; s.update(t) }
        XCTAssertFalse(s.isDancing(memberID: key))
    }

    func testThePhotoIncludesTheDitto() throws {
        let s = scene()
        s.setCharacter(frames())
        let before = try XCTUnwrap(s.photoInput()).actors.count
        s.applyDitto(shown())
        s.setMemberFrames(key, frames())
        XCTAssertEqual(try XCTUnwrap(s.photoInput()).actors.count, before + 1)
    }

    func testPoofMakesNoNodesWhilePaused() {
        let s = scene()
        s.applyDitto(shown())
        s.isPaused = true
        s.playDittoPoof()
        XCTAssertEqual(s.dustShown, 0)
        s.isPaused = false
        s.playDittoPoof()
        XCTAssertGreaterThan(s.dustShown, 0)
    }
}
