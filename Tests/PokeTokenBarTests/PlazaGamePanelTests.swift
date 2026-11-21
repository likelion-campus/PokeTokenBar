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
}
