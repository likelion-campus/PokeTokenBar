import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private let spaceKey: UInt16 = 49, escKey: UInt16 = 53, wKey: UInt16 = 13, rightKey: UInt16 = 124, heartKey: UInt16 = 18
private let upKey: UInt16 = 126, downKey: UInt16 = 125, returnKey: UInt16 = 36
private let zKey: UInt16 = 6, xKey: UInt16 = 7, cKey: UInt16 = 8

private extension PlazaOverlayContent {
    var cardMemberID: String? {
        switch self {
        case .card(.loading(let s)), .card(.loaded(let s, _)), .card(.failed(let s)): s.memberID
        case .none, .board, .memberMenu, .campfireMenu: nil
        }
    }
}

@MainActor
final class PlazaInteractionTests: XCTestCase {
    private func renderedWidth<V: View>(_ view: V) throws -> CGFloat {
        let r = ImageRenderer(content: view)
        r.scale = 1
        return CGFloat(try XCTUnwrap(r.cgImage).width)
    }

    func testMemberMenuGrowsToFitALongStatusButKeepsItsUsualWidth() throws {
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

    /// A seated user is never aimed at the pit by Space; if the seats move this fails loudly.
    func testNoSeatEverTargetsTheCampfire() {
        for seat in PlazaCampfire.seats {
            for d in PlazaDirection.allCases {
                let hit = PlazaInteraction.target(from: seat.tile, facing: d, map: PlazaMapData.map, members: [:])
                XCTAssertNotEqual(hit?.target, .campfire, "\(seat.tile) \(d)")
            }
        }
    }

    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testBoardWinsOverMember() {
        let board = map.boardTile
        let above = p(board.x, board.y - 1)
        // 소식판 칸에 팀원이 겹쳐 있어도 판이 먼저다.
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: ["a": board])?.target, .board)
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .down))
    }

    func testMemberAheadIsTheTarget() {
        let from = map.spawn
        let ahead = PlazaTargeting.facingTile(from: from, facing: .down)
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["b": ahead, "a": ahead])?.target, .member("a"))
        XCTAssertNil(PlazaInteraction.target(from: p(10, 10), facing: .down, map: map, members: ["far": p(1, 1)]))
    }

    /// A teammate right beside me can be talked to without facing them first; Space turns me towards them.
    func testMemberBesideMeIsTheTargetAndITurnToThem() {
        let from = p(10, 10)
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(11, 10)]),
                       PlazaInteractionHit(target: .member("m"), facing: .right))
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(10, 9)]),
                       PlazaInteractionHit(target: .member("m"), facing: .up))
        XCTAssertNil(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(11, 11)]), "diagonal is not beside")
    }

    /// The board is readable from any side, without facing it first.
    func testBoardBesideMeIsTheTarget() {
        let b = map.boardTile
        let left = p(b.x - 1, b.y + 1)
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .right))
        let below = p(b.x + 1, b.y + 2)
        XCTAssertEqual(PlazaInteraction.target(from: below, facing: .left, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .up))
    }

    /// Order: the board I face, a teammate I face, a teammate on my tile, the board beside me, a teammate beside me.
    func testFacedTargetsWinOverTargetsBeside() {
        let b = map.boardTile
        let left = p(b.x - 1, b.y + 1)
        let ahead = p(left.x, left.y + 1)
        XCTAssertTrue(map.isWalkable(ahead) && map.isWalkable(p(left.x - 1, left.y)), "test precondition")
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": ahead]),
                       PlazaInteractionHit(target: .member("m"), facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": left]),
                       PlazaInteractionHit(target: .member("m"), facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": p(left.x - 1, left.y)]),
                       PlazaInteractionHit(target: .board, facing: .right), "the board beside me wins over a teammate beside me")
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .right, map: map, members: ["m": left]),
                       PlazaInteractionHit(target: .board, facing: .right), "the board I face wins over everyone")
    }

    private func cardState(_ c: TeamMonSummary, dex: [TeamDexSpecies]?) -> PlazaCardState {
        let state = TeamMemberState(memberID: "m", nickname: "민수", character: c, inPlaza: true, tile: nil, facing: nil, isWalking: false)
        guard let dex else { return .loading(state) }
        return .loaded(state, TeamMemberProfile(memberID: "m", nickname: "민수", current: c, dex: dex))
    }

    private func dexEntry(_ id: Int, _ rarity: Rarity) -> TeamDexSpecies {
        TeamDexSpecies(speciesID: id, form: nil, name: "\(id)", rarity: rarity, hasShiny: false, hasNormal: true)
    }

    /// The big partner on the card says whose it is, what it is, and whether it is shiny or above common.
    func testCardNamesTheOwnerAndTheirPartner() {
        XCTAssertEqual(L(.ko).plazaCardTitle(nickname: "민수"), "민수의 포켓몬")
        let milotic = TeamMonSummary(speciesID: 350, isShiny: false, form: nil, speciesName: "밀로틱", gender: nil)
        XCTAssertEqual(cardState(milotic, dex: nil).characterName, "밀로틱")
        XCTAssertEqual(cardState(milotic, dex: nil).member.nickname, "민수")
        let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertEqual(cardState(egg, dex: []).characterName, L(.ko).plazaEggName)
        let unnamed = TeamMonSummary(speciesID: 350, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertNil(cardState(unnamed, dex: []).characterName, "an unknown name is left out, not shown as an egg")
    }

    func testCardBadgesShowShinyAndRarityAboveCommon() {
        let shinyMewtwo = TeamMonSummary(speciesID: 150, isShiny: true, form: nil, speciesName: "뮤츠", gender: nil)
        XCTAssertEqual(cardState(shinyMewtwo, dex: nil).characterBadges, [.shiny], "rarity is known only once the dex arrives")
        XCTAssertEqual(cardState(shinyMewtwo, dex: [dexEntry(1, .common), dexEntry(150, .legendary)]).characterBadges,
                       [.shiny, .rarity(.legendary)])
        let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil)
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(25, .common)]).characterBadges, [], "common gets no badge")
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(25, .uncommon)]).characterBadges, [.rarity(.uncommon)])
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(150, .legendary)]).characterBadges, [], "only its own species counts")
        let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertEqual(cardState(egg, dex: [dexEntry(150, .legendary)]).characterBadges, [])
    }

    /// Five 1.5x cells side by side must fit inside the card panel, or the grid spills over its border.
    @MainActor
    func testCardGridFitsThePanel() {
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

    func testCardShowsCurrentOnlyWhenItDiffersFromPlazaCharacter() {
        let pika = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let eevee = TeamMonSummary(speciesID: 133, isShiny: false, form: nil, speciesName: "Eevee", gender: nil)
        let state = TeamMemberState(memberID: "m", nickname: "민수", character: pika, inPlaza: true, tile: nil, facing: nil, isWalking: false)
        func profile(_ c: TeamMonSummary) -> TeamMemberProfile { TeamMemberProfile(memberID: "m", nickname: "민수", current: c, dex: []) }
        XCTAssertNil(PlazaCardState.loaded(state, profile(pika)).differingCurrent)
        XCTAssertEqual(PlazaCardState.loaded(state, profile(eevee)).differingCurrent?.speciesID, 133)
        var shiny = pika; shiny.isShiny = true
        XCTAssertNotNil(PlazaCardState.loaded(state, profile(shiny)).differingCurrent)
        XCTAssertNil(PlazaCardState.loading(state).differingCurrent)
    }
}

@MainActor
final class PlazaCardTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private let map = PlazaMapData.map

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
    }

    private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let suite = "plaza.card.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaCardTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let dex = [TeamDexSpecies(speciesID: 25, form: nil, name: "Pikachu", rarity: .common, hasShiny: true, hasNormal: true)]
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: dex) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func controller(_ me: Node, start: TilePoint, timeout: Duration = .seconds(5),
                            greeting: TeamEmoteKind = .party, stage: Int = 1) -> PlazaWindowController {
        let name = "plaza.card.prefs.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, evolutionStage: { stage }, session: me.session,
                                     greetingKind: { greeting },
                                     profileTimeout: timeout)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func step(_ scene: PlazaScene, seconds: TimeInterval) {
        var t: TimeInterval = 0
        scene.update(t)
        while t < seconds { t += 1.0 / 30; scene.update(t) }
    }

    private func space(_ scene: PlazaScene) { scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: false) }
    private func key(_ scene: PlazaScene, _ code: UInt16) { scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false) }

    /// 팀원 옆에서 스페이스로 메뉴를 열고 "포켓몬 보기"를 고른다.
    private func viewCard(_ scene: PlazaScene) {
        space(scene)
        key(scene, downKey)
        key(scene, downKey)
        key(scene, downKey)
        space(scene)
    }

    /// 나는 소식판 바로 위 칸에서 아래(판)를 보고 선다.
    private var aboveBoard: TilePoint { TilePoint(x: map.boardTile.x, y: map.boardTile.y - 1) }

    /// 내 앞(아래) 칸에 팀원이 선 장면.
    private func standing(timeout: Duration = .seconds(5), severed: Bool = false)
        async -> (c: PlazaWindowController, scene: PlazaScene, other: Node, id: String) {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn, timeout: timeout)
        c.prepareScene()
        let link = hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }   // a presence before the hello is dropped
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down)
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { me.session.members[other.settings.memberID]?.tile == ahead && c.scene?.memberTiles[other.settings.memberID] == ahead }
        if severed { hub.sever(link, silentlyOn: other.transport) }   // after the position arrived, so it never answers
        return (c, c.scene!, other, other.settings.memberID)
    }

    // MARK: - Space hint

    func testHintShowsBesideTheBoardAndHidesWhileItIsOpen() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        XCTAssertNil(c.hint, "Space now closes the board")
        space(c.scene!)
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
    }

    func testHintGoesAwayWhenIWalkOffAndComesBack() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        scene.handleKeyDown(keyCode: upKey, characters: nil, isRepeat: false)
        step(scene, seconds: 0.1)
        scene.handleKeyUp(keyCode: upKey)
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, TilePoint(x: aboveBoard.x, y: aboveBoard.y - 1), "test precondition")
        XCTAssertNil(c.hint)
        scene.handleKeyDown(keyCode: downKey, characters: nil, isRepeat: false)
        step(scene, seconds: 0.1)
        scene.handleKeyUp(keyCode: downKey)
        step(scene, seconds: 1)
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
    }

    func testBoardOpensFromTheSideAndITurnToIt() {
        let me = node("나")
        let side = TilePoint(x: map.boardTile.x - 1, y: map.boardTile.y + 1)
        let c = controller(me, start: side)
        c.prepareScene()
        XCTAssertEqual(c.scene!.walker.facing, .down)
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        XCTAssertEqual(c.scene!.walker.facing, .right)
    }

    /// A teammate right beside me (not in front) can be talked to: the hint names them and Space turns me to them.
    func testTeammateBesideMeGetsAHintAndSpaceTurnsToThem() async {
        let me = node("나"), other = node("민수")
        let start = TilePoint(x: 10, y: 10), beside = TilePoint(x: 11, y: 10)
        let c = controller(me, start: start)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        other.session.updatePlazaPosition(inPlaza: true, tile: beside, facing: .down, isWalking: false)
        let id = other.settings.memberID
        await waitUntil { me.session.members[id]?.tile == beside && c.scene?.memberTiles[id] == beside }
        let scene = c.scene!
        XCTAssertEqual(scene.walker.facing, .down)
        XCTAssertEqual(c.hint, L(.ko).plazaMemberHint(nickname: "민수"))
        space(scene)
        XCTAssertEqual(scene.walker.facing, .right)
        XCTAssertEqual(c.overlayContent, .memberMenu(PlazaMemberMenu(memberID: id, nickname: "민수")))
        XCTAssertNil(c.hint)
    }

    func testHintHidesWhileTheChatInputIsOpen() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(c.chatInputForTesting.isOpen)
        XCTAssertNil(c.hint, "Space types a space while the input is open")
        c.chatInputForTesting.close()
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
    }

    func testClosingThePlazaClearsTheHint() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        XCTAssertNotNil(c.hint)
        c.handleClose()
        XCTAssertNil(c.hint)
    }

    func testFacingNothingOpensNothing() {
        let me = node("나")
        let c = controller(me, start: TilePoint(x: 10, y: 10))
        c.prepareScene()
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(c.scene!.isOverlayOpen)
        XCTAssertEqual(c.scene!.dustCount, 0, "Space is for talking only; jumping is Z")
    }

    /// X and C need a teammate beside me. Alone, they show and send nothing.
    func testXAndCWithNobodyBesideDoNothing() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: TilePoint(x: 10, y: 10))
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        var received: [TeamEmote] = []
        other.session.onEmote = { received.append($1) }
        let scene = c.scene!
        key(scene, xKey)
        key(scene, cKey)
        XCTAssertNil(scene.shownEmote(memberID: nil))
        XCTAssertEqual(scene.impactCount, 0)
        XCTAssertEqual(c.overlayContent, .none)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(received, [])
    }

    func testSpaceOnBoardOpensEmptyBoardPanel() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        XCTAssertTrue(c.scene!.isOverlayOpen)
    }

    func testViewingTheCardLoadsTheProfile() async {
        let (c, scene, other, id) = await standing()
        viewCard(scene)
        guard case .card(.loading(let state)) = c.overlayContent else { return XCTFail("expected loading, got \(c.overlayContent)") }
        XCTAssertEqual(state.memberID, id)
        XCTAssertTrue(scene.isOverlayOpen)
        await waitUntil { if case .card(.loaded) = c.overlayContent { true } else { false } }
        guard case .card(.loaded(let s, let profile)) = c.overlayContent else { return XCTFail("expected loaded, got \(c.overlayContent)") }
        XCTAssertEqual(s.memberID, id)
        XCTAssertEqual(profile.nickname, "민수")
        XCTAssertEqual(profile.dex.map(\.speciesID), [25])
        _ = other
    }

    func testProfileTimeoutShowsFailure() async {
        let (c, scene, _, id) = await standing(timeout: .milliseconds(50), severed: true)
        viewCard(scene)
        XCTAssertEqual(c.overlayContent.cardMemberID, id)
        await waitUntil { if case .card(.failed) = c.overlayContent { true } else { false } }
        guard case .card(.failed(let state)) = c.overlayContent else { return XCTFail("expected failed, got \(c.overlayContent)") }
        XCTAssertEqual(state.memberID, id)
        XCTAssertTrue(scene.isOverlayOpen, "a failed card stays open until closed")
    }

    func testResultAfterCloseIsDiscarded() async {
        let (c, scene, _, _) = await standing(timeout: .milliseconds(50), severed: true)
        viewCard(scene)
        scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false)
        XCTAssertEqual(c.overlayContent, .none)
        try? await Task.sleep(for: .milliseconds(200))   // the request times out after the close
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(scene.isOverlayOpen)
    }

    func testStaleResultDoesNotOverwriteNewerCard() async {
        let me = node("나")
        // Both end up on the facing tile; the lower member ID wins that tie, so the fast one is the lower.
        let pair = [node("느림"), node("빠름")].sorted { $0.settings.memberID < $1.settings.memberID }
        let fast = pair[0], slow = pair[1]
        let c = controller(me, start: map.spawn, timeout: .milliseconds(600))
        c.prepareScene()
        let slowLink = hub.connect(me.transport, to: slow.transport)
        hub.connect(me.transport, to: fast.transport)
        // A presence that arrives before the hello is dropped, so wait until both are known.
        await waitUntil { me.session.members.count == 2 }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down)
        let far = TilePoint(x: 10, y: 10)
        slow.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        fast.session.updatePlazaPosition(inPlaza: true, tile: far, facing: .down, isWalking: false)
        let scene = c.scene!
        // Both positions must have arrived (an away member rests in the shelter, which could be `ahead`) before the link goes quiet.
        await waitUntil {
            scene.memberTiles[slow.settings.memberID] == ahead && scene.memberTiles[fast.settings.memberID] == far
                && me.session.members[slow.settings.memberID]?.tile == ahead && me.session.members[fast.settings.memberID]?.tile == far
        }
        hub.sever(slowLink, silentlyOn: slow.transport)
        viewCard(scene)                                                 // slow member: never answers
        XCTAssertEqual(c.overlayContent.cardMemberID, slow.settings.memberID)
        space(scene)                                                    // close
        fast.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        // (`ahead` is a shelter tile, so the scene tile alone can match before the update lands; wait on the received position)
        await waitUntil { me.session.members[fast.settings.memberID]?.tile == ahead && scene.memberTiles[fast.settings.memberID] == ahead }
        viewCard(scene)                                                 // fast member answers at once
        await waitUntil { if case .card(.loaded) = c.overlayContent { true } else { false } }
        try? await Task.sleep(for: .milliseconds(900))                 // the first request now times out
        guard case .card(.loaded(let s, _)) = c.overlayContent else { return XCTFail("stale result replaced the card: \(c.overlayContent)") }
        XCTAssertEqual(s.memberID, fast.settings.memberID)
    }

    // MARK: - Member menu

    /// Space beside a teammate opens a menu with 인사하기 chosen; nothing is sent until one is picked.
    func testSpaceBesideATeammateOpensTheMenu() async {
        let (c, scene, _, id) = await standing()
        space(scene)
        XCTAssertEqual(c.overlayContent, .memberMenu(PlazaMemberMenu(memberID: id, nickname: "민수", selection: .greet)))
        XCTAssertTrue(scene.isOverlayOpen)
        XCTAssertNil(scene.shownEmote(memberID: nil))
        XCTAssertNil(scene.shownEmote(memberID: id))
    }

    /// The menu's name is in the teammate's picked colour, like their name tag.
    func testMenuCarriesTheTeammatesPickedColor() async {
        let (c, scene, other, id) = await standing()
        // Not the teammate's own colour: the member ID is random, and a wait for a colour it already has passes at once.
        let pick = PlazaNameColor.hexes.first { $0 != PlazaNameColor.hex(forMemberID: id, chosen: nil) }!
        other.settings.nameColor = pick
        other.session.applySettings()
        await waitUntil { c.scene?.memberNameColor(id) == PlazaNameColor.color(forMemberID: id, chosen: pick) }
        space(scene)
        guard case .memberMenu(let menu) = c.overlayContent else { return XCTFail("no menu: \(c.overlayContent)") }
        XCTAssertEqual(menu.nameColor, pick)
    }

    func testArrowsMoveTheChoiceAndWrapAround() async {
        let (c, scene, _, _) = await standing()
        space(scene)
        func selection() -> PlazaMemberAction? { if case .memberMenu(let m) = c.overlayContent { m.selection } else { nil } }
        key(scene, downKey)
        XCTAssertEqual(selection(), .tackle)
        key(scene, downKey)
        XCTAssertEqual(selection(), .follow)
        key(scene, downKey)
        XCTAssertEqual(selection(), .viewCard)
        key(scene, downKey)
        XCTAssertEqual(selection(), .greet, "down from the last line goes to the first")
        key(scene, upKey)
        XCTAssertEqual(selection(), .viewCard, "up from the first line goes to the last")
        scene.handleKeyDown(keyCode: upKey, characters: nil, isRepeat: true)
        XCTAssertEqual(selection(), .viewCard, "a held arrow moves once")
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, map.spawn, "arrows move the choice, not me")
    }

    /// 인사하기 puts the same bubble over me and the teammate here, and sends it as a greeting so it shows over both
    /// on their screen too.
    func testGreetingShowsOverBothAndReachesTheTeammate() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn, greeting: .heart)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == ahead }
        var received: [(String, TeamEmote)] = []
        other.session.onEmote = { received.append(($0, $1)) }
        let scene = c.scene!
        space(scene)
        space(scene)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(scene.isOverlayOpen)
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart)
        XCTAssertEqual(scene.shownEmote(memberID: id), .heart)
        step(scene, seconds: 0.1)
        XCTAssertEqual(scene.emoteFrame(memberID: nil)?.size, PlazaEmoteArt.size(large: true), "a greeting is drawn bigger")
        XCTAssertEqual(scene.emoteFrame(memberID: id)?.size, PlazaEmoteArt.size(large: true))
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received.first?.0, me.settings.memberID)
        XCTAssertEqual(received.first?.1, TeamEmote(kind: .heart, targetMemberID: id, isShared: true))
    }

    /// 몸통박치기 from the menu: I lunge at the teammate, an impact pops on them, and they get a tackle aimed at them.
    /// Whether they move is up to their Mac.
    func testTackleLungesShowsAnImpactAndReachesTheTeammate() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == ahead }
        var received: [(String, TeamEmote)] = []
        other.session.onEmote = { received.append(($0, $1)) }
        let scene = c.scene!
        space(scene)
        key(scene, downKey)
        guard case .memberMenu(let menu) = c.overlayContent else { return XCTFail("no menu: \(c.overlayContent)") }
        XCTAssertEqual(menu.selection, .tackle)
        space(scene)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertEqual(scene.impactCount, 1)
        step(scene, seconds: PlazaActor.lungeDuration / 2)
        XCTAssertGreaterThan(scene.lungeOffset(memberID: nil)?.y ?? 0, 0, "I lunge down, toward them")
        XCTAssertEqual(scene.walker.tile, map.spawn, "and stay on my tile")
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received.first?.0, me.settings.memberID)
        XCTAssertEqual(received.first?.1, TeamEmote(kind: .tackle, targetMemberID: id))
    }

    /// An evolved tackler asks for a longer push: as many tiles as its evolution stage, at most three.
    func testTackleAsksForAsManyTilesAsMyEvolutionStage() async {
        for (stage, sent) in [(2, 2), (3, 3), (5, 3)] {
            let me = node("나"), other = node("민수")
            let c = controller(me, start: map.spawn, stage: stage)
            c.prepareScene()
            hub.connect(me.transport, to: other.transport)
            await waitUntil { me.session.members[other.settings.memberID] != nil }
            let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
            other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
            await waitUntil { c.scene?.memberTiles[id] == ahead }
            var received: [TeamEmote] = []
            other.session.onEmote = { received.append($1) }
            c.chooseMenu(.tackle, memberID: id)
            await waitUntil { !received.isEmpty }
            XCTAssertEqual(received.first, TeamEmote(kind: .tackle, targetMemberID: id, pushTiles: sent), "stage \(stage)")
            c.handleClose()
        }
    }

    /// X greets the teammate in front of me at once, without the menu, the same way 인사하기 does.
    func testXGreetsTheTeammateInFrontWithoutTheMenu() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn, greeting: .heart)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == ahead }
        var received: [(String, TeamEmote)] = []
        other.session.onEmote = { received.append(($0, $1)) }
        let scene = c.scene!
        key(scene, xKey)
        XCTAssertEqual(c.overlayContent, .none, "no menu")
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart)
        XCTAssertEqual(scene.shownEmote(memberID: id), .heart)
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received.first?.1, TeamEmote(kind: .heart, targetMemberID: id, isShared: true))
    }

    /// C tackles a teammate standing beside me, not only in front: I turn to them and lunge that way.
    func testCTurnsToTheTeammateBesideAndTacklesWithoutTheMenu() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let left = TilePoint(x: map.spawn.x - 1, y: map.spawn.y), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == left }
        var received: [(String, TeamEmote)] = []
        other.session.onEmote = { received.append(($0, $1)) }
        let scene = c.scene!
        XCTAssertNotEqual(scene.walker.facing, .left, "test precondition")
        key(scene, cKey)
        XCTAssertEqual(c.overlayContent, .none, "no menu")
        XCTAssertEqual(scene.walker.facing, .left, "turned to them")
        XCTAssertEqual(scene.impactCount, 1)
        step(scene, seconds: PlazaActor.lungeDuration / 2)
        XCTAssertLessThan(scene.lungeOffset(memberID: nil)?.x ?? 0, 0, "I lunge left, toward them")
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received.first?.1, TeamEmote(kind: .tackle, targetMemberID: id))
    }

    // MARK: - Follow

    private func follow(_ scene: PlazaScene) {
        space(scene)
        key(scene, downKey)
        key(scene, downKey)
        space(scene)
    }

    /// 따라가기 keeps me beside the teammate as they walk away, shows what I am doing, and an arrow key stops it.
    func testFollowingKeepsUpUntilAnArrowKey() async {
        let (c, scene, other, id) = await standing()
        follow(scene)
        XCTAssertEqual(scene.followingMember, id)
        XCTAssertEqual(c.hint, L(.ko).plazaFollowHint(nickname: "민수"))
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down)
        let away = TilePoint(x: ahead.x, y: ahead.y + 3)
        XCTAssertTrue((0...3).allSatisfy { map.isWalkable(TilePoint(x: ahead.x, y: ahead.y + $0)) }, "test precondition")
        other.session.updatePlazaPosition(inPlaza: true, tile: away, facing: .down, isWalking: false)
        // Their steps and mine are walked frame by frame; keep the scene running while waiting.
        var t: TimeInterval = 0
        for _ in 0..<300 where scene.memberTiles[id] != away || scene.walker.isWalking
            || abs(scene.walker.tile.x - away.x) + abs(scene.walker.tile.y - away.y) != 1 {
            await Task.yield(); t += 1.0 / 30; scene.update(t)
        }
        XCTAssertEqual(scene.memberTiles[id], away)
        XCTAssertEqual(abs(scene.walker.tile.x - away.x) + abs(scene.walker.tile.y - away.y), 1, "right beside them again")
        for _ in 0..<10 { t += 1.0 / 30; scene.update(t) }
        XCTAssertEqual(scene.followingMember, id, "still following after catching up")
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: rightKey)
        XCTAssertNil(scene.followingMember)
        XCTAssertNotEqual(c.hint, L(.ko).plazaFollowHint(nickname: "민수"))
    }

    /// Running reaches teammates, and a running teammate runs on my screen too.
    func testRunningReachesTeammatesBothWays() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil && other.session.members[me.settings.memberID] != nil }
        let scene = c.scene!, myID = me.settings.memberID, id = other.settings.memberID
        let right = TilePoint(x: map.spawn.x + 1, y: map.spawn.y)
        XCTAssertTrue(map.isWalkable(right), "test precondition")
        scene.currentModifiers = { .shift }
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false, modifiers: .shift)
        scene.update(0); scene.update(0.01)
        XCTAssertTrue(scene.walker.isRunning)
        await waitUntil { other.session.members[myID]?.isRunning == true }
        XCTAssertEqual(other.session.members[myID]?.isRunning, true)
        let spot = TilePoint(x: map.spawn.x - 3, y: map.spawn.y + 2)
        other.session.updatePlazaPosition(inPlaza: true, tile: spot, facing: .down, isWalking: true, isRunning: true)
        await waitUntil { scene.memberIsRunning(id) == true }
        XCTAssertEqual(scene.memberIsRunning(id), true)
        other.session.updatePlazaPosition(inPlaza: true, tile: spot, facing: .down, isWalking: false, isRunning: false)
        await waitUntil { scene.memberIsRunning(id) == false }
        XCTAssertEqual(scene.memberIsRunning(id), false, "stopping clears it")
    }

    /// Following a teammate who runs, I run too, so the train keeps together. Following one who walks, I walk.
    func testFollowingARunnerRuns() async {
        let (_, scene, other, id) = await standing()
        scene.currentModifiers = { [] }   // a real Shift held on this Mac must not make it pass
        follow(scene)
        XCTAssertEqual(scene.followingMember, id)
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down)
        let away = TilePoint(x: ahead.x, y: ahead.y + 3)
        XCTAssertTrue((0...3).allSatisfy { map.isWalkable(TilePoint(x: ahead.x, y: ahead.y + $0)) }, "test precondition")
        other.session.updatePlazaPosition(inPlaza: true, tile: away, facing: .down, isWalking: true, isRunning: false)
        var t: TimeInterval = 0, ran = false, walked = false
        for _ in 0..<300 where !walked {
            await Task.yield(); t += 1.0 / 60; scene.update(t)
            walked = scene.walker.isWalking; ran = ran || scene.walker.isRunning
        }
        XCTAssertTrue(walked)
        XCTAssertFalse(ran, "they walk, so I walk")
        let further = TilePoint(x: away.x, y: away.y + 2)
        XCTAssertTrue(map.isWalkable(TilePoint(x: away.x, y: away.y + 1)) && map.isWalkable(further), "test precondition")
        other.session.updatePlazaPosition(inPlaza: true, tile: further, facing: .down, isWalking: true, isRunning: true)
        for _ in 0..<300 where !ran { await Task.yield(); t += 1.0 / 60; scene.update(t); ran = scene.walker.isRunning }
        XCTAssertTrue(ran, "I ran after them without Shift")
    }

    /// Shift counts only with an arrow key held: typing a capital letter while following a walker does not run.
    func testShiftWithoutAnArrowKeyDoesNotRun() async {
        let (_, scene, other, _) = await standing()
        follow(scene)
        scene.currentModifiers = { .shift }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down)
        let away = TilePoint(x: ahead.x, y: ahead.y + 3)
        other.session.updatePlazaPosition(inPlaza: true, tile: away, facing: .down, isWalking: true)
        var t: TimeInterval = 0, walked = false, ran = false
        for _ in 0..<300 where !walked || scene.walker.isWalking {
            await Task.yield(); t += 1.0 / 60; scene.update(t)
            walked = walked || scene.walker.isWalking; ran = ran || scene.walker.isRunning
        }
        XCTAssertTrue(walked, "following walked")
        XCTAssertFalse(ran, "Shift alone does not run")
    }

    /// An egg cannot walk, so its menu has no 따라가기.
    func testAnEggIsNotOfferedFollowing() async {
        let (c, scene, _, id) = await standing()
        scene.canWalk = false
        space(scene)
        guard case .memberMenu(let menu) = c.overlayContent else { return XCTFail("no menu") }
        XCTAssertEqual(menu.actions, [.greet, .tackle, .viewCard])
        XCTAssertFalse(scene.follow(member: id))
    }

    /// Typing a line does not stop following, so a train can chat.
    func testChatDoesNotStopFollowing() async {
        let (c, scene, _, id) = await standing()
        follow(scene)
        key(scene, returnKey)
        XCTAssertTrue(c.chatInputForTesting.isOpen)
        XCTAssertEqual(scene.followingMember, id)
    }

    /// When the teammate leaves the plaza, following stops and the hint goes.
    func testFollowingStopsWhenTheTeammateLeaves() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        let link = hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == ahead }
        let scene = c.scene!
        follow(scene)
        XCTAssertEqual(scene.followingMember, id)
        hub.disconnect(link)
        await waitUntil { c.scene?.memberTiles[id] == nil }
        scene.update(0); scene.update(0.1)
        XCTAssertNil(scene.followingMember)
        XCTAssertNotEqual(c.hint, L(.ko).plazaFollowHint(nickname: "민수"), "the follow hint goes")
    }

    // MARK: - Jump

    /// Z makes me hop with dust at my feet and tells teammates. I cannot jump again in mid-air.
    func testJumpHopsRaisesDustAndReachesTheTeammate() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        var received: [(String, TeamEmote)] = []
        other.session.onEmote = { received.append(($0, $1)) }
        let scene = c.scene!
        scene.update(0)
        let groundY = scene.characterY, shadowY = scene.groundShadowY
        key(scene, zKey)
        key(scene, zKey)
        XCTAssertEqual(scene.dustCount, 2, "dust on both sides of my feet, once")
        var t: TimeInterval = 0
        scene.update(t)
        while t < PlazaActor.jumpDuration / 2 { t += 1.0 / 60; scene.update(t) }
        XCTAssertGreaterThan(scene.jumpLift(memberID: nil) ?? 0, PlazaActor.jumpHeight * 0.8, "up in the air halfway")
        XCTAssertGreaterThan(scene.characterY - groundY, PlazaActor.jumpHeight * 0.8, "the picture is drawn up there")
        XCTAssertEqual(scene.groundShadowY, shadowY, "the shadow stays on the ground")
        while t < PlazaActor.jumpDuration + 0.05 { t += 1.0 / 60; scene.update(t) }
        XCTAssertEqual(scene.jumpLift(memberID: nil), 0, "back on the ground")
        await waitUntil { !received.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received.map(\.1), [TeamEmote(kind: .jump, targetMemberID: nil)], "one jump went out")
    }

    func testEnterChoosesFromTheMenu() async {
        let (c, scene, _, id) = await standing()
        space(scene)
        key(scene, downKey)
        key(scene, downKey)
        key(scene, downKey)
        key(scene, returnKey)
        XCTAssertEqual(c.overlayContent.cardMemberID, id)
    }

    func testEscClosesTheMenuNotTheWindow() async {
        let (c, scene, _, id) = await standing()
        var closeRequests = 0
        scene.onCloseRequest = { closeRequests += 1 }
        space(scene)
        key(scene, escKey)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(scene.isOverlayOpen)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertNil(scene.shownEmote(memberID: id), "closing sends nothing")
    }

    func testHeldSpaceDoesNotChooseFromTheMenu() async {
        let (c, scene, _, id) = await standing()
        space(scene)
        scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: true)
        XCTAssertEqual(c.overlayContent, .memberMenu(PlazaMemberMenu(memberID: id, nickname: "민수")))
        XCTAssertNil(scene.shownEmote(memberID: nil))
    }

    /// Clicking a line calls the same choice as the keys.
    func testClickingALineChoosesIt() async {
        let (c, scene, _, id) = await standing()
        space(scene)
        c.chooseMenu(.viewCard, memberID: id)
        XCTAssertEqual(c.overlayContent.cardMemberID, id)
    }

    /// The teammate left while the menu was open: there is no card to fetch, so the menu just closes.
    func testViewingTheCardOfATeammateWhoLeftClosesTheMenu() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        let link = hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID] != nil }
        let ahead = PlazaTargeting.facingTile(from: map.spawn, facing: .down), id = other.settings.memberID
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await waitUntil { c.scene?.memberTiles[id] == ahead }
        let scene = c.scene!
        space(scene)
        hub.disconnect(link)
        await waitUntil { me.session.members[id] == nil && c.scene?.memberTiles[id] == nil }
        key(scene, downKey)
        key(scene, downKey)
        key(scene, downKey)
        space(scene)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(scene.isOverlayOpen)
    }

    /// Both lines fit the menu on one line each.
    func testMenuLinesFitTheMenu() {
        let inner = PlazaMemberMenuView.width - 2 * (PlazaRosterMetrics.padding + 2)
        for action in PlazaMemberAction.allCases {
            let text = "▶ " + PlazaMemberMenuView.title(action)
            let width = NSAttributedString(string: text, attributes: [.font: PlazaResources.font(.body)]).size().width
            XCTAssertLessThanOrEqual(width, inner, text)
        }
    }

    /// The menu renders at its fixed width, with the name and both lines one text line each.
    func testMenuViewKeepsItsWidthAndOneLineEach() {
        let view = PlazaMemberMenuView(menu: PlazaMemberMenu(memberID: "m", nickname: "ＷＷＷＷＷＷＷＷＷＷＷＷ", selection: .viewCard),
                                       onChoose: { _ in })
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(size.width, PlazaMemberMenuView.width)
        let line = NSLayoutManager().defaultLineHeight(for: PlazaResources.font(.body))
        // The name and four lines with four gaps; a wrapped line would add a whole line more.
        XCTAssertLessThan(size.height, 5.5 * line + 2 * (PlazaRosterMetrics.padding + 2) + 4 * 4, "five lines, none wrapped")
    }

    func testEscClosesOverlayNotWindow() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        var closeRequests = 0
        scene.onCloseRequest = { closeRequests += 1 }
        space(scene)
        XCTAssertEqual(scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false), .swallowed)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(scene.isOverlayOpen)
        // 닫힌 뒤의 Esc는 다시 창을 닫는다.
        XCTAssertEqual(scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false), .closeRequested)
        XCTAssertEqual(closeRequests, 1)
    }

    func testSpaceClosesOpenOverlay() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        space(c.scene!)
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .none)
    }

    func testHeldSpaceNeitherOpensNorClosesTheBoard() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)   // facing the board
        c.prepareScene()
        let scene = c.scene!
        scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: true)
        XCTAssertEqual(c.overlayContent, .none, "a repeat does not open")
        space(scene)
        XCTAssertEqual(c.overlayContent, .board)
        scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: true)
        XCTAssertEqual(c.overlayContent, .board, "a repeat does not close")
    }

    func testRepeatedEscNeverClosesAnything() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        var closeRequests = 0
        scene.onCloseRequest = { closeRequests += 1 }
        space(scene)
        scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false)
        XCTAssertEqual(scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: true), .swallowed)
        XCTAssertEqual(closeRequests, 0, "holding Esc after closing the panel must not close the window")
        XCTAssertEqual(c.overlayContent, .none)
        // a repeat does not close an open panel either
        space(scene)
        scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: true)
        XCTAssertEqual(c.overlayContent, .board)
    }

    func testRepeatedEscWithNothingOpenDoesNotCloseWindow() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        var closeRequests = 0
        scene.onCloseRequest = { closeRequests += 1 }
        XCTAssertEqual(scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: true), .swallowed)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertEqual(scene.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false), .closeRequested)
        XCTAssertEqual(closeRequests, 1)
    }

    func testArrowsAndEmoteKeysBlockedWhileOverlayOpen() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        space(scene)
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        scene.handleKeyDown(keyCode: heartKey, characters: "1", isRepeat: false)
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, aboveBoard)
        XCTAssertNil(scene.shownEmote(memberID: nil))
    }

    func testHeldKeyReleasedWhenOverlayOpens() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)   // held, not yet walked
        space(scene)
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, aboveBoard, "the held arrow does not walk under the panel")
        space(scene)   // close without ever releasing the arrow
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, aboveBoard, "and does not start walking once the panel closes")
    }

    func testCmdWStillClosesWindow() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        let scene = c.scene!
        var closeRequests = 0
        scene.onCloseRequest = { closeRequests += 1 }
        space(scene)
        XCTAssertEqual(scene.handleKeyDown(keyCode: wKey, characters: "w", isRepeat: false, modifiers: .command), .closeRequested)
        XCTAssertEqual(closeRequests, 1)
    }

    func testAwayMemberCanBeTalkedTo() async {
        let me = node("나"), other = node("민수")
        let id = other.settings.memberID
        // 자리 비운 팀원은 쉼터에서 쉰다. 같은 칸에 서면 말을 걸 수 있다.
        let spot = PlazaShelterWanderer(memberID: id, shelter: map.shelterTiles).tile
        let c = controller(me, start: spot)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await settle()
        XCTAssertEqual(c.scene?.memberTiles[id], spot)
        viewCard(c.scene!)
        XCTAssertEqual(c.overlayContent.cardMemberID, id)
        await waitUntil { if case .card(.loaded) = c.overlayContent { true } else { false } }
        guard case .card(.loaded) = c.overlayContent else { return XCTFail("away member did not load: \(c.overlayContent)") }
    }

    func testClosingTheWindowDropsTheOverlay() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        space(c.scene!)
        c.handleClose()
        XCTAssertEqual(c.overlayContent, .none)
    }
}
