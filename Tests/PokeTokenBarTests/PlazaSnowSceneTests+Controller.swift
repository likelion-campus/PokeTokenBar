import XCTest
@testable import PokeTokenBar

private struct SnowEmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaSnowSceneTests {

    func testTheSnowMapShowsOnAnyDayAndIsAskedForOnce() async throws {
        let e = Env(map: map, now: date(5, 23, 59, 59))
        e.scene.refreshSnowDay()
        XCTAssertTrue(e.scene.shownMapImage === e.snow)
        XCTAssertTrue(try XCTUnwrap(e.scene.photoInput()).mapImage === e.snow)
        e.now = date(6, 0, 0, 0)
        e.scene.update(1)
        e.now = date(7, 0, 0, 0)
        e.scene.update(2)
        XCTAssertTrue(e.scene.shownMapImage === e.snow)
        XCTAssertEqual(e.seen, [true])
        XCTAssertEqual(e.asked, 1)
    }


}
