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
            for m in members { engine.learn(m.game, from: m.memberID, now: now) }
            let id = engine.state?.id
            engine.tick(now: now, present: Set(members.filter(\.inPlaza).map(\.memberID)),
                        joins: Set(members.filter { $0.inPlaza && id != nil && $0.gameJoin == id }.map(\.memberID)),
                        connected: !members.isEmpty)
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
        XCTAssertEqual(menu.kinds, [.bomb, .draw])
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

    func testChoosingTheDrawingQuizOpensItForEveryone() async {
        let w = await world()
        press(w.c, mKey)
        press(w.c, 125)   // down
        press(w.c, spaceKey)
        await settle()
        XCTAssertEqual(w.c.overlayContent, .none)
        XCTAssertEqual(w.c.gameState?.kind, PlazaGameKind.draw.rawValue)
        XCTAssertEqual(w.b.session.members[w.me.id]?.game, w.c.gameState, "the teammate's Mac got it")
        XCTAssertEqual(Array(w.c.gameCard?.lines.prefix(3) ?? []), L(.ko).plazaGameRules(.draw), "the three rule lines are on the card")
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
        XCTAssertEqual(w.c.gameCard?.lines.first, L(.ko).plazaGameRules(.bomb).first, "the rules stay up through the countdown")
        XCTAssertEqual(w.c.gameCard?.lines.last, L(.ko).plazaGamePlayers(w.c.gameState!.players.map { $0 == w.me.id ? "나" : "가" }),
                       "with who plays")
        XCTAssertNil(w.c.gameCard?.buttons.first)
        // Who gets the bomb stays hidden until it is live: shown early, everyone else had the whole countdown to run.
        XCTAssertEqual(w.scene.bombHolders, [], "no bomb over anyone yet")
        XCTAssertNil(w.c.gameView.holder)
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameScatterHint)
        XCTAssertFalse(w.c.minimapDots.contains(where: \.hasBomb))
        now = starts.addingTimeInterval(-0.5)
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameTitle?.text, "1")
        now = starts.addingTimeInterval(0.2)
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameGo, tone: .go))
        XCTAssertNil(w.c.gameCard)
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameRunHint(nickname: "가"))
        XCTAssertEqual(w.scene.bombHolders, [w.b.id])
        XCTAssertEqual(w.c.minimapDots.filter(\.hasBomb).map(\.id), [w.b.id], "the holder is ringed on the minimap")
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
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameNoReturnHint(nickname: "가"), "the rule that blocks the way back is said")
        XCTAssertEqual(w.scene.bombHolders, [nil], "the bomb is over my head")
        now += PlazaBomb.returnImmunity
        w.c.advanceGame()
        XCTAssertEqual(w.c.hint, L(.ko).plazaGameHoldHint)
    }

    /// The teammate stands at `tile` on my screen (told and drawn).
    private func teammate(_ w: World, at tile: TilePoint) async {
        w.b.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .left, isWalking: false, isFlushed: false)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
    }

    /// A holder tackles when they touch me on their screen. Mine is behind theirs by the step each of us has just begun, so
    /// on my screen they can still be a tile or two short. The bomb passes all the same; I am only pushed when they touch
    /// me here. (Before: my screen had to show them touching, so a hit on a running player was often dropped.)
    func testTheHoldersTackleHandsMeTheBombWhenMyScreenShowsThemATileOrTwoShort() async {
        for gap in [2, 3] {
            let w = await world()
            let starts = await hostedByTeammate(w, holder: w.b.id)
            now = starts.addingTimeInterval(2)
            await sync(w)
            await teammate(w, at: TilePoint(x: mine.x + gap, y: mine.y))
            w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
            await settle()
            XCTAssertEqual(w.c.gameState?.bomb?.holder, w.me.id, "\(gap) tiles away on my screen")
            for _ in 0..<20 { t += 0.05; w.scene.update(t) }
            XCTAssertEqual(w.scene.walker.tile, mine, "not touching here: no push")
        }
    }

    /// Further than that is no hit: a tackle only counts near me.
    func testATackleFromFurtherAwayThanTheLagAllowsDoesNotPassTheBomb() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        await teammate(w, at: TilePoint(x: mine.x + 4, y: mine.y))
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.b.id)
        XCTAssertEqual(w.c.gameState?.bomb?.pass, 0)
    }

    /// The tile the holder last told me counts, not only where my screen has drawn them so far: the drawing walks behind.
    func testTheHoldersLastToldTileCountsWhenTheDrawingIsBehind() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        await teammate(w, at: TilePoint(x: mine.x + 4, y: mine.y))
        w.b.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: mine.x + 3, y: mine.y), facing: .left, isWalking: true, isFlushed: false)
        await settle()   // told, and no frame has drawn it yet
        XCTAssertEqual(w.scene.memberTiles[w.b.id], TilePoint(x: mine.x + 4, y: mine.y), "test precondition: the drawing is behind")
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        await settle()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.me.id)
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

    /// Only a tackle passes the bomb: the holder's throw lands on me and pushes me as always, and the bomb stays.
    func testTheHoldersThrowDoesNotHandMeTheBomb() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .left)
        await settle()
        for _ in 0..<40 { t += 0.05; w.scene.update(t) }
        await settle()
        XCTAssertEqual(w.scene.walker.tile, TilePoint(x: mine.x - 1, y: mine.y), "the throw landed and pushed me")
        XCTAssertEqual(w.c.gameState?.bomb?.holder, w.b.id)
        XCTAssertEqual(w.c.gameState?.bomb?.pass, 0)
    }

    // MARK: - Who plays: the rings, the minimap, the list

    /// From the moment the players are locked in, each has a ring under their feet and around their minimap dot, and
    /// the list under the hint names them. The holder's ring is the bomb's colour once the bomb is live.
    func testPlayersAreRingedAndListedFromTheCountdown() async {
        let w = await world()
        XCTAssertEqual(w.scene.gameMarks, [:], "nobody is marked outside a game")
        XCTAssertNil(w.c.gameStatus)
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(-2)
        w.c.advanceGame()
        XCTAssertEqual(w.scene.gameMarks, ["": .alive, w.b.id: .alive], "the countdown: both in, no holder shown yet")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: w.c.minimapDots.map { ($0.id, $0.game) }), [w.me.id: .alive, w.b.id: .alive])
        XCTAssertEqual(w.c.gameStatus, L(.ko).plazaGameStatus(alive: ["나", "가"].sorted { a, b in
            (a == "나" ? w.me.id : w.b.id) < (b == "나" ? w.me.id : w.b.id)
        }, out: [], holder: nil))
        now = starts.addingTimeInterval(2)
        w.c.advanceGame()
        XCTAssertEqual(w.scene.gameMarks, ["": .alive, w.b.id: .holder])
        XCTAssertEqual(w.c.minimapDots.first { $0.id == w.b.id }?.game, .holder)
        XCTAssertTrue(w.c.gameStatus?.contains("💣가") == true, "the holder is named with the bomb")
    }

    /// Whoever blew up keeps a grey ring and moves to the "out" half of the list until the game is over; then every
    /// mark goes.
    func testAnOutPlayerIsMarkedOutUntilTheGameEnds() async throws {
        let w = await world()
        let c = node("다")
        hub.connect(w.me.transport, to: c.transport)
        hub.connect(w.b.transport, to: c.transport)
        await settle()
        c.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 14, y: 6), facing: .left, isWalking: false, isFlushed: false)
        for _ in 0..<200 where w.scene.memberTiles[c.id] == nil { await Task.yield(); t += 0.05; w.scene.update(t) }
        // A three-player game that the teammate hosts; the third player's plaza steps along with the other two.
        func syncAll() async {
            for _ in 0..<6 {
                w.b.step(now)
                c.step(now)
                await settle()
                w.c.advanceGame()
                await settle()
            }
        }
        let players = [w.me.id, w.b.id, c.id].sorted()
        let seed = (UInt64(1)...500).first { PlazaBomb.firstHolder(seed: $0, round: 1, alive: players) == w.b.id }!
        w.b.engine.makeSeed = { seed }
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await syncAll()
        press(w.c, yKey)
        c.engine.answer(join: true, now: now)
        await syncAll()
        now += PlazaGame.recruitSeconds
        await syncAll()
        let s = try XCTUnwrap(w.c.gameState)
        XCTAssertEqual(s.players, players, "test precondition")
        let starts = Date(timeIntervalSince1970: s.startsAt ?? 0)
        now = starts.addingTimeInterval(PlazaBomb.fuse(seed: s.seed, round: 1) + 0.1)
        await syncAll()
        XCTAssertEqual(w.c.gameState?.bomb?.out, [w.b.id])
        XCTAssertEqual(w.scene.gameMarks[w.b.id], .out)
        XCTAssertEqual(w.scene.gameMarks[""], .alive)
        XCTAssertEqual(w.c.minimapDots.first { $0.id == w.b.id }?.game, .out)
        XCTAssertTrue(w.c.gameStatus?.hasSuffix("탈락 가") == true, w.c.gameStatus ?? "nil")
        // The game goes on without them, and they stay sooty for all of it: past the time the soot lasts by itself.
        for _ in 0..<Int(2 * PlazaActor.sootDuration / 0.05) { t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.gameMarks[w.b.id], .out, "test precondition: the game is still on")
        XCTAssertEqual(w.scene.sootAmount(memberID: w.b.id), PlazaActor.sootBlend)
    }

    /// When the game is over nobody is marked any more.
    func testTheMarksGoWhenTheGameEnds() async throws {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        let s = try XCTUnwrap(w.c.gameState)
        now = starts.addingTimeInterval(PlazaBomb.fuse(seed: s.seed, round: 1) + 0.1)
        await sync(w)
        XCTAssertEqual(w.c.gameState?.winner, w.me.id, "test precondition")
        XCTAssertEqual(w.scene.gameMarks, [:])
        XCTAssertNil(w.c.gameStatus)
        XCTAssertTrue(w.c.minimapDots.allSatisfy { $0.game == nil })
    }

    /// The list hides with the hint line in photo mode.
    func testTheListHidesInPhotoMode() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.b.id)
        now = starts.addingTimeInterval(2)
        w.c.advanceGame()
        XCTAssertNotNil(w.c.gameStatus)
        w.scene.enterPhotoMode()
        w.c.advanceGame()
        XCTAssertNil(w.c.gameStatus)
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
        XCTAssertEqual(w.scene.isBlastShaking, !PlatformPlaza.reduceMotion(), "a player's screen shakes, unless the OS asks for less motion")
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
        XCTAssertNil(w.c.gameView.holder, "no bomb before it is live")
        XCTAssertNil(w.c.gameView.hint)
        // The explosion and the result reach a watcher as banners too.
        let s = try XCTUnwrap(w.c.gameState)
        let holder = try XCTUnwrap(s.bomb?.holder)
        now = Date(timeIntervalSince1970: (s.startsAt ?? 0) + PlazaBomb.fuse(seed: s.seed, round: 1) + 0.1)
        for _ in 0..<4 { third.step(now); await settle(); w.b.step(now); await settle(); w.c.advanceGame(); await settle() }
        XCTAssertEqual(w.c.gameState?.bomb?.out, [holder], "test precondition")
        XCTAssertNil(w.c.gameTitle, "no big title for someone who is not playing")
        XCTAssertTrue(w.scene.isBlasting(memberID: holder), "test precondition: the blast plays")
        XCTAssertFalse(w.scene.isBlastShaking, "but a watcher's screen does not shake")
        let winner = holder == w.b.id ? "다" : "가"
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameWinBanner(nickname: winner, game: L(.ko).plazaGameName(.bomb)))
    }

    // MARK: - The 2026-11-22 audit

    /// Before: every player who left was drawn blowing up, sooty for a minute, under "탈락!".
    func testATeammateWhoLeavesMidGameIsNotShownBlowingUp() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.me.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.b.engine.leave(now: now, present: [w.me.id])   // the teammate closes the plaza without the bomb
        await sync(w)
        XCTAssertEqual(w.c.gameState?.bomb?.out, [w.b.id], "test precondition")
        XCTAssertFalse(w.scene.isBlasting(memberID: w.b.id))
        XCTAssertFalse(w.scene.isBlastShaking)
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameLeftBanner(nickname: "가"))
        XCTAssertEqual(w.c.gameTitle, .init(text: L(.ko).plazaGameWin(nickname: nil), tone: .win), "I am the one left")
    }

    /// Before: my Mac played whenever the list named me, so a list made up by a modified app pulled me out of a dive,
    /// took my hint line and showed me blowing up on every plaza.
    func testAListThatNamesMeWithoutMyYesNeitherPlaysMeNorBlowsMeUp() async {
        let w = await world()
        var forged = PlazaGameState(id: "\(w.b.id)@1", kind: "bomb", host: w.b.id, opensAt: now.timeIntervalSince1970 - 10)
        forged.startsAt = now.timeIntervalSince1970 - 5
        forged.players = [w.me.id, w.b.id].sorted()
        forged.seed = 1
        forged.bomb = PlazaBombState(round: 1, roundStartsAt: forged.startsAt!, holder: w.me.id)
        w.b.session.updateGame(forged, join: forged.id)
        await settle()
        w.c.advanceGame()
        XCTAssertNotNil(w.c.gameState, "test precondition: the list is within bounds")
        XCTAssertNil(w.c.gameView.hint, "my hint line is my own")
        XCTAssertNil(w.c.gameTitle)
        XCTAssertFalse(w.scene.isBlasting(memberID: nil))
        XCTAssertEqual(w.c.gameState?.bomb?.out.contains(w.me.id), true, "and I am out of it")
        // The forger marks me out by itself on another Mac's view: still no blast, no name.
        w.c.handleClose()
    }

    /// Before: whoever a list put out was drawn blowing up, under "탈락!", on every open plaza.
    func testAMemberPutOutByAListTheyNeverJoinedIsNotShownBlowingUp() async throws {
        let w = await world()
        let third = node("다")
        hub.connect(w.me.transport, to: third.transport)
        hub.connect(w.b.transport, to: third.transport)
        await settle()
        third.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 14, y: 6), facing: .down, isWalking: false, isFlushed: false)
        await settle()
        for _ in 0..<200 where w.scene.memberTiles[third.id] == nil { await Task.yield(); t += 0.05; w.scene.update(t) }
        // The teammate's (modified) app says a game is running with "다" holding a live bomb; "다" never said yes.
        var forged = PlazaGameState(id: "\(w.b.id)@1", kind: "bomb", host: w.b.id, opensAt: now.timeIntervalSince1970 - 10)
        forged.startsAt = now.timeIntervalSince1970 - 5
        forged.players = [third.id, w.b.id].sorted()
        forged.seed = 1
        forged.bomb = PlazaBombState(round: 1, roundStartsAt: forged.startsAt!, holder: third.id)
        w.b.session.updateGame(forged, join: forged.id)
        await settle()
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameState?.bomb?.holder, third.id, "test precondition: I saw the holder before the blast")
        forged.bomb?.out = [third.id]
        forged.bomb?.pass = 1
        forged.endedAt = now.timeIntervalSince1970
        forged.winner = w.b.id
        w.b.session.updateGame(forged, join: forged.id)
        await settle()
        w.c.advanceGame()
        XCTAssertEqual(w.c.gameState?.bomb?.out, [third.id], "test precondition")
        XCTAssertFalse(w.scene.isBlasting(memberID: third.id))
        XCTAssertNotEqual(w.c.banner, L(.ko).plazaGameOutBanner(nickname: "다"))
        XCTAssertNotEqual(w.c.banner, L(.ko).plazaGameLeftBanner(nickname: "다"))
    }

    /// Before: in the plaza a focusing player could not be tackled, so the campfire was a shelter from the bomb.
    func testTheHolderCanTackleAFocusingPlayerButNobodyElseCan() async {
        let w = await world()
        var tackles = 0
        w.b.session.onEmote = { _, emote in if emote.kind == .tackle { tackles += 1 } }
        let starts = await hostedByTeammate(w, holder: w.me.id)
        w.b.session.updateFocus(endsAt: now.addingTimeInterval(600))
        await settle()
        w.scene.onTackleKey?()   // the countdown: no live bomb in my hands yet
        await settle()
        XCTAssertEqual(tackles, 0, "a focusing teammate is left alone")
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.scene.onTackleKey?()
        await settle()
        XCTAssertEqual(tackles, 1, "but my live bomb reaches a player")
    }

    /// Before: closing the plaza left the last game in my presence, sent with every heartbeat until the plaza reopened.
    func testAGameThatIsOverIsNoLongerSent() async {
        let w = await world()
        let starts = await hostedByTeammate(w, holder: w.me.id)
        now = starts.addingTimeInterval(2)
        await sync(w)
        w.c.handleClose()
        XCTAssertNotNil(w.me.session.makePresence().game, "the result goes out while it is fresh")
        now += PlazaGame.endedKeep
        XCTAssertNil(w.me.session.makePresence().game)
        XCTAssertNil(w.me.session.makePresence().gameJoin)
    }

    /// Before: Y in photo mode joined a game whose card photo mode was hiding.
    func testGameKeysDoNothingInPhotoMode() async {
        let w = await world()
        XCTAssertTrue(w.b.engine.open(.bomb, now: now))
        await sync(w)
        w.scene.enterPhotoMode()
        press(w.c, yKey)
        await sync(w)
        XCTAssertNil(w.c.gameJoined)
    }

    /// Before: the menu said another game was open in the seconds after one ended, and a host could loop invitations.
    func testTheMenuSaysHowLongUntilICanOpenAgainAfterCancelling() async {
        let w = await world()
        press(w.c, mKey)
        press(w.c, spaceKey)
        await sync(w)
        XCTAssertEqual(w.c.gameState?.host, w.me.id, "test precondition")
        press(w.c, nKey)   // I cancel my own game
        await sync(w)
        XCTAssertNil(w.c.banner, "nothing to tell the one who cancelled")
        now += PlazaGame.rematchDelay + 1
        press(w.c, mKey)
        guard case .gameMenu(let menu) = w.c.overlayContent else { return XCTFail("the menu opens") }
        XCTAssertEqual(menu.blocked, L(.ko).plazaGameMenuWait(seconds: Int(PlazaGame.reopenDelay - PlazaGame.rematchDelay - 1)))
    }
}
