import XCTest
@testable import PokeTokenBar

/// Tall grass in the plaza scene: Pokémon hide, name plates stay, and the grass rustles as they move.
/// Patch A covers x 5-11, y 5-8; (7,10), (4,6), (5,9) and (20,20) are open ground.
@MainActor
final class PlazaTallGrassSceneTests: XCTestCase {
    let map = PlazaMapData.map
    let rightKey: UInt16 = 124
    let upKey: UInt16 = 126

    func scene(start: TilePoint, tallGrass: PlazaTallGrassArt?, zoom: Int = 2) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: zoom,
                           nickname: "me", tallGrass: tallGrass)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        return s
    }

    /// 32x48 image: 72 world px tall at x1.5, taller than the 30 px the hidden plate sits at.
    func frames(egg: Bool = false) -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: PlazaImage(bitmap: PlazaTestImages.solid(width: 32, height: 48, PlazaRGBA(r: 255, g: 0, b: 0, a: 255))), delay: 0.1)]
        var result = PlazaCharacterFrames(front: f, back: f)
        result.isEgg = egg
        return result
    }

    func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false)
    }

    func sceneWithMember(at tile: TilePoint, tallGrass: PlazaTallGrassArt?, egg: Bool = false, zoom: Int = 2) -> PlazaScene {
        let s = scene(start: TilePoint(x: 20, y: 22), tallGrass: tallGrass, zoom: zoom)
        s.setCharacter(frames())
        s.applyMembers([member("a", tile)])
        s.setMemberFrames("a", frames(egg: egg))
        return s
    }

    @discardableResult
    func step(_ s: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0,
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

    /// Driven only through playJump and update: the landing bounce rides the scene clock, not an action.
    func jump(from tile: TilePoint, grass: PlazaTallGrassArt) -> (opacityAt18: CGFloat, opacityAt50: CGFloat, bounced: [TimeInterval]) {
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

    func testWithoutTheArtNobodyHides() async {
        let s = sceneWithMember(at: TilePoint(x: 7, y: 6), tallGrass: nil)
        step(s, seconds: 0.1)
        XCTAssertEqual(s.memberOpacity("a"), 1)
        XCTAssertNil(s.tallGrassLayer)
    }

    /// My plate top above my foot, in world px.
    func myPlateHeight(_ s: PlazaScene) -> CGFloat {
        s.myNamePlateTop / CGFloat(s.zoom) + s.cameraPosition.y - (map.pixelSize.height - s.myFootPoint.y)
    }
}
