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

/// 앞모습은 항상 주고, 뒷모습은 `backAfter`번 실패한 뒤에 준다. nil이면 끝내 주지 않는다.
private final class BacklessFetcher: PlazaSpriteFetching {
    private let image: NSImage = {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 2, height: 2))
    }()
    private let backAfter: Int?
    private(set) var backRequests = 0

    init(backAfter: Int? = nil) { self.backAfter = backAfter }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? {
        guard back else { return image }
        backRequests += 1
        if let backAfter, backRequests > backAfter { return image }
        return nil
    }
    func egg() async -> NSImage? { nil }
}

/// Holds the retry timer until the test fires it.
@MainActor
private final class RetryGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiting.count }
    func sleep(_ d: Duration) async { await withCheckedContinuation { waiting.append($0) } }
    func fire() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
}

@MainActor
final class PlazaMembersTests: XCTestCase {
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

    private func controller(_ me: Node, fetcher: PlazaSpriteFetching = CountingFetcher(),
                            retry: RetryGate? = nil) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: { "나" }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { nil }, session: me.session,
                              spriteRetrySleep: { d in
                                  if let retry { await retry.sleep(d) } else { try? await Task.sleep(for: d) }
                              })
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

    // MARK: - 목록에서 팀원에게 걸어가기

    private let rightKey: UInt16 = 124

    func testChoosingATeammateWalksBesideThemAndFacesThem() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let target = walkableTile(5)
        other.session.updatePlazaPosition(inPlaza: true, tile: target, facing: .down, isWalking: false)
        await settle()
        let scene = c.scene!
        c.walkToMember(other.settings.memberID)
        XCTAssertEqual(scene.walkingToMember, other.settings.memberID)
        step(scene, seconds: 3)
        XCTAssertTrue(PlazaPathfinder.isAdjacent(scene.walker.tile, target), "\(scene.walker.tile) beside \(target)")
        XCTAssertEqual(scene.walker.facing, PlazaPathfinder.direction(from: scene.walker.tile, to: target))
        XCTAssertNil(scene.walkingToMember, "arriving ends the walk")
    }

    func testFollowsATeammateWhoMovesOnTheWay() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(6), facing: .down, isWalking: false)
        await settle()
        let scene = c.scene!
        c.walkToMember(other.settings.memberID)
        step(scene, seconds: 0.3)
        let moved = TilePoint(x: map.spawn.x, y: map.spawn.y + 4)
        other.session.updatePlazaPosition(inPlaza: true, tile: moved, facing: .down, isWalking: false)
        await settle()
        // Re-routing at once takes about five steps. Finishing the old route first would take twice as long.
        step(scene, seconds: 1.5, from: 0.3)
        XCTAssertTrue(PlazaPathfinder.isAdjacent(scene.walker.tile, moved), "\(scene.walker.tile) beside \(moved)")
    }

    func testTeammateAlreadyBesideMeIsTurnedTo() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        let left = TilePoint(x: scene.walker.tile.x - 1, y: scene.walker.tile.y)
        other.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(scene.walker.facing, .down)
        c.walkToMember(other.settings.memberID)
        step(scene, seconds: 0.1)
        XCTAssertEqual(scene.walker.facing, .left)
        XCTAssertNil(scene.walkingToMember)
    }

    func testArrowKeyOrOverlayStopsTheWalk() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(6), facing: .down, isWalking: false)
        await settle()
        let scene = c.scene!
        c.walkToMember(other.settings.memberID)
        step(scene, seconds: 0.1)
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        XCTAssertNil(scene.walkingToMember)
        scene.handleKeyUp(keyCode: rightKey)
        c.walkToMember(other.settings.memberID)
        scene.isOverlayOpen = true
        XCTAssertNil(scene.walkingToMember)
    }

    func testEggOrUnknownMemberCannotBeWalkedTo() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        XCTAssertFalse(scene.walk(toMember: "nobody"))
        scene.canWalk = false
        XCTAssertFalse(scene.walk(toMember: other.settings.memberID))
    }

    // MARK: - 자리비움(입력 없음)과 작은 지도

    func testIdleShowsInPlaceAndComingBackClearsIt() async {
        let me = node("나"), other = node("민수")
        let mine = PlazaRosterEntry(id: me.settings.memberID, nickname: "나", speciesID: 25, speciesName: "Pikachu", gender: nil,
                                    isShiny: false, presence: .online, isMe: true)
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                      loader: PlazaCharacterLoader(fetcher: CountingFetcher()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      myRosterEntry: { mine }, session: me.session)
        let watcher = controller(other)
        c.prepareScene(); watcher.prepareScene()
        await connect(me, other)
        let myID = me.settings.memberID
        let before = watcher.scene!.memberTiles[myID]
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .online)
        me.session.updateIdle(true)
        await settle()
        XCTAssertEqual(other.session.members[myID]?.isIdle, true)
        XCTAssertEqual(other.session.members[myID]?.inPlaza, true)
        XCTAssertEqual(watcher.scene?.memberName(myID), "나 zZ")
        XCTAssertEqual(watcher.scene?.memberTiles[myID], before, "an idle member stays where they were")
        XCTAssertEqual(watcher.rosterEntries.first { $0.id == myID }?.presence, .idle)
        XCTAssertEqual(watcher.minimapDots.first { $0.id == myID }?.isAway, true)
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .idle, "my own row follows my input too")
        me.session.updateIdle(false)
        await settle()
        XCTAssertEqual(other.session.members[myID]?.isIdle, false)
        XCTAssertEqual(watcher.scene?.memberName(myID), "나")
        XCTAssertEqual(watcher.rosterEntries.first { $0.id == myID }?.presence, .online)
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .online)
    }

    /// The report: a teammate working with the plaza closed showed 잠. Now they are 접속, without zZ, until they stop typing.
    func testPlazaClosedIsOnlineUntilIdle() async {
        let me = node("나"), other = node("민수")
        let watcher = controller(other)
        watcher.prepareScene()
        await connect(me, other)   // my plaza stays closed
        let myID = me.settings.memberID
        XCTAssertEqual(other.session.members[myID]?.inPlaza, false, "test precondition")
        XCTAssertEqual(watcher.rosterEntries.first { $0.id == myID }?.presence, .online)
        XCTAssertEqual(watcher.scene?.memberName(myID), "나", "no zZ while working")
        XCTAssertEqual(watcher.minimapDots.first { $0.id == myID }?.isAway, false)
        me.session.updateIdle(true)
        await settle()
        XCTAssertEqual(other.session.members[myID]?.isIdle, true, "idle reaches teammates with the plaza closed")
        XCTAssertEqual(watcher.rosterEntries.first { $0.id == myID }?.presence, .idle)
        XCTAssertEqual(watcher.scene?.memberName(myID), "나 zZ")
    }

    /// The report: a teammate whose Mac slept or who quit vanished. Now they stay as 잠 (off the map) until they connect again.
    func testDisconnectedTeammateStaysAsleepUntilTheyReconnect() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        let link = hub.connect(me.transport, to: other.transport)
        await settle()
        let id = other.settings.memberID
        XCTAssertEqual(c.rosterEntries.first { $0.id == id }?.presence, .online)
        hub.disconnect(link)
        await settle()
        XCTAssertEqual(c.rosterEntries.first { $0.id == id }?.presence, .asleep)
        XCTAssertEqual(c.rosterEntries.first { $0.id == id }?.nickname, "민수")
        XCTAssertNil(c.scene?.memberTiles[id], "off the map")
        XCTAssertNil(c.minimapDots.first { $0.id == id })
        hub.connect(me.transport, to: other.transport)
        await settle()
        XCTAssertEqual(c.rosterEntries.filter { $0.id == id }.map(\.presence), [.online])
    }

    func testMinimapShowsMeAndTeammatesAndTheVisibleArea() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: walkableTile(3), facing: .down, isWalking: false)
        await settle()
        let dots = c.minimapDots
        XCTAssertEqual(dots.first { $0.isMe }?.tile, c.scene?.walker.tile)
        let mate = dots.first { $0.id == other.settings.memberID }
        XCTAssertEqual(mate?.tile, walkableTile(3))
        XCTAssertEqual(mate?.isAway, false)
        XCTAssertEqual(mate?.color, c.scene?.memberNameColor(other.settings.memberID))
        XCTAssertEqual(c.minimapView, c.scene?.visibleWorldRect)
        other.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await settle()
        XCTAssertEqual(c.minimapDots.first { $0.id == other.settings.memberID }?.isAway, false, "closing the plaza is not idle")
        other.session.updateIdle(true)
        await settle()
        XCTAssertEqual(c.minimapDots.first { $0.id == other.settings.memberID }?.isAway, true)
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

    /// A teammate outside the plaza stands in the shelter. zZ marks only no input, not a closed plaza.
    func testMemberOutsideThePlazaStandsInTheShelter() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)   // inPlaza is false right after hello
        let id = other.settings.memberID
        guard let scene = c.scene else { return XCTFail("no scene") }
        XCTAssertEqual(scene.memberName(id), "민수")
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

    func testDisconnectedMemberLeavesTheMapAndSleepsInTheRoster() async {
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
        XCTAssertEqual(c.rosterEntries.map(\.presence), [.asleep])
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

    /// A teammate who picks a name colour shows in it here at once.
    func testTeammatesPickedNameColorShowsHere() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        let pick = PlazaNameColor.hexes.first { $0 != PlazaNameColor.hex(forMemberID: id, chosen: nil) }!
        other.settings.nameColor = pick
        other.session.applySettings()
        await settle()
        XCTAssertEqual(c.scene?.memberNameColor(id), PlazaNameColor.color(forMemberID: id, chosen: pick))
    }

    /// Picking a colour saves it, paints my name at once, folds the palette, and is still there when the plaza reopens.
    func testPickingMyNameColorPaintsMeAndIsKept() {
        let me = node("나"), id = me.settings.memberID
        var saved: UInt32?
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                                      loader: PlazaCharacterLoader(fetcher: CountingFetcher()),
                                      nickname: { "나" }, memberID: { id }, subject: { .init(speciesID: 25, isShiny: false) },
                                      nameColor: { saved }, chooseNameColor: { saved = $0 }, session: me.session)
        c.prepareScene()
        let own = PlazaNameColor.hex(forMemberID: id, chosen: nil)
        XCTAssertEqual(c.shownNameColor, own)
        XCTAssertEqual(c.scene?.nameColor, PlazaNameColor.color(forMemberID: id))
        c.toggleNameColorPicker()
        XCTAssertTrue(c.isNameColorPickerOpen)
        let pick = PlazaNameColor.hexes.first { $0 != own }!
        c.pickNameColor(pick)
        XCTAssertEqual(saved, pick)
        XCTAssertFalse(c.isNameColorPickerOpen)
        XCTAssertEqual(c.shownNameColor, pick)
        XCTAssertEqual(c.scene?.nameColor, PlazaNameColor.color(forMemberID: id, chosen: pick))
        c.handleClose()
        c.prepareScene()
        XCTAssertEqual(c.scene?.nameColor, PlazaNameColor.color(forMemberID: id, chosen: pick))
        XCTAssertEqual(c.shownNameColor, pick)
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

    func testFailedMemberSpriteIsRequestedAgainWhileOpen() async {
        let fetcher = CountingFetcher()
        let retry = RetryGate()
        let me = node("나"), other = node("민수", character: Self.pikachu)
        let c = controller(me, fetcher: fetcher, retry: retry)
        c.prepareScene()
        await connect(me, other)
        await settle()
        let first = fetcher.calls.count(25)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(retry.waitingCount, 1, "the failed load waits to retry")
        retry.fire()
        await settle()
        XCTAssertEqual(fetcher.calls.count(25), first * 2, "the retry asked for the sprite again")
    }

    func testMemberSpriteRetryIsDroppedWhenTheCharacterChangedOrThePlazaClosed() async {
        let fetcher = CountingFetcher()
        let retry = RetryGate()
        let me = node("나"), other = node("민수", character: Self.pikachu)
        let c = controller(me, fetcher: fetcher, retry: retry)
        c.prepareScene()
        await connect(me, other)
        await settle()
        other.session.updateCharacter(Self.eevee)
        await settle()
        let pikachuBefore = fetcher.calls.count(25)
        retry.fire()   // both timers: the stale pikachu one and the eevee one
        await settle()
        XCTAssertEqual(fetcher.calls.count(25), pikachuBefore, "a changed character is not fetched as the old one")
        c.handleClose()
        let total = fetcher.calls.all.count
        retry.fire()
        await settle()
        XCTAssertEqual(fetcher.calls.all.count, total, "a closed plaza retries nothing")
    }

    func testFailedOwnSpriteIsRequestedAgainWhileOpen() async {
        let fetcher = CountingFetcher()
        let retry = RetryGate()
        let c = controller(node("나"), fetcher: fetcher, retry: retry)
        c.prepareScene()
        await c.refreshCharacter()
        await settle()
        let first = fetcher.calls.count(25)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(retry.waitingCount, 1, "the failed load waits to retry")
        retry.fire()
        await settle()
        XCTAssertEqual(fetcher.calls.count(25), first * 2, "the retry asked for the sprite again")
    }

    func testOwnSpriteRetryIsDroppedByANewerLoadOrAClose() async {
        let fetcher = CountingFetcher()
        let retry = RetryGate()
        let c = controller(node("나"), fetcher: fetcher, retry: retry)
        c.prepareScene()
        await c.refreshCharacter()
        await c.refreshCharacter()
        await settle()
        XCTAssertEqual(retry.waitingCount, 2)
        let one = fetcher.calls.count(25) / 2
        retry.fire()   // the first load's stale timer and the newer load's timer
        await settle()
        XCTAssertEqual(fetcher.calls.count(25), one * 3, "only the newer load asks again")
        c.handleClose()
        let total = fetcher.calls.all.count
        retry.fire()
        await settle()
        XCTAssertEqual(fetcher.calls.all.count, total, "a closed plaza retries nothing")
    }

    func testMissingBackIsRequestedOnlyAFewTimes() async {
        let fetcher = BacklessFetcher()
        let retry = RetryGate()
        let c = controller(node("나"), fetcher: fetcher, retry: retry)
        c.prepareScene()
        await c.refreshCharacter()
        await settle()
        for attempt in 0..<PlazaWindowController.backRetryLimit {
            XCTAssertEqual(retry.waitingCount, 1, "attempt \(attempt) waits to retry")
            retry.fire()
            await settle()
        }
        XCTAssertEqual(retry.waitingCount, 0, "a back picture that may not exist stops being requested")
        XCTAssertEqual(fetcher.backRequests, 1 + PlazaWindowController.backRetryLimit)
    }

    func testMemberBackThatFailedOnceIsRecovered() async {
        let fetcher = BacklessFetcher(backAfter: 1)
        let retry = RetryGate()
        let me = node("나"), other = node("민수", character: Self.pikachu)
        let c = controller(me, fetcher: fetcher, retry: retry)
        c.prepareScene()
        await connect(me, other)
        await settle()
        XCTAssertEqual(retry.waitingCount, 1, "a failed back waits to retry")
        retry.fire()
        await settle()
        XCTAssertEqual(fetcher.backRequests, 2)
        XCTAssertEqual(retry.waitingCount, 0, "a recovered back stops retrying")
        XCTAssertEqual(c.appliedMemberSpecies(other.settings.memberID).count, 2, "the recovered frames reach the scene")
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
