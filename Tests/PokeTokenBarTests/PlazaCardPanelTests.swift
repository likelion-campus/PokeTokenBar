import XCTest
@testable import PokeTokenBar

/// The member card as a panel (Track A Task 17d), stub graphics (monospace: body 9 points a character and 15 a line, small
/// 7.2 and 12), so it runs on Windows too. The SwiftUI view's own numbers are in `PlazaCardPanelRenderTests+Mac`.
@MainActor final class PlazaCardPanelTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    private func member(_ nick: String = "민수", species: Int? = 25, name: String? = "피카츄", shiny: Bool = false, activity: PlazaActivity? = nil) -> TeamMemberState {
        var m = TeamMemberState(memberID: "m-\(nick)", nickname: nick, character: TeamMonSummary(speciesID: species, isShiny: shiny, form: nil, speciesName: name, gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        m.activity = activity
        return m
    }
    private func today(_ now: Date) -> PlazaActivity {
        var a = PlazaActivity(day: PlazaActivity.dayKey(now))
        a.addSeconds(3 * 3600 + 25 * 60)
        a.record(.iceBreak); a.record(.firework); a.record(.tackle); a.record(.snowballHit); a.record(.greeting); a.record(.pickup)
        return a
    }
    private func dex(_ n: Int) -> [TeamDexSpecies] {
        (0..<n).map { TeamDexSpecies(speciesID: 100 + $0, form: nil, name: $0 == 1 ? String(repeating: "가", count: 20) : "종\($0)", rarity: $0 % 4 == 3 ? .legendary : .common,
                                     hasShiny: $0 % 3 == 0, hasNormal: true) }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let model: PlazaOverlayModel, panel: PlazaCardPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics, icons: FakeIcons, actions: PlazaBoardPanelTests.Actions
    }

    private func rig(_ state: PlazaCardState?, viewport: CGSize = CGSize(width: 960, height: 640), scale: CGFloat = 2, icons: FakeIcons = FakeIcons()) -> Rig {
        let model = PlazaOverlayModel()
        if let state { model.content = .card(state) }
        let panel = PlazaCardPanel(model: model, icons: icons, now: { self.now })
        panel.scrollIndicator.isDisabled = true   // the SwiftUI original draws no scroller off screen; the indicator has its own tests
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost(), actions = PlazaBoardPanelTests.Actions()
        hud.onAction = { id, hit in actions.list.append("\(id) \(hit.action)") }
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        return Rig(model: model, panel: panel, hud: hud, host: host, graphics: graphics, icons: icons, actions: actions)
    }
    private func frame(_ r: Rig) -> CGRect? { r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.card] }
    private func wheel(_ r: Rig, _ dy: CGFloat, at p: CGPoint) -> Bool {
        let f = frame(r) ?? .zero
        return r.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: dy), location: CGPoint(x: f.minX + p.x, y: f.minY + p.y)), in: .card)
    }
    private func labels(_ r: Rig) -> [String] { (r.host.drawings[.card]?.accessibility ?? []).map(\.label) }

    // MARK: size, place, states

    /// The fixed panel (380 x 460) in the middle of every window, whatever the state and the activity (the invariants of
    /// `testCardHeightDoesNotDependOnTheActivity` and `testProfileCardContentFitsTheFixedPanel`).
    func testTheCardIsTheFixedPanelInTheMiddleInEveryState() async {
        let m = member(activity: today(now))
        let profile = TeamMemberProfile(memberID: m.memberID, nickname: "", current: m.character, dex: dex(30))
        for state in [PlazaCardState.loading(m), .failed(m), .loaded(m, profile), .loaded(member(), TeamMemberProfile(memberID: "x", nickname: "", current: m.character, dex: []))] {
            for v in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640), CGSize(width: 2560, height: 1440)] {
                let r = rig(state, viewport: v)
                let f = frame(r)!
                XCTAssertEqual(f.size, PlazaCardMetrics.panelSize)
                XCTAssertEqual(f.midX, v.width / 2, accuracy: 0.5)
                XCTAssertEqual(f.midY, v.height / 2, accuracy: 0.5)
            }
        }
        let m2 = PlazaCardMetrics.self
        let inner = m2.panelSize.height - 2 * m2.panelInset
        XCTAssertGreaterThanOrEqual(inner - (m2.spriteSide + m2.stackSpacing + m2.activityHeight + m2.stackSpacing), 2 * m2.cellSize.height + m2.spacing, "two dex rows stay visible")
        XCTAssertEqual(PlazaCardStyle.lower.height, 174)
    }

    func testItShowsOnlyForACardAndGoesWhenItCloses() async {
        let r = rig(nil)
        XCTAssertNil(frame(r))
        XCTAssertEqual(r.hud.renderCounts[.card] ?? 0, 0)
        r.model.content = .card(.loading(member()))
        await flush()
        XCTAssertNotNil(r.host.drawings[.card])
        r.model.content = .board
        await flush()
        XCTAssertNil(r.host.drawings[.card])
    }

    func testLoadingAndFailedSayTheirMessageAndHaveNoGrid() async {
        let m = member(activity: today(now))
        let loading = rig(.loading(m)), failed = rig(.failed(m))
        XCTAssertTrue(labels(loading).contains("불러오는 중…"))
        XCTAssertTrue(labels(failed).contains("도감을 받지 못했어요"))
        XCTAssertFalse(labels(failed).contains("불러오는 중…"))
        for r in [loading, failed] {
            XCTAssertEqual(r.host.drawings[.card]?.layers.count, 1, "the plate and everything on it: no dex rows")
            XCTAssertEqual(r.host.drawings[.card]?.tooltips, [])
            XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 100, y: 300)))
        }
        XCTAssertTrue(labels(loading).contains("민수의 포켓몬"), "the header is there while the dex loads")
    }

    // MARK: activity

    func testTheActivityBoxShowsTheSevenValuesOrNoRecord() async {
        let withRecord = rig(.failed(member(activity: today(now))))
        let items = withRecord.host.drawings[.card]!.accessibility
        let rows = items.filter { $0.value != nil }
        XCTAssertEqual(rows.map { "\($0.label) \($0.value ?? "")" }, PlazaActivity.rows(today(now)).map { "\($0.label) \($0.value)" })
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(labels(withRecord).contains("오늘 광장"))
        let none = rig(.failed(member(activity: nil)))
        XCTAssertTrue(labels(none).contains("기록 없음"))
        XCTAssertEqual((none.host.drawings[.card]?.accessibility ?? []).filter { $0.value != nil }.count, 0)
        var old = PlazaActivity(day: "2001-01-01"); old.record(.pickup)
        XCTAssertTrue(labels(rig(.failed(member(activity: old)))).contains("기록 없음"), "another day's record is not shown")
        // The box is the same size either way: the rows are drawn into one image of the fixed panel.
        XCTAssertEqual(frame(withRecord)?.size, frame(none)?.size)
    }

    // MARK: header

    func testTheHeaderHasTheTitleNameAndBadges() async {
        let m = member("가나다라마바사아자차카타", species: 5, name: "리자드", shiny: true)
        let loaded = PlazaCardState.loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: "", current: TeamMonSummary(speciesID: 6, isShiny: false, form: nil, speciesName: "리자몽", gender: nil),
                                                                 dex: [TeamDexSpecies(speciesID: 5, form: nil, name: "리자드", rarity: .rare, hasShiny: true, hasNormal: true)]))
        let r = rig(loaded)
        await flush()
        let l = labels(r)
        XCTAssertTrue(l.contains("가나다라마바사아자차카타의 포켓몬") || l.contains(where: { $0.hasSuffix("의 포켓몬") }))
        XCTAssertTrue(l.contains("리자드"))
        XCTAssertTrue(l.contains("★ 이로치"), "the shiny pill")
        XCTAssertTrue(l.contains(L(.ko).rarityLabel(.rare)), "the rarity pill (known once the dex is)")
        // The different Pokémon in hand shows as a small icon (asked for through the picture source).
        XCTAssertTrue(r.icons.asked.contains(6))
        XCTAssertTrue(r.icons.spritesAsked.contains(5), "the character's own picture")
    }

    func testAnEggMemberIsNamedEggAndAsksForTheEggPicture() async {
        let egg = member("알친구", species: nil, name: nil)
        let r = rig(.loading(egg))
        await flush()
        XCTAssertTrue(labels(r).contains(L(.ko).plazaEggName))
        XCTAssertTrue(r.icons.spritesAsked.contains(nil))
    }

    func testAPictureThatArrivesRendersTheCardOnceMore() async {
        let icons = FakeIcons()
        icons.loadable[25] = samplePicture(96, 96)
        let r = rig(.loading(member()), icons: icons)
        let first = r.hud.renderCounts[.card] ?? 0
        XCTAssertEqual((r.graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }.count, 0, "a placeholder first")
        await flush()
        XCTAssertEqual((r.hud.renderCounts[.card] ?? 0) - first, 1)
        let calls = (r.graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains(", 144.0, 144.0)"), "the 96-pixel picture fills the 144-point box: \(calls[0])")
        for _ in 0..<300 { await Task.yield() }
        XCTAssertEqual((r.hud.renderCounts[.card] ?? 0) - first, 1, "idle: nothing more")
    }

    // MARK: dex

    private func loaded(_ n: Int, icons: FakeIcons = FakeIcons()) -> Rig {
        let m = member(activity: today(now))
        return rig(.loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: "", current: m.character, dex: dex(n))), icons: icons)
    }

    func testTheDexIsFiveColumnsOfCellsAndScrollsInTheLowerArea() async {
        let r = loaded(80)
        let s = r.panel.scrollState
        XCTAssertEqual(s.viewport, 174)
        XCTAssertEqual(s.content, 16 * 66 + 15 * 4)
        XCTAssertTrue(s.isAtTop)
        let l = r.panel.layout(scale: 2, text: r.graphics.text)!
        XCTAssertEqual(l.rows, 16)
        XCTAssertEqual(l.rowFrames[1].minY - l.rowFrames[0].minY, 70)
        XCTAssertFalse(wheel(r, 20, at: CGPoint(x: 100, y: 300)), "at the top")
        XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 100, y: 100)), "over the header it goes on")
        XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 100, y: 200)), "over the activity box too")
        XCTAssertTrue(wheel(r, -140, at: CGPoint(x: 100, y: 300)))
        XCTAssertEqual(r.panel.scrollState.offset, 140)
        await flush()
        let d = r.host.drawings[.card]!
        XCTAssertLessThanOrEqual(d.layers.count - 1, 4, "the rows in view only: 174 high shows at most 4 rows of 70")
        XCTAssertTrue(wheel(r, -1_000_000, at: CGPoint(x: 100, y: 300)))
        XCTAssertTrue(r.panel.scrollState.isAtBottom)
        XCTAssertFalse(wheel(r, -10, at: CGPoint(x: 100, y: 300)))
    }

    func testAFewSpeciesDoNotScroll() async {
        let r = loaded(7)   // two rows: 136 of the 174
        XCTAssertFalse(r.panel.scrollState.canScroll)
        XCTAssertFalse(wheel(r, -50, at: CGPoint(x: 100, y: 300)))
    }

    func testEveryVisibleCellHasItsNameAsHoverTextAndAccessibility() async {
        let r = loaded(80)
        XCTAssertTrue(wheel(r, -140, at: CGPoint(x: 100, y: 300)))
        await flush()
        let d = r.host.drawings[.card]!
        let cells = d.tooltips
        XCTAssertGreaterThanOrEqual(cells.count, 10)
        XCTAssertLessThanOrEqual(cells.count, 20, "only what shows")
        let lower = PlazaCardStyle.lower
        for t in cells {
            XCTAssertTrue(lower.contains(CGPoint(x: t.frame.midX, y: t.frame.midY)), "inside the lower area")
            XCTAssertLessThanOrEqual(t.frame.maxY, lower.maxY + 0.001, "cut at the viewport's edge")
            XCTAssertTrue(d.accessibility.contains { $0.frame == t.frame && $0.label == t.text && $0.role == .staticText })
        }
        XCTAssertTrue(cells.contains { $0.text.hasPrefix("종") })
    }

    func testTheLegendaryAndShinyMarksAndLongNamesAreDrawn() async {
        let r = loaded(10)
        let calls = r.graphics.canvases.last?.calls ?? []
        _ = calls
        // The first row's cells are drawn into its own image: that canvas has a line per name, the long name cut with "…".
        let all = r.graphics.canvases.flatMap(\.calls)
        XCTAssertTrue(all.contains { $0.contains("…") && $0.hasPrefix("line") }, "a 20-character name is cut at the cell's 60 points")
        XCTAssertTrue(all.contains { $0.hasPrefix("strokeRoundedRect") && $0.hasSuffix(" 6.0 1.5") }, "the legendary outline (1.5)")
        XCTAssertTrue(all.contains { $0.hasPrefix("line \"★\"") }, "a shiny star")
    }

    func testClicksOnTheCardAreTakenAndDoNothing() async {
        let r = loaded(20)
        let f = frame(r)!
        let p = CGPoint(x: f.midX, y: f.midY)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .card)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: .card)
        XCTAssertEqual(r.actions.list, ["card card"])
        XCTAssertNil(r.hud.hit(at: CGPoint(x: 3, y: 3), in: .card), "outside the plate: the scene gets it")
        let roles = Set(r.host.drawings[.card]!.accessibility.map(\.role))
        XCTAssertEqual(roles, [.staticText], "no buttons, no input")
    }

    func testOpeningAnotherCardStartsAtTheTop() async {
        let r = loaded(80)
        XCTAssertTrue(wheel(r, -300, at: CGPoint(x: 100, y: 300)))
        let m = member("다른")
        r.model.content = .card(.loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: "", current: m.character, dex: dex(80))))
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtTop)
    }
}
