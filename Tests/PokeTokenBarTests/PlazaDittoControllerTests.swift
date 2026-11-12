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
    /// When set, sessions made by `node` read this time (the clock-skew check on a received Ditto compares against it).
    private var sessionNow: Date?

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
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: current, dex: []) },
                                  clock: { [unowned self] in sessionNow ?? Date() })
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
                            seed: UInt64 = 7, nickname: String = "나", start: TilePoint? = nil,
                            myEntry: PlazaRosterEntry? = nil, clock: @escaping () -> Date = Date.init) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        if let start { prefs.saveLastTile(start) }
        return PlazaWindowController(preferences: prefs,
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: { nickname }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { myEntry }, session: me.session, clock: clock,
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

    // MARK: - Dancing along

    /// [host a, me, member m]: a hosts the Ditto (the resting Ditto form, or a copy of a) on `ditto`; m stands on `dancer`.
    @MainActor private struct Dance {
        let c: PlazaWindowController, a: Node, me: Node, m: Node
        var scene: PlazaScene { c.scene! }
    }

    private func dancing(ditto: TilePoint, dancer: TilePoint, copy: Bool = false) async -> Dance {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        place(m, at: dancer)
        let now = Date()
        let form = dittoForm(ditto, now: now).turnedBack(now: now)
        host(a, copy ? form.copying(a.id, now: now) : form)
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(c.scene?.dittoTile, ditto, "test precondition")
        XCTAssertEqual(c.shownDitto?.isDecoy, copy, "test precondition")
        return Dance(c: c, a: a, me: me, m: m)
    }

    func testTheDittoDancesAlongWithADancerAroundIt() async {
        let t = await dancing(ditto: ground(4, 0), dancer: ground(5, 1))
        t.c.showDance(memberID: t.m.id, style: "spin")
        XCTAssertTrue(t.scene.isDancing(memberID: t.m.id), "test precondition")
        XCTAssertTrue(t.scene.isDancing(memberID: key))
        XCTAssertEqual(t.scene.danceStyle(memberID: key), .spin)
        // The next round's style follows too.
        t.c.showDance(memberID: t.m.id, style: "twirl")
        XCTAssertEqual(t.scene.danceStyle(memberID: key), .twirl)
    }

    func testADancerTwoTilesAwayIsNotFollowed() async {
        let t = await dancing(ditto: ground(4, 0), dancer: ground(6, 0))
        t.c.showDance(memberID: t.m.id, style: "spin")
        XCTAssertTrue(t.scene.isDancing(memberID: t.m.id), "test precondition")
        XCTAssertFalse(t.scene.isDancing(memberID: key))
    }

    func testTheCopyDancesAlongToo() async {
        let t = await dancing(ditto: ground(4, 0), dancer: ground(4, 1), copy: true)
        t.c.showDance(memberID: t.m.id, style: "bounce")
        XCTAssertTrue(t.scene.isDancing(memberID: key))
        XCTAssertEqual(t.scene.danceStyle(memberID: key), .bounce)
    }

    func testTheDittoDancesAlongWithMe() async {
        let nodes = sorted(2)
        let (a, me) = (nodes[0], nodes[1])
        await connect(a, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        let now = Date()
        host(a, dittoForm(beside(), now: now).turnedBack(now: now))
        await settle()
        c.advanceDitto(now: now)
        let scene = c.scene!
        _ = scene.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false)   // D
        XCTAssertTrue(scene.isDancing(memberID: nil), "test precondition")
        XCTAssertTrue(scene.isDancing(memberID: key))
        XCTAssertEqual(scene.danceStyle(memberID: key), scene.danceStyle(memberID: nil))
    }

    // MARK: - Dancing the same dance as a teammate (here for this file's nodes sorted by ID)

    /// [a, me, z] by ID. `near` stands on `tile`; the other one is far away.
    @MainActor private final class Together {
        var now = Date()
        var c: PlazaWindowController!, a: Node!, me: Node!, z: Node!
        var scene: PlazaScene { c.scene! }
        func d() { _ = scene.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false) }
    }

    private func together(aAt: TilePoint? = nil, zAt: TilePoint? = nil) async -> Together {
        let t = Together()
        let nodes = sorted(3)
        (t.a, t.me, t.z) = (nodes[0], nodes[1], nodes[2])
        await connect(t.a, t.me); await connect(t.z, t.me)
        t.c = controller(t.me, start: meStart.me, clock: { t.now })
        t.c.prepareScene()
        t.scene.now = { t.now }
        t.scene.pickDanceStyle = { _ in .bounce }
        place(t.a, at: aAt ?? ground(-5, 0))
        place(t.z, at: zAt ?? ground(8, 8))
        await settle()
        return t
    }

    func testIDanceTheDanceOfANearbyDancerWhoBeganBeforeMeRoundAfterRound() async {
        let t = await together(zAt: beside())
        let sent = emotes(from: t.a)
        t.c.showDance(memberID: t.z.id, style: "spin", since: t.now)
        XCTAssertFalse(t.scene.isDancing(memberID: nil), "their dance alone does not start mine")
        t.now += 0.5
        let began = t.now
        t.d()
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin)
        t.now += PlazaDance.round - 0.5
        t.c.showDance(memberID: t.z.id, style: "twirl", since: began.addingTimeInterval(-0.5))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .twirl)
        await settle()
        let dances = sent.items.filter { $0.kind == .dance }
        XCTAssertEqual(dances.map(\.danceStyle), ["spin", "twirl"], "others see the dance I do")
        XCTAssertEqual(dances.map(\.danceSince), [began.timeIntervalSince1970, began.timeIntervalSince1970],
                       "every round carries when I began, so every Mac ranks me the same")
    }

    func testADancerWhoBeganAfterMeFollowsMeNotTheOtherWayRound() async {
        let t = await together(aAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.a.id, style: "spin", since: t.now)
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
        t.now += PlazaDance.round
        t.c.showDance(memberID: t.a.id, style: "twirl", since: t.now.addingTimeInterval(-PlazaDance.round))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
    }

    /// My round ends and the next one starts by itself: I still began first, so I pick a new dance instead of taking theirs.
    func testILeadThroughMyNextRoundToo() async {
        let t = await together(aAt: beside())
        var picks: [PlazaDance.Style] = [.bounce, .twirl]
        t.scene.pickDanceStyle = { _ in picks.removeFirst() }
        var clock: TimeInterval = 0
        t.scene.update(clock)
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.a.id, style: "bounce", since: t.now)
        while picks.count == 1, clock < 3 {
            clock += 0.05; t.now += 0.05
            t.scene.update(clock)
        }
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .twirl)
    }

    /// Two Macs that began within the network delay each saw their own dance first. What they sent settles it.
    func testWhenTheyBeganDecidesNotWhenTheirNewsArrived() async {
        let t = await together(zAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.z.id, style: "spin", since: t.now.addingTimeInterval(-1))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin)
    }

    func testBeginningAtTheSameInstantTheSmallerIDLeads() async {
        let t = await together(aAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.a.id, style: "spin", since: t.now.addingTimeInterval(-0.5))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin)
    }

    func testBeginningAtTheSameInstantALargerIDFollowsMe() async {
        let t = await together(zAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.z.id, style: "spin", since: t.now.addingTimeInterval(-0.5))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
    }

    /// 2.5.625 and earlier send no start time, so their dance began when it started on my screen, and stays so each round.
    func testADancerWhoSendsNoStartTimeBeganWhenTheirDanceStartedHere() async {
        let t = await together(zAt: beside())
        t.c.showDance(memberID: t.z.id, style: "spin")
        t.now += 0.5
        t.d()
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin, "they began first")
        t.now += PlazaDance.round - 0.5
        t.c.showDance(memberID: t.z.id, style: "twirl")
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .twirl, "a later round does not make them begin later")
        // They stop, and begin again after me: now I began first.
        t.c.stopDance(memberID: t.z.id)
        t.now += 0.5
        t.c.showDance(memberID: t.z.id, style: "sway")
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .twirl)
    }

    func testAfterIStopAndDanceAgainIFollowWhoeverKeptDancing() async {
        let t = await together(aAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.a.id, style: "spin", since: t.now)
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce, "test precondition: I lead")
        t.scene.stopDance(memberID: nil)
        t.now += 0.5
        t.d()
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin)
    }

    /// A modified app can send any start time. The far past only makes it the one to follow; the far future makes it follow.
    func testAnAbsurdStartTimeOnlyDecidesWhoLeads() async {
        let t = await together(zAt: beside())
        t.d()
        t.now += 0.5
        t.c.showDance(memberID: t.z.id, style: "spin", since: Date(timeIntervalSince1970: 1.7e308))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
        t.now += 0.5
        t.c.showDance(memberID: t.z.id, style: "twirl", since: Date(timeIntervalSince1970: -1.7e308))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .twirl)
    }

    func testADancerThreeTilesAwayIsNotFollowed() async {
        let far = TilePoint(x: meStart.me.x + PlazaDance.togetherRange + 1, y: meStart.me.y)
        let t = await together(aAt: far)
        t.c.showDance(memberID: t.a.id, style: "spin", since: t.now)
        XCTAssertTrue(t.scene.isDancing(memberID: t.a.id), "test precondition")
        t.now += 0.5
        t.d()
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
        t.now += PlazaDance.round
        t.c.showDance(memberID: t.a.id, style: "twirl", since: t.now.addingTimeInterval(-PlazaDance.round - 0.5))
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce)
    }

    /// Their round can arrive while they still finish a step on my screen, so their own dance has not started yet.
    func testALeaderStillFinishingAStepIsFollowedAtOnce() async {
        let t = await together(aAt: TilePoint(x: beside().x + 1, y: beside().y))
        t.d()
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .bounce, "test precondition: nobody to follow yet")
        t.a.session.updatePlazaPosition(inPlaza: true, tile: beside(), facing: .left, isWalking: true)
        await settle()
        t.now += PlazaDance.round
        t.c.showDance(memberID: t.a.id, style: "spin", since: t.now.addingTimeInterval(-PlazaDance.round - 1))
        XCTAssertFalse(t.scene.isDancing(memberID: t.a.id), "test precondition")
        XCTAssertEqual(t.scene.danceStyle(memberID: nil), .spin)
    }

    /// The host holds the dancing Ditto still while a dancer keeps going, and lets it wander once the dancing stops.
    /// `hidden`: the host's plaza window is covered, so its scene draws nothing, but other Macs still show the dance.
    /// `local`: I am the dancer (D every round) instead of m.
    private func assertTheHostHoldsADancingDitto(hidden: Bool = false, local: Bool = false,
                                                 file: StaticString = #filePath, line: UInt = #line) async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        var now = Date()
        let c = controller(me, start: meStart.me, clock: { now })
        c.prepareScene()
        c.scene?.now = { now }
        let ditto = local ? beside() : ground(4, 0)
        place(m, at: local ? ground(-5, 0) : ground(5, 1))
        host(a, dittoForm(ditto, now: now).turnedBack(now: now))
        await settle()
        c.advanceDitto(now: now)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        now += 0.05
        c.advanceDitto(now: now)
        XCTAssertTrue(c.isDittoHost, "test precondition", file: file, line: line)
        if hidden { c.setRendering(visible: false) }
        // A round every 1.6 s for 12 s, longer than any wait before the Ditto's next walk (2–6 s).
        var next = now
        let end = now.addingTimeInterval(12)
        while now < end {
            if now >= next {
                if local { _ = c.scene?.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false) }
                else { c.showDance(memberID: m.id, style: "sway") }
                next += PlazaDance.round
            }
            now += 0.1
            c.advanceDitto(now: now)
            XCTAssertEqual(c.shownDitto?.tile, ditto, "held at \(12 - end.timeIntervalSince(now))", file: file, line: line)
        }
        if local { XCTAssertTrue(c.scene?.isDancing(memberID: nil) == true, "test precondition", file: file, line: line) }
        // The rounds stop: the Ditto wanders again.
        let free = now.addingTimeInterval(8)
        while now < free, c.shownDitto?.tile == ditto { now += 0.1; c.advanceDitto(now: now) }
        XCTAssertNotEqual(c.shownDitto?.tile, ditto, file: file, line: line)
    }

    func testTheHostKeepsADancingDittoStill() async { await assertTheHostHoldsADancingDitto() }

    func testAHiddenHostStillKeepsADancingDittoStill() async { await assertTheHostHoldsADancingDitto(hidden: true) }

    func testTheHostKeepsTheDittoStillWhileIDance() async { await assertTheHostHoldsADancingDitto(local: true) }

    /// On my screen the dancer may still be finishing a step when their round arrives: their own dance waits for the step,
    /// and the Ditto follows at once rather than a round later.
    func testADancerFinishingAStepIsFollowedAtOnce() async {
        let t = await dancing(ditto: ground(4, 0), dancer: ground(5, 1))
        t.m.session.updatePlazaPosition(inPlaza: true, tile: ground(5, 0), facing: .up, isWalking: true)   // a step, both tiles in range
        await settle()
        t.c.showDance(memberID: t.m.id, style: "spin")
        XCTAssertFalse(t.scene.isDancing(memberID: t.m.id), "test precondition: the dancer's own dance waits for the step")
        XCTAssertTrue(t.scene.isDancing(memberID: key))
        XCTAssertEqual(t.scene.danceStyle(memberID: key), .spin)
    }

    func testAFormChangeStopsTheDittosDance() async {
        // Found: the copy dancing with me turns back.
        let t = await adjacentCopy()
        _ = t.scene.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false)
        XCTAssertTrue(t.scene.isDancing(memberID: key), "test precondition")
        t.c.showDecoyFound(from: t.m.id, copied: t.m.id)
        XCTAssertNil(t.c.shownDitto?.decoyOf, "test precondition")
        XCTAssertFalse(t.scene.isDancing(memberID: key))
        // Transformed: the dancing Ditto form becomes a copy where it stands.
        let d = await dancing(ditto: ground(4, 0), dancer: ground(5, 1))
        d.c.showDance(memberID: d.m.id, style: "spin")
        XCTAssertTrue(d.scene.isDancing(memberID: key), "test precondition")
        let now = Date().addingTimeInterval(1)
        host(d.a, dittoForm(ground(4, 0), now: now).copying(d.a.id, now: now))
        await settle()
        d.c.advanceDitto(now: now)
        XCTAssertEqual(d.c.shownDitto?.decoyOf, d.a.id, "test precondition")
        XCTAssertFalse(d.scene.isDancing(memberID: key))
    }

    func testTheCopysHopStopsItsDance() async {
        let t = await adjacentCopy()
        _ = t.scene.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false)
        XCTAssertTrue(t.scene.isDancing(memberID: key), "test precondition")
        t.c.showDecoyJump(from: t.a.id)
        XCTAssertFalse(t.scene.isDancing(memberID: key))
    }

    /// A host's state that puts the Ditto somewhere else (a snap, not a walk) ends its dance there.
    func testASnappedDittoStopsDancing() async {
        let t = await dancing(ditto: ground(4, 0), dancer: ground(5, 1))
        t.c.showDance(memberID: t.m.id, style: "spin")
        XCTAssertTrue(t.scene.isDancing(memberID: key), "test precondition")
        let now = Date().addingTimeInterval(1)
        var moved = dittoForm(ground(-5, 0), now: now).turnedBack(now: now)
        moved.since = t.c.shownDitto?.since ?? now
        moved.restUntil = t.c.shownDitto?.restUntil
        host(t.a, moved)
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.scene.dittoTile, ground(-5, 0), "test precondition")
        XCTAssertFalse(t.scene.isDancing(memberID: key))
    }

    // MARK: - Finding the copy

    /// [host a, me, member m] with a hosting a copy of `copied` right beside me (spawn, one tile right).
    @MainActor private struct Adjacent {
        let c: PlazaWindowController, a: Node, me: Node, m: Node, since: Date
        var scene: PlazaScene { c.scene! }
    }

    private func adjacentCopy(ofMe: Bool = false, nickname: String = "나", now: Date = Date(),
                              myEntry: PlazaRosterEntry? = nil) async -> Adjacent {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me, nickname: nickname, start: meStart.me, myEntry: myEntry)
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
        t.scene.onInteractKey?()
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

    /// [host a, me] with a hosting the Ditto form right beside me, resting so it does not copy me on its own.
    private func adjacentDittoForm(now: Date = Date()) async -> (c: PlazaWindowController, a: Node, me: Node) {
        let nodes = sorted(2)
        let (a, me) = (nodes[0], nodes[1])
        await connect(a, me)
        let c = controller(me, start: meStart.me)
        c.prepareScene()
        host(a, dittoForm(beside(), now: now).turnedBack(now: now))
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(c.scene?.dittoTile, beside(), "test precondition")
        XCTAssertEqual(c.shownDitto?.isDecoy, false, "test precondition")
        return (c, a, me)
    }

    func testSpaceOnTheDittoFormOffersOnlyTackle() async {
        let t = await adjacentDittoForm()
        t.c.scene?.onInteractKey?()
        guard case .memberMenu(let menu) = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        XCTAssertEqual(menu.memberID, key)
        XCTAssertEqual(menu.nickname, L(.ko).plazaDittoName)
        XCTAssertEqual(menu.actions, [.tackle])
        XCTAssertEqual(menu.selection, .tackle)
    }

    /// Diving takes tackle away, and the Ditto form has nothing else: Space opens no empty menu.
    func testSpaceOnTheDittoFormWhileDivingOpensNothing() async throws {
        // A shore tile with water on one side: I start there, get pushed into the water, and the Ditto takes the shore.
        var pair: (shore: TilePoint, toWater: PlazaDirection)?
        search: for y in 0..<map.height { for x in 0..<map.width {
            let g = TilePoint(x: x, y: y)
            guard PlazaDitto.isGround(g, in: map) else { continue }
            if let d = PlazaDirection.allCases.first(where: { map.isWater(PlazaWalker.offset(g, $0)) }) { pair = (g, d); break search }
        } }
        let (shore, toWater) = try XCTUnwrap(pair)
        let back: PlazaDirection = switch toWater { case .up: .down; case .down: .up; case .left: .right; case .right: .left }
        let nodes = sorted(2)
        let (a, me) = (nodes[0], nodes[1])
        await connect(a, me)
        let c = controller(me, start: shore)
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        scene.isPaused = true   // a paused scene lands the push at once
        scene.pushMe(toWater)
        scene.isPaused = false
        XCTAssertTrue(scene.isMeInWater, "test precondition")
        let now = Date()
        host(a, dittoForm(shore, now: now).turnedBack(now: now))
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(scene.dittoTile, shore, "test precondition")
        scene.face(back)
        scene.setDiving(true)
        XCTAssertTrue(scene.isDiving, "test precondition")
        scene.onInteractKey?()
        XCTAssertEqual(c.overlayContent, .none)
        scene.setDiving(false)
        scene.onInteractKey?()
        guard case .memberMenu = c.overlayContent else { return XCTFail("control: surfaced, the menu opens") }
    }

    func testGreetAndBubblesStillSkipTheDittoForm() async {
        let t = await adjacentDittoForm()
        let log = emotes(from: t.a)
        t.c.scene?.onGreetKey?()
        XCTAssertNil(t.c.scene?.shownEmote(memberID: key), "X does not greet the Ditto form")
        t.c.scene?.onEmoteKey?(.heart)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.heart], "only the bubble goes out, aimed at nobody")
        XCTAssertNil(log.items.first?.targetMemberID)
        XCTAssertNil(log.items.first?.overDecoy)
        XCTAssertNil(t.c.banner)
    }

    /// A non-host's tackle goes to the host, aimed at the Ditto and pushing nobody. Nothing is found.
    func testTacklingTheDittoFormAsksTheHostToCopyMe() async {
        let t = await adjacentDittoForm()
        let log = emotes(from: t.a)
        t.c.scene?.onTackleKey?()
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertEqual(log.items.first?.targetMemberID, key)
        XCTAssertNil(log.items.first?.pushTiles)
        XCTAssertNil(t.c.banner)
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "the host decides")
    }

    func testTackleFromTheDittoFormMenu() async {
        let t = await adjacentDittoForm()
        let log = emotes(from: t.a)
        t.c.scene?.onInteractKey?()
        t.c.chooseMenu(.tackle, memberID: key)
        await settle()
        XCTAssertEqual(t.c.overlayContent, .none)
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertEqual(log.items.first?.targetMemberID, key)
    }

    /// A menu opened on the Ditto form does nothing once the Ditto has become someone: the tackle would otherwise find it.
    func testAMenuOnTheDittoFormThatBecameACopyDoesNothing() async {
        let t = await adjacentDittoForm()
        t.c.scene?.onInteractKey?()
        guard case .memberMenu = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        let log = emotes(from: t.a)
        let now = Date().addingTimeInterval(1)
        host(t.a, dittoForm(beside(), now: now).copying(t.me.id, now: now))
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.me.id, "test precondition")
        t.c.chooseMenu(.tackle, memberID: key)
        await settle()
        XCTAssertEqual(t.c.overlayContent, .none)
        XCTAssertTrue(log.items.isEmpty)
        XCTAssertNil(t.c.banner)
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.me.id)
    }

    /// The finder turns the copy back with its own clock; the host's state then brings the same Ditto form with the host's
    /// `since`. A menu opened on the Ditto form in between still works: it is still the Ditto form.
    func testAMenuOnTheDittoFormSurvivesTheHostRestampingIt() async {
        let t = await adjacentDittoForm()
        t.c.scene?.onInteractKey?()
        guard case .memberMenu = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        let log = emotes(from: t.a)
        let now = Date().addingTimeInterval(0.4)
        host(t.a, dittoForm(beside(), now: now).turnedBack(now: now))
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.shownDitto?.since, now, "test precondition")
        t.c.chooseMenu(.tackle, memberID: key)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertEqual(log.items.first?.targetMemberID, key)
    }

    /// A menu opened on m's copy does nothing once the Ditto copies someone else: its name and card would be wrong.
    func testAMenuOnACopyThatNowCopiesSomeoneElseDoesNothing() async {
        let t = await adjacentCopy()
        t.scene.onInteractKey?()
        guard case .memberMenu = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        let log = emotes(from: t.m)
        let now = t.since.addingTimeInterval(1)
        host(t.a, dittoForm(beside(), now: now).copying(t.a.id, now: now))
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.a.id, "test precondition")
        t.c.chooseMenu(.tackle, memberID: key)
        await settle()
        XCTAssertEqual(t.c.overlayContent, .none)
        XCTAssertTrue(log.items.isEmpty)
        XCTAssertNil(t.c.banner)
    }

    /// The copy turns back on the tile I face: the hint follows at once, though my target tile did not change.
    func testTheHintFollowsAFormChangeOnTheSameTile() async {
        let t = await adjacentCopy()
        XCTAssertEqual(t.c.hint, L(.ko).plazaMemberHint(nickname: t.m.settings.nickname), "test precondition")
        t.scene.onTackleKey?()
        XCTAssertNil(t.c.shownDitto?.decoyOf, "test precondition")
        XCTAssertEqual(t.c.hint, L(.ko).plazaMemberHint(nickname: L(.ko).plazaDittoName))
    }

    /// [me host, m]: the host's Ditto form rests right beside me; m stands away from it.
    private func hostingDittoForm(now: Date = Date(), seed: UInt64 = 7, resting: Bool = true,
                                  clock: @escaping () -> Date = Date.init) async -> (c: PlazaWindowController, me: Node, m: Node) {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me, seed: seed, start: meStart.me, clock: clock)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        host(a, resting ? dittoForm(beside(), now: now).turnedBack(now: now) : dittoForm(beside(), now: now))
        await settle()
        c.advanceDitto(now: now)
        // a leaves; I carry the resting Ditto form on.
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        XCTAssertTrue(c.isDittoHost, "test precondition")
        XCTAssertEqual(c.shownDitto?.isDecoy, false, "test precondition")
        XCTAssertEqual(c.shownDitto?.restUntil != nil, resting, "test precondition")
        return (c, me, m)
    }

    func testTheHostTurnsTheDittoFormIntoWhoeverTackledIt() async {
        let t = await hostingDittoForm()
        // I stand right beside it, yet m's tackle wins.
        t.c.showTackle(from: t.m.id, on: key)
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.m.id)
        XCTAssertEqual(t.c.scene?.decoyTile, beside())
        XCTAssertEqual(t.c.scene?.memberName(key), t.m.settings.nickname)
        XCTAssertNil(t.c.banner)
        await settle()
        XCTAssertEqual(t.m.session.members[t.me.id]?.ditto?.decoyOf, t.m.id, "the new copy is sent at once")
    }

    /// Someone the Ditto can't copy (an egg, idle, focusing, or not ready) tackles it: the hit shows, nothing else changes.
    func testATackleBySomeoneWhoCannotBeCopiedLeavesTheDittoForm() async {
        let t = await hostingDittoForm()
        place(t.m, at: ground(-5, 0), ready: false)
        await settle()
        let before = t.c.shownDitto
        t.c.showTackle(from: t.m.id, on: key)
        XCTAssertEqual(t.c.shownDitto, before)
        XCTAssertEqual(t.c.scene?.children.filter { $0.name == "tackle-impact" }.count, 1)
    }

    /// Whether a tackle from beside it copies or bounces is the brain's draw: seed 1 copies, seed 7 bounces.
    func testTheHostsOwnTackleSometimesBouncesTheDittoFormAway() async {
        let now = Date()
        let t = await hostingDittoForm(now: now, seed: 7)
        t.c.scene?.onTackleKey?()
        XCTAssertEqual(t.c.shownDitto?.isBouncing, true)
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false)
        XCTAssertNil(t.c.banner)
        t.c.advanceDitto(now: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(hop(t.c), 0, "it hops as it goes")
        XCTAssertEqual(t.c.shownDitto?.tile, TilePoint(x: beside().x + 1, y: beside().y), "away from me")
        await settle()
        XCTAssertEqual(t.m.session.members[t.me.id]?.ditto?.isBouncing, true, "teammates are told it bounces")
    }

    /// The real case: I walk up to a Ditto that is not resting. It does not copy me at once, so my tackle is what decides.
    func testATackleRightAfterWalkingUpToAFreshDittoStillBouncesIt() async {
        var now = Date()
        let t = await hostingDittoForm(now: now, seed: 7, resting: false, clock: { now })
        for _ in 0..<10 { now += 0.05; t.c.advanceDitto(now: now) }
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "half a second beside it is not enough to be copied")
        XCTAssertEqual(t.c.shownDitto?.tile, beside(), "and it stays to be tackled")
        t.c.scene?.onTackleKey?()
        XCTAssertEqual(t.c.shownDitto?.isBouncing, true)
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false)
    }

    /// Standing beside a fresh Ditto for the copy delay is what gets me copied.
    func testAFreshDittoCopiesMeAfterIStandBesideItForTheDelay() async {
        var now = Date()
        let t = await hostingDittoForm(now: now, resting: false, clock: { now })
        let start = now
        while now.timeIntervalSince(start) < PlazaDittoBrain.copyDelay - 0.2 { now += 0.05; t.c.advanceDitto(now: now) }
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false)
        while now.timeIntervalSince(start) < PlazaDittoBrain.copyDelay + 0.3 { now += 0.05; t.c.advanceDitto(now: now) }
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.me.id)
    }

    /// I dance beside a fresh Ditto: it dances along in its own form for as long as I keep going, and copies me only after
    /// I have stopped and stayed for the delay.
    func testAFreshDittoDancingAlongWithMeDoesNotCopyMe() async {
        var now = Date()
        let t = await hostingDittoForm(now: now, resting: false, clock: { now })
        t.c.scene?.now = { now }
        var next = now, lastRound = now
        let end = now.addingTimeInterval(10)
        while now < end {
            if now >= next {
                _ = t.c.scene?.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false)
                lastRound = now
                next += PlazaDance.round
            }
            now += 0.05
            t.c.advanceDitto(now: now)
            XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "at \(10 - end.timeIntervalSince(now))")
        }
        XCTAssertTrue(t.c.scene?.isDancing(memberID: key) == true)
        XCTAssertEqual(t.c.shownDitto?.tile, beside())
        // The dancing stops: the hold runs out a round and its grace after my last round, and the delay starts from there.
        let held = lastRound.addingTimeInterval(PlazaDitto.danceHold)
        while now < held.addingTimeInterval(PlazaDittoBrain.copyDelay - 0.3) {
            now += 0.05; t.c.advanceDitto(now: now)
            XCTAssertEqual(t.c.shownDitto?.isDecoy, false)
        }
        while now < held.addingTimeInterval(PlazaDittoBrain.copyDelay + 0.3) { now += 0.05; t.c.advanceDitto(now: now) }
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.me.id)
    }

    private func hop(_ c: PlazaWindowController) -> CGFloat {
        c.scene?.update(0)
        c.scene?.update(0.1)
        return c.scene?.jumpLift(memberID: key) ?? 0
    }

    func testTheHostsBouncingDittoHopsOnMyScreenToo() async {
        let now = Date()
        let t = await adjacentDittoForm(now: now)
        var s = dittoForm(TilePoint(x: beside().x + 1, y: beside().y), now: now).turnedBack(now: now)
        s.isBouncing = true
        host(t.a, s)
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertGreaterThan(hop(t.c), 0)
    }

    /// A step is shorter than a hop. The next step does not start the hop over while the Ditto is still in the air.
    func testAHopIsNotCutShortByTheNextStep() async {
        let now = Date()
        let t = await adjacentDittoForm(now: now)
        var s = dittoForm(TilePoint(x: beside().x + 1, y: beside().y), now: now).turnedBack(now: now)
        s.isBouncing = true
        host(t.a, s)
        await settle()
        t.c.advanceDitto(now: now)
        let lift = hop(t.c)
        s.tile = TilePoint(x: beside().x + 2, y: beside().y)
        host(t.a, s)
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.scene?.jumpLift(memberID: key), lift)
    }

    /// Frames an honest host does not send: a bounce without a step, and a bouncing copy. Neither hops.
    func testABounceWithoutAStepOrOnACopyDoesNotHop() async {
        let now = Date()
        let t = await adjacentDittoForm(now: now)
        var s = dittoForm(beside(), now: now).turnedBack(now: now)
        s.isBouncing = true
        host(t.a, s)
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.shownDitto?.isBouncing, true, "test precondition")
        XCTAssertEqual(hop(t.c), 0, "it stands where it stood")

        var copy = dittoForm(TilePoint(x: beside().x + 1, y: beside().y), now: now).copying(t.me.id, now: now)
        copy.isBouncing = true
        host(t.a, copy)
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(hop(t.c), 0, "a copy never bounces")
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.decoyTile, TilePoint(x: beside().x + 1, y: beside().y), "the copy did move")
    }

    func testTheHostsOwnTackleTurnsTheDittoFormIntoMe() async {
        let t = await hostingDittoForm(seed: 1)
        let log = emotes(from: t.m)
        t.c.scene?.onTackleKey?()
        await settle()
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.me.id)
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertEqual(log.items.first?.targetMemberID, key)
        XCTAssertNil(t.c.banner)
    }

    /// A tackle aimed at the Ditto form that arrives after it became a copy neither finds it nor changes whom it copies.
    func testATackleOnTheDittoFormArrivingAfterItBecameACopyIsIgnored() async {
        let t = await hostingDittoForm()
        t.c.showTackle(from: t.m.id, on: key)
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.m.id, "test precondition")
        let since = t.c.shownDitto?.since
        let impacts = { t.c.scene?.children.filter { $0.name == "tackle-impact" }.count ?? 0 }
        let before = impacts()
        XCTAssertEqual(before, 1, "the first tackle hit the Ditto form")
        t.c.showTackle(from: t.m.id, on: key)
        XCTAssertEqual(impacts(), before, "no hit is drawn on the copy: that would give it away")
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.m.id)
        XCTAssertEqual(t.c.shownDitto?.since, since)
        XCTAssertNil(t.c.banner)
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
        t.scene.onInteractKey?()
        t.c.chooseMenu(.follow, memberID: key)
        XCTAssertEqual(t.scene.followingMember, key)
        XCTAssertEqual(t.c.hint, L(.ko).plazaFollowHint(nickname: t.m.settings.nickname))
    }

    func testFacingTheDittoFormNamesTheDitto() async {
        let t = await adjacentDittoForm()
        XCTAssertEqual(t.c.hint, L(.ko).plazaMemberHint(nickname: L(.ko).plazaDittoName))
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

    // MARK: - Coverage gaps

    /// A copy of me wears my nature title, like my own plate does.
    func testACopyOfMeShowsMyNatureTitle() async {
        let entry = PlazaRosterEntry(id: "me", nickname: "재헌", speciesID: 25, speciesName: "Pikachu", gender: nil, isShiny: false,
                                     presence: .online, isMe: true, nature: .jolly)
        let t = await adjacentCopy(ofMe: true, nickname: "재헌", myEntry: entry)
        XCTAssertEqual(t.scene.memberTitle(key), L(.ko).plazaNatureTitle(.jolly))
    }

    /// "View card" on the copy opens the card of the member it copies, and the request goes to that member.
    func testViewingTheCopysCardLoadsTheCopiedMembersCard() async {
        let t = await adjacentCopy()
        t.scene.onInteractKey?()
        t.c.chooseMenu(.viewCard, memberID: key)
        guard case .card(.loading(let state)) = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        XCTAssertEqual(state.memberID, t.m.id)
        for _ in 0..<200 {
            if case .card(.loaded) = t.c.overlayContent { break }
            await Task.yield()
        }
        guard case .card(.loaded(let loaded, let profile)) = t.c.overlayContent else { return XCTFail("\(t.c.overlayContent)") }
        XCTAssertEqual(loaded.memberID, t.m.id)
        XCTAssertEqual(profile.memberID, t.m.id)
    }

    /// Following the copy stops when the copy turns back (the host found it, or its time ran out).
    func testFollowingTheCopyStopsWhenItTurnsBack() async {
        let t = await adjacentCopy()
        t.scene.onInteractKey?()
        t.c.chooseMenu(.follow, memberID: key)
        XCTAssertEqual(t.scene.followingMember, key, "test precondition")
        let now = t.since.addingTimeInterval(1)
        host(t.a, dittoForm(beside(), now: now))
        await settle()
        t.c.advanceDitto(now: now)
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "test precondition")
        XCTAssertNil(t.scene.followingMember)
    }

    /// With no ready host to follow (the hosts sending a Ditto are not in the plaza), the smaller ID's Ditto is the one shown.
    func testTheSmallerIDsDittoIsShownWhenTwoSendOne() async {
        let trio = sorted(3)
        let (a, b, me) = (trio[0], trio[1], trio[2])
        await connect(a, me); await connect(b, me); await connect(a, b)
        let c = controller(me)
        c.prepareScene()
        let now = Date()
        for (n, tile) in [(a, ground(6, 0)), (b, ground(5, 3))] {
            n.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
            n.session.updateDitto(ready: true, state: dittoForm(tile, now: now))
        }
        await settle()
        c.advanceDitto(now: now)
        XCTAssertFalse(c.isDittoHost, "a smaller ID is sending a Ditto")
        XCTAssertEqual(c.scene?.dittoTile, ground(6, 0))
    }
}

// MARK: - The copy's pranks

/// Row 3 of the map is open ground from x 3 to 44.
extension PlazaDittoControllerTests {
    /// Starts at the real time: the session drops a Ditto state stamped far from its own clock.
    @MainActor private final class Clock { var now = Date() }

    private func row(_ x: Int) -> TilePoint { TilePoint(x: x, y: 3) }

    private func run(_ s: PlazaScene) {
        var t = 0.0
        s.update(t)
        while t < 1 { t += 1.0 / 30; s.update(t) }
    }

    /// `a` hosts a copy of `m` standing at `copyX` on row 3; I stand at x 10 and am not the host.
    private func pranked(copyAt copyX: Int = 11) async -> (c: PlazaWindowController, a: Node, me: Node, m: Node, clock: Clock) {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let clock = Clock()
        let c = controller(me, start: row(10), clock: { clock.now })
        c.prepareScene()
        place(m, at: row(30))
        await moveCopy(c, host: a, of: m, to: copyX, clock: clock)
        return (c, a, me, m, clock)
    }

    private func moveCopy(_ c: PlazaWindowController, host a: Node, of m: Node, to x: Int, clock: Clock) async {
        host(a, dittoForm(row(x), now: clock.now).copying(m.id, now: clock.now))
        await settle()
        c.advanceDitto(now: clock.now)
        run(c.scene!)   // a copy that moved walks there
        XCTAssertEqual(c.scene?.decoyTile, row(x), "test precondition")
    }

    func testTheHostsCopyTacklePushesMeAwayWithoutSayingWhoItWas() async {
        let t = await pranked()
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(9), "one tile away from the copy")
        XCTAssertNil(t.c.banner, "nothing gives the copy away")

        t.clock.now += PlazaWindowController.decoyTackleInterval + 1
        await moveCopy(t.c, host: t.a, of: t.m, to: 10, clock: t.clock)
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(8), "pushed again after the interval")
    }

    func testACopyTackleFromSomeoneWhoIsNotTheHostIsDropped() async {
        let t = await pranked()
        t.c.showDecoyTackle(from: t.m.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(10))
        XCTAssertNil(t.c.banner)
    }

    func testACopyTackleFromACopyThatIsNotBesideMeIsDropped() async {
        let t = await pranked(copyAt: 12)
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(10))
    }

    func testACopyTackleOnSomeoneElseDoesNotMoveMe() async {
        let t = await pranked()
        let below = TilePoint(x: 11, y: 4)   // right under the copy, so the push goes down, where nothing blocks me
        place(t.m, at: below)
        await settle()
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.memberTiles[t.m.id], below)
        t.c.showDecoyTackle(from: t.a.id, on: t.m.id)
        t.c.showDecoyTackle(from: t.a.id, on: nil)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(10))
    }

    func testCopyTacklesPushMeOnceInTheInterval() async {
        let t = await pranked()
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        t.clock.now += PlazaWindowController.decoyTackleInterval - 1
        await moveCopy(t.c, host: t.a, of: t.m, to: 10, clock: t.clock)
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(9), "a host that sends them in a burst moves me once")
    }

    func testNoCopyTackleInPhotoMode() async {
        let t = await pranked()
        _ = t.c.scene?.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(t.c.isPhotoMode)
        t.c.showDecoyTackle(from: t.a.id, on: t.me.id)
        run(t.c.scene!)
        XCTAssertEqual(t.c.scene?.walker.tile, row(10))
    }

    func testAsHostMyCopyWalksUpToATeammateAndTheTackleIsSent() async {
        let nodes = sorted(4)
        let (a, me, m, v) = (nodes[0], nodes[1], nodes[2], nodes[3])
        await connect(a, me); await connect(m, me); await connect(v, me)
        let c = controller(me, start: row(40))
        c.prepareScene()
        place(m, at: row(36))
        place(v, at: row(10))
        var now = Date()
        host(a, dittoForm(row(14), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        let log = emotes(from: v)
        for _ in 0..<5_000 where !log.items.contains(where: { $0.kind == .decoyTackle }) {
            now = now.addingTimeInterval(0.05)
            c.advanceDitto(now: now)
            guard c.shownDitto?.isDecoy == true else { break }
            await Task.yield()
        }
        await settle()
        let sent = log.items.filter { $0.kind == .decoyTackle }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.targetMemberID, v.id)
        XCTAssertEqual(v.session.members[me.id]?.ditto.map { PlazaPathfinder.isAdjacent($0.tile, row(10)) }, true,
                       "the copy's place reached the teammate before the tackle")
    }

    // MARK: - Snowballs

    private var snowDay: Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    }

    /// A row of four ground tiles for me and three more to my right, clear of where the other members stand.
    private func rowOfFour() -> TilePoint {
        let taken = [ground(8, 8), ground(-5, 0), map.spawn]
        for y in 0..<map.height { for x in 0..<(map.width - 4) {
            let row = (0..<4).map { TilePoint(x: x + $0, y: y) }
            if row.allSatisfy({ PlazaDitto.isGround($0, in: map) && !taken.contains($0) }) { return row[0] }
        } }
        XCTFail("no row of four ground tiles")
        return map.spawn
    }

    func testASnowballRevealsTheCopyWhenItLands() async {
        let now = snowDay
        sessionNow = now
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let start = rowOfFour()
        let copyTile = TilePoint(x: start.x + 3, y: start.y)
        let c = controller(me, start: start, clock: { now })
        c.prepareScene()
        place(m, at: ground(-5, 0))
        host(a, dittoForm(copyTile, now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        XCTAssertEqual(c.scene?.decoyTile, copyTile, "test precondition")
        let log = emotes(from: a)
        c.scene?.face(.right)
        _ = c.scene?.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        await settle()
        XCTAssertEqual(log.items.filter { $0.kind == .snowball }.first?.targetMemberID, key)
        XCTAssertTrue(log.items.filter { $0.kind == .decoyFound }.isEmpty, "not found before it lands")
        XCTAssertEqual(c.shownDitto?.decoyOf, m.id)
        var t = 0.0
        c.scene?.update(t)
        while t < 0.5 { t += 0.05; c.scene?.update(t) }
        await settle()
        XCTAssertEqual(log.items.filter { $0.kind == .decoyFound }.first?.targetMemberID, m.id)
        XCTAssertEqual(c.shownDitto?.isDecoy, false)
        XCTAssertEqual(c.banner, "나님이 메타몽을 찾았어요!")
    }

    func testASnowballMissesACopyThatSteppedAwayBeforeItLanded() async {
        let now = snowDay
        sessionNow = now
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let start = rowOfFour()
        let copyTile = TilePoint(x: start.x + 3, y: start.y)
        let aside = [TilePoint(x: copyTile.x, y: copyTile.y + 1), TilePoint(x: copyTile.x, y: copyTile.y - 1)]
            .first { PlazaDitto.isGround($0, in: map) && $0 != ground(8, 8) && $0 != ground(-5, 0) }
        guard let aside else { return XCTFail("no tile beside the copy") }
        let c = controller(me, start: start, clock: { now })
        c.prepareScene()
        place(m, at: ground(-5, 0))
        host(a, dittoForm(copyTile, now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        let log = emotes(from: a)
        c.scene?.face(.right)
        _ = c.scene?.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        await settle()
        host(a, dittoForm(aside, now: now).copying(m.id, now: now))
        await settle()
        var t = 0.0
        c.scene?.update(t)
        while t < 0.2 { t += 0.05; c.scene?.update(t) }
        XCTAssertNotEqual(c.scene?.dittoTile, copyTile, "test precondition: the copy left its tile")
        while t < 0.8 { t += 0.05; c.scene?.update(t) }
        await settle()
        XCTAssertTrue(log.items.filter { $0.kind == .decoyFound }.isEmpty, "the ball landed where the copy no longer stood")
        XCTAssertEqual(c.shownDitto?.isDecoy, true)
    }

    func testASnowballFromAfarTurnsTheHostsDittoFormIntoTheThrower() async {
        let now = snowDay
        sessionNow = now
        let t = await hostingDittoForm(now: now, clock: { now })
        let scene = t.c.scene!
        let ditto = beside()
        var spot: (tile: TilePoint, toward: PlazaDirection)?
        search: for k in 2...6 {
            for (d, back) in [(PlazaDirection.right, PlazaDirection.left), (.left, .right), (.down, .up), (.up, .down)] {
                var tile = ditto
                for _ in 0..<k { tile = PlazaWalker.offset(tile, back) }
                var clear = PlazaDitto.isGround(tile, in: map) && tile != meStart.me
                var between = ditto
                for _ in 0..<(k - 1) { between = PlazaWalker.offset(between, back); clear = clear && map.isWalkable(between) && between != meStart.me }
                if clear { spot = (tile, d); break search }
            }
        }
        guard let spot else { return XCTFail("no tile in line with the Ditto form") }
        place(t.m, at: spot.tile)
        var time = 0.0
        for _ in 0..<200 where scene.memberTiles[t.m.id] != spot.tile { await Task.yield(); time += 0.05; scene.update(time) }
        XCTAssertEqual(scene.memberTiles[t.m.id], spot.tile, "test precondition")
        let across: PlazaDirection = (spot.toward == .left || spot.toward == .right) ? .down : .right
        t.c.showSnowball(from: t.m.id, on: key, tiles: 1, direction: across)
        for _ in 0..<20 { time += 0.05; scene.update(time) }
        XCTAssertEqual(t.c.shownDitto?.isDecoy, false, "out of line the form stays")
        t.c.showSnowball(from: t.m.id, on: key, tiles: 1, direction: spot.toward)
        for _ in 0..<20 { time += 0.05; scene.update(time) }
        XCTAssertEqual(t.c.shownDitto?.decoyOf, t.m.id)
    }
}
