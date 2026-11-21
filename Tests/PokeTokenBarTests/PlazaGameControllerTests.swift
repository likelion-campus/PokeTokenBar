import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// The plaza side of the minigame: my plaza (a real controller) and a teammate whose Mac is a bare session driven by its
/// own engine, as a second plaza would drive it.
@MainActor
final class PlazaGameControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t: TimeInterval = 0
    private let mKey: UInt16 = 46, yKey: UInt16 = 16, nKey: UInt16 = 45, zKey: UInt16 = 6, spaceKey: UInt16 = 49

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Date(timeIntervalSince1970: 1_800_000_000)
        t = 0
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor final class Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var engine: PlazaGameEngine
        var id: String { settings.memberID }

        init(settings: TeamSettings, session: TeamSession, transport: FakeTeamTransport) {
            self.settings = settings
            self.session = session
            self.transport = transport
            engine = PlazaGameEngine(me: settings.memberID)
        }

        /// What a plaza does every step: hear, move, tell.
        func step(_ now: Date) {
            let members = session.members.values
            for m in members { engine.learn(m.game, now: now) }
            let id = engine.state?.id
            engine.tick(now: now, present: Set(members.filter(\.inPlaza).map(\.memberID)),
                        joins: Set(members.filter { $0.inPlaza && id != nil && $0.gameJoin == id }.map(\.memberID)))
            session.updateGame(engine.state, join: engine.joined)
        }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.game.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaGameControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) },
                                  clock: { [unowned self] in now })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func controller(_ me: Node, start: TilePoint, speciesID: Int? = 25) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.game.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private func press(_ c: PlazaWindowController, _ key: UInt16) {
        c.scene?.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    private let mine = TilePoint(x: 10, y: 6), beside = TilePoint(x: 11, y: 6)

    /// Me in my plaza and teammate "가" standing right beside me.
    private func world(speciesID: Int? = 25, start: TilePoint? = nil) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, start: start ?? mine, speciesID: speciesID)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        b.session.updatePlazaPosition(inPlaza: true, tile: beside, facing: .left, isWalking: false, isFlushed: false)
        let w = World(c: c, me: me, b: b)
        for _ in 0..<200 where w.scene.memberTiles[b.id] != beside { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[b.id], beside, "test precondition")
        return w
    }

    /// Both step until what they know stops changing.
    private func sync(_ w: World) async {
        for _ in 0..<6 {
            w.b.step(now)
            await settle()
            w.c.advanceGame()
            await settle()
        }
    }

    /// The teammate hosts a game I joined and locks it so that `holder` starts with the bomb. Returns when play begins.
    private func hostedByTeammate(_ w: World, holder: String) async -> Date {
        let players = [w.me.id, w.b.id]
        let seed = (UInt64(1)...500).first { PlazaBomb.firstHolder(seed: $0, round: 1, alive: players) == holder }!
        w.b.engine.makeSeed = { seed }
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await sync(w)
        press(w.c, yKey)
        await sync(w)
        now += PlazaGame.recruitSeconds
        await sync(w)
        let starts = Date(timeIntervalSince1970: w.c.gameState?.startsAt ?? 0)
        XCTAssertEqual(w.c.gameState?.players.sorted(), players.sorted(), "test precondition")
        XCTAssertEqual(w.c.gameState?.bomb?.holder, holder, "test precondition")
        return starts
    }

    // MARK: - Opening and answering

    func testMOpensTheMenuWithTheRulesAndChoosingOpensAGameEveryoneSees() async {
        let w = await world()
        press(w.c, mKey)
        guard case .gameMenu(let menu) = w.c.overlayContent else { return XCTFail("no menu") }
        XCTAssertEqual(menu.kinds, [.bomb])
        XCTAssertNil(menu.blocked)
        w.c.chooseGame(index: 0)
        await settle()
        XCTAssertEqual(w.c.overlayContent, .none)
        let state = w.c.gameState
        XCTAssertEqual(state?.host, w.me.id)
        XCTAssertEqual(w.b.session.members[w.me.id]?.game, state, "the teammate's Mac got it")
        XCTAssertEqual(w.b.session.members[w.me.id]?.gameJoin, state?.id, "the host is in")
        let card = w.c.gameCard
        XCTAssertEqual(card?.title, L(.ko).plazaGameCardTitle(host: nil, game: L(.ko).plazaGameName(.bomb)))
        XCTAssertEqual(Array(card?.lines.prefix(3) ?? []), L(.ko).plazaGameRules(.bomb), "the rules are on the card")
        XCTAssertEqual(card?.buttons.map(\.action), ["start", "decline"])
        XCTAssertEqual(card?.buttons.first?.isEnabled, false, "alone, the host cannot start yet")
    }

    func testAnEggCannotOpenAGameAndTheMenuSaysWhy() async {
        let w = await world(speciesID: nil)
        press(w.c, mKey)
        guard case .gameMenu(let menu) = w.c.overlayContent else { return XCTFail("no menu") }
        XCTAssertEqual(menu.blocked, L(.ko).plazaGameMenuEgg)
        w.c.chooseGame(index: 0)
        XCTAssertNil(w.c.gameState)
    }

    func testATeammatesGameShowsAnInvitationAndYJoinsIt() async {
        let w = await world()
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await sync(w)
        let card = w.c.gameCard
        XCTAssertEqual(card?.title, L(.ko).plazaGameCardTitle(host: "가", game: L(.ko).plazaGameName(.bomb)))
        XCTAssertEqual(card?.buttons.map(\.action), ["join", "decline"])
        XCTAssertEqual(card?.lines.last, L(.ko).plazaGameRecruiting(players: 1, seconds: Int(PlazaGame.recruitSeconds)))
        press(w.c, yKey)
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.gameJoin, w.b.engine.state?.id)
        XCTAssertEqual(w.c.gameCard?.buttons.map(\.action), ["decline"], "after joining only leaving is left")
        XCTAssertTrue(w.c.gameCard?.lines.last?.hasPrefix(L(.ko).plazaGameJoined) == true)
        XCTAssertTrue(w.c.gameCard?.lines.last?.contains(L(.ko).plazaGameRecruiting(players: 2, seconds: Int(PlazaGame.recruitSeconds))) == true)
    }

    func testNPutsTheInvitationAwayAndTellsNobody() async {
        let w = await world()
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await sync(w)
        press(w.c, nKey)
        await settle()
        XCTAssertNil(w.c.gameCard)
        XCTAssertNil(w.b.session.members[w.me.id]?.gameJoin)
        now += 5
        await sync(w)
        XCTAssertNil(w.c.gameCard, "it stays away")
    }

    func testAnEggSeesTheInvitationButCannotJoin() async {
        let w = await world(speciesID: nil)
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await sync(w)
        XCTAssertEqual(w.c.gameCard?.lines.last, L(.ko).plazaGameEggNote)
        XCTAssertEqual(w.c.gameCard?.buttons.map(\.action), ["decline"])
        press(w.c, yKey)
        await settle()
        XCTAssertNil(w.c.gameJoined)
    }

    func testTheHostStartsEarlyWithMOnceATeammateIsIn() async {
        let w = await world()
        press(w.c, mKey)
        w.c.chooseGame(index: 0)
        await sync(w)
        w.b.engine.answer(join: true, now: now)
        await sync(w)
        XCTAssertEqual(w.c.gameCard?.buttons.first?.isEnabled, true)
        now += 3
        press(w.c, mKey)
        await settle()
        XCTAssertEqual(w.c.overlayContent, .none, "M starts the game, it does not open the menu again")
        XCTAssertEqual(w.c.gameState?.startsAt, now.timeIntervalSince1970 + PlazaGame.countdownSeconds)
        XCTAssertEqual(w.c.gameState?.players.sorted(), [w.me.id, w.b.id].sorted())
    }

    func testClosingThePlazaCancelsTheGameIOpened() async {
        let w = await world()
        press(w.c, mKey)
        w.c.chooseGame(index: 0)
        await sync(w)
        w.c.handleClose()
        await settle()
        let seen = w.b.session.members[w.me.id]?.game
        XCTAssertNotNil(seen?.endedAt)
        XCTAssertNil(seen?.winner)
        XCTAssertNil(w.b.session.members[w.me.id]?.gameJoin)
    }

    // MARK: - Playing

    func testTheCountdownShowsBigAndTheStartToo() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        XCTAssertEqual(w.c.gameTitle, .init(text: "3", tone: .count))
        XCTAssertEqual(w.c.gameCard?.lines.last, L(.ko).plazaGameStartingSoon, "the rules stay up through the countdown")
        XCTAssertNil(w.c.gameCard?.buttons.first)
        now = starts.addingTimeInterval(-0.5)
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameTitle?.text, "1")
        now = starts.addingTimeInterval(0.2)
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameGo, tone: .go))
        XCTAssertNil(w.c.gameCard)
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameRunHint(nickname: "가"))
        XCTAssertEqual(w.scene.bombHolders, [w.b.id])
        now = starts.addingTimeInterval(1.5)
        w.c.advanceGame()
        XCTAssertNil(w.c.gameTitle)
    }

    func testTheHoldersTackleHandsMeTheBomb() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)   // what the runtime calls when the tackle arrives
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.me.id)
        XCTAssertEqual(w.c.gameState?.bomb?.from, w.b.id)
        XCTAssertEqual(w.b.session.members[w.me.id]?.game?.bomb?.holder, w.me.id, "and the teammate's Mac hears it")
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameHoldHint)
        XCTAssertEqual(w.scene.bombHolders, [nil], "the bomb is over my head")
    }

    func testATackleFromSomeoneWithoutTheBombChangesNothing() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.me.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.me.id)
        XCTAssertEqual(w.c.gameState?.bomb?.pass, 0)
    }

    func testTheHoldersThrowHandsMeTheBombWhenItLands() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .left)
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.b.id, "not before it lands")
        await settle()
        for _ in 0..<40 { t += 0.05; w.scene.update(t) }
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.me.id)
    }

    func testIBlowUpWhenTheFuseRunsOutInMyHandsAndTheTeammateWins() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.me.id)
        let s = try! XCTUnwrap(w.c.gameState)
        let fuse = PlazaBomb.fuse(seed: s.seed, round: 1)
        now = starts.addingTimeInterval(fuse - PlazaBomb.urgentSeconds + 0.5)
        w.c.advanceGame()
        XCTAssertTrue(w.c.gameView.urgent, "the last three seconds show")
        now = starts.addingTimeInterval(fuse + 0.1)
        w.c.advanceGame()
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.out, [w.me.id])
        XCTAssertEqual(w.c.gameState?.winner, w.b.id)
        XCTAssertEqual(w.b.session.members[w.me.id]?.game?.winner, w.b.id)
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameOut(nickname: nil), tone: .out))
        XCTAssertTrue(w.scene.isBlasting(memberID: nil), "I fly")
        XCTAssertEqual(w.scene.bombHolders, [], "the bomb is gone")
        now += PlazaWindowController.gameOutFlash + 0.1
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameWin(nickname: "가"), tone: .win), "then who won")
        now += PlazaWindowController.gameWinFlash + 0.1
        w.c.advanceGame()
        XCTAssertNil(w.c.gameTitle)
        XCTAssertNil(w.c.gameView.hint, "the game's hint is gone")
    }

    func testTheTeammateBlowingUpMakesMeTheWinner() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        let s = try! XCTUnwrap(w.c.gameState)
        now = starts.addingTimeInterval(PlazaBomb.fuse(seed: s.seed, round: 1) + 0.1)
        await sync(w)
        XCTAssertEqual(w.c.gameState?.winner, w.me.id)
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameOut(nickname: "가"), tone: .out))
        XCTAssertTrue(w.scene.isBlasting(memberID: w.b.id))
    }

    func testNoDivingWhileIPlay() async throws {
        let map = PlazaMapData.map
        // A land tile with hot-spring water to its right: I plunge in from there.
        let shore = try XCTUnwrap((1..<map.width).lazy.flatMap { x in (0..<map.height).lazy.map { TilePoint(x: x, y: $0) } }
            .first { map.isHotSpring($0) && map.isWalkable(TilePoint(x: $0.x - 1, y: $0.y)) }.map { TilePoint(x: $0.x - 1, y: $0.y) })
        let w = await world(start: shore)
        w.scene.face(.right)
        press(w.c, zKey)
        for _ in 0..<30 { t += 0.05; w.scene.update(t) }
        XCTAssertTrue(w.scene.isMeInWater, "test precondition")
        now += 1
        press(w.c, zKey)
        XCTAssertTrue(w.scene.isDiving, "outside a game Z dives")
        now += 1
        press(w.c, zKey)
        XCTAssertFalse(w.scene.isDiving)
        _ = await hostedByTeammate(w, holder: w.b.id)
        now += 1
        press(w.c, zKey)
        XCTAssertFalse(w.scene.isDiving, "a diver cannot be hit, so a player cannot dive")
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameNoDive)
    }

    func testClosingThePlazaWithTheBombBlowsMeUp() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.me.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.handleClose()
        await settle()
        let seen = w.b.session.members[w.me.id]?.game
        XCTAssertEqual(seen?.bomb?.out, [w.me.id])
        XCTAssertEqual(seen?.winner, w.b.id)
    }

    func testAWatcherGetsBannersNotTheBigTitle() async throws {
        let w = await world()
        // The teammate and a third member play; I never answer.
        let third = node("다")
        hub.connect(w.me.transport, to: third.transport)
        hub.connect(w.b.transport, to: third.transport)
        await settle()
        third.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 14, y: 6), facing: .down, isWalking: false, isFlushed: false)
        await settle()
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        for _ in 0..<4 { w.b.step(now); await settle(); third.step(now); await settle(); w.c.advanceGame(); await settle() }
        third.engine.answer(join: true, now: now)
        now += PlazaGame.recruitSeconds
        for _ in 0..<4 { third.step(now); await settle(); w.b.step(now); await settle(); w.c.advanceGame(); await settle() }
        XCTAssertEqual(w.c.gameState?.players.sorted(), [w.b.id, third.id].sorted(), "test precondition")
        XCTAssertNil(w.c.gameTitle)
        XCTAssertNil(w.c.gameCard)
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameStartedBanner(game: L(.ko).plazaGameName(.bomb), players: 2))
        XCTAssertNotNil(w.c.gameView.holder, "the bomb still shows over the holder")
        XCTAssertNil(w.c.gameView.hint)
        // The explosion and the result reach a watcher as banners too.
        let s = try XCTUnwrap(w.c.gameState)
        let holder = try XCTUnwrap(s.bomb?.holder)
        now = Date(timeIntervalSince1970: (s.startsAt ?? 0) + PlazaBomb.fuse(seed: s.seed, round: 1) + 0.1)
        for _ in 0..<4 { third.step(now); await settle(); w.b.step(now); await settle(); w.c.advanceGame(); await settle() }
        XCTAssertEqual(w.c.gameState?.bomb?.out, [holder], "test precondition")
        XCTAssertNil(w.c.gameTitle, "no big title for someone who is not playing")
        let winner = holder == w.b.id ? "다" : "가"
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameWinBanner(nickname: winner, game: L(.ko).plazaGameName(.bomb)))
    }
}
