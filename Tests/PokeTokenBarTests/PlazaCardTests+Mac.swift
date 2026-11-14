// PlazaCardTests+Mac: SwiftUI ImageRenderer and AppKit font metrics of the card, menu and roster views
import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

extension PlazaInteractionTests {
    private func renderedWidth<V: View>(_ view: V) throws -> CGFloat {
        let r = ImageRenderer(content: view)
        r.scale = 1
        return CGFloat(try XCTUnwrap(r.cgImage).width)
    }

    func testMemberMenuGrowsToFitALongStatusButKeepsItsUsualWidth() async throws {
        var menu = PlazaMemberMenu(memberID: "a", nickname: "가", nameColor: nil)
        let plain = try renderedWidth(PlazaMemberMenuView(menu: menu, onChoose: { _ in }))
        XCTAssertEqual(plain, PlazaMemberMenuView.width)
        menu.status = L(.ko).plazaFocusStatus(seconds: 7 * 3600 + 43 * 60)
        let long = try renderedWidth(PlazaMemberMenuView(menu: menu, onChoose: { _ in }))
        XCTAssertGreaterThan(long, PlazaMemberMenuView.width)
        for join in [false, true] {
            let c = PlazaCampfireMenu(isJoin: join, minutes: PlazaCampfire.durations, selection: 0)
            XCTAssertGreaterThanOrEqual(try renderedWidth(PlazaCampfireMenuView(menu: c, onChoose: { _ in })), PlazaMemberMenuView.width)
        }
    }

    /// Five 1.5x cells side by side must fit inside the card panel, or the grid spills over its border.
    @MainActor
    func testCardGridFitsThePanel() async {
        let m = PlazaCardMetrics.self
        XCTAssertEqual(m.iconSize, CGSize(width: 40 * 1.5, height: 30 * 1.5), "box icons drawn at 1.5x stay crisp on Retina")
        XCTAssertEqual(m.spriteSide, 96 * 1.5)
        let inner = m.panelSize.width - 2 * m.panelInset
        let grid = CGFloat(m.columns) * m.cellSize.width + CGFloat(m.columns - 1) * m.spacing
        XCTAssertLessThanOrEqual(grid, inner)
        // Each cell has the icon and one line of the name under it; a long name is cut, not wrapped or widened.
        let nameLine = NSLayoutManager().defaultLineHeight(for: PlazaResources.font(.small))
        XCTAssertLessThanOrEqual(m.iconSize.height + 1 + nameLine, m.cellSize.height)
        let dex = (1...15).map {
            TeamDexSpecies(speciesID: $0, form: nil, name: $0 == 1 ? "아주아주긴포켓몬이름" : "\($0)",
                           rarity: $0.isMultiple(of: 5) ? .legendary : .common, hasShiny: $0.isMultiple(of: 3), hasNormal: true)
        }
        // The widest header: a 12-character nickname, both badges (species 5 is legendary above) and a different current Pokémon.
        let long = TeamMemberState(memberID: "m", nickname: "가나다라마바사아자차카타", character:
            TeamMonSummary(speciesID: 5, isShiny: true, form: nil, speciesName: "리자드", gender: nil),
                                   inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let current = TeamMonSummary(speciesID: 6, isShiny: false, form: nil, speciesName: "리자몽", gender: nil)
        let loaded = PlazaCardState.loaded(long, TeamMemberProfile(memberID: "m", nickname: "", current: current, dex: dex))
        XCTAssertEqual(loaded.characterBadges, [.shiny, .rarity(.legendary)], "test precondition")
        XCTAssertNotNil(loaded.differingCurrent, "test precondition")
        let proposal = CGSize(width: inner, height: m.panelSize.height - 2 * m.panelInset)
        let fit = NSHostingController(rootView: PlazaCardView(state: loaded)).sizeThatFits(in: proposal)
        XCTAssertLessThanOrEqual(fit.width, inner, "a 12-character nickname wraps instead of widening the card")
        let egg = TeamMemberState(memberID: "e", nickname: "알", character: TeamMonSummary(speciesID: nil, isShiny: false, form: nil,
                                  speciesName: nil, gender: nil), inPlaza: true, tile: nil, facing: nil, isWalking: false)
        XCTAssertLessThanOrEqual(NSHostingController(rootView: PlazaCardView(state: .loading(egg))).sizeThatFits(in: proposal).width, inner)
    }
}

extension PlazaCardTests {
    /// Both lines fit the menu on one line each.
    func testMenuLinesFitTheMenu() async {
        let inner = PlazaMemberMenuView.width - 2 * (PlazaRosterMetrics.padding + 2)
        for action in PlazaMemberAction.allCases {
            let text = "▶ " + PlazaMemberMenuView.title(action)
            let width = NSAttributedString(string: text, attributes: [.font: PlazaResources.font(.body)]).size().width
            XCTAssertLessThanOrEqual(width, inner, text)
        }
    }

    /// The menu renders at its fixed width, with the name and both lines one text line each.
    func testMenuViewKeepsItsWidthAndOneLineEach() async {
        let view = PlazaMemberMenuView(menu: PlazaMemberMenu(memberID: "m", nickname: "ＷＷＷＷＷＷＷＷＷＷＷＷ", selection: .viewCard),
                                       onChoose: { _ in })
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(size.width, PlazaMemberMenuView.width)
        let line = NSLayoutManager().defaultLineHeight(for: PlazaResources.font(.body))
        // The name and four lines with four gaps; a wrapped line would add a whole line more.
        XCTAssertLessThan(size.height, 5.5 * line + 2 * (PlazaRosterMetrics.padding + 2) + 4 * 4, "five lines, none wrapped")
    }
}
