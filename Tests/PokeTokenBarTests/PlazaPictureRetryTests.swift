import XCTest
@testable import PokeTokenBar

/// Task 17w review item 2: a picture that failed to load is tried again each time its slot or the card appears (SwiftUI's `.task(id:)`), with
/// no timer and no loop. Stub graphics, so it runs on Windows too.
@MainActor final class PlazaPictureRetryTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)); for _ in 0..<20 { await Task.yield() } }

    func testAFailedPictureIsAskedForAgainOnlyAfterAnAppearance() async {
        let icons = FakeIcons()
        let cache = PlazaPictureCache(source: icons)
        cache.retryDelay = .milliseconds(1)
        var arrivals = 0
        cache.onArrival = { arrivals += 1 }
        XCTAssertNil(cache.icon(25))
        await flush()
        let first = icons.asked.count
        XCTAssertEqual(first, 2, "a box icon: the first try and the second one")
        XCTAssertNil(cache.icon(25))
        await flush()
        XCTAssertEqual(icons.asked.count, first, "no loop: asking again without an appearance does not ask the source")
        icons.loadable[25] = samplePicture()
        cache.forgetFailures()   // the slot appeared again
        XCTAssertNil(cache.icon(25), "the placeholder until it arrives")
        await flush()
        XCTAssertEqual(arrivals, 1)
        XCTAssertNotNil(cache.icon(25), "and then it stays")
    }

    func testARosterIconThatFailedShowsWhenItsSlotAppearsAgainAfterAPageTurn() async {
        let model = PlazaRosterModel()
        model.capacity = 1
        model.entries = [PlazaRosterEntry(id: "a", nickname: "가", speciesID: 25, speciesName: "x", gender: nil, isShiny: false, presence: .idle, isMe: false),
                         PlazaRosterEntry(id: "b", nickname: "나", speciesID: 26, speciesName: "y", gender: nil, isShiny: false, presence: .idle, isMe: false)]
        let icons = FakeIcons()
        icons.loadable[26] = samplePicture()
        let panel = PlazaRosterPanel(model: model, icons: icons)
        panel.pictures.retryDelay = .milliseconds(1)
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        hud.host = host
        await flush()
        func pictures() -> Int { (graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }.count }
        XCTAssertEqual(pictures(), 0, "offline: the placeholder")
        let asked = icons.asked.filter { $0 == 25 }.count
        icons.loadable[25] = samplePicture()   // back online
        model.page = 1
        await flush()
        model.page = 0   // the first member's slot appears again
        await flush()
        XCTAssertGreaterThan(icons.asked.filter { $0 == 25 }.count, asked, "asked again")
        XCTAssertEqual(pictures(), 1, "the icon shows")
    }

    func testACardPictureThatFailedShowsWhenTheCardIsReopened() async {
        let m = TeamMemberState(memberID: "m", nickname: "민수", character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let state = PlazaCardState.loaded(m, TeamMemberProfile(memberID: "m", nickname: "민수", current: m.character,
                                                               dex: [TeamDexSpecies(speciesID: 100, form: nil, name: "종", rarity: .common, hasShiny: false, hasNormal: true)]))
        let model = PlazaOverlayModel()
        let icons = FakeIcons()
        let panel = PlazaCardPanel(model: model, icons: icons)
        panel.pictures.retryDelay = .milliseconds(1)
        let hud = PlazaHUD(panels: [panel], graphics: CanvasKeepingGraphics())
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        hud.host = host
        model.content = .card(state)
        await flush()
        let before = icons.asked.filter { $0 == 100 }.count
        XCTAssertGreaterThan(before, 0)
        model.content = .none
        await flush()
        icons.loadable[100] = samplePicture()
        let rendered = hud.renderCounts[.card] ?? 0
        model.content = .card(state)   // reopened
        await flush()
        XCTAssertGreaterThan(icons.asked.filter { $0 == 100 }.count, before, "asked again on reopening")
        XCTAssertGreaterThan(hud.renderCounts[.card] ?? 0, rendered + 1, "the arrival rendered the card once more")
    }
}
