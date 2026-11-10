import XCTest
import AppKit
@testable import PokeTokenBar

/// Records which species were asked for, so a test can see a frame load start without any network.
private final class RecordingFetcher: PlazaSpriteFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        add(speciesID)
        return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
final class PlazaDittoControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private let map = PlazaMapData.map
    private let key = PlazaDitto.sceneKey

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

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private func node(_ name: String, character: TeamMonSummary? = nil) -> Node {
        let suite = "plaza.ditto.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaDittoControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let current = character ?? Self.pikachu
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: current, dex: []) })
        session.updateCharacter(current)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func defaults() -> UserDefaults {
        let name = "plaza.ditto.prefs.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Holds the Ditto loop's sleep until the test fires it.
    @MainActor private final class LoopGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var waitingCount: Int { waiting.count }
        /// Every duration the loop asked to sleep, in order.
        private(set) var requested: [Duration] = []
        func sleep(_ d: Duration) async { requested.append(d); await withCheckedContinuation { waiting.append($0) } }
        func fire() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
    }

    /// The loop sleeps for good, so only `advanceDitto(now:)` moves the Ditto.
    private func controller(_ me: Node, fetcher: PlazaSpriteFetching = RecordingFetcher(), gate: LoopGate? = nil,
                            seed: UInt64 = 7, nickname: String = "나", start: TilePoint? = nil) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        if let start { prefs.saveLastTile(start) }
        return PlazaWindowController(preferences: prefs,
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: { nickname }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { nil }, session: me.session,
                              spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                              dittoLoopSleep: { d in
                                  if let gate { await gate.sleep(d) } else { try? await Task.sleep(for: .seconds(3600)) }
                              },
                              dittoSeed: { seed })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    /// Nodes ordered by member ID, so a test knows who would host.
    private func sorted(_ count: Int, character: TeamMonSummary? = nil) -> [Node] {
        (0..<count).map { node("n\($0)", character: character) }.sorted { $0.id < $1.id }
    }

    private func ground(_ dx: Int = 0, _ dy: Int = 0) -> TilePoint {
        let t = TilePoint(x: map.spawn.x + dx, y: map.spawn.y + dy)
        XCTAssertTrue(PlazaDitto.isGround(t, in: map), "\(t) must be ground")
        return t
    }

    /// Where my character starts in the adjacency tests, and the ground tile right beside it (to its right).
    private lazy var meStart: (me: TilePoint, beside: TilePoint) = {
        let far = [ground(8, 8), ground(-5, 0), map.spawn]
        for y in 0..<map.height { for x in 0..<(map.width - 1) {
            let t = TilePoint(x: x, y: y), r = TilePoint(x: x + 1, y: y)
            guard PlazaDitto.isGround(t, in: map), PlazaDitto.isGround(r, in: map) else { continue }
            if far.allSatisfy({ abs($0.x - x) + abs($0.y - y) > 4 }) { return (t, r) }
        } }
        XCTFail("no two neighbouring ground tiles")
        return (map.spawn, map.spawn)
    }()

    private func beside() -> TilePoint { meStart.beside }

    private func place(_ n: Node, at tile: TilePoint, ready: Bool = true) {
        n.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        n.session.updateDitto(ready: ready, state: nil)
    }

    private func host(_ n: Node, _ state: PlazaDittoState) {
        n.session.updatePlazaPosition(inPlaza: true, tile: ground(8, 8), facing: .down, isWalking: false)
        n.session.updateDitto(ready: true, state: state)
    }

    private func dittoForm(_ tile: TilePoint, now: Date = Date()) -> PlazaDittoState {
        PlazaDittoState(tile: tile, facing: .down, isWalking: nil, isRunning: nil, decoyOf: nil, since: now, restUntil: nil)
    }

    // MARK: - Readiness

    func testOpeningTheWindowMakesMeReadyAndClosingClearsIt() async {
        let me = node("나"), other = node("민수")
        await connect(me, other)
        XCTAssertNotEqual(other.session.members[me.id]?.dittoReady, true)
        let c = controller(me)
        c.prepareScene()
        await settle()
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, true)
        c.advanceDitto(now: Date())
        await settle()
        c.handleClose()
        await settle()
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, false)
        XCTAssertNil(other.session.members[me.id]?.ditto)
        XCTAssertNil(c.shownDitto)
        XCTAssertFalse(c.isDittoHost)
    }

    func testAControllerWhoseWindowWasNeverShownNeverSendsReady() async {
        let me = node("나"), other = node("민수")
        await connect(me, other)
        _ = controller(me)
        me.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await settle()
        XCTAssertNotNil(other.session.members[me.id], "my presence did reach the other side")
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, false)
    }

    func testTheLoopTicksWhileOpenStopsOnCloseAndRestartsOnce() async {
        let me = node("나")
        let gate = LoopGate()
        let c = controller(me, gate: gate)
        c.prepareScene()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1)
        XCTAssertNil(c.shownDitto, "no tick yet")
        gate.fire()
        await settle()
        XCTAssertNotNil(c.shownDitto, "a tick reached advanceDitto")
        XCTAssertEqual(gate.waitingCount, 1, "and the loop sleeps again")

        c.handleClose()
        gate.fire()
        await settle()
        XCTAssertEqual(gate.waitingCount, 0, "closing ends the loop")

        c.prepareScene()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1)
        gate.fire()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1, "one stream of ticks after reopening, not two")
        XCTAssertNotNil(c.shownDitto)
    }

    func testOnlyAWalkingHostTicksAtFiftyMilliseconds() async {
        // A non-host does not need the clock: it follows the host through presence changes, with a slow fallback.
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        host(a, dittoForm(ground(8, 8)))
        await settle()
        let follower = LoopGate()
        let c = controller(me, gate: follower)
        c.prepareScene()
        await settle()
        XCTAssertGreaterThanOrEqual(follower.requested.first ?? .zero, .seconds(1))
        c.handleClose()

        // A host that stands still sleeps longer than a step; one that walks asks for 50 ms.
        let lone = node("나")
        let gate = LoopGate()
        let h = controller(lone, gate: gate)
        h.prepareScene()
        await settle()
        XCTAssertEqual(gate.requested.last, .milliseconds(50), "about to take over: a quick first tick")
        var requested = 0
        var sawLong = false, sawWalk = false
        let t0 = Date()
        for i in 1...4000 where !(sawLong && sawWalk) {
            gate.fire()
            await settle()
            h.advanceDitto(now: t0.addingTimeInterval(Double(i) * 0.05))
            guard gate.requested.count > requested else { continue }
            requested = gate.requested.count
            if let d = gate.requested.last { if d > .milliseconds(50) { sawLong = true } else { sawWalk = true } }
        }
        XCTAssertTrue(sawLong, "standing still sleeps more than 50 ms")
        XCTAssertTrue(sawWalk, "walking ticks at 50 ms")
        XCTAssertTrue(gate.requested.allSatisfy { $0 <= .milliseconds(250) })
        h.handleClose()
    }

    func testAPresenceChangeMovesTheDittoWithoutALoopTick() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let gate = LoopGate()   // never fired
        let c = controller(me, gate: gate)
        c.prepareScene()
        host(a, dittoForm(ground(8, 8)))
        await settle()
        XCTAssertEqual(c.scene?.dittoTile, ground(8, 8), "followed from the presence alone")
        host(a, dittoForm(ground(8, 9)))
        for _ in 0..<400 where c.shownDitto?.tile != ground(8, 9) { await Task.yield() }
        XCTAssertEqual(c.shownDitto?.tile, ground(8, 9), "the scene walks there on its own update")
        XCTAssertEqual(gate.waitingCount, 1)
        c.handleClose()
    }

    func testAnUnchangedDittoLeavesTheSceneAlone() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(4, 0))
        // Remove it behind the controller's back: a tick with nothing new must not redraw it.
        c.scene?.applyDitto(nil)
        c.advanceDitto(now: Date())
        XCTAssertNil(c.scene?.dittoTile)
        host(a, dittoForm(ground(6, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(6, 0), "a change is drawn")
    }

    // MARK: - Host choice

    func testTheSmallestReadyIDHosts() async {
        let pair = sorted(2)
        let (a, b) = (pair[0], pair[1])
        await connect(a, b)
        place(a, at: ground(4, 0))
        let cb = controller(b)
        cb.prepareScene()
        await settle()
        cb.advanceDitto(now: Date())
        await settle()
        XCTAssertFalse(cb.isDittoHost, "a smaller ready ID hosts")
        XCTAssertNil(a.session.members[b.id]?.ditto)

        let ca = controller(a)
        ca.prepareScene()
        place(b, at: ground(6, 0))
        await settle()
        ca.advanceDitto(now: Date())
        await settle()
        XCTAssertTrue(ca.isDittoHost)
        XCTAssertNotNil(b.session.members[a.id]?.ditto, "the host's presence carries the Ditto")
    }

    func testANonHostShowsTheHostsDitto() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(4, 0))
        XCTAssertEqual(c.shownDitto?.tile, ground(4, 0))
        XCTAssertEqual(c.scene?.memberName(key), L(.ko).plazaDittoName)
    }

    func testTwoHostsSettleOnTheSmallerID() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertTrue(c.isDittoHost, "alone, I host")
        host(a, dittoForm(ground(6, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertFalse(c.isDittoHost, "a smaller ID hosting wins at once")
        XCTAssertEqual(c.scene?.dittoTile, ground(6, 0))
    }

    func testANewHostCarriesOnTheCopyWhereTheOldHostLeftIt() async {
        let trio = sorted(3)
        let (a, me, m) = (trio[0], trio[1], trio[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        let before = try? XCTUnwrap(c.shownDitto)
        XCTAssertEqual(before?.decoyOf, m.id)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        await settle()
        XCTAssertTrue(c.isDittoHost)
        let sent = a.session.members[me.id]?.ditto
        XCTAssertEqual(sent?.decoyOf, m.id)
        XCTAssertEqual(sent?.since, before?.since)
        XCTAssertEqual(sent?.tile, before?.tile)
    }

    func testASmallerIDOpeningThePlazaCarriesOnTheCopy() async throws {
        let trio = sorted(3)
        let (me, b, m) = (trio[0], trio[1], trio[2])   // I would host the moment I open the window
        await connect(me, b); await connect(m, b); await connect(me, m)
        place(m, at: ground(-5, 0))
        let now = Date()
        host(b, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        let before = try XCTUnwrap(me.session.members[b.id]?.ditto)
        let c = controller(me)
        c.prepareScene()
        // b yields on seeing my ready frame, before my first tick.
        b.session.updateDitto(ready: true, state: nil)
        await settle()
        XCTAssertNil(me.session.members[b.id]?.ditto, "test precondition: the old host has already let go")
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        await settle()
        XCTAssertTrue(c.isDittoHost)
        let kept = c.shownDitto
        XCTAssertEqual(kept?.decoyOf, m.id)
        XCTAssertEqual(kept?.since, before.since)
        XCTAssertEqual(kept?.tile, before.tile)
        XCTAssertEqual(c.scene?.decoyTile, before.tile)
    }

    func testTheHostMovesTheDittoWithoutSceneFrames() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        c.scene?.isPaused = true
        var now = Date()
        c.advanceDitto(now: now)
        var tiles: Set<TilePoint> = [try! XCTUnwrap(c.shownDitto).tile]
        for _ in 0..<1200 {
            now = now.addingTimeInterval(0.05)
            c.advanceDitto(now: now)
            if let t = c.shownDitto?.tile { tiles.insert(t) }
        }
        XCTAssertGreaterThan(tiles.count, 1, "the brain walks on the controller's clock alone")
    }

    // MARK: - Showing

    /// [host a, me, member m] with m ready next to nothing, and a hosting a copy of m.
    private func copyScene(character: TeamMonSummary? = nil, fetcher: PlazaSpriteFetching = RecordingFetcher())
        async -> (c: PlazaWindowController, a: Node, m: Node) {
        let nodes = sorted(3)
        let (a, me) = (nodes[0], nodes[1])
        let m = nodes[2]
        await connect(a, me); await connect(m, me)
        let c = controller(me, fetcher: fetcher)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        return (c, a, m)
    }

    func testACopyLooksLikeTheRealOne() async {
        let (c, _, m) = await copyScene()
        let scene = c.scene!
        XCTAssertEqual(scene.memberName(key), m.settings.nickname)
        XCTAssertEqual(scene.memberNameColor(key), PlazaNameColor.color(forMemberID: m.id, chosen: m.settings.nameColor))
        XCTAssertEqual(scene.memberNameColor(key), scene.memberNameColor(m.id))
        XCTAssertEqual(scene.decoyTile, ground(5, 3))
        // Filter by id, not colour: another teammate's random ID can map to the same palette colour.
        let dots = c.minimapDots.filter { ($0.id == m.id || $0.id == key) && !$0.isMe }
        XCTAssertEqual(Set(dots.map(\.id)), [m.id, key])
        XCTAssertEqual(Set(dots.map(\.color)).count, 1, "the copy's dot is the real one's colour")
    }

    func testTheCopyFollowsTheRealOnesLookChange() async {
        let fetcher = RecordingFetcher()
        let (c, _, m) = await copyScene(fetcher: fetcher)
        let scene = c.scene!
        var changed = Self.pikachu
        changed.nature = .jolly
        m.session.updateCharacter(changed)
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(scene.memberTitle(key), L(.ko).plazaNatureTitle(.jolly))
        XCTAssertEqual(scene.memberTitle(key), scene.memberTitle(m.id))

        let before = c.appliedMemberSpecies(key).count
        m.session.updateCharacter(TeamMonSummary(speciesID: 4, isShiny: false, form: nil, speciesName: "Charmander", gender: nil))
        await settle()
        c.advanceDitto(now: Date())
        await settle()
        XCTAssertGreaterThan(c.appliedMemberSpecies(key).count, before)
        XCTAssertEqual(c.appliedMemberSpecies(key).last, 4, "a species change starts a load under the Ditto key")
    }

    func testDittoFormHasNoMinimapDot() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNotNil(c.scene?.dittoTile)
        XCTAssertFalse(c.minimapDots.contains { $0.id == key })
    }

    func testTransformStopsMyWalkToTheCopiedMember() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now))
        await settle()
        c.advanceDitto(now: now)
        c.walkToMember(m.id)
        XCTAssertEqual(c.scene?.walkingToMember, m.id)
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        XCTAssertEqual(c.scene?.decoyTile, ground(5, 3))
        XCTAssertNil(c.scene?.walkingToMember, "the walk to the real one ends at the swap")
    }

    func testAStateOffTheGroundIsIgnored() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        var water: TilePoint?
        for y in 0..<map.height { for x in 0..<map.width where map.isWater(TilePoint(x: x, y: y)) { water = TilePoint(x: x, y: y) } }
        host(a, dittoForm(try! XCTUnwrap(water)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNil(c.scene?.dittoTile)
        XCTAssertNil(c.shownDitto)
    }

    // MARK: - Hostile peers

    func testACopyOfAMemberNotInThePlazaIsNotShown() async {
        let (c, a, m) = await copyScene()
        XCTAssertEqual(c.shownDitto?.decoyOf, m.id, "test precondition")
        let before = c.shownDitto
        m.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await settle()
        let now = Date().addingTimeInterval(1)
        host(a, dittoForm(ground(6, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(c.shownDitto, before, "the previous look stays, as for an unknown member")
    }

    func testAStateOffTheMapIsIgnored() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        for off in [TilePoint(x: -1, y: 0), TilePoint(x: map.width, y: map.height), TilePoint(x: 1_000_000, y: -1_000_000)] {
            host(a, dittoForm(off))
            await settle()
            c.advanceDitto(now: Date())
            XCTAssertNil(c.scene?.dittoTile, "\(off)")
            XCTAssertNil(c.shownDitto)
        }
    }

    func testABurstOfDittoStatesLeavesTheLastGoodOneShown() async {
        let (c, a, m) = await copyScene()
        let membersBefore = c.scene?.memberTiles.count
        let now = Date()
        var last: TilePoint?
        for i in 0..<300 {
            let tile = i % 3 == 0 ? TilePoint(x: -i, y: i) : ground(i % 7, 3)
            if PlazaDitto.isGround(tile, in: map) { last = tile }
            host(a, dittoForm(tile, now: now).copying(i % 2 == 0 ? m.id : String(repeating: "x", count: i + 1), now: now))
        }
        await settle()
        c.advanceDitto(now: now)
        let shown = try? XCTUnwrap(c.shownDitto)
        XCTAssertNotNil(shown)
        XCTAssertTrue(PlazaDitto.isGround(shown?.tile ?? TilePoint(x: -1, y: -1), in: map))
        XCTAssertNotNil(last)
        XCTAssertEqual(c.scene?.memberTiles.count, membersBefore, "the burst adds no one to the scene")
    }

    // MARK: - Campfire seats

    func testACampfireSeatUnderTheDittoIsNotChosen() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        let scene = c.scene!
        let seat = try! XCTUnwrap(PlazaCampfire.nearestFreeSeat(from: scene.walker.tile, occupied: []))
        scene.applyDitto(PlazaDittoShown(tile: seat.tile, facing: .down, isWalking: false, isRunning: false, name: "d",
                                         nameColor: PlazaNameColor.palette[0], title: nil, isDecoy: false))
        c.startFocus(minutes: 25)
        XCTAssertNotNil(c.focus)
        XCTAssertNotEqual(c.focus?.seat, seat.tile)
    }

    // MARK: - Finding the copy

    /// [host a, me, member m] with a hosting a copy of `copied` right beside me (spawn, one tile right).
    @MainActor private struct Adjacent {
        let c: PlazaWindowController, a: Node, me: Node, m: Node, since: Date
        var scene: PlazaScene { c.scene! }
    }

    private func adjacentCopy(ofMe: Bool = false, nickname: String = "나", now: Date = Date()) async -> Adjacent {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me, nickname: nickname, start: meStart.me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        host(a, dittoForm(beside(), now: now).copying(ofMe ? me.id : m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(c.scene?.decoyTile, beside(), "test precondition")
        return Adjacent(c: c, a: a, me: me, m: m, since: now)
    }

    private func emotes(from node: Node) -> EmoteLog {
        let log = EmoteLog()
        node.session.onEmote = { log.items.append($1) }
        return log
    }

    @MainActor private final class EmoteLog { var items: [TeamEmote] = [] }

    func testTacklingTheCopyRevealsItForEveryone() async {
        let t = await adjacentCopy(nickname: "재헌")
        let log = emotes(from: t.a)
        t.scene.onTackleKey?()
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.decoyFound])
        XCTAssertEqual(log.items.first?.targetMemberID, t.m.id)
        XCTAssertNil(t.c.shownDitto?.decoyOf)
        XCTAssertEqual(t.scene.dittoTile, beside())
        XCTAssertNil(t.scene.decoyTile, "Ditto form at that tile")
        XCTAssertEqual(t.scene.memberName(key), L(.ko).plazaDittoName)
        XCTAssertEqual(t.c.banner, "재헌님이 메타몽을 찾았어요!")
        XCTAssertEqual(t.scene.shownEmote(memberID: key), .exclaim)
    }

    func testTheCopiedPersonCanTackleTheirOwnCopy() async {
        let t = await adjacentCopy(ofMe: true, nickname: "재헌")
        let log = emotes(from: t.a)
        t.scene.onTackleKey?()
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.decoyFound])
        XCTAssertEqual(log.items.first?.targetMemberID, t.me.id)
        XCTAssertNil(t.scene.decoyTile)
        XCTAssertEqual(t.c.banner, "재헌님이 메타몽을 찾았어요!")
    }

    func testTacklingTheRealOneStillPushes() async {
        let nodes = sorted(2)
        let (m, me) = (nodes[0], nodes[1])
        await connect(m, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        place(m, at: beside())
        await settle()
        let log = emotes(from: m)
        c.scene?.onTackleKey?()
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertEqual(log.items.first?.targetMemberID, m.id)
    }

    func testAReceivedFindShowsTheBannerOnce() async {
        let t = await adjacentCopy()
        t.c.showDecoyFound(from: t.m.id, copied: t.m.id)
        XCTAssertEqual(t.c.banner, L(.ko).plazaDecoyFound(nickname: t.m.settings.nickname))
        t.c.showBanner("other")
        t.c.showDecoyFound(from: t.a.id, copied: t.m.id)
        XCTAssertEqual(t.c.banner, "other", "the second find of the same copy shows nothing")
        XCTAssertNil(t.c.shownDitto?.decoyOf)
    }

    func testAFindWithNoCopyIsIgnored() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        c.showDecoyFound(from: m.id, copied: m.id)
        XCTAssertNil(c.banner)
        XCTAssertNil(c.scene?.shownEmote(memberID: key))
        // A copy of somebody else is not found by a find naming m either.
        let now = Date()
        host(a, dittoForm(ground(4, 0), now: now).copying(a.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        c.showDecoyFound(from: m.id, copied: m.id)
        XCTAssertNil(c.banner)
        c.showDecoyFound(from: m.id, copied: nil)
        XCTAssertNil(c.banner)
        XCTAssertEqual(c.shownDitto?.decoyOf, a.id)
    }

    func testAPresenceFromBeforeTheFindDoesNotBringTheCopyBack() async {
        let t = await adjacentCopy()
        t.c.showDecoyFound(from: t.m.id, copied: t.m.id)
        XCTAssertNil(t.scene.decoyTile)
        // The host's presence has not caught up yet: it still carries the copy with the same since.
        await settle()
        t.c.advanceDitto(now: t.since.addingTimeInterval(0.05))
        XCTAssertNil(t.scene.decoyTile, "the stale copy is not drawn again")
        XCTAssertNil(t.c.shownDitto?.decoyOf)
        // The host later turns back, rests, and copies again: a new since is shown.
        let later = t.since.addingTimeInterval(300)
        host(t.a, dittoForm(beside(), now: later).copying(t.m.id, now: later))
        await settle()
        t.c.advanceDitto(now: later)
        XCTAssertEqual(t.scene.decoyTile, beside())
    }

    func testTheHostTurnsBackOnAReceivedFind() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(beside(), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        XCTAssertTrue(c.isDittoHost)
        XCTAssertEqual(c.shownDitto?.decoyOf, m.id)
        c.showDecoyFound(from: m.id, copied: m.id)
        c.advanceDitto(now: now.addingTimeInterval(0.1))
        await settle()
        let sent = try? XCTUnwrap(a.session.members[me.id]?.ditto)
        XCTAssertNil(sent?.decoyOf)
        XCTAssertEqual(sent?.restUntil?.timeIntervalSinceReferenceDate ?? 0,
                       Date().addingTimeInterval(PlazaDitto.restDuration).timeIntervalSinceReferenceDate, accuracy: 5)
    }

    func testGreetingTheCopyLooksLikeGreetingTheRealOne() async {
        let t = await adjacentCopy()
        let log = emotes(from: t.m)
        t.c.chooseMenu(.greet, memberID: key)
        await settle()
        XCTAssertNotNil(t.scene.shownEmote(memberID: nil))
        XCTAssertEqual(t.scene.shownEmote(memberID: key), t.scene.shownEmote(memberID: nil))
        XCTAssertEqual(log.items.count, 1)
        XCTAssertNil(log.items.first?.targetMemberID, "the real one is not told")
        XCTAssertEqual(log.items.first?.overDecoy, true)
    }

    func testHeartAtTheCopyHasNoTarget() async {
        let t = await adjacentCopy()
        let log = emotes(from: t.m)
        t.scene.onEmoteKey?(.heart)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.heart])
        XCTAssertNil(log.items.first?.targetMemberID)
    }

    func testClickingTheCopiedMemberInTheRosterAsksInsteadOfWalking() async {
        let t = await adjacentCopy()
        let log = emotes(from: t.a)
        t.c.walkToMember(t.m.id)
        await settle()
        XCTAssertNil(t.scene.walkingToMember)
        XCTAssertEqual(t.scene.shownEmote(memberID: nil), .question)
        XCTAssertEqual(log.items.map(\.kind), [.question])
        XCTAssertNil(log.items.first?.targetMemberID)
    }

    func testClickingAnotherMemberStillWalks() async {
        let t = await adjacentCopy()
        t.c.walkToMember(t.a.id)
        XCTAssertEqual(t.scene.walkingToMember, t.a.id)
    }

    func testSpaceAndTackleDoNothingOnDittoForm() async {
        let nodes = sorted(2)
        let (a, me) = (nodes[0], nodes[1])
        await connect(a, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        host(a, dittoForm(beside()))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNotNil(c.scene?.dittoTile)
        let log = emotes(from: a)
        c.scene?.onInteractKey?()
        XCTAssertEqual(c.overlayContent, .none)
        c.scene?.onTackleKey?()
        c.scene?.onGreetKey?()
        c.scene?.onEmoteKey?(.heart)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.heart], "only the bubble goes out, aimed at nobody")
        XCTAssertNil(log.items.first?.targetMemberID)
        XCTAssertNil(c.banner)
    }

    func testSpaceOnTheCopyOpensTheCopiedMembersMenu() async {
        let t = await adjacentCopy()
        t.scene.onInteractKey?()
        guard case .memberMenu(let menu) = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        XCTAssertEqual(menu.memberID, key)
        XCTAssertEqual(menu.nickname, t.m.settings.nickname)
        XCTAssertTrue(menu.actions.contains(.viewCard))
        t.c.chooseMenu(.follow, memberID: key)
        XCTAssertEqual(t.scene.followingMember, key)
    }

    func testAMenuOnACopyThatTurnedBackDoesNothing() async {
        for action in [PlazaMemberAction.follow, .greet, .tackle, .viewCard] {
            let t = await adjacentCopy()
            t.scene.onInteractKey?()
            guard case .memberMenu = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
            let log = emotes(from: t.m)
            let now = t.since.addingTimeInterval(1)
            host(t.a, dittoForm(beside(), now: now))
            await settle()
            t.c.advanceDitto(now: now)
            XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "test precondition")
            t.c.chooseMenu(action, memberID: key)
            await settle()
            XCTAssertEqual(t.c.overlayContent, .none, "\(action)")
            XCTAssertNil(t.scene.followingMember, "\(action)")
            XCTAssertTrue(log.items.isEmpty, "\(action)")
        }
    }

    func testTheMenuOnMyOwnCopyHasNoCard() async {
        let t = await adjacentCopy(ofMe: true, nickname: "재헌")
        t.scene.onInteractKey?()
        guard case .memberMenu(let menu) = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        XCTAssertEqual(menu.nickname, "재헌")
        XCTAssertFalse(menu.actions.contains(.viewCard))
        XCTAssertTrue(menu.actions.contains(.tackle))
    }

    // MARK: - The hints must not give the copy away

    func testTheHintOnTheCopyIsTheHintOnTheRealMember() async {
        let t = await adjacentCopy()
        XCTAssertEqual(t.c.hint, L(.ko).plazaMemberHint(nickname: t.m.settings.nickname))
        let mine = await adjacentCopy(ofMe: true, nickname: "재헌")
        XCTAssertEqual(mine.c.hint, L(.ko).plazaMemberHint(nickname: "재헌"))
    }

    func testFollowingTheCopyShowsTheFollowLine() async {
        let t = await adjacentCopy()
        t.c.chooseMenu(.follow, memberID: key)
        XCTAssertEqual(t.scene.followingMember, key)
        XCTAssertEqual(t.c.hint, L(.ko).plazaFollowHint(nickname: t.m.settings.nickname))
    }

    func testFacingTheDittoFormShowsNoHint() async {
        let nodes = sorted(2)
        let (a, me) = (nodes[0], nodes[1])
        await connect(a, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        host(a, dittoForm(beside()))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNotNil(c.scene?.dittoTile)
        XCTAssertNil(c.hint)
    }

    func testADecoyJumpFromANonHostIsIgnored() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(beside(), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        let scene = c.scene!
        c.showDecoyJump(from: m.id)
        scene.update(0.01)
        XCTAssertEqual(scene.dustCount, 0, "m is not the host")
        c.showDecoyJump(from: a.id)
        XCTAssertGreaterThan(scene.dustCount, 0, "the host's jump hops the copy")
    }

    func testTheHostsCopyJumpsAreSent() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        var now = Date()
        host(a, dittoForm(beside(), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        let log = emotes(from: m)
        var jumped = false
        for _ in 0..<12_000 where !jumped {
            now = now.addingTimeInterval(0.05)
            c.advanceDitto(now: now)
            guard c.shownDitto?.isDecoy == true else { break }
            c.scene?.update(0)
            jumped = c.scene?.dustCount ?? 0 > 0
        }
        XCTAssertTrue(jumped, "the host's copy hopped")
        await settle()
        XCTAssertEqual(log.items.filter { $0.kind == .decoyJump }.count, 1)
        XCTAssertNil(log.items.first { $0.kind == .decoyJump }?.targetMemberID)
    }
}
