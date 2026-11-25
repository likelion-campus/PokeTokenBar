import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// A chat field a test can type into: the line is set with `type`, Enter is `submit` (the line goes to `onSubmit`; taken, the field closes), and
/// `close` ends it for any other reason, as the real field's Esc does.
@MainActor final class PlazaTypingChatInput: PlazaChatInputHost {
    private(set) var isOpen = false
    var isLoud: Bool { false }
    var purpose: PlazaChatInputPurpose = .chat
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?
    private(set) var text = ""

    func open() {
        guard !isOpen else { return }
        isOpen = true
        text = ""
    }

    func close() {
        purpose = .chat
        guard isOpen else { return }
        isOpen = false
        text = ""
        onClose?()
    }

    func type(_ line: String) { text = line }

    /// Enter. Returns what `onSubmit` said (false keeps the field open with the line in it).
    @discardableResult func submit() -> Bool {
        guard isOpen else { return false }
        let taken = onSubmit?(text) != false
        if taken { close() }
        return taken
    }
}

/// The drawing quiz in the plaza: my plaza is a real controller, and the teammates are bare sessions each driving its own engine, as their own
/// plazas would.
@MainActor
final class PlazaDrawControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mKey: UInt16 = 46, yKey: UInt16 = 16, returnKey: UInt16 = 36
    private let word = "사과"
    private var viewport = CGSize(width: 960, height: 640)
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Date(timeIntervalSince1970: 1_800_000_000)
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

        func tell() { session.updateGame(engine.state, join: engine.joined) }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.draw.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaDrawControllerTests-\(UUID())")
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
        let c: PlazaWindowController, me: Node, others: [Node], input: PlazaTypingChatInput
        /// My side's name for the link to each teammate.
        let peers: [String: TeamPeerID]
        var b: Node { others[0] }
        var d: Node { others[1] }
        var scene: PlazaScene { c.scene! }
        var all: [String] { [me.id] + others.map(\.id) }
    }

    private func controller(_ me: Node, input: PlazaTypingChatInput) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.draw.prefs.\(UUID())"))
        prefs.saveLastTile(TilePoint(x: 10, y: 6))
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now },
                                     renderCheckSleep: Self.park, focusTickSleep: Self.park,
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: input)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func press(_ c: PlazaWindowController, _ key: UInt16) {
        c.scene?.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    /// Me in my plaza with `count` teammates, all standing in it. `mesh`: the teammates also hear each other (a game needs it to lock).
    private func world(others count: Int = 2, mesh: Bool = true) async -> World {
        let me = node("나")
        let others = (0..<count).map { node(["가", "다", "라", "마", "바", "아", "자", "차"][$0]) }
        let input = PlazaTypingChatInput()
        let c = controller(me, input: input)
        c.prepareScene()
        var peers: [String: TeamPeerID] = [:]
        for o in others { peers[o.id] = hub.connect(me.transport, to: o.transport).peerID(on: me.transport) }
        if mesh { for i in others.indices { for j in others.indices where j > i { hub.connect(others[i].transport, to: others[j].transport) } } }
        await settle()
        for (i, o) in others.enumerated() {
            o.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 11 + i, y: 6), facing: .left, isWalking: false, isFlushed: false)
        }
        await settle()
        return World(c: c, me: me, others: others, input: input, peers: peers)
    }

    /// Everyone hears everyone until nothing more happens.
    private func sync(_ w: World) async {
        for _ in 0..<6 {
            for o in w.others { o.step(now) }
            await settle()
            w.c.advanceGame()
            await settle()
        }
    }

    /// `host` (the first teammate) opens the quiz with a seed that makes `first` draw first, everyone else says yes, and recruiting runs out.
    /// `meJoins: false` leaves me watching.
    private func lock(_ w: World, first: String, meJoins: Bool = true, joining: [Node]? = nil) async {
        let joiners = joining ?? Array(w.others.dropFirst())
        let players = (meJoins ? [w.me.id] : []) + [w.b.id] + joiners.map(\.id)
        let seed = (UInt64(1)...5000).first { PlazaDraw.order(players: players, seed: $0).first == first }!
        w.b.engine.makeSeed = { seed }
        XCTAssertTrue(w.b.engine.open(.draw, now: now))
        await sync(w)
        if meJoins { press(w.c, yKey) }
        await settle()
        for o in joiners {
            o.step(now)
            o.engine.answer(join: true, now: now)
            o.tell()
        }
        await sync(w)
        now += PlazaGame.recruitSeconds
        await sync(w)
        XCTAssertEqual(Set(w.c.gameState?.players ?? []), Set(players), "test precondition")
        XCTAssertEqual(w.c.gameState?.draw?.order.first, first, "test precondition")
    }

    /// The countdown (first turn) runs out and the drawer's word field is asked for.
    private func beginEntry(_ w: World) async {
        now += PlazaGame.countdownSeconds + 1
        await sync(w)
    }

    /// The teammate whose turn it is names the word and tells everyone.
    private func teammateSetsWord(_ w: World, _ n: Node) async {
        XCTAssertNotNil(n.engine.state?.draw?.entryAt, "test precondition: the word field is open")
        XCTAssertTrue(n.engine.setWord(word, now: now))
        n.tell()
        await sync(w)
    }

    /// I am the first drawer, the word is set and the drawing runs.
    private func myDrawing(_ w: World) async {
        await lock(w, first: w.me.id)
        await beginEntry(w)
        XCTAssertTrue(w.input.isOpen, "test precondition")
        w.input.type(word)
        XCTAssertTrue(w.input.submit())
        await sync(w)
        XCTAssertEqual(w.c.drawBoard?.canDraw, true, "test precondition")
    }

    private func stroke(_ w: World, seq: Int, _ points: [Int], turn: Int = 0, color: Int = 2) -> TeamDraw {
        TeamDraw(game: w.c.gameState!.id, turn: turn, seq: seq, op: .stroke, color: color, width: 1, points: points)
    }

    private func encoded(_ m: TeamMessage) -> String { String(decoding: (try? TeamWire.encode(m)) ?? Data(), as: UTF8.self) }

    /// What I sent to one teammate, in order.
    private func sentDraws(_ w: World, to n: Node) -> [TeamDraw] {
        w.me.transport.sent.filter { $0.peer == w.peers[n.id] }.compactMap { if case .draw(let d) = $0.message { d } else { nil } }
    }

    /// The chat lines I sent (to one teammate: each goes to all).
    private func sentChats(_ w: World) -> [String] {
        w.me.transport.sent.filter { $0.peer == w.peers[w.b.id] }.compactMap { if case .chat(let c) = $0.message { c.text } else { nil } }
    }

    // MARK: the board for mouse input

    private var panelHost: RecordingPanelHost?

    /// The board rendered in the controller's own HUD, so that the mouse goes through `hud.handleMouse` as it does in the window.
    private func attachHUD(_ w: World, size: CGSize? = nil) async {
        if let size { viewport = size }
        let host = RecordingPanelHost()
        panelHost = host
        w.c.hud.host = host
        w.c.hud.setViewport(viewport, scale: 2)
        await settle()
    }

    private func point(_ w: World, x: Int, y: Int) -> CGPoint {
        let panel = w.c.hud.panels.first { $0.id == .drawBoard } as! PlazaDrawPanel
        let placed = panel.layout(in: viewport, scale: 2, text: w.c.hud.graphics.text)
        let frame = w.c.hud.layout(viewport: viewport, scale: 2)[.drawBoard]!
        let n = CGFloat(placed.cell) / 2
        return CGPoint(x: frame.minX + placed.canvas.minX + (CGFloat(x) + 0.5) * n, y: frame.minY + placed.canvas.minY + (CGFloat(y) + 0.5) * n)
    }

    @discardableResult
    private func mouse(_ w: World, _ kind: PlazaMouseEvent.Kind, x: Int, y: Int) -> Bool {
        w.c.hud.handleMouse(PlazaMouseEvent(kind: kind, location: point(w, x: x, y: y)), in: .drawBoard)
    }

    // MARK: - My turn

    func testMyTurnOpensTheWordFieldAndTheWordStartsTheDrawing() async {
        let w = await world()
        await lock(w, first: w.me.id)
        await beginEntry(w)
        XCTAssertTrue(w.input.isOpen)
        XCTAssertEqual(w.input.purpose, .quizWord)
        XCTAssertEqual(w.c.drawBoard?.canDraw, false, "no drawing before the word")
        w.input.type(word)
        XCTAssertTrue(w.input.submit())
        XCTAssertFalse(w.input.isOpen)
        await sync(w)
        XCTAssertEqual(w.c.drawBoard?.canDraw, true)
        XCTAssertEqual(w.c.drawBoard?.foot, .tools(word: word))
        for o in w.others {
            let theirs = o.session.members[w.me.id]?.game
            XCTAssertNotNil(theirs?.draw?.drawAt, "they know the drawing began")
            XCTAssertFalse(String(decoding: (try? JSONEncoder().encode(theirs)) ?? Data(), as: UTF8.self).contains(word), "the word is not in the state")
        }
        XCTAssertFalse(w.me.transport.sent.contains { encoded($0.message).contains(word) }, "the word was in no message I sent")
    }

    func testAWordThatBreaksTheRulesKeepsTheFieldOpen() async {
        let w = await world()
        await lock(w, first: w.me.id)
        await beginEntry(w)
        w.input.type("사과!")
        XCTAssertFalse(w.input.submit())
        XCTAssertTrue(w.input.isOpen)
        XCTAssertEqual(w.input.purpose, .quizWord)
        XCTAssertEqual(w.c.hint, L(.ko).plazaDrawWordInvalid)
        XCTAssertEqual(w.c.drawBoard?.canDraw, false)
        w.input.type("")   // an empty Enter is a refused word too: the field stays and the same line shows
        XCTAssertFalse(w.input.submit())
        XCTAssertTrue(w.input.isOpen)
        XCTAssertEqual(w.c.hint, L(.ko).plazaDrawWordInvalid)
        w.input.type(word)
        XCTAssertTrue(w.input.submit())
        await sync(w)
        XCTAssertEqual(w.c.drawBoard?.canDraw, true)
    }

    func testMyTurnWaitsForAnOpenChatLine() async {
        let w = await world()
        await lock(w, first: w.me.id)
        press(w.c, returnKey)
        XCTAssertTrue(w.input.isOpen)
        w.input.type("안녕")
        await beginEntry(w)
        XCTAssertNotNil(w.c.gameState?.draw?.entryAt, "test precondition: my entry began")
        XCTAssertTrue(w.input.isOpen)
        XCTAssertEqual(w.input.purpose, .chat, "the chat line is not turned into the word")
        XCTAssertEqual(w.input.text, "안녕", "and not thrown away")
        XCTAssertTrue(w.input.submit())
        XCTAssertEqual(sentChats(w), ["안녕"])
        await sync(w)
        XCTAssertTrue(w.input.isOpen, "the word field opens once the line is out")
        XCTAssertEqual(w.input.purpose, .quizWord)
        XCTAssertEqual(w.input.text, "")
    }

    func testTheWordFieldClosesAtTheDeadlineWithoutSending() async {
        let w = await world()
        await lock(w, first: w.me.id)
        await beginEntry(w)
        XCTAssertEqual(w.input.purpose, .quizWord)
        w.input.type("사")   // a syllable half typed
        now += PlazaDraw.wordSeconds + 1
        await sync(w)
        XCTAssertFalse(w.input.isOpen)
        XCTAssertEqual(w.input.purpose, .chat)
        XCTAssertEqual(sentChats(w), [], "nothing was said")
        XCTAssertFalse(w.me.transport.sent.contains { encoded($0.message).contains("사") }, "nothing half typed went out in any message")
        let draw = w.c.gameState?.draw
        XCTAssertEqual(draw?.last?.drawer, w.me.id)
        XCTAssertNil(draw?.last?.word)
        XCTAssertEqual(draw?.turn, 1, "the turn moved on")
    }

    func testATeammatesRightAnswerEndsMyTurnAndScores() async {
        let w = await world()
        await myDrawing(w)
        w.c.showChat(memberID: w.b.id, text: word + "!")
        await settle()
        let scores = w.c.gameState?.draw?.scores
        XCTAssertEqual(scores?[w.b.id], PlazaDraw.guessPoints)
        XCTAssertEqual(scores?[w.me.id], PlazaDraw.drawerPoints)
        XCTAssertEqual(w.c.gameTitle, PlazaGameView.Title(text: L(.ko).plazaDrawRightBy(nickname: "가"), tone: .win), "everyone but the solver reads who solved it")
        XCTAssertEqual(w.c.gameState?.draw?.last?.solver, w.b.id)
    }

    func testAWrongAnswerDoesNotEndMyTurn() async {
        let w = await world()
        await myDrawing(w)
        w.c.showChat(memberID: w.b.id, text: "사과인가")
        await settle()
        XCTAssertEqual(w.c.gameState?.draw?.turn, 0)
        XCTAssertNil(w.c.gameTitle)
    }

    func testICannotSayMyOwnWord() async {
        let w = await world()
        await myDrawing(w)
        press(w.c, returnKey)
        XCTAssertEqual(w.input.purpose, .chat)
        w.input.type("이건 사 과야")
        XCTAssertFalse(w.input.submit())
        XCTAssertTrue(w.input.isOpen, "the line stays")
        XCTAssertEqual(w.c.banner, L(.ko).plazaDrawOwnWordBlocked)
        XCTAssertEqual(sentChats(w), [])
        w.input.type("과일이야")
        XCTAssertTrue(w.input.submit())
        XCTAssertEqual(sentChats(w), ["과일이야"])
    }

    // MARK: - Strokes out

    func testMyStrokesGoOutInBatchesAndASnapshotFollowsANewcomer() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        let path = (0..<96).map { ($0, 0) } + (1...4).map { (95, $0) }
        XCTAssertEqual(path.count, 100)
        XCTAssertTrue(mouse(w, .down, x: path[0].0, y: path[0].1))
        for p in path.dropFirst() { mouse(w, .moved, x: p.0, y: p.1) }
        mouse(w, .up, x: path.last!.0, y: path.last!.1)
        let strokes = sentDraws(w, to: w.b).filter { $0.op == .stroke }
        XCTAssertEqual(strokes.map { ($0.points?.count ?? 0) / 2 }, [64, 37], "at most 64 points a message, the rest when the stroke ends")
        XCTAssertEqual(strokes.map(\.seq), [1, 2])
        XCTAssertEqual(strokes.map(\.turn), [0, 0])
        for pair in zip(strokes, strokes.dropFirst()) {
            XCTAssertEqual(Array(pair.1.points?.prefix(2) ?? []), Array(pair.0.points?.suffix(2) ?? []), "a message starts where the one before ended")
        }
        var rebuilt: [Int] = []
        for s in strokes { rebuilt += rebuilt.isEmpty ? (s.points ?? []) : Array((s.points ?? []).dropFirst(2)) }
        XCTAssertEqual(rebuilt, path.flatMap { [$0.0, $0.1] }, "together they are the whole stroke")
        XCTAssertEqual(sentDraws(w, to: w.b).filter { $0.op == .snapshot }.count, 0)

        // A member who was not in the plaza appears in it: one snapshot of my canvas, to everyone.
        w.d.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false, isFlushed: false)
        await sync(w)
        XCTAssertEqual(sentDraws(w, to: w.b).filter { $0.op == .snapshot }.count, 0, "someone leaving is no reason")
        w.d.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 12, y: 6), facing: .left, isWalking: false, isFlushed: false)
        await sync(w)
        let snapshots = sentDraws(w, to: w.b).filter { $0.op == .snapshot }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.seq, 2, "the last message it includes")
        let cells = snapshots.first?.cells.flatMap { Data(base64Encoded: $0) }.flatMap { PlazaDrawCanvas(packed: $0) }
        XCTAssertEqual(cells, w.c.drawCanvas)
        XCTAssertNotEqual(cells, PlazaDrawCanvas())
        XCTAssertEqual(sentDraws(w, to: w.d).filter { $0.op == .snapshot }.count, 1)
    }

    func testClearingTheCanvasIsSentAndTheNextStrokeFollowsIt() async throws {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        mouse(w, .down, x: 3, y: 3)
        mouse(w, .up, x: 3, y: 3)
        w.c.drawModel.canvas.clear()
        let panel = try XCTUnwrap(w.c.hud.panels.first { $0.id == .drawBoard } as? PlazaDrawPanel)
        panel.onClear?()
        mouse(w, .down, x: 5, y: 5)
        mouse(w, .up, x: 5, y: 5)
        XCTAssertEqual(sentDraws(w, to: w.b).map(\.op), [.stroke, .clear, .stroke])
        XCTAssertEqual(sentDraws(w, to: w.b).map(\.seq), [1, 2, 3])
    }

    func testAnOverlayOpenedMidStrokeEndsTheStroke() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        mouse(w, .down, x: 0, y: 0)
        mouse(w, .moved, x: 1, y: 0)
        mouse(w, .moved, x: 2, y: 0)
        press(w.c, mKey)
        guard case .gameMenu = w.c.overlayContent else { return XCTFail("the menu is open") }
        mouse(w, .moved, x: 8, y: 0)
        mouse(w, .moved, x: 9, y: 0)
        mouse(w, .up, x: 9, y: 0)
        XCTAssertEqual(w.c.drawCanvas[2, 0], 1)
        XCTAssertEqual(w.c.drawCanvas[6, 0], 0, "the stroke stopped at the last point before the overlay")
        XCTAssertEqual(w.c.drawCanvas[9, 0], 0)
        XCTAssertEqual(sentDraws(w, to: w.b).filter { $0.op == .stroke }.last?.points?.suffix(2).map { $0 }, [2, 0], "and what was held went out")
        w.c.chooseGame(index: 0)   // the menu says the game is busy and closes
        XCTAssertEqual(w.c.overlayContent, .none)
        mouse(w, .down, x: 10, y: 3)
        mouse(w, .moved, x: 11, y: 3)
        mouse(w, .up, x: 11, y: 3)
        XCTAssertEqual(w.c.drawCanvas[10, 3], 1, "the next press draws")
        XCTAssertEqual(w.c.drawCanvas[11, 3], 1)
    }

    func testPhotoModeStartedMidStrokeEndsTheStroke() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        mouse(w, .down, x: 0, y: 0)
        mouse(w, .moved, x: 1, y: 0)
        w.scene.enterPhotoMode()
        mouse(w, .moved, x: 8, y: 0)
        mouse(w, .up, x: 8, y: 0)
        XCTAssertEqual(w.c.drawCanvas[1, 0], 1)
        XCTAssertEqual(w.c.drawCanvas[6, 0], 0, "nothing is drawn after photo mode began")
        w.scene.exitPhotoMode()
        mouse(w, .moved, x: 20, y: 0)
        XCTAssertEqual(w.c.drawCanvas[20, 0], 0, "no capture was left behind")
        mouse(w, .down, x: 10, y: 3)
        mouse(w, .up, x: 10, y: 3)
        XCTAssertEqual(w.c.drawCanvas[10, 3], 1, "the next press draws")
    }

    func testTheCanvasClearsWhenTheTurnChanges() async {
        let w = await world()
        await myDrawing(w)
        w.c.drawModel.canvas.stroke(points: [5, 5, 40, 5], color: 4, width: 3)
        w.c.drawModel.color = 4
        w.c.drawModel.width = 1
        w.c.showChat(memberID: w.b.id, text: word)
        await sync(w)
        XCTAssertEqual(w.c.gameState?.draw?.turn, 1)
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas())
        XCTAssertEqual(w.c.drawModel.color, 1)
        XCTAssertEqual(w.c.drawModel.width, 3)
    }

    // MARK: - Strokes in

    func testATeammatesStrokesDrawOnMyCanvasOnlyFromTheDrawer() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        let id = w.c.gameState!.id
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 10, 20, 10]))
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "the drawer's presence does not say drawing yet")
        await teammateSetsWord(w, w.b)
        w.c.showDraw(from: w.d.id, stroke(w, seq: 1, [10, 12, 20, 12]))
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "not the drawer")
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 14, 20, 14], turn: 1))
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "not this turn")
        var other = stroke(w, seq: 1, [10, 16, 20, 16])
        other.game = id + "x"
        w.c.showDraw(from: w.b.id, other)
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "not this game")
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 18, 90, 18]))
        XCTAssertEqual(w.c.drawCanvas[15, 18], 2, "the drawer's stroke")
        XCTAssertEqual(w.c.drawCanvas[85, 18], 2)
        w.c.showDraw(from: w.b.id, stroke(w, seq: 2, [200, 5, 205, 5]))
        w.c.showDraw(from: w.b.id, TeamDraw(game: id, turn: 0, seq: 3, op: .stroke, color: 99, width: 1, points: [3, 3, 4, 4]))
        XCTAssertEqual(w.c.drawCanvas[3, 3], 0, "a colour that does not exist")
        w.c.showDraw(from: w.b.id, TeamDraw(game: id, turn: 0, seq: 3, op: .clear))
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "clear")
    }

    func testTheFirstStrokesAfterTheWordAreNotLost() async {
        let w = await world()
        w.me.session.onDraw = { [weak c = w.c] id, d in c?.showDraw(from: id, d) }
        await lock(w, first: w.b.id)
        await beginEntry(w)
        let first = stroke(w, seq: 1, [10, 10, 30, 10])
        // The drawer's presence and its first stroke arrive one right after the other: no game step and no turn of this plaza's own copy of the
        // members in between.
        XCTAssertTrue(w.b.engine.setWord(word, now: now))
        w.b.tell()
        w.b.session.sendDraw(first)
        XCTAssertEqual(w.c.drawCanvas[20, 10], 2, "drawn at once")
    }

    func testASnapshotReplacesTheCanvasAndOldStrokesAreIgnored() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        let id = w.c.gameState!.id
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [60, 40, 70, 40]))
        var theirs = PlazaDrawCanvas()
        theirs.stroke(points: [5, 5, 30, 5], color: 3, width: 1)
        let snapshot = TeamDraw(game: id, turn: 0, seq: 5, op: .snapshot, cells: theirs.packed().base64EncodedString())
        w.c.showDraw(from: w.b.id, snapshot)
        XCTAssertEqual(w.c.drawCanvas, theirs, "the snapshot is the canvas now")
        w.c.showDraw(from: w.b.id, stroke(w, seq: 3, [50, 50, 60, 50]))
        XCTAssertEqual(w.c.drawCanvas, theirs, "a stroke the snapshot already holds is ignored")
        w.c.showDraw(from: w.b.id, stroke(w, seq: 5, [50, 50, 60, 50]))
        XCTAssertEqual(w.c.drawCanvas, theirs, "so is the one at its own number")
        w.c.showDraw(from: w.b.id, stroke(w, seq: 6, [50, 50, 60, 50]))
        XCTAssertEqual(w.c.drawCanvas[55, 50], 2, "the next one follows it")
        XCTAssertEqual(w.c.drawCanvas[10, 5], 3)
    }

    func testAnOversizedOrBrokenSnapshotChangesNothing() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        let id = w.c.gameState!.id
        for cells in [String(repeating: "A", count: TeamDraw.maxCellsBase64 + 4), "!!!!", Data([1, 2, 3]).base64EncodedString(),
                      Data([200, 99]).base64EncodedString()] {
            w.c.showDraw(from: w.b.id, TeamDraw(game: id, turn: 0, seq: 9, op: .snapshot, cells: cells))
            XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas(), "\(cells.prefix(8))")
        }
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 10, 20, 10]))
        XCTAssertEqual(w.c.drawCanvas[15, 10], 2, "the numbering did not move")
    }

    func testTheViewerWhoIsNotPlayingSeesNoBoardAndNoDrawing() async {
        let w = await world()
        await lock(w, first: w.b.id, meJoins: false)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        XCTAssertNil(w.c.gameJoined)
        XCTAssertNil(w.c.drawBoard)
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 10, 20, 10]))
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas())
        XCTAssertEqual(w.c.gameStatus?.hasPrefix("그림 퀴즈 진행 중"), true, "\(w.c.gameStatus ?? "")")
        XCTAssertNil(w.c.gameCard)
        XCTAssertNil(w.c.gameTitle)
        XCTAssertFalse(w.input.isOpen)
        // The game ends (the other player leaves): everyone in the plaza gets the ranking card.
        w.d.engine.leave(now: now, present: [w.b.id, w.me.id])
        w.d.tell()
        now += PlazaDraw.drawSeconds + 1
        await sync(w)
        XCTAssertNotNil(w.c.gameState?.endedAt)
        XCTAssertEqual(w.c.gameCard?.title, L(.ko).plazaDrawRankingTitle)
        XCTAssertEqual(w.c.gameCard?.lines.count, 2)
        XCTAssertNil(w.c.drawBoard)
    }

    // MARK: - What the view shows

    func testTheInvitationClosesAtEightPlayers() async {
        let w = await world(others: 8, mesh: false)
        let host = w.b
        XCTAssertTrue(host.engine.open(.draw, now: now))
        host.tell()
        await settle()
        w.c.advanceGame()
        await settle()
        let state = host.engine.state!
        func join(_ n: Int) async {
            for o in w.others.dropFirst().prefix(n) { o.session.updateGame(state, join: state.id) }
            await settle()
            w.c.advanceGame()
            await settle()
        }
        await join(6)   // the host and six: seven
        var button = w.c.gameCard?.buttons.first { $0.action == "join" }
        XCTAssertEqual(button?.isEnabled, true)
        XCTAssertEqual(w.c.gameCard?.lines.last, L(.ko).plazaDrawRecruiting(players: 7, seconds: Int(PlazaGame.recruitSeconds)))
        await join(7)   // eight
        button = w.c.gameCard?.buttons.first { $0.action == "join" }
        XCTAssertEqual(button?.isEnabled, false)
        XCTAssertEqual(w.c.gameCard?.lines.last, L(.ko).plazaDrawFull)
        XCTAssertTrue(w.c.gameCard?.lines.contains(L(.ko).plazaDrawRecruiting(players: 8, seconds: Int(PlazaGame.recruitSeconds))) == true)
        press(w.c, yKey)
        XCTAssertNil(w.c.gameJoined, "the Y key honours the disabled button")
    }

    func testPlayersAreRingedDuringTheQuiz() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        XCTAssertEqual(w.scene.gameMarks, ["": .alive, w.b.id: .alive, w.d.id: .alive])
        XCTAssertFalse(w.scene.gameMarks.values.contains(.holder))
        XCTAssertEqual(Set(w.c.minimapDots.filter { $0.game == .alive }.map(\.id)), Set(w.all))
        XCTAssertNil(w.c.gameView.holder)
    }

    func testTheBoardAndTheHintFollowTheTurn() async {
        let w = await world()
        await lock(w, first: w.b.id)
        XCTAssertNotNil(w.c.drawBoard?.cover, "the countdown")
        await beginEntry(w)
        XCTAssertEqual(w.c.drawBoard?.cover, L(.ko).plazaDrawOtherEntry(nickname: "가", seconds: Int(PlazaDraw.wordSeconds)))
        XCTAssertEqual(w.c.drawBoard?.head, L(.ko).plazaDrawHead(turn: 1, of: 6, drawer: "가"))
        XCTAssertEqual(w.c.drawBoard?.canDraw, false)
        await teammateSetsWord(w, w.b)
        XCTAssertNil(w.c.drawBoard?.cover)
        XCTAssertEqual(w.c.drawBoard?.foot, .lines([L(.ko).plazaDrawHintLater(seconds: Int(PlazaDraw.drawSeconds - PlazaDraw.lettersHintSeconds))]))
        XCTAssertEqual(w.c.hint, L(.ko).plazaDrawOtherDrawing)
        now += PlazaDraw.lettersHintSeconds + 1
        await sync(w)
        XCTAssertEqual(w.c.drawBoard?.foot, .lines([L(.ko).plazaDrawHintLetters(2)]), "the drawer's Mac publishes the hint")
    }

    func testTheTurnsResultShowsBetweenTurns() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        XCTAssertTrue(w.b.engine.guess(word, from: w.me.id, now: now, playing: Set(w.all)))
        w.b.tell()
        await sync(w)
        XCTAssertEqual(w.c.gameTitle, PlazaGameView.Title(text: L(.ko).plazaDrawRight, tone: .win))
        XCTAssertEqual(w.c.drawBoard?.foot, .lines([L(.ko).plazaDrawResultSolved(word: word, solver: "나"),
                                                     L(.ko).plazaDrawResultPoints(solver: "나", solverPoints: 10, drawer: "가", drawerPoints: 5)]))
        XCTAssertEqual(w.c.drawBoard?.cover?.hasPrefix("다음은"), true)
    }

    func testATimeoutShowsTheTimeUpTitle() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        now += PlazaDraw.drawSeconds + 1
        await sync(w)
        XCTAssertEqual(w.c.gameTitle, PlazaGameView.Title(text: L(.ko).plazaDrawTimeUp, tone: .out))
        XCTAssertEqual(w.c.drawBoard?.foot, .lines([L(.ko).plazaDrawResultTimeout(word: word), L(.ko).plazaDrawResultNoPoints]))
    }

    // MARK: - Review round: guards and the time paths

    func testAStrokeIsNotSentAfterMyTurnEndedMidDrag() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        mouse(w, .down, x: 0, y: 0)
        mouse(w, .moved, x: 1, y: 0)
        mouse(w, .moved, x: 2, y: 0)
        let before = sentDraws(w, to: w.b).count
        w.c.showChat(memberID: w.b.id, text: word)   // a right guess ends my turn while the button is down
        await settle()
        XCTAssertEqual(w.c.gameState?.draw?.turn, 1)
        mouse(w, .moved, x: 3, y: 0)
        mouse(w, .moved, x: 4, y: 0)
        mouse(w, .up, x: 4, y: 0)
        await settle()
        XCTAssertEqual(sentDraws(w, to: w.b).count, before, "no drawing message left after the turn ended")
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas())
    }

    func testTheWordFieldWaitsForAnOverlayAndOpensWhenItCloses() async {
        let w = await world()
        await lock(w, first: w.me.id)
        press(w.c, mKey)
        guard case .gameMenu = w.c.overlayContent else { return XCTFail("the menu is open") }
        await beginEntry(w)
        XCTAssertNotNil(w.c.gameState?.draw?.entryAt, "test precondition: my entry began")
        XCTAssertFalse(w.input.isOpen, "the menu has the keyboard")
        w.c.chooseGame(index: 0)   // closes the menu
        XCTAssertEqual(w.c.overlayContent, .none)
        await sync(w)
        XCTAssertTrue(w.input.isOpen)
        XCTAssertEqual(w.input.purpose, .quizWord)
    }

    func testTheWordFieldWaitsForPhotoMode() async {
        let w = await world()
        await lock(w, first: w.me.id)
        w.scene.enterPhotoMode()
        await beginEntry(w)
        XCTAssertFalse(w.input.isOpen)
        w.scene.exitPhotoMode()
        await sync(w)
        XCTAssertEqual(w.input.purpose, .quizWord)
        XCTAssertTrue(w.input.isOpen)
    }

    func testAStrokeFromADrawerWhoLeftTheGameIsIgnored() async {
        let w = await world()
        await lock(w, first: w.b.id)
        await beginEntry(w)
        await teammateSetsWord(w, w.b)
        w.c.showDraw(from: w.b.id, stroke(w, seq: 1, [10, 10, 20, 10]))
        XCTAssertEqual(w.c.drawCanvas[15, 10], 2, "test precondition: the drawer is heard")
        // Their own presence now says they are not in this game.
        w.b.session.updateGame(w.b.engine.state, join: nil)
        w.c.showDraw(from: w.b.id, stroke(w, seq: 2, [10, 20, 20, 20]))
        XCTAssertEqual(w.c.drawCanvas[15, 20], 0)
        w.b.tell()
        w.b.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false, isFlushed: false)
        w.c.showDraw(from: w.b.id, stroke(w, seq: 2, [10, 30, 20, 30]))
        XCTAssertEqual(w.c.drawCanvas[15, 30], 0, "nor from one who is not in the plaza")
    }

    func testAShortHeldStrokeGoesOutOnceTheIntervalHasPassed() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        mouse(w, .down, x: 0, y: 0)
        mouse(w, .moved, x: 1, y: 0)
        XCTAssertEqual(sentDraws(w, to: w.b).count, 0, "held: 2 points, no time has passed")
        now += PlazaWindowController.drawFlushInterval + 0.02
        w.c.advanceGame()
        let sent = sentDraws(w, to: w.b)
        XCTAssertEqual(sent.map(\.op), [.stroke])
        XCTAssertEqual(sent.first?.points, [0, 0, 1, 0])
        mouse(w, .up, x: 1, y: 0)
        XCTAssertEqual(sentDraws(w, to: w.b).count, 1, "nothing more was held")
    }

    func testASnapshotGoesOutEveryTenSecondsOnlyWhileThePictureChanged() async {
        let w = await world()
        await myDrawing(w)
        await attachHUD(w)
        func snapshots() -> Int { sentDraws(w, to: w.b).filter { $0.op == .snapshot }.count }
        now += PlazaWindowController.drawSnapshotInterval + 0.5
        w.c.advanceGame()
        XCTAssertEqual(snapshots(), 0, "an untouched canvas is not sent")
        mouse(w, .down, x: 4, y: 4)
        mouse(w, .up, x: 4, y: 4)
        w.c.advanceGame()
        XCTAssertEqual(snapshots(), 0, "the interval counts from the last look, not from the stroke")
        now += PlazaWindowController.drawSnapshotInterval + 0.5
        w.c.advanceGame()
        XCTAssertEqual(snapshots(), 1)
        now += PlazaWindowController.drawSnapshotInterval + 0.5
        w.c.advanceGame()
        XCTAssertEqual(snapshots(), 1, "unchanged since the last one")
        mouse(w, .down, x: 8, y: 8)
        mouse(w, .up, x: 8, y: 8)
        now += PlazaWindowController.drawSnapshotInterval + 0.5
        w.c.advanceGame()
        XCTAssertEqual(snapshots(), 2)
    }

    func testAMemberWhoJoinsThePlazaWithoutPlayingGetsASnapshotToo() async {
        let w = await world(others: 3)
        let watcher = w.others[2]
        watcher.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false, isFlushed: false)
        await settle()
        await lock(w, first: w.me.id, joining: [w.d])
        await beginEntry(w)
        w.input.type(word)
        XCTAssertTrue(w.input.submit())
        await sync(w)
        func snapshots(_ n: Node) -> Int { sentDraws(w, to: n).filter { $0.op == .snapshot }.count }
        XCTAssertEqual(snapshots(w.b), 0)
        watcher.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 14, y: 6), facing: .left, isWalking: false, isFlushed: false)
        await sync(w)
        // Pinned: the drawer cannot tell who plays from who stands there, so everyone gets the snapshot; a viewer discards it.
        XCTAssertEqual(snapshots(w.b), 1)
        XCTAssertEqual(snapshots(watcher), 1)
    }

    func testWhenTheOthersLeaveTheGameEndsAndTheBoardTheFieldAndTheRoomGoAway() async {
        let w = await world()
        await attachHUD(w, size: CGSize(width: 600, height: 372))
        await lock(w, first: w.me.id)
        await beginEntry(w)
        await settle()
        w.input.type("사")
        XCTAssertNotNil(w.c.drawBoard)
        XCTAssertTrue(w.c.showsShortcutsFolded, "test precondition: the small window made room")
        for o in w.others {
            o.engine.leave(now: now, present: Set(w.all))
            o.tell()
        }
        now += PlazaDraw.wordSeconds + 1
        await sync(w)
        XCTAssertNotNil(w.c.gameState?.endedAt)
        XCTAssertNil(w.c.drawBoard)
        XCTAssertFalse(w.input.isOpen)
        XCTAssertEqual(sentChats(w), [])
        XCTAssertFalse(w.me.transport.sent.contains { encoded($0.message).contains("사") }, "the half-typed word was not sent")
        await settle()
        XCTAssertFalse(w.c.showsShortcutsFolded, "the room is given back")
    }

    // MARK: - Closing

    func testClosingThePlazaTakesTheBoardAndTheWordFieldAway() async {
        let w = await world()
        await lock(w, first: w.me.id)
        await beginEntry(w)
        w.input.type("사")
        XCTAssertNotNil(w.c.drawBoard)
        XCTAssertTrue(w.input.isOpen)
        w.c.handleClose()
        XCTAssertNil(w.c.drawBoard)
        XCTAssertFalse(w.input.isOpen)
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas())
        XCTAssertEqual(sentChats(w), [])
        XCTAssertFalse(w.me.transport.sent.contains { encoded($0.message).contains("사") }, "the half-typed word was not sent")
    }

    func testLeavingTheTeamClosesThePlazaAndTakesTheBoardAway() async {
        let w = await world()
        await myDrawing(w)
        XCTAssertNotNil(w.c.drawBoard)
        w.c.show()
        w.c.closeIfOpen()   // what the runtime does when the team is left
        XCTAssertNil(w.c.drawBoard)
        XCTAssertEqual(w.c.drawCanvas, PlazaDrawCanvas())
        XCTAssertNil(w.c.gameJoined)
    }
}
