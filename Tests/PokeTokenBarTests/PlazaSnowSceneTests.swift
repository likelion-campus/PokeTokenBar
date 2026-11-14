import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

private struct SnowEmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

@MainActor
final class PlazaSnowSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let greens: Set<UInt32> = [0x99E550, 0x6ABE30]

    private func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }

    private func defaults() -> UserDefaults {
        let name = "PlazaSnowSceneTests-\(UUID().uuidString)"
        let d = TestDefaults.make(suite: name)
        return d
    }

    @MainActor private final class Env {
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

    func testTheSnowMapShowsOnAnyDayAndIsAskedForOnce() throws {
        let e = Env(map: map, now: date(5, 23, 59, 59))
        e.scene.refreshSnowDay()
        XCTAssertTrue(e.scene.shownMapImage === e.snow)
        XCTAssertTrue(try XCTUnwrap(e.scene.photoInput()).mapImage.cgImage === e.snow.cgImage)
        e.now = date(6, 0, 0, 0)
        e.scene.update(1)
        e.now = date(7, 0, 0, 0)
        e.scene.update(2)
        XCTAssertTrue(e.scene.shownMapImage === e.snow)
        XCTAssertEqual(e.seen, [true])
        XCTAssertEqual(e.asked, 1)
    }

    func testTheTallGrassTurnsSnowyWithTheMap() throws {
        let normal = try XCTUnwrap(PlazaTallGrassArt.load())
        let sheet = try XCTUnwrap(PlazaResources.tallGrassSheet())
        let snowy = try XCTUnwrap(PlazaTallGrassArt(sheet: PlazaSnowSheet.tallGrass(PlazaImage(cgImage: sheet))))
        let e = Env(map: map, now: date(5, 12, 0, 0), tallGrass: normal, snowTallGrass: snowy)
        let layer = try XCTUnwrap(e.scene.tallGrassLayer)
        let whole = CGRect(origin: .zero, size: map.pixelSize)
        func hasGreen() -> Bool { layer.photoBands(in: whole).contains { SnowPixels.contains($0.image.cgImage, rgb: greens) } }
        e.scene.update(1)
        XCTAssertFalse(hasGreen())
    }

    func testWithoutSnowArtTheDayIsSnowButTheMapStays() {
        let e = Env(map: map, now: date(6, 12, 0, 0), hasSnow: false)
        e.scene.update(1)
        XCTAssertTrue(e.scene.isSnowDay)
        XCTAssertTrue(e.scene.isSnowShown)
        XCTAssertEqual(e.seen, [true])
        XCTAssertTrue(e.scene.shownMapImage === e.plain)
    }

    func testHidingTheBackgroundKeepsTheSnowDay() {
        let e = Env(map: map, now: date(6, 12, 0, 0))
        e.scene.update(1)
        e.scene.setBackgroundHidden(true)
        e.scene.update(2)
        XCTAssertTrue(e.scene.isSnowDay)
        XCTAssertTrue(e.scene.isSnowShown)
    }

    private func controller(on day: Int) -> PlazaWindowController {
        let at = date(day, 12, 0, 0)
        return PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                     loader: PlazaCharacterLoader(fetcher: SnowEmptyFetcher()),
                                     nickname: { "나" }, memberID: { "m1" },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: nil, clock: { at })
    }

    func testTheMinimapShowsTheSnowMap() throws {
        let a = controller(on: 6), b = controller(on: 7)
        [a, b].forEach { $0.prepareScene() }
        XCTAssertTrue(a.minimapShowsSnow)
        XCTAssertTrue(b.minimapShowsSnow)
        XCTAssertTrue(try XCTUnwrap(a.scene).shownMapImage === (try XCTUnwrap(b.scene).shownMapImage))
    }
}
