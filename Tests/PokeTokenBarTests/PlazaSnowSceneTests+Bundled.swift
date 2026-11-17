// PlazaSnowSceneTests+Bundled: the tall-grass snow test reads the bundled tall-grass sheet; the minimap test builds the snow map
import XCTest
@testable import PokeTokenBar

extension PlazaSnowSceneTests {
    func testTheTallGrassTurnsSnowyWithTheMap() async throws {
        let normal = try XCTUnwrap(PlatformPlaza.tallGrassArt())
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let snowy = try XCTUnwrap(PlazaTallGrassArt(sheet: PlazaSnowSheet.tallGrass(sheet)))
        let e = Env(map: map, now: date(5, 12, 0, 0), tallGrass: normal, snowTallGrass: snowy)
        let layer = try XCTUnwrap(e.scene.tallGrassLayer)
        let whole = CGRect(origin: .zero, size: map.pixelSize)
        func hasGreen() -> Bool { layer.photoBands(in: whole).contains { SnowPixels.contains($0.image, rgb: greens) } }
        e.scene.update(1)
        XCTAssertFalse(hasGreen())
    }
}

private struct SnowEmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaSnowSceneTests {
    private func controller(on day: Int) -> PlazaWindowController {
        let at = date(day, 12, 0, 0)
        return PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                     loader: PlazaCharacterLoader(fetcher: SnowEmptyFetcher()),
                                     nickname: { "나" }, memberID: { "m1" },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: nil, clock: { at },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    func testTheMinimapShowsTheSnowMap() async throws {
        let a = controller(on: 6), b = controller(on: 7)
        [a, b].forEach { $0.prepareScene() }
        XCTAssertTrue(a.minimapShowsSnow)
        XCTAssertTrue(b.minimapShowsSnow)
        XCTAssertTrue(try XCTUnwrap(a.scene).shownMapImage === (try XCTUnwrap(b.scene).shownMapImage))
    }
}
