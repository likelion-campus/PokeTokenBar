import XCTest
@testable import PokeTokenBar

/// The minigame's two panels: the invitation card with its buttons, and the big title.
@MainActor
final class PlazaGamePanelTests: XCTestCase {
    private let viewport = CGSize(width: 760, height: 480)

    private func rig() -> (game: PlazaGameModel, overlay: PlazaOverlayModel, card: PlazaGameCardPanel, title: PlazaGameTitlePanel, hud: PlazaHUD) {
        let game = PlazaGameModel(), overlay = PlazaOverlayModel()
        let pills = PlazaPillsPanel(model: overlay)
        let card = PlazaGameCardPanel(game: game, overlay: overlay, pills: pills)
        let title = PlazaGameTitlePanel(game: game)
        let hud = PlazaHUD(panels: [title, card, pills])
        hud.setViewport(viewport, scale: 2)
        return (game, overlay, card, title, hud)
    }

    private let invitation = PlazaGameView.Card(title: "민수님의 폭탄 돌리기", lines: ["규칙 한 줄", "참가 2명 · 24초 뒤 시작"],
                                                buttons: [.init(label: "Y 참가", action: "join"), .init(label: "N 안 함", action: "decline")])

    func testTheCardShowsOnlyWithAnInvitationAndNeverOverAMenuOrInPhotoMode() async {
        let r = rig()
        XCTAssertFalse(r.card.isVisible)
        r.game.card = invitation
        XCTAssertTrue(r.card.isVisible)
        r.overlay.content = .board
        XCTAssertFalse(r.card.isVisible, "the board has the window")
        r.overlay.content = .none
        r.overlay.isPhotoMode = true
        XCTAssertFalse(r.card.isVisible)
    }

    func testAClickOnAButtonAnswersAndTheRestOfThePlateDoesNothing() async throws {
        let r = rig()
        r.game.card = invitation
        _ = r.card.render(scale: 2, viewport: viewport, graphics: PlatformPlaza.graphics)
        let placed = try XCTUnwrap(r.card.placed)
        XCTAssertEqual(placed.lines.map(\.text), ["민수님의 폭탄 돌리기", "규칙 한 줄", "참가 2명 · 24초 뒤 시작"])
        XCTAssertEqual(placed.buttons.count, 2)
        let join = placed.buttons[0].frame, decline = placed.buttons[1].frame
        XCTAssertEqual(r.card.hit(CGPoint(x: join.midX, y: join.midY)), PlazaPanelHit(action: "join", index: nil))
        XCTAssertEqual(r.card.hit(CGPoint(x: decline.midX, y: decline.midY)), PlazaPanelHit(action: "decline", index: nil))
        XCTAssertEqual(r.card.hit(CGPoint(x: 6, y: 6)), PlazaPanelHit(action: "card", index: nil), "the plate takes the click")
        XCTAssertNil(r.card.hit(CGPoint(x: -4, y: 6)), "outside the plate the click goes on to the plaza")
        XCTAssertLessThan(join.maxX, decline.minX, "side by side")
        XCTAssertGreaterThan(join.minY, placed.lines[2].frame.maxY, "under the text")
        XCTAssertLessThanOrEqual(decline.maxX, placed.size.width)
    }

    func testADisabledButtonTakesTheClickWithoutAnswering() async throws {
        let r = rig()
        r.game.card = PlazaGameView.Card(title: "내가 연 폭탄 돌리기", lines: ["두 명부터"],
                                         buttons: [.init(label: "M 바로 시작", action: "start", isEnabled: false)])
        let drawing = r.card.render(scale: 2, viewport: viewport, graphics: PlatformPlaza.graphics)
        let b = try XCTUnwrap(r.card.placed?.buttons.first).frame
        XCTAssertEqual(r.card.hit(CGPoint(x: b.midX, y: b.midY)), PlazaPanelHit(action: "card", index: nil))
        XCTAssertEqual(drawing.accessibility.last?.isEnabled, false)
    }

    func testTheCardSitsUnderThePills() async throws {
        let r = rig()
        r.game.card = invitation
        let alone = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.gameCard])
        r.overlay.hint = "안내"
        let under = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.gameCard])
        let pills = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.pills])
        XCTAssertGreaterThan(under.minY, alone.minY)
        XCTAssertGreaterThanOrEqual(under.minY, pills.maxY)
        XCTAssertEqual(under.midX, viewport.width / 2, accuracy: 1)
    }

    func testTheTitleIsBigAndBelowTheMiddleSoItDoesNotCoverMe() async throws {
        let r = rig()
        XCTAssertFalse(r.title.isVisible)
        r.game.title = .init(text: "3", tone: .count)
        XCTAssertTrue(r.title.isVisible)
        let frame = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.gameTitle])
        let body = PlatformPlaza.graphics.text.metrics(.plaza(.body))
        XCTAssertGreaterThanOrEqual(frame.height, (body.ascender - body.descender) * PlazaGameTitlePanel.magnify)
        XCTAssertEqual(frame.midX, viewport.width / 2, accuracy: 1)
        XCTAssertGreaterThan(frame.minY, viewport.height / 2, "my character stands in the middle")
        XCTAssertLessThan(frame.maxY, viewport.height)
        XCTAssertNil(r.title.hit(CGPoint(x: 4, y: 4)), "it takes no clicks")
        let drawing = r.title.render(scale: 2, viewport: viewport, graphics: PlatformPlaza.graphics)
        XCTAssertEqual(drawing.layers.count, 1)
        XCTAssertEqual(drawing.accessibility.map(\.label), ["3"])
        r.game.title = .init(text: "민수 탈락!", tone: .out)
        XCTAssertGreaterThan(try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.gameTitle]).width, frame.width)
    }

    func testTheRankingCardListsEveryoneAndMarksATie() async throws {
        let name: (String) -> String = { $0.uppercased() }
        let tie = PlazaGameView.rankingCard([("a", 35), ("b", 35), ("c", 20), ("d", 0)], name: name)
        XCTAssertEqual(tie.title, "그림 퀴즈 결과")
        XCTAssertEqual(tie.lines, ["공동 1등 A 35점", "공동 1등 B 35점", "3등 C 20점", "4등 D 0점"])
        XCTAssertTrue(tie.buttons.isEmpty)
        let single = PlazaGameView.rankingCard([("a", 35), ("b", 20)], name: name)
        XCTAssertEqual(single.lines, ["1등 A 35점", "2등 B 20점"])
        // The biggest game: eight lines under the title still sit inside the smallest window.
        let eight = PlazaGameView.rankingCard((0..<8).map { ("p\($0)", 80 - 10 * $0) }, name: name)
        let r = rig()
        r.game.card = eight
        _ = r.card.render(scale: 2, viewport: viewport, graphics: PlatformPlaza.graphics)
        let placed = try XCTUnwrap(r.card.placed)
        XCTAssertEqual(placed.lines.map(\.text), [eight.title] + eight.lines)
        let frame = try XCTUnwrap(r.hud.layout(viewport: CGSize(width: 600, height: 372), scale: 2)[.gameCard])
        XCTAssertLessThanOrEqual(frame.maxY, 372)
    }

    /// The drawing quiz's invitation, the longest it gets (rules, the count, the full-house line), has to fit the smallest window.
    func testTheDrawInvitationFitsTheSmallestWindow() async throws {
        let l = L(.ko)
        let r = rig()
        r.game.card = PlazaGameView.Card(title: l.plazaGameCardTitle(host: "민수", game: l.plazaGameName(.draw)),
                                         lines: l.plazaGameRules(.draw) + [l.plazaDrawRecruiting(players: 8, seconds: 30), l.plazaDrawFull],
                                         buttons: [.init(label: l.plazaGameButtonJoin, action: "join", isEnabled: false), .init(label: l.plazaGameButtonDecline, action: "decline")])
        _ = r.card.render(scale: 2, viewport: viewport, graphics: PlatformPlaza.graphics)
        let placed = try XCTUnwrap(r.card.placed)
        let narrow = CGSize(width: 600, height: 372)
        let frame = try XCTUnwrap(r.hud.layout(viewport: narrow, scale: 2)[.gameCard])
        XCTAssertLessThanOrEqual(placed.size.width, narrow.width - 2 * PlazaRosterMetrics.margin, "card \(placed.size.width) pt wide")
        XCTAssertLessThanOrEqual(frame.maxY, narrow.height)
    }
}
