import XCTest
@testable import PokeTokenBar

private struct SnowEmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

@MainActor
final class PlazaSnowSceneTests: XCTestCase {
    let map = PlazaMapData.map
    let greens: Set<UInt32> = [0x99E550, 0x6ABE30]

    func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }

    func defaults() -> UserDefaults {
        let name = "PlazaSnowSceneTests-\(UUID().uuidString)"
        let d = TestDefaults.make(suite: name)
        return d
    }

    @MainActor final class Env {
        var now: Date
        var asked = 0
        var seen: [Bool] = []
        let plain: PlazaImage, snow: PlazaImage
        let scene: PlazaScene
        init(map: PlazaMap, now: Date, tallGrass: PlazaTallGrassArt? = nil, snowTallGrass: PlazaTallGrassArt? = nil, hasSnow: Bool = true) {
            self.now = now
            plain = PlazaTileArt.plainGrassImage(map)
            snow = PlazaTileArt.plainGrassImage(map)
            scene = PlazaScene(map: map, mapImage: plain, start: map.spawn, zoom: 2, nickname: "나", tallGrass: tallGrass)
            scene.backingOverride = 2
            scene.size = CGSize(width: 800, height: 600)
            scene.now = { [unowned self] in self.now }
            scene.seasonLook = { [unowned self] _ in
                self.asked += 1
                return hasSnow ? PlazaSnowLook(mapImage: self.snow, tallGrass: snowTallGrass) : nil
            }
            scene.onSeasonChange = { [unowned self] in self.seen.append($0 == .winter) }
        }
    }

    func testWithoutSnowArtTheDayIsSnowButTheMapStays() async {
        let e = Env(map: map, now: date(6, 12, 0, 0), hasSnow: false)
        e.scene.update(1)
        XCTAssertTrue(e.scene.isSnowDay)
        XCTAssertTrue(e.scene.isSnowShown)
        XCTAssertEqual(e.seen, [true])
        XCTAssertTrue(e.scene.shownMapImage === e.plain)
    }

    func testHidingTheBackgroundKeepsTheSnowDay() async {
        let e = Env(map: map, now: date(6, 12, 0, 0))
        e.scene.update(1)
        e.scene.setBackgroundHidden(true)
        e.scene.update(2)
        XCTAssertTrue(e.scene.isSnowDay)
        XCTAssertTrue(e.scene.isSnowShown)
    }
}
