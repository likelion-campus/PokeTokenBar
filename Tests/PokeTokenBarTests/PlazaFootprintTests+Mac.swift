import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// The scene-driven footprint tests: `PlazaScene` is a SpriteKit scene until the plaza stage lands.
extension PlazaFootprintTests {
    private var map: PlazaMap { PlazaMapData.map }
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }

    @MainActor private final class Env {
        var now: Date
        var time: TimeInterval = 1
        let scene: PlazaScene
        init(map: PlazaMap, day: Int = 6) {
            now = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
            let plain = PlazaTileArt.plainGrassImage(map)
            scene = PlazaScene(map: map, mapImage: plain, start: TilePoint(x: 10, y: 10), zoom: 2, nickname: "me")
            scene.backingOverride = 2
            scene.size = CGSize(width: 800, height: 600)
            scene.now = { [unowned self] in self.now }
            scene.seasonLook = { _ in PlazaSnowLook(mapImage: plain, tallGrass: nil) }
            scene.refreshSnowDay()
            scene.update(time)
        }
        func frames(_ seconds: TimeInterval) {
            var t = 0.0
            while t < seconds - 1e-9 { time += 1.0 / 30; scene.update(time); t += 1.0 / 30 }
        }
        func walkRight() {
            scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
            scene.handleKeyUp(keyCode: 124)
        }
    }

    private func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .right, isWalking: false)
    }

    private func shown(_ tile: TilePoint, bouncing: Bool = false) -> PlazaDittoShown {
        PlazaDittoShown(tile: tile, facing: .right, isWalking: false, isRunning: false, isBouncing: bouncing,
                        name: "d", nameColor: PlazaColor(srgbRed: 1, green: 0, blue: 0), title: nil, isDecoy: false)
    }

    func testWalkingOnASnowDayLeavesMarksThatFadeAway() {
        let e = Env(map: map)
        e.walkRight()
        e.frames(0.2)
        XCTAssertEqual(e.scene.footprintCount, 2)
        e.frames(4.8)
        XCTAssertEqual(e.scene.footprintAlphas.count, 2)
        for a in e.scene.footprintAlphas { XCTAssertEqual(a, 0.66, accuracy: 0.001) }
        e.frames(4.3)
        XCTAssertEqual(e.scene.footprintCount, 0)
    }

    func testAPushLeavesNoMarks() {
        let e = Env(map: map)
        e.scene.pushMe(.right, tiles: 2)
        e.frames(1)
        XCTAssertEqual(e.scene.myFootPoint, PlazaWalker.footPoint(from: p(12, 10), to: p(12, 10), progress: 0))
        XCTAssertEqual(e.scene.footprintCount, 0)
    }

    func testAWalkingTeammateAndTheDittoLeaveMarks() {
        let e = Env(map: map)
        e.scene.applyMembers([member("a", p(14, 10))])
        e.frames(0.3)
        e.scene.applyMembers([member("a", p(15, 10))])
        e.frames(0.3)
        XCTAssertEqual(e.scene.footprintCount, 2)
        e.scene.applyDitto(shown(p(18, 12)))
        e.frames(0.3)
        e.scene.applyDitto(shown(p(19, 12)))
        e.frames(0.3)
        XCTAssertEqual(e.scene.footprintCount, 4)
        e.scene.applyDitto(shown(p(20, 12), bouncing: true))
        e.frames(0.5)
        XCTAssertEqual(e.scene.footprintCount, 4)
    }

    func testAHiddenBackgroundClearsAndMakesNoMarks() {
        let e = Env(map: map)
        e.walkRight()
        e.frames(0.2)
        XCTAssertEqual(e.scene.footprintCount, 2)
        e.scene.setBackgroundHidden(true)
        XCTAssertEqual(e.scene.footprintCount, 0)
        e.walkRight()
        e.frames(0.3)
        XCTAssertEqual(e.scene.footprintCount, 0)
    }

}
