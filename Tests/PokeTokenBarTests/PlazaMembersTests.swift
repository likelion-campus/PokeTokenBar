import XCTest
import AppKit
@testable import PokeTokenBar

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return ids }
    func count(_ id: Int) -> Int { all.filter { $0 == id }.count }
}

/// 호출만 세고 빈 결과를 돌려준다. `slowIDs`에 든 종은 gate가 열릴 때까지 기다린다.
private final class CountingFetcher: PlazaSpriteFetching, @unchecked Sendable {
    let calls = Calls()
    private let lock = NSLock()
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var slow: Set<Int> = []

    func makeSlow(_ id: Int) { lock.lock(); slow.insert(id); lock.unlock() }
    private func isSlow(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return slow.contains(id) }
    private func park(_ id: Int, _ c: CheckedContinuation<Void, Never>) { lock.lock(); gates[id] = c; lock.unlock() }
    func release(_ id: Int) {
        lock.lock(); let c = gates.removeValue(forKey: id); lock.unlock()
        c?.resume()
    }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        calls.add(speciesID)
        if isSlow(speciesID) { await withCheckedContinuation { park(speciesID, $0) } }
        return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
final class PlazaMembersTests: XCTestCase {
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

    private func node(_ name: String, character: TeamMonSummary? = nil) -> Node {
        let suite = "plaza.members.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaMembersTests-\(UUID())")
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
    private static let charmander = TeamMonSummary(speciesID: 4, isShiny: false, form: nil, speciesName: "Charmander", gender: nil)
    private static let eevee = TeamMonSummary(speciesID: 133, isShiny: false, form: nil, speciesName: "Eevee", gender: nil)

    private func defaults() -> UserDefaults {
        let name = "plaza.members.prefs.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func controller(_ me: Node, fetcher: PlazaSpriteFetching = CountingFetcher()) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: { "나" }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { nil }, session: me.session)
    }

    /// 관찰 콜백(Task)이 돌 틈을 준다.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func walkableTile(_ dx: Int = 0) -> TilePoint {
        var p = map.spawn
        p.x += dx
        return p
    }

    private func treeTile() -> TilePoint { TilePoint(x: 0, y: 0) }

    private func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    private func footTile(_ scene: PlazaScene, _ id: String) -> TilePoint? {
        guard let f = scene.memberFoot(id) else { return nil }
        let s = CGFloat(PlazaMap.tileSize)
        return TilePoint(x: Int((f.x / s).rounded(.down)), y: Int((f.y / s).rounded(.down)))
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    // MARK: - 테스트

    func testPresenceFramesDoNotRebuildMyRosterEntry() async {
        let me = node("나"), other = node("민수")
        var builds = 0
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                      loader: PlazaCharacterLoader(fetcher: CountingFetcher()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      myRosterEntry: { builds += 1; return nil }, session: me.session)
        c.prepareScene()
        let afterOpen = builds
        XCTAssertGreaterThan(afterOpen, 0)
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(1), facing: .down, isWalking: false)
        await settle()
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(2), facing: .down, isWalking: true)
        await settle()
        XCTAssertEqual(builds, afterOpen, "member frames reuse the cached entry")
        c.refreshMyEntry()
        XCTAssertEqual(builds, afterOpen + 1, "my own change rebuilds it")
    }

    func testOnlineMemberAppearsAtTheirTile() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let tile = walkableTile(2)
        other.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .left, isWalking: false)
        await settle()
        guard let scene = c.scene else { return XCTFail("no scene") }
        XCTAssertEqual(scene.memberTiles[other.settings.memberID], tile)
        XCTAssertEqual(footTile(scene, other.settings.memberID), tile)
        XCTAssertEqual(scene.memberName(other.settings.memberID), "민수")
    }

    func testMemberMovesWhenPresenceChanges() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        let a = walkableTile(), b = walkableTile(1)
        other.session.updatePlazaPosition(inPlaza: true, tile: a, facing: .down, isWalking: false)
        await settle()
        other.session.updatePlazaPosition(inPlaza: true, tile: b, facing: .right, isWalking: true)
        await settle()
        guard let scene = c.scene else { return XCTFail("no scene") }
        step(scene, seconds: 0.05)
        XCTAssertEqual(scene.memberTiles[id], b, "the visible spot is the destination of the step in flight")
        step(scene, seconds: 1, from: 1)
        XCTAssertEqual(footTile(scene, id), b)
    }

    func testAwayMemberStandsInShelterWithZzName() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)   // inPlaza is false right after hello
        let id = other.settings.memberID
        guard let scene = c.scene else { return XCTFail("no scene") }
        XCTAssertEqual(scene.memberName(id), "민수 " + L(.ko).plazaAwaySuffix)
        XCTAssertTrue(map.shelterTiles.contains(scene.memberTiles[id]!))
        step(scene, seconds: 40)
        XCTAssertTrue(map.shelterTiles.contains(scene.memberTiles[id]!), "wandering stays in the shelter")
    }

    func testMemberBecomingOnlineSnapsToTheirTile() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        guard let scene = c.scene else { return XCTFail("no scene") }
        let far = TilePoint(x: map.spawn.x + 8, y: map.spawn.y)
        guard let tile = (0..<map.height).map({ TilePoint(x: far.x, y: $0) }).first(where: { map.isWalkable($0) && abs($0.y - far.y) > 4 })
        else { return XCTFail("no far tile") }
        other.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(footTile(scene, id), tile, "no walking across the map from the shelter")
        XCTAssertEqual(scene.memberName(id), "민수")
        other.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await settle()
        XCTAssertTrue(map.shelterTiles.contains(footTile(scene, id)!), "back to the shelter at once")
    }

    func testDisconnectedMemberDisappears() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        let connection = hub.connect(me.transport, to: other.transport)
        await settle()
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(), facing: .down, isWalking: false)
        await settle()
        let id = other.settings.memberID
        XCTAssertNotNil(c.scene?.memberFoot(id))
        XCTAssertEqual(c.rosterEntries.count, 1)
        hub.disconnect(connection)
        await settle()
        XCTAssertNil(c.scene?.memberFoot(id))
        XCTAssertTrue(c.scene?.memberTiles.isEmpty ?? false)
        XCTAssertTrue(c.rosterEntries.isEmpty)
    }

    func testInvalidRemoteTileFallsBackToShelter() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        guard let scene = c.scene else { return XCTFail("no scene") }
        for bad in [treeTile(), TilePoint(x: 9999, y: -5)] {
            other.session.updatePlazaPosition(inPlaza: true, tile: bad, facing: .down, isWalking: false)
            await settle()
            XCTAssertTrue(map.shelterTiles.contains(scene.memberTiles[id]!), "\(bad) should fall back to the shelter")
        }
        other.session.updatePlazaPosition(inPlaza: true, tile: nil, facing: nil, isWalking: false)
        await settle()
        XCTAssertTrue(map.shelterTiles.contains(scene.memberTiles[id]!), "a missing tile also falls back")
    }

    func testLowerMemberDrawsInFront() async {
        let me = node("나"), upper = node("위"), lower = node("아래")
        let c = controller(me)
        c.prepareScene()
        await connect(me, upper); await connect(me, lower)
        let top = walkableTile(), bottom = TilePoint(x: top.x, y: top.y + 4)
        XCTAssertTrue(map.isWalkable(bottom))
        upper.session.updatePlazaPosition(inPlaza: true, tile: top, facing: .down, isWalking: false)
        lower.session.updatePlazaPosition(inPlaza: true, tile: bottom, facing: .down, isWalking: false)
        await settle()
        guard let scene = c.scene else { return XCTFail("no scene") }
        step(scene, seconds: 0.1)
        XCTAssertGreaterThan(scene.memberZ(lower.settings.memberID)!, scene.memberZ(upper.settings.memberID)!)
    }

    func testMyWalkIsNotBlockedByMembers() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        guard let scene = c.scene else { return XCTFail("no scene") }
        let start = scene.walker.tile
        let ahead = TilePoint(x: start.x + 1, y: start.y)
        XCTAssertTrue(map.isWalkable(ahead))
        other.session.updatePlazaPosition(inPlaza: true, tile: ahead, facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(scene.memberTiles[other.settings.memberID], ahead)
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: 124)
        step(scene, seconds: 1)
        XCTAssertEqual(scene.walker.tile, ahead)
    }

    func testMemberNameUsesMemberColor() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        XCTAssertEqual(c.scene?.memberNameColor(id), PlazaNameColor.color(forMemberID: id))
    }

    func testCharacterChangeReloadsOnlyThatMember() async {
        let fetcher = CountingFetcher()
        let me = node("나"), a = node("가", character: Self.pikachu), b = node("나나", character: Self.eevee)
        let c = controller(me, fetcher: fetcher)
        c.prepareScene()
        await connect(me, a); await connect(me, b)
        await settle()
        XCTAssertGreaterThan(fetcher.calls.count(25), 0)
        XCTAssertGreaterThan(fetcher.calls.count(133), 0)
        let eeveeBefore = fetcher.calls.count(133)
        a.session.updateCharacter(Self.charmander)
        await settle()
        XCTAssertGreaterThan(fetcher.calls.count(4), 0, "the changed member is fetched again")
        XCTAssertEqual(fetcher.calls.count(133), eeveeBefore, "the other member is left alone")
        a.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(), facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(fetcher.calls.count(133), eeveeBefore, "moving does not reload anything")
    }

    func testStaleMemberSpriteLoadIsDiscarded() async {
        let fetcher = CountingFetcher()
        fetcher.makeSlow(25)
        let me = node("나"), other = node("민수", character: Self.pikachu)
        let c = controller(me, fetcher: fetcher)
        c.prepareScene()
        await connect(me, other)
        await settle()
        XCTAssertGreaterThan(fetcher.calls.count(25), 0, "the slow load is in flight")
        other.session.updateCharacter(Self.eevee)   // the newer character
        await settle()
        let id = other.settings.memberID
        XCTAssertEqual(c.appliedMemberSpecies(id), [133], "the new character's frames arrived first")
        fetcher.release(25)   // front
        await settle()
        fetcher.release(25)   // back
        await settle()
        XCTAssertEqual(c.appliedMemberSpecies(id), [133], "the old result must not replace the new one")
    }

    func testOpeningSendsPositionAndClosingSendsAway() async {
        let me = node("나"), other = node("민수")
        await connect(me, other)
        let c = controller(me)
        c.prepareScene()
        await settle()
        let state = other.session.members[me.settings.memberID]
        XCTAssertEqual(state?.inPlaza, true)
        XCTAssertEqual(state?.tile, c.scene?.walker.tile)
        c.handleClose()
        await settle()
        XCTAssertEqual(other.session.members[me.settings.memberID]?.inPlaza, false)
    }

    func testClosedPlazaLoadsNoSprites() async {
        let fetcher = CountingFetcher()
        let me = node("나"), other = node("민수", character: Self.pikachu)
        let c = controller(me, fetcher: fetcher)
        c.prepareScene()
        c.handleClose()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(), facing: .down, isWalking: true)
        other.session.updateCharacter(Self.eevee)
        await settle()
        XCTAssertTrue(fetcher.calls.all.isEmpty, "a closed plaza fetches nothing")
        XCTAssertNil(c.scene)
    }

    func testReopenShowsCurrentMembers() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        c.handleClose()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(3), facing: .down, isWalking: false)
        await settle()
        c.prepareScene()
        XCTAssertEqual(c.scene?.memberTiles[other.settings.memberID], walkableTile(3))
        XCTAssertEqual(c.rosterEntries.count, 1)
    }

    func testLocalPositionChangeIsReportedOnlyWhenItChanges() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        guard let scene = c.scene else { return XCTFail("no scene") }
        var reports: [(TilePoint, PlazaDirection, Bool)] = []
        scene.onLocalPositionChange = { reports.append(($0, $1, $2)) }
        step(scene, seconds: 0.5)
        XCTAssertTrue(reports.isEmpty, "standing still reports nothing")
        let start = scene.walker.tile
        let key: UInt16 = map.isWalkable(TilePoint(x: start.x + 1, y: start.y)) ? 124 : 123
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        step(scene, seconds: 1, from: 1)
        XCTAssertFalse(reports.isEmpty)
        XCTAssertEqual(reports.last?.0, scene.walker.tile)
        XCTAssertEqual(reports.last?.2, false)
        XCTAssertTrue(reports.contains { $0.2 }, "the walking step is reported too")
    }
}
