import XCTest
@testable import PokeTokenBar

/// The news board as a panel (Track A Task 17d), stub graphics (monospace: body 9 points a character and 15 a line, small
/// 7.2 and 12), so it runs on Windows too. The SwiftUI view's own numbers are in `PlazaBoardPanelRenderTests+Mac`.
@MainActor final class PlazaBoardPanelTests: XCTestCase {
    private var dirs: [URL] = []
    private func flush() async { for _ in 0..<20 { await Task.yield() } }
    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func feed() -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardPanelTests-\(UUID())")
        dirs.append(dir)
        return TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me", clock: { Date(timeIntervalSince1970: 1_793_400_000) })
    }

    /// `age` minutes before the feed's clock: the feed lists the newest first, so a smaller age is higher on the board.
    private func event(_ id: String, species: String = "깨봉이", kind: TeamEventKind = .hatch, shiny: Bool = false, age: Int = 0) -> TeamEvent {
        TeamEvent(id: id, authorID: "a", authorNickname: "민수", kind: kind, speciesID: 25, fromSpeciesID: nil, speciesName: species, fromSpeciesName: nil,
                  form: nil, isShiny: shiny, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: Date(timeIntervalSince1970: 1_793_400_000 - 3600 - Double(age) * 60))
    }
    private func reaction(_ id: String, on e: String, by: String, _ kind: TeamReactionKind, author: String? = nil) -> TeamReaction {
        TeamReaction(id: id, eventID: e, authorID: author ?? by, authorNickname: by, kind: kind, text: nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100))
    }

    private struct Rig {
        let model: PlazaOverlayModel, feed: TeamFeedStore, panel: PlazaBoardPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics, actions: Actions
    }
    @MainActor final class Actions { var list: [String] = [] }

    private func rig(events: Int = 0, open: Bool = true, viewport: CGSize = CGSize(width: 960, height: 640), scale: CGFloat = 2,
                     species: (Int) -> String = { "포켓몬\($0)" }) -> Rig {
        let model = PlazaOverlayModel()
        if open { model.content = .board }
        let f = feed()
        for i in (0..<events).reversed() { f.insert(event("e\(i)", species: species(i), age: i + 1)) }
        let panel = PlazaBoardPanel(model: model, feed: f, myMemberID: "me")
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost(), actions = Actions()
        hud.onAction = { id, hit in actions.list.append("\(id) \(hit.action) \(hit.index.map(String.init) ?? "-")") }
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        return Rig(model: model, feed: f, panel: panel, hud: hud, host: host, graphics: graphics, actions: actions)
    }

    private func frame(_ r: Rig) -> CGRect? { r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.board] }
    private func press(_ r: Rig, _ p: CGPoint) {
        let f = frame(r) ?? .zero
        let at = CGPoint(x: f.minX + p.x, y: f.minY + p.y)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: at), in: .board)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: at), in: .board)
    }
    private func wheel(_ r: Rig, _ dy: CGFloat, at p: CGPoint) -> Bool {
        let f = frame(r) ?? .zero
        return r.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: dy), location: CGPoint(x: f.minX + p.x, y: f.minY + p.y)), in: .board)
    }
    private let listPoint = CGPoint(x: 100, y: 100)

    // MARK: showing and placing

    func testItShowsOnlyWhileTheBoardIsOpenAndSitsInTheMiddleOfTheWindow() async {
        let r = rig(events: 2, open: false)
        await flush()
        XCTAssertFalse(r.panel.isVisible)
        XCTAssertNil(frame(r))
        XCTAssertNil(r.host.drawings[.board])
        XCTAssertEqual(r.hud.renderCounts[.board] ?? 0, 0, "closed: never rendered")
        r.model.content = .board
        await flush()
        XCTAssertNotNil(r.host.drawings[.board])
        for v in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640), CGSize(width: 2560, height: 1440), CGSize(width: 961, height: 641)] {
            for scale in [CGFloat(1), 2] {
                r.hud.setViewport(v, scale: scale)
                let f = frame(r)!
                XCTAssertEqual(f.size, CGSize(width: 340, height: 380))
                XCTAssertEqual(f.midX, v.width / 2, accuracy: 1 / scale, "\(v) \(scale)x centred across")
                XCTAssertEqual(f.midY, v.height / 2, accuracy: 1 / scale, "and down")
            }
        }
        r.model.content = .none
        await flush()
        XCTAssertNil(r.host.drawings[.board], "closed again")
    }

    func testAnEmptyBoardSaysSoAndOnlyTheTitleAndTheNoteAreThere() async {
        let r = rig()
        let d = r.host.drawings[.board]!
        XCTAssertEqual(d.accessibility.map(\.label), ["소식판", "아직 소식이 없어요"])
        XCTAssertEqual(d.layers.count, 1, "the plate with both texts: no rows")
        XCTAssertFalse(r.panel.scroll(dx: 0, dy: -30, at: listPoint), "nothing to scroll")
    }

    // MARK: rows

    func testARowIsItsTextDateReactionsAndThreeButtonsAndWrapsWithTheTextWidth() async {
        // Rows are 6 + text lines of 15 + 4 + date 12 + [4 + reaction lines of 12] + 4 + buttons 16 + 6 wide 312; the text
        // wraps at 300 (33 characters of 9).
        let r = rig(events: 1, species: { _ in "가" })
        let one = r.panel.layout(scale: 2, text: r.graphics.text).rows[0]
        let text = L(.ko).teamEventText(event("e0", species: "가"))
        let lines = Int((Double(text.count) * 9 / 300).rounded(.up))
        XCTAssertEqual(one.frame.height, 6 + CGFloat(lines) * 15 + 4 + 12 + 4 + (12 + 4) + 6, accuracy: 0.001)
        XCTAssertEqual(one.frame.width, 312)
        r.feed.insert(reaction("r1", on: "e0", by: "영희", .cute))
        r.feed.insert(reaction("r2", on: "e0", by: "철수", .congrats))
        await flush()
        let withReactions = r.panel.layout(scale: 2, text: r.graphics.text).rows[0]
        XCTAssertEqual(withReactions.frame.height, one.frame.height + 4 + 2 * 12 + 1, accuracy: 0.001, "4 above, a line per kind, 1 between")
        XCTAssertEqual(withReactions.buttons.map(\.kind), [.cute, .lol, .congrats])
        XCTAssertEqual(withReactions.buttons.map(\.frame.width), [30, 30, 30], "at least 30 wide, the label is shorter")
        // (The feed refuses a species name over 64 bytes, so 21 Hangul is the longest there is.)
        let long = rig(events: 1, species: { _ in String(repeating: "가", count: 21) }).panel
        let tall = long.layout(scale: 2, text: r.graphics.text).rows[0]
        XCTAssertEqual(tall.text.count, 2, "a long species name wraps the text onto a second line")
    }

    func testRowsAreNewestFirstAndGapped() async {
        let r = rig(events: 3)
        let rows = r.panel.layout(scale: 2, text: r.graphics.text).rows
        XCTAssertEqual(rows.map(\.row.id), ["e0", "e1", "e2"], "the feed's order, newest first")
        XCTAssertEqual(rows[1].frame.minY, rows[0].frame.maxY + 6)
        XCTAssertEqual(rows[2].frame.minY, rows[1].frame.maxY + 6)
    }

    // MARK: buttons

    func testAReactionButtonReactsAndMyOwnIsInert() async {
        let r = rig(events: 2)
        r.feed.insert(reaction("mine", on: "e0", by: "나", .lol, author: "me"))
        await flush()
        let rows = r.panel.layout(scale: 2, text: r.graphics.text).rows
        func center(_ row: Int, _ k: Int) -> CGPoint {
            let b = rows[row].buttons[k].frame
            return CGPoint(x: PlazaBoardStyle.list.minX + b.midX, y: PlazaBoardStyle.list.minY + rows[row].frame.minY + b.midY)
        }
        press(r, center(1, 2))
        XCTAssertEqual(r.actions.list, ["board react 5"])
        XCTAssertEqual(r.panel.reaction(forHit: PlazaPanelHit(action: "react", index: 5)).map { "\($0.eventID) \($0.kind)" }, "e1 congrats")
        press(r, center(0, 1))
        XCTAssertEqual(r.actions.list.last, "board board -", "I already gave 웃겨: its button is dimmed and does nothing")
        press(r, CGPoint(x: 10, y: 10))
        XCTAssertEqual(r.actions.list.last, "board board -", "the plate takes the click")
        XCTAssertNil(r.panel.reaction(forHit: PlazaPanelHit(action: "react", index: 99)))
        XCTAssertNil(r.hud.hit(at: CGPoint(x: 5, y: 5), in: .board), "outside the plate the scene gets the click")
    }

    func testPressingAButtonDimsItAndTheButtonsAccessibilityPressReacts() async {
        let r = rig(events: 2)
        await flush()
        let base = r.hud.renderCounts[.board] ?? 0
        let rows = r.panel.layout(scale: 2, text: r.graphics.text).rows
        let b = rows[0].buttons[0].frame
        let f = frame(r)!
        let p = CGPoint(x: f.minX + PlazaBoardStyle.list.minX + b.midX, y: f.minY + PlazaBoardStyle.list.minY + b.midY)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .board)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .moved, location: p), in: .board)
        await flush()
        XCTAssertEqual((r.hud.renderCounts[.board] ?? 0) - base, 1)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: .board)
        XCTAssertEqual(r.actions.list, ["board react 0"])
        let buttons = r.host.drawings[.board]!.accessibility.filter { $0.role == .button }
        XCTAssertEqual(buttons.prefix(3).map(\.label), [L(.ko).teamReactionLabel(.cute), L(.ko).teamReactionLabel(.lol), L(.ko).teamReactionLabel(.congrats)])
        r.hud.press(buttons[1].action!, in: .board)
        XCTAssertEqual(r.actions.list.last, "board react 1")
    }

    // MARK: scrolling

    func testTheListScrollsAndTakesTheWheelOnlyWhileItCanMove() async {
        let r = rig(events: 30)
        let state = { r.panel.scrollState }
        XCTAssertTrue(state().isAtTop, "it opens at the top")
        XCTAssertEqual(state().viewport, 320)
        XCTAssertGreaterThan(state().content, 320)
        XCTAssertFalse(wheel(r, 30, at: listPoint), "at the top, further up goes on")
        XCTAssertTrue(wheel(r, -50, at: listPoint))
        XCTAssertEqual(state().offset, 50)
        XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 100, y: 30)), "over the title it goes on")
        XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 5, y: 100)), "over the plate's margin too")
        XCTAssertTrue(wheel(r, -1_000_000, at: listPoint))
        XCTAssertTrue(state().isAtBottom)
        XCTAssertFalse(wheel(r, -10, at: listPoint), "at the bottom, further down goes on")
    }

    func testOnlyTheRowsInViewAreDrawnAndTheEdgeRowsAreCut() async {
        let r = rig(events: 30)
        XCTAssertTrue(wheel(r, -200, at: listPoint))
        await flush()
        let d = r.host.drawings[.board]!
        let rows = d.layers.dropFirst()
        XCTAssertLessThan(rows.count, 12, "never the whole content")
        let list = PlazaBoardStyle.list
        for case .image(_, let f) in rows {
            XCTAssertGreaterThanOrEqual(f.minY, list.minY - 0.001)
            XCTAssertLessThanOrEqual(f.maxY, list.maxY + 0.001, "cut at the list's edges")
        }
        XCTAssertTrue(d.accessibility.allSatisfy { $0.frame.minY >= list.minY - 0.001 || $0.label == "소식판" })
    }

    func testEachOpeningStartsAtTheTop() async {
        let r = rig(events: 30)
        XCTAssertTrue(wheel(r, -300, at: listPoint))
        r.model.content = .none
        await flush()
        r.model.content = .board
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtTop, "a new ScrollView each time")
    }

    func testANewEventShowsAtTheTopWithoutMovingTheOffset() async {
        let r = rig(events: 30)
        XCTAssertTrue(wheel(r, -100, at: listPoint))
        r.feed.insert(event("fresh", age: 0))
        await flush()
        XCTAssertEqual(r.panel.scrollState.offset, 100, "the offset stays (as the ScrollView kept it)")
        XCTAssertEqual(r.panel.layout(scale: 2, text: r.graphics.text).rows.first?.row.id, "fresh")
    }

    func testRendersAreOnePerChange() async {
        let r = rig(events: 5)
        await flush()
        let base = r.hud.renderCounts[.board] ?? 0
        for _ in 0..<300 { await Task.yield() }
        XCTAssertEqual(r.hud.renderCounts[.board] ?? 0, base, "idle: none")
        r.feed.insert(event("x1", age: 0))
        r.feed.insert(event("x2", age: 0))
        await flush()
        XCTAssertEqual((r.hud.renderCounts[.board] ?? 0) - base, 1, "two events in one turn: one render")
        r.hud.isRendering = false
        r.feed.insert(event("x3", age: 0))
        await flush()
        XCTAssertEqual((r.hud.renderCounts[.board] ?? 0) - base, 1, "hidden: none")
    }

    func testThereIsNoTextInputOnTheBoard() async {
        // The board has no text field: nothing to reserve for a platform control (the keys that close it are the scene's).
        let r = rig(events: 3)
        let roles = Set(r.host.drawings[.board]!.accessibility.map(\.role))
        XCTAssertEqual(roles, [.staticText, .button])
    }
}
