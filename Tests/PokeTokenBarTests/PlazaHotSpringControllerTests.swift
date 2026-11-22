import XCTest
@testable import PokeTokenBar

private struct SpringEmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Holds the soak deadline's sleep until the test fires it, like `LoopGate` in the Ditto tests.
@MainActor private final class SoakGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []
    func sleep(_ d: Duration) async { requested.append(d); await withCheckedContinuation { waiting.append($0) } }
    func fire() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
}

/// The hot spring's three-minute soak and the red flush, from the controller's side: one deadline, the flag riding in
/// the presence that moves me, and the receiver drawing red only on a spring tile.
@MainActor
final class PlazaHotSpringControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = PlazaHotSpringControllerTests.noon
    private var t: TimeInterval = 0
    private var gate = SoakGate()
    private let zKey: UInt16 = 6, leftKey: UInt16 = 123, rightKey: UInt16 = 124

    private static let noon = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Self.noon
        t = 0
        gate = SoakGate()
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.spring.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaHotSpringControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func controller(_ me: Node, start: TilePoint) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.spring.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        // The left pond is broken so the ice never freezes under the test.
        prefs.iceBreak = PlazaIceBreak(at: now.timeIntervalSince1970, pond: TilePoint(x: 5, y: 13))
        let gate = self.gate
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: SpringEmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, evolutionStage: { 1 }, session: me.session, clock: { [unowned self] in now },
                                     soakSleep: { await gate.sleep($0) },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    /// `bBeforeOpen`: b is already in the plaza (at `bTile`, red when `bFlushed`) when my plaza opens, so the scene's first
    /// sight of b is that. Otherwise b is first seen away and the scene follows what b sends later.
    private func world(me mine: TilePoint, b bTile: TilePoint? = nil, bFlushed: Bool = false, bBeforeOpen: Bool = false) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, start: mine)
        hub.connect(me.transport, to: b.transport)
        await settle()
        if bBeforeOpen, let bTile {
            b.session.updatePlazaPosition(inPlaza: true, tile: bTile, facing: .down, isWalking: false, isFlushed: bFlushed)
            await settle()
        }
        c.prepareScene()
        await settle()
        let w = World(c: c, me: me, b: b)
        w.scene.face(.right)
        if let bTile, !bBeforeOpen { await place(w, bTile, flushed: bFlushed) }
        run(w.scene, 0.1)
        return w
    }

    private func place(_ w: World, _ tile: TilePoint, flushed: Bool = false, inPlaza: Bool = true) async {
        w.b.session.updatePlazaPosition(inPlaza: inPlaza, tile: tile, facing: .down, isWalking: false, isFlushed: flushed)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile && inPlaza { await Task.yield(); t += 0.05; w.scene.update(t) }
        await settle()
    }

    /// Z at the water's edge: I jump in and stand in the spring at (32,17).
    private func enterTheSpring(_ w: World) async {
        w.scene.handleKeyDown(keyCode: zKey, characters: "ㅁ", isRepeat: false)
        run(w.scene, 1)
        w.scene.handleKeyUp(keyCode: zKey)
        XCTAssertEqual(w.scene.walker.tile, p(32, 17), "test precondition")
        await settle()   // the deadline's task starts and asks for its sleep
    }

    private func presences(of n: Node) -> [TeamPresence] {
        n.transport.sent.compactMap { if case .presence(let p) = $0.message { p } else { nil } }
    }

    private func blend(_ w: World) -> CGFloat? { w.scene.memberFlushBlend(w.b.id) }

    // MARK: - My soak

    func testTheSoakTimeInTheSpringFlushesMeOnEveryScreen() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        await settle()
        XCTAssertEqual(gate.requested, [.milliseconds(Int(PlazaHotSpring.flushAfter * 1000))])
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, false)
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, true)
        XCTAssertEqual(w.scene.myFlushBlend, 0, accuracy: 1e-6)
        now += 2
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.myFlushBlend, 0.45, accuracy: 1e-6)
    }

    func testOneDeadlineNotAPoll() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        func tap(_ key: UInt16) {
            w.scene.handleKeyDown(keyCode: key, characters: "", isRepeat: false)
            run(w.scene, 0.05)
            w.scene.handleKeyUp(keyCode: key)
            run(w.scene, 0.7)   // the step finishes
        }
        for _ in 0..<4 { tap(rightKey); now += 12 }
        XCTAssertEqual(w.scene.walker.tile, p(36, 17), "four steps inside the spring")
        XCTAssertEqual(gate.requested.count, 1, "walking inside the spring arms nothing more")
        for _ in 0..<5 { tap(leftKey); now += 1 }
        XCTAssertFalse(PlazaMapData.map.isHotSpring(w.scene.walker.tile), "test precondition: out")
        XCTAssertEqual(gate.requested.count, 1, "leaving arms nothing")
        gate.fire()   // the cancelled deadline returns after its sleep and must do nothing
        await settle()
        now += 400
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, false)
        // Re-entering waits the full soak time again.
        w.scene.face(.right)
        await enterTheSpring(w)
        XCTAssertEqual(gate.requested.count, 2)
        XCTAssertEqual(gate.requested.last, .milliseconds(Int(PlazaHotSpring.flushAfter * 1000)))
    }

    /// The system clock was set back while the deadline slept: it wakes early, flushes nobody and the soak restarts from now (the
    /// full soak time), not after the whole set-back.
    func testAClockSetBackWhileSoakingRestartsTheSoakFromNow() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        now -= 3600
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, false)
        XCTAssertEqual(gate.requested, [.milliseconds(Int(PlazaHotSpring.flushAfter * 1000)), .milliseconds(Int(PlazaHotSpring.flushAfter * 1000))], "the full soak time from the new now, not the set-back plus it")
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, true)
    }

    func testLeavingClearsTheFlagInThePresenceThatMovesMe() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, true, "test precondition")
        w.scene.handleKeyDown(keyCode: leftKey, characters: "", isRepeat: false)
        run(w.scene, 1)
        w.scene.handleKeyUp(keyCode: leftKey)
        await settle()
        let sent = presences(of: w.me)
        let land = sent.filter { $0.tile == p(31, 17) }
        XCTAssertFalse(land.isEmpty)
        XCTAssertNil(land.first?.isFlushed, "the first presence at the land tile already has no flag")
        for presence in sent {
            if let tile = presence.tile, !PlazaMapData.map.isHotSpring(tile) {
                XCTAssertNil(presence.isFlushed, "no flag on land \(tile)")
            }
        }
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, false)
    }

    func testClosingThePlazaClearsTheFlag() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, true, "test precondition")
        w.c.handleClose()
        await settle()
        let last = presences(of: w.me).last
        XCTAssertEqual(last?.inPlaza, false)
        XCTAssertNil(last?.isFlushed)

        // Closing before the deadline: the cancelled deadline sends nothing when it wakes.
        let v = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(v)
        let before = presences(of: v.me).count
        v.c.handleClose()
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertFalse(presences(of: v.me).dropFirst(before).contains { $0.isFlushed == true })
        XCTAssertEqual(v.b.session.members[v.me.id]?.isFlushed, false)
    }

    func testAHiddenPlazaStillFlushes() async {
        let w = await world(me: p(31, 17), b: p(20, 12))
        await enterTheSpring(w)
        w.c.setRendering(visible: false)
        now += PlazaHotSpring.flushAfter
        gate.fire()
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.isFlushed, true)
    }

    // MARK: - Their red

    func testATeammatesRedFadesOverAMinuteAfterTheyLeave() async {
        let w = await world(me: p(23, 6), b: p(34, 17), bFlushed: true, bBeforeOpen: true)
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0.45, accuracy: 1e-6, "a first sight has no rise")
        await place(w, p(31, 17))
        now += 30
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0.225, accuracy: 0.01)
        now += 30
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0, accuracy: 1e-6)
    }

    func testATeammateTurningRedRisesOverTwoSeconds() async {
        let w = await world(me: p(23, 6), b: p(34, 17))
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0, accuracy: 1e-6)
        await place(w, p(34, 17), flushed: true)
        now += 1
        run(w.scene, 1)
        XCTAssertEqual(blend(w) ?? -1, 0.225, accuracy: 0.01)
    }

    func testAPausedSceneIsRightOnItsFirstFrameBack() async {
        let w = await world(me: p(23, 6), b: p(34, 17), bFlushed: true, bBeforeOpen: true)
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0.45, accuracy: 1e-6)
        w.c.setRendering(visible: false)
        await place(w, p(31, 17))
        now += 30
        w.c.setRendering(visible: true)
        run(w.scene, 1.0 / 60)
        XCTAssertEqual(blend(w) ?? -1, 0.225, accuracy: 0.01)
    }

    // MARK: - Hostile peers

    func testAFlushClaimOffTheSpringIsNotDrawn() async {
        let w = await world(me: p(23, 6))
        await place(w, p(30, 17), flushed: true)
        now += 3
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0, accuracy: 1e-6)
    }

    func testAFlushClaimFromAnAwayMemberIsNotDrawn() async {
        let w = await world(me: p(23, 6))
        await place(w, p(34, 17), flushed: true, inPlaza: false)
        now += 3
        run(w.scene, 0.1)
        XCTAssertEqual(blend(w) ?? -1, 0, accuracy: 1e-6)
    }
}
