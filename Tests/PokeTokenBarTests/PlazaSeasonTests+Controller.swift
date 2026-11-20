import XCTest
@testable import PokeTokenBar

private struct SeasonNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaSeasonTests {

    // MARK: 연못

    func testThePondFreezesOnlyInWinter() async throws {
        let s = scene(ice: true, iceArt: PlazaIceLayerTests.fixtureArt)
        s.setIceBreak(nil)
        s.update(0)
        let anchor = try XCTUnwrap(s.frozenPondAnchor)
        XCTAssertTrue(s.isWalkableNow(anchor))
        for choice in [PlazaSeasonChoice.spring, .summer, .autumn] {
            s.seasonChoice = choice
            XCTAssertNil(s.frozenPondAnchor, "\(choice)")
            XCTAssertFalse(s.isWalkableNow(anchor), "\(choice)")
            XCTAssertTrue(s.isWaterNow(anchor), "\(choice)")
            s.seasonChoice = .winter
            XCTAssertEqual(s.frozenPondAnchor, anchor, "back in winter")
        }
    }

    func testAWarmSeasonSetBeforeTheFirstFrameNeverShowsIce() async {
        let s = scene(ice: true, iceArt: PlazaIceLayerTests.fixtureArt)
        s.seasonChoice = .summer
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor)
        s.update(1)
        XCTAssertNil(s.frozenPondAnchor)
    }

    func testAnIceBreakLearnedInAWarmSeasonDoesNotFreezeOrKeepRedrawing() async throws {
        let s = scene(ice: true, iceArt: PlazaIceLayerTests.fixtureArt)
        s.seasonChoice = .summer
        let pond = try XCTUnwrap(PlazaIce.ponds(in: map).first)
        s.setIceBreak(PlazaIceBreak(at: now.timeIntervalSince1970 - 3600, pond: pond.anchor))
        s.update(0)
        let drawn = s.iceDrawCount
        for i in 1...10 { s.update(Double(i) / 60) }
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertEqual(s.iceDrawCount, drawn, "a refreeze that is long due must not redraw the ice every frame")
    }

    func testThePondFreezesWhenTheCalendarTurnsToWinter() async {
        let s = scene(ice: true, iceArt: PlazaIceLayerTests.fixtureArt)
        s.seasonChoice = .auto
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor, "30 November")
        now = now.addingTimeInterval(1)
        s.update(1)
        XCTAssertNotNil(s.frozenPondAnchor, "1 December")
    }

    func testWhoStandsOnTheIceFallsInWhenTheSeasonTurns() async throws {
        let probe = scene(ice: true, iceArt: PlazaIceLayerTests.fixtureArt)
        probe.setIceBreak(nil)
        let anchor = try XCTUnwrap(probe.frozenPondAnchor)
        let s = scene(ice: true, start: anchor, iceArt: PlazaIceLayerTests.fixtureArt)
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertTrue(s.isMeOnIce)
        s.seasonChoice = .spring
        XCTAssertFalse(s.isMeOnIce)
        XCTAssertTrue(s.isMeInWater)
    }


    // MARK: 색


    // MARK: 팀 설정

    func controller(_ current: @escaping () -> PlazaSchedule?) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "ptb.test.season.\(UUID().uuidString)")),
                              loader: PlazaCharacterLoader(fetcher: SeasonNoSprites()),
                              nickname: { "나" }, memberID: { "me" },
                              subject: { .init(speciesID: 25, isShiny: false) }, schedule: current, clock: { [unowned self] in now },
                              shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }


}
