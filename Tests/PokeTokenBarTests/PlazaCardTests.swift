import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private let spaceKey: UInt16 = 49, escKey: UInt16 = 53, wKey: UInt16 = 13, rightKey: UInt16 = 124, heartKey: UInt16 = 18

private extension PlazaOverlayContent {
    var cardMemberID: String? {
        switch self {
        case .card(.loading(let s)), .card(.loaded(let s, _)), .card(.failed(let s)): s.memberID
        case .none, .board: nil
        }
    }
}

final class PlazaInteractionTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testBoardWinsOverMember() {
        let board = map.boardTile
        let above = p(board.x, board.y - 1)
        // 소식판 칸에 팀원이 겹쳐 있어도 판이 먼저다.
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: ["a": board]), .board)
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: [:]), .board)
    }

    func testMemberAheadIsTheTarget() {
        let from = map.spawn
        let ahead = PlazaTargeting.facingTile(from: from, facing: .down)
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["b": ahead, "a": ahead]), .member("a"))
        XCTAssertNil(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["far": p(1, 1)]))
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
        try await super.setUp()
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
        try await super.tearDown()
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

    private func controller(_ me: Node, start: TilePoint, timeout: Duration = .seconds(5)) -> PlazaWindowController {
        let name = "plaza.card.prefs.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, profileTimeout: timeout)
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

    func testFacingNothingOpensNothing() {
        let me = node("나")
        let c = controller(me, start: TilePoint(x: 10, y: 10))
        c.prepareScene()
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertFalse(c.scene!.isOverlayOpen)
    }

    func testSpaceOnBoardOpensEmptyBoardPanel() {
        let me = node("나")
        let c = controller(me, start: aboveBoard)
        c.prepareScene()
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        XCTAssertTrue(c.scene!.isOverlayOpen)
    }

    func testSpaceOnMemberLoadsProfile() async {
        let (c, scene, other, id) = await standing()
        space(scene)
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
        space(scene)
        XCTAssertEqual(c.overlayContent.cardMemberID, id)
        await waitUntil { if case .card(.failed) = c.overlayContent { true } else { false } }
        guard case .card(.failed(let state)) = c.overlayContent else { return XCTFail("expected failed, got \(c.overlayContent)") }
        XCTAssertEqual(state.memberID, id)
        XCTAssertTrue(scene.isOverlayOpen, "a failed card stays open until closed")
    }

    func testResultAfterCloseIsDiscarded() async {
        let (c, scene, _, _) = await standing(timeout: .milliseconds(50), severed: true)
        space(scene)
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
        space(scene)                                                    // slow member: never answers
        XCTAssertEqual(c.overlayContent.cardMemberID, slow.settings.memberID)
        space(scene)                                                    // close
        fast.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        // (`ahead` is a shelter tile, so the scene tile alone can match before the update lands; wait on the received position)
        await waitUntil { me.session.members[fast.settings.memberID]?.tile == ahead && scene.memberTiles[fast.settings.memberID] == ahead }
        space(scene)                                                    // fast member answers at once
        await waitUntil { if case .card(.loaded) = c.overlayContent { true } else { false } }
        try? await Task.sleep(for: .milliseconds(900))                 // the first request now times out
        guard case .card(.loaded(let s, _)) = c.overlayContent else { return XCTFail("stale result replaced the card: \(c.overlayContent)") }
        XCTAssertEqual(s.memberID, fast.settings.memberID)
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
        space(c.scene!)
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
