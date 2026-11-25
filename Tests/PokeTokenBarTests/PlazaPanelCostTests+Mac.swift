import AppKit
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 10: what one render of the board (300 events) and of a card with a big dex costs, and what a change check costs.
/// Printed as `COST ...` lines; run with `-c release` for the numbers that matter.
@MainActor final class PlazaPanelCostTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() async throws { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    func testBoardWith300EventsAndACardWithABigDexCostPerRender() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaPanelCostTests-\(UUID())")
        dirs.append(dir)
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me", clock: { now })
        for i in 0..<300 {
            feed.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)", fromSpeciesName: nil,
                                  form: nil, isShiny: i % 7 == 0, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: now.addingTimeInterval(-3600 - Double(i) * 60)))
            if i % 3 == 0 { feed.insert(TeamReaction(id: "r\(i)", eventID: "e\(i)", authorID: "x\(i)", authorNickname: "친구", kind: .cute, text: nil, createdAt: now)) }
        }
        let model = PlazaOverlayModel()
        model.content = .board
        let board = PlazaBoardPanel(model: model, feed: feed, myMemberID: "me")
        board.scrollIndicator.isDisabled = true
        let g = PlatformPlaza.graphics
        let viewport = CGSize(width: 960, height: 640)
        _ = board.render(scale: 2, viewport: viewport, graphics: g)   // warm: wraps every row once
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        var t0 = clock.now
        for _ in 0..<20 { _ = board.render(scale: 2, viewport: viewport, graphics: g) }
        let render = ms(clock.now - t0) / 20
        t0 = clock.now
        for _ in 0..<20 { _ = board.scroll(dx: 0, dy: -3, at: CGPoint(x: 170, y: 200)); _ = board.render(scale: 2, viewport: viewport, graphics: g) }
        let scrollStep = ms(clock.now - t0) / 20
        // A change check: the feed gained a reaction; what the panel does to find out is observed through one model change.
        let renders = board.renderCountForTesting
        t0 = clock.now
        for i in 0..<20 { feed.insert(TeamReaction(id: "n\(i)", eventID: "e1", authorID: "y\(i)", authorNickname: "친구\(i)", kind: .lol, text: nil, createdAt: now)); for _ in 0..<3 { await Task.yield() } }
        let change = ms(clock.now - t0) / 20
        print("COST board 300 events: render \(String(format: "%.2f", render)) ms, scroll step incl. render \(String(format: "%.2f", scrollStep)) ms, change detection per feed change \(String(format: "%.2f", change)) ms (renders seen \(board.renderCountForTesting - renders))")

        let m = TeamMemberState(memberID: "m", nickname: "민수", character: TeamMonSummary(speciesID: 6, isShiny: false, form: nil, speciesName: "리자몽", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let dex = (0..<1000).map { TeamDexSpecies(speciesID: 100_000 + $0, form: nil, name: "종\($0)", rarity: $0 % 9 == 0 ? .legendary : .common, hasShiny: $0 % 5 == 0, hasNormal: true) }
        let cardModel = PlazaOverlayModel()
        cardModel.content = .card(.loaded(m, TeamMemberProfile(memberID: "m", nickname: "민수", current: m.character, dex: dex)))
        let card = PlazaCardPanel(model: cardModel, icons: PlazaStubIconSource())
        card.scrollIndicator.isDisabled = true
        _ = card.render(scale: 2, viewport: viewport, graphics: g)
        t0 = clock.now
        for _ in 0..<20 { _ = card.render(scale: 2, viewport: viewport, graphics: g) }
        let cardRender = ms(clock.now - t0) / 20
        t0 = clock.now
        for _ in 0..<20 { _ = card.scroll(dx: 0, dy: -3, at: CGPoint(x: 190, y: 380)); _ = card.render(scale: 2, viewport: viewport, graphics: g) }
        print("COST card 1000-species dex: render \(String(format: "%.2f", cardRender)) ms, scroll step incl. render \(String(format: "%.2f", ms(clock.now - t0) / 20)) ms")
    }
    /// The drawing quiz panel while a stroke is under way: one render after each canvas change at the default window on a 2x screen. The
    /// panel caps its change reports at 30 a second; this is what each of them costs.
    func testDrawBoardRenderCost() async throws {
        let model = PlazaDrawModel()
        model.board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 민수", time: "⏱ 52", cover: nil, foot: .tools(word: "사과"), canDraw: true)
        let panel = PlazaDrawPanel(model: model, neighbours: { _, _ in [:] })
        let g = PlatformPlaza.graphics, viewport = CGSize(width: 960, height: 640)
        _ = panel.render(scale: 2, viewport: viewport, graphics: g)   // warm: the plate is drawn once
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        let t0 = clock.now
        for i in 0..<200 {
            model.canvas.stroke(points: [i % 96, (i * 7) % 64], color: 1 + i % 8, width: 3)
            _ = panel.render(scale: 2, viewport: viewport, graphics: g)
        }
        let mean = ms(clock.now - t0) / 200
        print("COST draw board: render after a canvas change \(String(format: "%.3f", mean)) ms (mean of 200, 960x640 at 2x)")
    }
}
