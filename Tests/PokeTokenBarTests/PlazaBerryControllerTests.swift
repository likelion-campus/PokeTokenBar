import XCTest
@testable import PokeTokenBar

private struct EmptyBerryFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Berry five at the plaza table: my plaza is a real controller, and the teammates are bare sessions each driving its own engine, sending its
/// own bell, as their own plazas would. The host (the first teammate) deals.
@MainActor
final class PlazaBerryControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var up: Double = 100
    private var viewport = CGSize(width: 960, height: 640)
    private var panelHost: RecordingPanelHost?
    private var asked: [String] = []
    private let mKey: UInt16 = 46, yKey: UInt16 = 16, nKey: UInt16 = 45, returnKey: UInt16 = 36, escKey: UInt16 = 53, spaceKey: UInt16 = 49
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Date(timeIntervalSince1970: 1_800_000_000)
        up = 100
        asked = []
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

        /// What a plaza does every step: hear, move, show its screen, tell (with its bell).
        func step(_ now: Date, up: Double) {
            let members = session.members.values
            for m in members where m.inPlaza { if let j = m.gameJoin { engine.heardPlaying(j) } }
            for m in members { engine.learn(m.game, from: m.memberID, now: now) }
            let id = engine.state?.id
            engine.tick(now: now, present: Set(members.filter(\.inPlaza).map(\.memberID)),
                        joins: Set(members.filter { $0.inPlaza && id != nil && $0.gameJoin == id }.map(\.memberID)),
                        connected: !members.isEmpty, heard: Set(session.members.keys),
                        bells: Dictionary(uniqueKeysWithValues: members.filter(\.inPlaza).compactMap { m in m.gameBell.map { (m.memberID, $0) } }))
            engine.berrySeen(at: up)
            tell()
        }

        func tell() { session.updateGame(engine.state, join: engine.joined, bell: engine.berryBell) }
    }

    private func node(_ name: String, id: String) -> Node {
        let defaults = TestDefaults.make(suite: "plaza.berry.\(UUID())")
        defaults.set(id, forKey: "team.memberID")
        let settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBerryControllerTests-\(UUID())")
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

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node, d: Node, input: PlazaTypingChatInput
        var links: [FakeConnection]
        var scene: PlazaScene { c.scene! }
    }

    private func controller(_ me: Node, input: PlazaTypingChatInput) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.berry.prefs.\(UUID())"))
        prefs.saveLastTile(TilePoint(x: 10, y: 6))
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyBerryFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil },
                                     throwItem: { [unowned self] name in asked.append(name); return nil }, session: me.session,
                                     clock: { [unowned self] in now }, uptime: { [unowned self] in up },
                                     renderCheckSleep: Self.park, focusTickSleep: Self.park,
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: input)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func press(_ w: World, _ key: UInt16, repeating: Bool = false) {
        w.c.scene?.handleKeyDown(keyCode: key, characters: key == spaceKey ? " " : "ㅁ", isRepeat: repeating)
    }

    /// Me (id between the teammates', so I sit second) with the host and one more teammate, all standing in the plaza and hearing each other.
    private func world() async -> World {
        let me = node("나", id: "m-me"), b = node("가", id: "a-host"), d = node("다", id: "z-last")
        let input = PlazaTypingChatInput()
        let c = controller(me, input: input)
        c.prepareScene()
        let links = [hub.connect(me.transport, to: b.transport), hub.connect(me.transport, to: d.transport)]
        hub.connect(b.transport, to: d.transport)
        await settle()
        for (i, o) in [b, d].enumerated() {
            o.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 11 + i, y: 6), facing: .left, isWalking: false, isFlushed: false)
        }
        await settle()
        return World(c: c, me: me, b: b, d: d, input: input, links: links)
    }

    private func sync(_ w: World) async {
        for _ in 0..<6 {
            w.b.step(now, up: up + 7000)
            w.d.step(now, up: up + 9000)
            await settle()
            w.c.advanceGame()
            await settle()
        }
    }

    /// 0.1 s of time, once per step.
    private func run(_ w: World, ticks: Int) async {
        for _ in 0..<ticks {
            now += 0.1
            up += 0.1
            w.b.step(now, up: up + 7000)
            w.d.step(now, up: up + 9000)
            await settle()
            w.c.advanceGame()
            await settle()
        }
    }

    private func run(_ w: World, seconds: Double) async { await run(w, ticks: Int((seconds * 10).rounded())) }

    // MARK: the deals

    private func dealState(seed: UInt64) -> PlazaGameState {
        var s = PlazaGameState(id: "g", kind: "berry", host: "a", opensAt: 1_800_000_000, startsAt: 1_800_000_030,
                               players: ["p0", "p1", "p2"], seed: seed)
        s.berry = PlazaBerryState(seats: 3)
        return s
    }

    private func firstFive(_ seed: UInt64) -> Int? {
        var s = dealState(seed: seed)
        for i in 0..<8 {
            guard let seat = PlazaBerry.nextSeat(s, playing: [0, 1, 2]), let next = PlazaBerry.flipped(s, seat: seat, at: 0) else { return nil }
            s = next
            if !PlazaBerry.fives(PlazaBerry.table(s)).isEmpty { return i }
        }
        return nil
    }

    /// How many fives show when each is rung at once by one seat.
    private func clearedFives(_ seed: UInt64) -> Int {
        var s = dealState(seed: seed)
        var n = 0
        for _ in 0..<PlazaBerry.deckSize {
            guard let seat = PlazaBerry.nextSeat(s, playing: [0, 1, 2]), let next = PlazaBerry.flipped(s, seat: seat, at: 0) else { break }
            s = next
            guard !PlazaBerry.fives(PlazaBerry.table(s)).isEmpty else { continue }
            n += 1
            let bell = PlazaBerryBell(game: "g", clears: s.berry!.clears.count, flip: s.berry!.flips.count, ms: 300, right: true, serial: n)
            s = PlazaBerry.cleared(s, seat: 1, bell: bell, playing: [0, 1, 2], at: 0) ?? s
            if s.endedAt != nil { break }
        }
        return n
    }

    private func seed(_ ok: (UInt64) -> Bool) -> UInt64 {
        for s in UInt64(1)...100_000 where ok(s) { return s }
        XCTFail("no seed deals what the test needs")
        return 1
    }

    /// A five within the first six flips, the first card alone no five.
    private var earlyFive: UInt64 { seed { s in firstFive(s).map { (1...5).contains($0) } ?? false } }
    private var richDeal: UInt64 { seed { clearedFives($0) >= 5 } }

    // MARK: the table

    private func lock(_ w: World, seed: UInt64? = nil, meJoins: Bool = true, beforeLock: () async -> Void = {}) async {
        let s = seed ?? earlyFive
        w.b.engine.makeSeed = { s }
        XCTAssertTrue(w.b.engine.open(.berry, now: now))
        await sync(w)
        if meJoins { press(w, yKey) }
        await settle()
        w.d.step(now, up: up + 9000)
        w.d.engine.answer(join: true, now: now)
        w.d.tell()
        await sync(w)
        await beforeLock()
        now += PlazaGame.recruitSeconds
        up += PlazaGame.recruitSeconds
        await sync(w)
        XCTAssertNotNil(w.c.gameState?.berry, "test precondition: the game is locked")
    }

    private var suppressedAll: (PlazaWindowController) -> Set<PlazaPanelID> { { Set($0.hud.panels.map(\.id)).subtracting([.berryTable]) } }

    private func table(_ w: World) -> [PlazaBerry.Card?] { w.c.gameState.map { PlazaBerry.table($0) } ?? [] }
    private func hasFive(_ w: World) -> Bool { !PlazaBerry.fives(table(w)).isEmpty }
    private func hasCardsNoFive(_ w: World) -> Bool { table(w).contains { $0 != nil } && !hasFive(w) }

    /// Steps until `done`; false if it never held.
    @discardableResult
    private func until(_ w: World, limit: Int = 400, _ done: () -> Bool) async -> Bool {
        for _ in 0..<limit {
            if done() { return true }
            await run(w, ticks: 1)
        }
        return done()
    }

    /// My last bell on the wire.
    private func lastBell(_ w: World) -> PlazaBerryBell? {
        for sent in w.me.transport.sent.reversed() {
            if case .presence(let p) = sent.message, let b = p.gameBell { return b }
        }
        return nil
    }

    private func sentChats(_ w: World) -> [String] {
        w.me.transport.sent.compactMap { if case .chat(let c) = $0.message { c.text } else { nil } }
    }

    private func mySeat(_ w: World) -> Int? { w.c.gameState?.players.firstIndex(of: w.me.id) }

    // MARK: - Tests

    func testTheTableOpensForPlayersAndHidesEveryOtherPanel() async {
        let w = await world()
        await lock(w)
        XCTAssertTrue(w.c.isBerryTableOpen)
        XCTAssertEqual(w.c.overlayContent, .berryTable)
        XCTAssertEqual(w.c.hud.suppressed, suppressedAll(w.c))
        XCTAssertFalse(w.c.hud.suppressed.contains(.berryTable))
        XCTAssertNotNil(w.c.berryBoard)

        let watching = await world()
        await lock(watching, meJoins: false)
        XCTAssertEqual(watching.c.gameState?.players.contains(watching.me.id), false, "test precondition: I did not join")
        XCTAssertFalse(watching.c.isBerryTableOpen, "a teammate who did not join has no table")
        XCTAssertEqual(watching.c.overlayContent, .none)
        XCTAssertTrue(watching.c.hud.suppressed.isEmpty)
    }

    func testTheTableTakesOverAnOpenChatFieldOverlayOrPhotoMode() async {
        // The chat field, with a line in it.
        var w = await world()
        await lock(w) {
            press(w, returnKey)
            XCTAssertTrue(w.input.isOpen, "test precondition")
            w.input.type("안녕")
        }
        XCTAssertTrue(w.c.isBerryTableOpen)
        XCTAssertFalse(w.input.isOpen, "the chat field is closed")
        XCTAssertEqual(sentChats(w), [], "unsent: no teammate received a line")
        await expectRightBell(w)

        // Another overlay: the game menu (opened by M while the game recruits) is replaced through the same `openOverlay` the news board uses.
        w = await world()
        await lock(w) {
            press(w, mKey)
            if case .gameMenu = w.c.overlayContent {} else { XCTFail("test precondition: M opened the game menu") }
        }
        XCTAssertEqual(w.c.overlayContent, .berryTable, "replaced")
        await expectRightBell(w)

        // Photo mode.
        w = await world()
        await lock(w) {
            w.scene.enterPhotoMode()
            XCTAssertTrue(w.c.isPhotoMode, "test precondition")
        }
        XCTAssertTrue(w.c.isBerryTableOpen)
        XCTAssertFalse(w.c.isPhotoMode, "photo mode is left")
        await expectRightBell(w)
    }

    /// Space on the next five sends a right bell.
    private func expectRightBell(_ w: World, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = await until(w) { hasFive(w) }
        XCTAssertTrue(reached, "a five showed", file: file, line: line)
        press(w, spaceKey)
        XCTAssertEqual(lastBell(w)?.right, true, file: file, line: line)
    }

    func testSpaceRingsAndHoldingItRingsOnce() async throws {
        let w = await world()
        await lock(w)
        await until(w) { hasFive(w) }
        press(w, spaceKey)
        let bell = try XCTUnwrap(lastBell(w))
        XCTAssertTrue(bell.right)
        await run(w, seconds: 1.2)
        let seat = try XCTUnwrap(mySeat(w))
        XCTAssertEqual(w.c.gameState?.berry?.scores[seat], 1, "the teammate dealer cleared for me")
        for _ in 0..<10 { press(w, spaceKey, repeating: true) }
        XCTAssertEqual(lastBell(w)?.serial, bell.serial, "held Space rings nothing more")
        XCTAssertEqual(w.c.berryTableSpaces, 1, "the one press reached the table")
    }

    func testAPressOnTheBellRingsAtThePress() async throws {
        let w = await world()
        let host = RecordingPanelHost()
        panelHost = host
        w.c.hud.host = host
        w.c.hud.setViewport(viewport, scale: 2)
        await lock(w)
        await until(w) { hasFive(w) }
        await settle()
        let panel = try XCTUnwrap(w.c.hud.panels.first { $0.id == .berryTable } as? PlazaBerryTablePanel)
        let bell = panel.layout(viewport: viewport, scale: 2).bell
        let frame = try XCTUnwrap(w.c.hud.layout(viewport: viewport, scale: 2)[.berryTable])
        let centre = CGPoint(x: frame.minX + bell.midX, y: frame.minY + bell.midY)
        XCTAssertNil(lastBell(w), "test precondition")
        XCTAssertTrue(w.c.hud.handleMouse(PlazaMouseEvent(kind: .down, location: centre), in: .berryTable))
        XCTAssertEqual(lastBell(w)?.right, true, "rung at the press, before any .up")
        _ = w.c.hud.handleMouse(PlazaMouseEvent(kind: .up, location: centre), in: .berryTable)
    }

    func testOtherKeysDoNothingAtTheTable() async {
        let w = await world()
        await lock(w)
        await run(w, seconds: 3.2)
        let tile = w.scene.walker.tile
        let state = w.c.gameState, joined = w.c.gameJoined
        for key in [mKey, yKey, nKey, returnKey, escKey, 126, 125, 123, 124] { press(w, key) }
        XCTAssertTrue(w.c.isBerryTableOpen, "the table stays")
        XCTAssertEqual(w.c.overlayContent, .berryTable, "no menu")
        XCTAssertEqual(w.c.gameJoined, joined, "no answer")
        XCTAssertEqual(w.c.gameState?.id, state?.id)
        XCTAssertEqual(w.scene.walker.tile, tile)
        XCTAssertFalse(w.input.isOpen)
        XCTAssertNil(lastBell(w), "none of them rang")
    }

    func testAWrongBellShowsTheCrossForASecond() async {
        let w = await world()
        await lock(w)
        let reached = await until(w) { hasCardsNoFive(w) }
        XCTAssertTrue(reached, "a table with cards and no five showed")
        XCTAssertEqual(w.c.berryBoard?.wrong, false)
        press(w, spaceKey)
        XCTAssertEqual(lastBell(w)?.right, false, "test precondition: a wrong bell")
        XCTAssertEqual(w.c.berryBoard?.wrong, true, "the cross shows right after the bell")
        await run(w, seconds: 1.1)
        XCTAssertEqual(w.c.berryBoard?.wrong, false, "and is gone a second later")
    }

    /// Plays to the end: I ring every five and win.
    private func playToResult(_ w: World) async {
        var rung = -1
        for _ in 0..<2500 {
            await run(w, ticks: 1)
            guard let s = w.c.gameState, let b = s.berry else { continue }
            if s.endedAt != nil { return }
            if hasFive(w), rung != b.clears.count {
                rung = b.clears.count
                press(w, spaceKey)
            }
        }
        XCTFail("the game did not end")
    }

    func testTheResultShowsFiveSecondsThenTheHUDComesBack() async throws {
        let w = await world()
        await lock(w, seed: richDeal)
        await playToResult(w)
        XCTAssertTrue(w.c.isBerryTableOpen)
        guard case .result(let lines)? = w.c.berryBoard?.center else { return XCTFail("the centre shows the result") }
        XCTAssertEqual(lines.first, L(.ko).plazaBerryWinner(nickname: nil))
        XCTAssertEqual(lines.last, L(.ko).plazaBerryCloseHint)
        await run(w, seconds: 4.5)
        XCTAssertTrue(w.c.isBerryTableOpen, "still showing before the five seconds are up")
        await run(w, seconds: 0.8)
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertEqual(w.c.overlayContent, .none)
        XCTAssertTrue(w.c.hud.suppressed.isEmpty)
        XCTAssertNil(w.c.berryBoard)
        await run(w, seconds: 3)
        XCTAssertNotNil(w.c.gameState?.endedAt, "test precondition: the ended game is kept")
        XCTAssertFalse(w.c.isBerryTableOpen, "it does not reopen")
        press(w, mKey)
        XCTAssertNotEqual(w.c.overlayContent, .none, "M opens the menu once the rematch delay has passed")
        XCTAssertNotEqual(w.c.overlayContent, .berryTable)
    }

    func testSpaceOrEscClosesTheResultAtOnce() async {
        for key in [spaceKey, escKey] {
            let w = await world()
            await lock(w, seed: richDeal)
            await playToResult(w)
            XCTAssertTrue(w.c.isBerryTableOpen, "test precondition")
            press(w, key)
            XCTAssertFalse(w.c.isBerryTableOpen, "key \(key)")
            XCTAssertTrue(w.c.hud.suppressed.isEmpty)
            await run(w, seconds: 1)
            XCTAssertFalse(w.c.isBerryTableOpen, "key \(key): it stays closed")
        }
    }

    func testClosingThePlazaLeavesTheGameAndReopeningWatches() async {
        let w = await world()
        await lock(w)
        await run(w, seconds: 3.2)
        XCTAssertTrue(w.c.isBerryTableOpen, "test precondition")
        w.c.handleClose()
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertTrue(w.c.hud.suppressed.isEmpty)
        w.c.prepareScene()
        await sync(w)
        await run(w, seconds: 2)
        XCTAssertFalse(w.c.isBerryTableOpen, "no table after reopening")
        XCTAssertNil(w.c.berryBoard)
        XCTAssertFalse(w.b.engine.berryPlaying.contains(w.me.id), "the teammates' boards draw my seat faded")
        XCTAssertTrue(w.b.engine.berryPlaying.contains(w.d.id))
    }

    func testTheBoardSeatsMeAtTheBottomThenClockwise() async {
        let w = await world()
        await lock(w)
        XCTAssertEqual(w.c.gameState?.players, ["a-host", "m-me", "z-last"], "test precondition: I sit between")
        XCTAssertEqual(w.c.berryBoard?.seats.map(\.id), ["m-me", "z-last", "a-host"])
        XCTAssertEqual(w.c.berryBoard?.seats.map(\.name), ["나", "다", "가"])
    }

    func testAFiveWithoutABellShowsNoHint() async {
        let w = await world()
        await lock(w)
        await until(w) { hasFive(w) }
        let flips = w.c.gameState?.berry?.flips.count
        let before = w.c.berryBoard?.center
        XCTAssertNil(w.c.berryBoard?.ring)
        await run(w, seconds: 1.4)
        XCTAssertEqual(w.c.gameState?.berry?.flips.count, flips, "no flip before 1.5 s")
        XCTAssertNil(w.c.berryBoard?.ring, "no card glows before someone rings")
        XCTAssertEqual(w.c.berryBoard?.center, before, "the event line is unchanged")
        await run(w, ticks: 1)
        XCTAssertEqual(w.c.gameState?.berry?.flips.count, (flips ?? 0) + 1, "the next flip comes 1.5 s after the last")
    }

    func testAJumpOfSeveralFlipsShowsTheLatestTable() async throws {
        let w = await world()
        await lock(w)
        let panel = try XCTUnwrap(w.c.hud.panels.first { $0.id == .berryTable } as? PlazaBerryTablePanel)
        let before = try XCTUnwrap(w.c.berryBoard?.flip)   // the countdown's board: no flip yet, nothing animating
        XCTAssertFalse(panel.isAnimating, "test precondition")
        w.c.setRendering(visible: false)
        await until(w) { (w.c.gameState?.berry?.flips.count ?? 0) >= before + 3 }
        XCTAssertEqual(w.c.berryBoard?.flip, before, "a hidden window keeps the board it had")
        let flips = try XCTUnwrap(w.c.gameState?.berry?.flips.count)
        w.c.setRendering(visible: true)
        let board = try XCTUnwrap(w.c.berryBoard)
        XCTAssertEqual(board.flip, flips)
        XCTAssertGreaterThanOrEqual(board.flip, before + 3)
        XCTAssertFalse(panel.isAnimating, "a jump of several flips is one sudden change")
        let state = try XCTUnwrap(w.c.gameState)
        let mine = try XCTUnwrap(mySeat(w))
        let expected = PlazaBerry.table(state)
        let order = (0..<expected.count).map { (mine + $0) % expected.count }
        XCTAssertEqual(board.seats.map(\.top), order.map { expected[$0] })
        press(w, spaceKey)
        XCTAssertEqual(lastBell(w)?.right, !PlazaBerry.fives(expected).isEmpty, "judged on that table")
    }

    func testAHiddenWindowStampsItsFiveWhenItIsShownAgain() async throws {
        let w = await world()
        await lock(w)
        w.c.setRendering(visible: false)
        await until(w) { hasFive(w) }
        await run(w, seconds: 0.9)   // the next flip is 1.5 s after the five's
        press(w, spaceKey)
        XCTAssertNil(lastBell(w), "a hidden window rings nothing")
        w.c.setRendering(visible: true)
        press(w, spaceKey)
        let bell = try XCTUnwrap(lastBell(w), "shown again, the five can be rung")
        XCTAssertTrue(bell.right)
        XCTAssertLessThan(bell.ms, 100, "the time counts from when the five showed on screen, not from when it was dealt")
    }

    func testTheBerryPicturesLoadWhenTheGameOpens() async {
        let w = await world()
        asked = []
        w.b.engine.makeSeed = { 1 }
        XCTAssertTrue(w.b.engine.open(.berry, now: now))
        await sync(w)
        let names = PlazaBerry.Berry.allCases.map(\.itemName) + [PlazaBerry.bellItem]
        for name in names { XCTAssertEqual(asked.filter { $0 == name }.count, 1, name) }
        XCTAssertTrue(names.contains("soothe-bell"))
        await sync(w)
        for name in names { XCTAssertEqual(asked.filter { $0 == name }.count, 1, "once: \(name)") }
    }

    func testAClosedPlazasRunningCopyIsNotAdoptedByAMachineWithNoGameOfItsOwn() async throws {
        // A game runs among the host and one more teammate (I am not in it); take the host's running copy.
        let first = await world()
        await lock(first, meJoins: false)
        await run(first, seconds: 3.2)
        let stale = try XCTUnwrap(first.b.engine.state)
        XCTAssertNotNil(stale.berry, "test precondition: a running berry copy")
        XCTAssertNil(stale.endedAt)

        // My plaza opens with no game of its own and hears only a teammate whose plaza is closed, still sending that copy.
        let w = await world()
        w.b.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false, isFlushed: false)
        w.b.session.updateGame(stale, join: stale.id, bell: nil)
        await settle()
        XCTAssertEqual(w.c.gameState, nil, "test precondition: nothing yet")
        XCTAssertNotNil(w.me.session.members[w.b.id]?.game, "test precondition: I hear the copy")
        await run(w, seconds: 2)
        XCTAssertNil(w.c.gameState, "a closed plaza cannot follow a berry five game: I do not adopt its copy")
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertNil(w.c.gameStatus, "no spectator status either")
    }

    func testARingThatChangesOnlyTheBellStillReachesTheTeammateAtOnce() async throws {
        let w = await world()
        await lock(w)
        await until(w) { hasFive(w) }
        // Silence the dealer so nothing but my bell changes: the state and the join stay as they were.
        let state = w.c.gameState, joined = w.c.gameJoined
        let sentBefore = w.me.transport.sent.count
        press(w, spaceKey)
        XCTAssertEqual(w.c.gameState, state, "same state")
        XCTAssertEqual(w.c.gameJoined, joined, "same join")
        XCTAssertGreaterThan(w.me.transport.sent.count, sentBefore, "the bell went out in the same step")
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.gameBell?.right, true, "the teammate has it at once")
    }

    // MARK: - Watchers and the result

    /// A teammate (not me) rings at the next five on their own screen.
    private func ring(_ w: World, _ o: Node) {
        _ = o.engine.ringBerry(now: now, uptime: up + 9000)
        o.tell()
    }

    func testWatchersSeeTheScoresAndTheBellOverTheRinger() async {
        let w = await world()
        await lock(w, meJoins: false)
        XCTAssertFalse(w.c.isBerryTableOpen, "no table for a watcher")
        let l = L(.ko)
        XCTAssertTrue(w.c.gameStatus?.hasPrefix("열매 다섯 진행 중") == true, "\(String(describing: w.c.gameStatus))")
        XCTAssertEqual(w.c.gameStatus, l.plazaBerryStatus(scores: [("가", 0), ("다", 0)]))
        XCTAssertNil(w.scene.shownChat(memberID: w.d.id))
        let seen = await until(w) { hasFive(w) }
        XCTAssertTrue(seen)
        ring(w, w.d)
        let rang = await until(w) { w.scene.shownChat(memberID: w.d.id) == "🔔" }
        XCTAssertTrue(rang, "the bell over the ringer")
        XCTAssertEqual(w.c.gameStatus, l.plazaBerryStatus(scores: [("다", 1), ("가", 0)]))
        XCTAssertNil(w.scene.shownChat(memberID: w.b.id))
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertNil(w.c.gameTitle)
        XCTAssertNil(w.c.gameCard)
    }

    func testTheResultIsABannerForWatchersAndForPlayersAfterTheTable() async throws {
        let l = L(.ko)
        // A watcher: the teammate d rings every five and wins.
        let w = await world()
        await lock(w, seed: richDeal, meJoins: false)
        var rung = -1
        for _ in 0..<2500 {
            await run(w, ticks: 1)
            guard let s = w.c.gameState, let b = s.berry else { continue }
            if s.endedAt != nil { break }
            if hasFive(w), rung != b.clears.count { rung = b.clears.count; ring(w, w.d) }
        }
        XCTAssertEqual(w.c.gameState?.winner, w.d.id, "test precondition")
        XCTAssertEqual(w.c.banner, l.plazaGameWinBanner(nickname: "다", game: l.plazaGameName(.berry)))
        XCTAssertNil(w.c.gameTitle)

        // A player in a tie: one right bell each, the rest of the deck runs out.
        let t = await world()
        await lock(t)
        var meRang = false, dRang = false
        for _ in 0..<3000 {
            await run(t, ticks: 1)
            guard let s = t.c.gameState, let b = s.berry else { continue }
            if s.endedAt != nil { break }
            if hasFive(t), b.clears.count == 0, !meRang { meRang = true; press(t, spaceKey) }
            if hasFive(t), b.clears.count == 1, !dRang { dRang = true; ring(t, t.d) }
        }
        XCTAssertEqual(t.c.gameState?.berry?.scores.sorted(by: >).prefix(2).map { $0 }, [1, 1], "test precondition: level at the top")
        XCTAssertNil(t.c.gameState?.winner)
        XCTAssertTrue(t.c.isBerryTableOpen, "the table shows the result")
        XCTAssertNil(t.c.banner, "not before the table closes")
        XCTAssertNil(t.c.gameTitle, "no big title for berry")
        press(t, spaceKey)
        XCTAssertFalse(t.c.isBerryTableOpen)
        XCTAssertEqual(t.c.banner, l.plazaBerryTieBanner(names: ["나", "다"]))
        XCTAssertNil(t.c.gameTitle)
    }

    func testThePlayerGetsTheBannerWhenTheResultTimesOut() async {
        let w = await world()
        await lock(w, seed: richDeal)
        await playToResult(w)
        XCTAssertNil(w.c.banner)
        await run(w, seconds: PlazaBerry.resultSeconds + 0.3)
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameWinBanner(nickname: "나", game: L(.ko).plazaGameName(.berry)))
    }

    func testTheInvitationClosesAtEightPlayers() async {
        let me = node("나", id: "m-me")
        let others = (0..<8).map { node("가\($0)", id: "o\($0)") }
        let input = PlazaTypingChatInput()
        let c = controller(me, input: input)
        c.prepareScene()
        for o in others { hub.connect(me.transport, to: o.transport) }
        await settle()
        for (i, o) in others.enumerated() {
            o.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 11 + i, y: 6), facing: .left, isWalking: false, isFlushed: false)
        }
        await settle()
        let host = others[0]
        XCTAssertTrue(host.engine.open(.berry, now: now))
        host.tell()
        await settle()
        c.advanceGame()
        await settle()
        let state = host.engine.state!
        func join(_ n: Int) async {
            for o in others.dropFirst().prefix(n) { o.session.updateGame(state, join: state.id) }
            await settle()
            c.advanceGame()
            await settle()
        }
        let l = L(.ko), seconds = Int(PlazaGame.recruitSeconds)
        await join(6)   // the host and six: seven
        var button = c.gameCard?.buttons.first { $0.action == "join" }
        XCTAssertEqual(button?.isEnabled, true)
        XCTAssertEqual(c.gameCard?.lines.last, l.plazaGameRecruiting(players: 7, seconds: seconds))
        await join(7)   // eight
        button = c.gameCard?.buttons.first { $0.action == "join" }
        XCTAssertEqual(button?.isEnabled, false)
        XCTAssertEqual(c.gameCard?.lines.last, l.plazaDrawFull)
        XCTAssertTrue(c.gameCard?.lines.contains(l.plazaGameRecruiting(players: 8, seconds: seconds)) == true)
        c.scene?.handleKeyDown(keyCode: yKey, characters: "ㅛ", isRepeat: false)
        XCTAssertNil(c.gameJoined, "the Y key honours the disabled button")
    }

    func testALoudLineDuringTheTableShowsNoBanner() async {
        let w = await world()
        await lock(w)
        XCTAssertTrue(w.c.isBerryTableOpen, "test precondition")
        let before = w.c.banner
        w.c.showChat(memberID: w.b.id, text: "모두 회의실로", isLoud: true)
        w.c.showBanner(L(.ko).teamMegaphoneNotice(nickname: "가", text: "모두 회의실로"))   // what the notifier asks of the plaza
        XCTAssertEqual(w.c.banner, before)
        XCTAssertEqual(w.c.chatLogLines.last?.text, "모두 회의실로")
        XCTAssertEqual(w.c.chatLogLines.last?.isLoud, true)
    }

    func testPlayersAreRingedDuringTheGame() async {
        let w = await world()
        await lock(w)
        XCTAssertEqual(w.scene.gameMarks, ["": .alive, w.b.id: .alive, w.d.id: .alive])
        XCTAssertFalse(w.scene.gameMarks.values.contains(.holder))
        XCTAssertNil(w.c.gameView.holder)
    }

    func testBeingIsolatedMidGameShowsTheLostConnectionBannerAndClosesTheTable() async {
        let w = await world()
        await lock(w)
        XCTAssertTrue(w.c.isBerryTableOpen, "test precondition")
        for link in w.links { hub.disconnect(link) }
        await settle()
        XCTAssertTrue(w.me.session.members.isEmpty, "test precondition: I hear nobody")
        now += 1
        w.c.advanceGame()
        XCTAssertTrue(w.c.isBerryTableOpen, "not yet")
        now += PlazaGame.isolationLimit
        w.c.advanceGame()
        XCTAssertEqual(w.c.banner, L(.ko).plazaGameLostConnectionBanner)
        XCTAssertFalse(w.c.isBerryTableOpen)
        XCTAssertNil(w.c.gameJoined)
    }
}
