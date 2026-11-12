import XCTest
import AppKit
@testable import PokeTokenBar

/// Records which species were asked for, so a test can see a frame load start without any network.
private final class RecordingFetcher: PlazaSpriteFetching, @unchecked Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor private final class TickGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { waiters.append($0) } }
    func tick() async {
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
}

/// A Ditto teammate's disguise, as the receiving Mac draws it.
@MainActor
final class PlazaMimicControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let gate = TickGate()
    private let map = PlazaMapData.map
    private let key = PlazaDitto.sceneKey
    private var mySpecies = 7
    private let myColor: UInt32 = 0xFFE14D

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

    private static let ditto = TeamMonSummary(speciesID: 132, isShiny: false, form: nil, speciesName: "Ditto", gender: nil)
    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    private static let jia = TeamMonSummary(speciesID: 25, isShiny: true, form: nil, speciesName: "Pikachu", gender: nil, nature: .timid)
    private static let other = TeamMonSummary(speciesID: 4, isShiny: false, form: nil, speciesName: "Charmander", gender: nil)
    private let jiaColor: UInt32 = 0xFF9ECF

    private func node(_ name: String, character: TeamMonSummary? = nil, nameColor: UInt32? = nil) -> Node {
        let suite = "plaza.mimic.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.nameColor = nameColor
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaMimicControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let current = character ?? Self.pikachu
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: current, dex: []) },
                                  clock: { [unowned self] in now })
        session.updateCharacter(current)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func prefs() -> PlazaPreferences {
        let name = "plaza.mimic.prefs.\(UUID())"
        suites.append(name)
        return PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
    }

    private func controller(_ me: Node) -> PlazaWindowController {
        let p = prefs()
        p.saveLastTile(row(10))
        return PlazaWindowController(preferences: p, loader: PlazaCharacterLoader(fetcher: RecordingFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { [unowned self] in .init(speciesID: mySpecies, isShiny: false) },
                                     nameColor: { [unowned self] in myColor },
                                     session: me.session, clock: { [unowned self] in now },
                                     spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                     focusTickSleep: { [gate] in await gate.sleep($0) },
                                     dittoLoopSleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                     dittoSeed: { 7 })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", line: line)
    }

    private func row(_ x: Int) -> TilePoint { TilePoint(x: x, y: 3) }

    private func ground(_ dx: Int = 0, _ dy: Int = 0) -> TilePoint {
        let t = TilePoint(x: map.spawn.x + dx, y: map.spawn.y + dy)
        XCTAssertTrue(PlazaDitto.isGround(t, in: map), "\(t) must be ground")
        return t
    }

    @MainActor private struct World {
        let me: Node
        let quiet: Node
        let c: PlazaWindowController
        var scene: PlazaScene { c.scene! }
    }

    /// My controller, plus a quiet teammate with the smallest ID who is ready and far away, so this Mac never hosts the guest Ditto.
    private func world() async -> World {
        let me = node("나")
        // A chosen colour that no test copies, so the quiet one never shares a colour with a copied teammate by chance.
        var quiet = node("조용", nameColor: 0xFFFFFF)
        while quiet.id >= me.id { quiet = node("조용", nameColor: 0xFFFFFF) }
        let c = controller(me)
        c.prepareScene()
        await connect(me, quiet)
        quiet.session.updatePlazaPosition(inPlaza: true, tile: ground(8, 8), facing: .down, isWalking: false)
        quiet.session.updateDitto(ready: true, state: nil)
        await settle()
        return World(me: me, quiet: quiet, c: c)
    }

    /// A teammate who stands on `tile` and whom my scene sees.
    @discardableResult
    private func join(_ w: World, _ name: String, _ character: TeamMonSummary, at tile: TilePoint, nameColor: UInt32? = nil) async -> Node {
        let n = node(name, character: character, nameColor: nameColor)
        await connect(w.me, n)
        n.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        await waitUntil { w.scene.memberTiles[n.id] == tile }
        await settle()
        return n
    }

    private func nature(_ n: PokemonNature) -> String { L(.ko).plazaNatureTitle(n) }

    // MARK: - Drawing

    func testATeammatesDisguiseDrawsThemAsTheOneTheyCopy() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        XCTAssertEqual(w.scene.memberName(m.id), "민수", "test precondition")
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        await settle()
        XCTAssertEqual(w.scene.memberName(m.id), "지아")
        XCTAssertEqual(w.scene.memberNameColor(m.id), PlazaNameColor.color(forMemberID: x.id, chosen: jiaColor))
        XCTAssertEqual(w.scene.memberTitle(m.id), nature(.timid))
        XCTAssertEqual(w.c.shownMimics, [m.id: x.id])
        XCTAssertEqual(w.c.appliedMemberSpecies(m.id).last, 25)
        let same = w.c.minimapDots.filter { $0.color == w.scene.memberNameColor(x.id) }
        XCTAssertEqual(Set(same.map(\.id)), [m.id, x.id], "both dots wear the copied colour")

        m.session.updateMimic(nil)
        await waitUntil { w.c.shownMimics.isEmpty }
        await settle()
        XCTAssertEqual(w.scene.memberName(m.id), "민수")
        XCTAssertEqual(w.c.appliedMemberSpecies(m.id).last, 132)
    }

    func testACopyOfMeShowsMyRealLook() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        m.session.updateMimic(w.me.id)
        await waitUntil { w.c.shownMimics[m.id] == w.me.id }
        await settle()
        XCTAssertEqual(w.scene.memberName(m.id), "나")
        XCTAssertEqual(w.scene.memberNameColor(m.id), PlazaNameColor.color(forMemberID: w.me.id, chosen: myColor))
        XCTAssertEqual(w.c.appliedMemberSpecies(m.id).last, mySpecies)
    }

    func testACopyOfACopierShowsTheirRealLook() async {
        let w = await world()
        let a = await join(w, "에이", Self.ditto, at: row(20))
        let b = await join(w, "비", Self.ditto, at: row(22))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        b.session.updateMimic(x.id)
        a.session.updateMimic(b.id)
        await waitUntil { w.c.shownMimics[a.id] == b.id && w.c.shownMimics[b.id] == x.id }
        await settle()
        XCTAssertEqual(w.scene.memberName(a.id), "비", "b's own name, not 지아")
        XCTAssertEqual(w.c.appliedMemberSpecies(a.id).last, 132)
        XCTAssertEqual(w.scene.memberName(b.id), "지아")
    }

    func testHostileMimicValuesDrawTheSenderAsThemselves() async {
        let w = await world()
        let p = await join(w, "피카", Self.pikachu, at: row(20))
        let m = await join(w, "민수", Self.ditto, at: row(22))
        let d = await join(w, "디토", Self.ditto, at: row(24))
        let x = await join(w, "지아", Self.jia, at: row(26), nameColor: jiaColor)
        p.session.updateMimic(x.id)          // a Pikachu cannot copy
        m.session.updateMimic("nobody")      // not a member
        d.session.updateMimic(d.id)          // itself
        await waitUntil { w.me.session.members[d.id]?.mimicOf == d.id && w.me.session.members[p.id]?.mimicOf == x.id
            && w.me.session.members[m.id]?.mimicOf == "nobody" }
        await settle()
        XCTAssertEqual(w.scene.memberName(p.id), "피카")
        XCTAssertEqual(w.scene.memberName(m.id), "민수")
        XCTAssertEqual(w.scene.memberName(d.id), "디토")
        XCTAssertTrue(w.c.shownMimics.isEmpty)
    }

    func testADisguiseOfAMemberWhoLeftIsDrawnAsTheSender() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        x.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await waitUntil { w.c.shownMimics.isEmpty }
        await settle()
        XCTAssertEqual(w.me.session.members[m.id]?.mimicOf, x.id, "test precondition: m still says it copies x")
        XCTAssertEqual(w.scene.memberName(m.id), "민수")
    }

    func testACoveredWindowStillDropsADisguiseAfterItsTime() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        let t0 = now
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        w.c.setRendering(visible: false)
        await settle()

        now = t0.addingTimeInterval(PlazaMimic.duration + PlazaMimic.receiverGrace - 1)
        await gate.tick()
        XCTAssertEqual(w.scene.memberName(m.id), "지아", "still inside the grace")
        now = t0.addingTimeInterval(PlazaMimic.duration + PlazaMimic.receiverGrace)
        await gate.tick()
        XCTAssertEqual(w.scene.memberName(m.id), "민수")
        XCTAssertTrue(w.c.shownMimics.isEmpty)
    }

    /// The 1 s tick runs for as long as the plaza is open; with nothing changed it must not redraw every member.
    func testATickWithNoChangeDoesNotRedrawTheMembers() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        await settle()
        let before = w.scene.applyMembersCount
        await gate.tick()
        await gate.tick()
        XCTAssertEqual(w.scene.applyMembersCount, before, "an idle tick leaves the drawn members alone")
        XCTAssertEqual(w.scene.memberName(m.id), "지아")

        now = now.addingTimeInterval(PlazaMimic.duration + PlazaMimic.receiverGrace)
        await gate.tick()
        XCTAssertGreaterThan(w.scene.applyMembersCount, before, "test precondition: a real change does redraw")
    }

    // MARK: - Walks, chat, the guest Ditto

    func testADisguiseStopsMyWalkToEitherOfThem() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        XCTAssertTrue(w.scene.walk(toMember: x.id))
        XCTAssertEqual(w.scene.walkingToMember, x.id, "test precondition")
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        XCTAssertNil(w.scene.walkingToMember, "walking to the one being copied stops")

        m.session.updateMimic(nil)
        await waitUntil { w.c.shownMimics.isEmpty }
        XCTAssertTrue(w.scene.follow(member: m.id))
        XCTAssertEqual(w.scene.followingMember, m.id, "test precondition")
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        XCTAssertNil(w.scene.walkingToMember, "following the copier stops")
    }

    func testTheChatLogKeepsTheRealNameAndColour() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20), nameColor: 0x7FD4FF)
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        w.c.showChat(memberID: m.id, text: "안녕")
        let line = w.c.chatLogLines.last
        XCTAssertEqual(line?.name, "민수")
        XCTAssertEqual(line?.color, PlazaNameColor.color(forMemberID: m.id, chosen: 0x7FD4FF))
    }

    func testTheGuestDittoCopiesADisguisedMembersRealLook() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20), nameColor: 0x7FD4FF)
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        let y = await join(w, "노랑", Self.other, at: row(28))
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        let state = PlazaDittoState(tile: row(12), facing: .down, isWalking: nil, isRunning: nil, decoyOf: nil, since: now, restUntil: nil)
            .copying(m.id, now: now)
        w.quiet.session.updateDitto(ready: true, state: state)
        await settle()
        w.c.advanceDitto(now: now)
        await settle()
        XCTAssertEqual(w.scene.memberName(key), "민수")
        XCTAssertEqual(w.scene.memberNameColor(key), PlazaNameColor.color(forMemberID: m.id, chosen: 0x7FD4FF))
        XCTAssertEqual(w.c.appliedMemberSpecies(key).last, 132)

        let loads = w.c.appliedMemberSpecies(key).count
        m.session.updateMimic(y.id)
        await waitUntil { w.c.shownMimics[m.id] == y.id }
        await settle()
        XCTAssertEqual(w.c.appliedMemberSpecies(key).count, loads, "m switching disguise does not reload the guest Ditto")
    }

    // MARK: - My own disguise

    @MainActor private final class EmoteLog { var items: [TeamEmote] = [] }

    private func emotes(from node: Node) -> EmoteLog {
        let log = EmoteLog()
        node.session.onEmote = { log.items.append($1) }
        return log
    }

    /// A world where I am a Ditto, with a Pikachu copy target `x` ("지아") in view.
    private func dittoWorld() async -> (w: World, x: Node) {
        mySpecies = 132
        let w = await world()
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        return (w, x)
    }

    func testADittosTackleSendsAMimicTackleAndPushesNobody() async {
        mySpecies = 132
        let w = await world()
        let x = await join(w, "지아", Self.jia, at: row(11), nameColor: jiaColor)
        let log = emotes(from: x)
        w.scene.face(.right)
        w.scene.onTackleKey?()
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.mimicTackle])
        XCTAssertEqual(log.items.first?.targetMemberID, x.id)
        XCTAssertNil(log.items.first?.pushTiles)
    }

    func testOnlyADittoOnThePlazaMimics() async {
        mySpecies = 25   // subject() already shows an egg-disguised Ditto as its fake species (spec 3)
        let w = await world()
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        let log = emotes(from: x)
        w.c.chooseMenu(.tackle, memberID: x.id)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.tackle])
        XCTAssertNil(w.c.mimicking)
    }

    func testTacklingATeammateDisguisesMeAsThem() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        await waitUntil { x.session.members[w.me.id]?.mimicOf == x.id }
        XCTAssertEqual(w.c.mimicking, x.id)
        XCTAssertEqual(w.scene.myShownName, "지아")
        XCTAssertEqual(w.scene.myShownNameColor, PlazaNameColor.color(forMemberID: x.id, chosen: jiaColor))
        XCTAssertEqual(w.scene.myTitle, nature(.timid))
        XCTAssertEqual(w.c.myShownSubject, .init(speciesID: 25, isShiny: true))
    }

    func testTacklingAnotherTeammateSwitchesAndRestartsTheClock() async {
        let (w, x) = await dittoWorld()
        let y = await join(w, "노랑", Self.other, at: row(28))
        let t0 = now
        w.c.chooseMenu(.tackle, memberID: x.id)
        now = t0.addingTimeInterval(200)
        w.c.chooseMenu(.tackle, memberID: y.id)
        XCTAssertEqual(w.c.mimicking, y.id)
        now = t0.addingTimeInterval(499)
        await gate.tick()
        XCTAssertEqual(w.c.mimicking, y.id)
        now = t0.addingTimeInterval(500)
        await gate.tick()
        XCTAssertNil(w.c.mimicking)
    }

    func testTacklingTheSameTeammateAgainReleasesMe() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        now = now.addingTimeInterval(1)
        w.c.chooseMenu(.tackle, memberID: x.id)
        await waitUntil { x.session.members[w.me.id]?.mimicOf == nil }
        XCTAssertNil(w.c.mimicking)
        XCTAssertEqual(w.scene.myShownName, "나")
    }

    func testTacklingADisguisedDittoLeavesMeAsIAm() async {
        let (w, x) = await dittoWorld()
        let y = await join(w, "노랑", Self.other, at: row(28))
        let b = await join(w, "비", Self.ditto, at: row(20))
        let log = emotes(from: b)
        b.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[b.id] == x.id }
        w.c.chooseMenu(.tackle, memberID: b.id)
        await settle()
        XCTAssertEqual(log.items.map(\.kind), [.mimicTackle])
        XCTAssertNil(w.c.mimicking)

        now = now.addingTimeInterval(1)
        w.c.chooseMenu(.tackle, memberID: y.id)
        now = now.addingTimeInterval(1)
        w.c.chooseMenu(.tackle, memberID: b.id)
        XCTAssertEqual(w.c.mimicking, y.id)
    }

    func testCopyingAnUndisguisedDittoTakesItsRealLook() async {
        let (w, x) = await dittoWorld()
        let b = await join(w, "비", Self.ditto, at: row(20))
        w.c.chooseMenu(.tackle, memberID: b.id)
        XCTAssertEqual(w.c.mimicking, b.id)
        XCTAssertEqual(w.scene.myShownName, "비")
        XCTAssertEqual(w.c.myShownSubject.speciesID, 132)
        b.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[b.id] == x.id }
        await settle()
        XCTAssertEqual(w.scene.myShownName, "비")
        XCTAssertEqual(w.c.myShownSubject.speciesID, 132)
    }

    func testFiveMinutesEndMyDisguiseWhileTheWindowIsCovered() async {
        let (w, x) = await dittoWorld()
        let t0 = now
        w.c.chooseMenu(.tackle, memberID: x.id)
        w.c.setRendering(visible: false)
        await settle()
        now = t0.addingTimeInterval(299)
        await gate.tick()
        XCTAssertEqual(w.c.mimicking, x.id)
        now = t0.addingTimeInterval(300)
        await gate.tick()
        XCTAssertNil(w.c.mimicking)
        await waitUntil { x.session.members[w.me.id]?.mimicOf == nil }
        XCTAssertEqual(w.scene.myShownName, "나")
        XCTAssertEqual(w.c.myShownSubject.speciesID, 132)
    }

    func testTheCopiedMemberLeavingEndsMyDisguise() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        XCTAssertEqual(w.c.mimicking, x.id)
        x.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await waitUntil { w.c.mimicking == nil }
        await waitUntil { x.session.members[w.me.id]?.mimicOf == nil }
        XCTAssertNil(x.session.members[w.me.id]?.mimicOf)
    }

    /// Copying another Ditto draws the same species I already am, so no sprite reload follows to notice the leaver:
    /// only the member-list path can end the disguise before the next tick.
    func testACopiedDittoLeavingEndsMyDisguiseWithoutATick() async {
        mySpecies = 132
        let w = await world()
        let d = await join(w, "디토", Self.ditto, at: row(24))
        w.c.chooseMenu(.tackle, memberID: d.id)
        XCTAssertEqual(w.c.mimicking, d.id)
        d.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await waitUntil { w.c.mimicking == nil }
        XCTAssertNil(w.c.mimicking)
    }

    func testNoLongerADittoEndsMyDisguise() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        XCTAssertEqual(w.c.mimicking, x.id)
        mySpecies = 25
        await w.c.refreshCharacter()
        XCTAssertNil(w.c.mimicking)
    }

    func testClosingThePlazaEndsMyDisguise() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        await waitUntil { x.session.members[w.me.id]?.mimicOf == x.id }
        w.c.handleClose()
        await waitUntil { x.session.members[w.me.id]?.mimicOf == nil }
        w.c.prepareScene()
        XCTAssertNil(w.c.mimicking)
        XCTAssertEqual(w.c.scene?.myShownName, "나")
    }

    func testTheHintShowsWhoIAmAndTheTimeLeft() async {
        let (w, x) = await dittoWorld()
        let t0 = now
        w.c.chooseMenu(.tackle, memberID: x.id)
        now = t0.addingTimeInterval(48)
        w.c.refreshHintForTesting()
        XCTAssertEqual(w.c.hint, "지아로 변신 중 · 4:12")
        now = t0.addingTimeInterval(59.5)
        await gate.tick()
        XCTAssertEqual(w.c.hint, "지아로 변신 중 · 4:01")
        now = now.addingTimeInterval(1)
        w.c.chooseMenu(.tackle, memberID: x.id)
        w.c.refreshHintForTesting()
        XCTAssertFalse(w.c.hint?.contains("변신 중") ?? false)
    }

    func testMyDisguiseFollowsTheirNameColour() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        x.settings.nameColor = 0x7FD4FF
        x.session.applySettings()
        await waitUntil { w.scene.myShownNameColor == PlazaNameColor.color(forMemberID: x.id, chosen: 0x7FD4FF) }
    }

    // MARK: - Roster, menu and hints

    func testClickingEitherOfThemInTheRosterAsks() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(20))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        let y = await join(w, "노랑", Self.other, at: row(28))
        let log = emotes(from: x)
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        w.c.walkToMember(x.id)
        await settle()
        XCTAssertNil(w.scene.walkingToMember)
        XCTAssertEqual(w.scene.shownEmote(memberID: nil), .question)
        now = now.addingTimeInterval(0.4)   // past the 0.3 s emote throttle (0.3 exactly rounds under it)
        w.c.walkToMember(m.id)
        await settle()
        XCTAssertNil(w.scene.walkingToMember)
        XCTAssertEqual(w.scene.shownEmote(memberID: nil), .question)
        XCTAssertEqual(log.items.map(\.kind), [.question, .question])
        w.c.walkToMember(y.id)
        XCTAssertEqual(w.scene.walkingToMember, y.id)
    }

    func testWhileIMimicClickingTheOneICopyAsks() async {
        let (w, x) = await dittoWorld()
        w.c.chooseMenu(.tackle, memberID: x.id)
        XCTAssertEqual(w.c.mimicking, x.id, "test precondition")
        now = now.addingTimeInterval(0.4)   // the tackle just used the emote throttle
        w.c.walkToMember(x.id)
        await settle()
        XCTAssertNil(w.scene.walkingToMember)
        XCTAssertEqual(w.scene.shownEmote(memberID: nil), .question)
    }

    /// m ("민수", a Ditto) stands beside me, facing me, and copies x ("지아").
    private func copyBeside() async -> (w: World, m: Node, x: Node) {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(11))
        let x = await join(w, "지아", Self.jia, at: row(24), nameColor: jiaColor)
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        await settle()
        w.scene.face(.right)
        return (w, m, x)
    }

    func testTheSpaceHintAndMenuUseTheCopiedName() async {
        let (w, m, x) = await copyBeside()
        w.c.refreshHintForTesting()
        XCTAssertEqual(w.c.hint, "스페이스바를 눌러 지아에게 말 걸기")
        w.scene.onInteractKey?()
        guard case .memberMenu(let menu) = w.c.overlayContent else { return XCTFail("menu opens") }
        XCTAssertEqual(menu.nickname, "지아")
        XCTAssertEqual(menu.nameColor, 0xFF9ECF)
        XCTAssertTrue(menu.actions.contains(.viewCard))
        w.c.chooseMenu(.viewCard, memberID: m.id)
        guard case .card(.loading(let state)) = w.c.overlayContent else { return XCTFail("card opens") }
        XCTAssertEqual(state.memberID, x.id)
    }

    func testAMenuOnACopyOfMeHasNoCard() async {
        let w = await world()
        let m = await join(w, "민수", Self.ditto, at: row(11))
        m.session.updateMimic(w.me.id)
        await waitUntil { w.c.shownMimics[m.id] == w.me.id }
        await settle()
        w.scene.face(.right)
        w.scene.onInteractKey?()
        guard case .memberMenu(let menu) = w.c.overlayContent else { return XCTFail("menu opens") }
        XCTAssertEqual(menu.nickname, "나")
        XCTAssertFalse(menu.actions.contains(.viewCard))
    }

    func testAMenuWhoseDisguiseChangedDoesNothing() async {
        let (w, m, _) = await copyBeside()
        w.scene.onInteractKey?()
        guard case .memberMenu = w.c.overlayContent else { return XCTFail("menu opens") }
        m.session.updateMimic(nil)
        await waitUntil { w.c.shownMimics[m.id] == nil }
        w.c.chooseMenu(.viewCard, memberID: m.id)
        XCTAssertEqual(w.c.overlayContent, .none)
    }

    // MARK: - Being found

    private var clockT: TimeInterval = 0

    private func run(_ w: World, _ seconds: TimeInterval) {
        let end = clockT + seconds
        w.scene.update(clockT)
        while clockT < end - 1e-9 { clockT += 0.05; w.scene.update(clockT) }
    }

    /// I am a Ditto copying x ("지아"), Doyun ("도윤", Pikachu) stands at `doyunAt`.
    private func disguisedWorld(doyunAt: TilePoint? = nil) async -> (w: World, x: Node, doyun: Node, log: EmoteLog) {
        let (w, x) = await dittoWorld()
        let doyun = await join(w, "도윤", Self.pikachu, at: doyunAt ?? row(11))
        let log = emotes(from: doyun)
        w.c.chooseMenu(.tackle, memberID: x.id)
        await waitUntil { x.session.members[w.me.id]?.mimicOf == x.id }
        XCTAssertEqual(w.c.mimicking, x.id, "test precondition")
        return (w, x, doyun, log)
    }

    private func founds(_ log: EmoteLog) -> [TeamEmote] { log.items.filter { $0.kind == .mimicFound } }

    func testATackleRevealsMeInsteadOfPushing() async {
        let (w, _, doyun, log) = await disguisedWorld()
        let start = w.scene.walker.tile
        w.c.showTackle(from: doyun.id, on: w.me.id, tiles: 2)
        run(w, 1)
        XCTAssertEqual(w.scene.walker.tile, start)
        XCTAssertNil(w.c.mimicking)
        await waitUntil { !self.founds(log).isEmpty }
        XCTAssertEqual(founds(log).first?.targetMemberID, doyun.id)
        await waitUntil { doyun.session.members[w.me.id]?.mimicOf == nil }
        XCTAssertEqual(w.scene.shownEmote(memberID: nil), .exclaim)
        XCTAssertEqual(w.c.banner, "도윤님이 나의 메타몽을 찾았어요!")
    }

    func testTheFindIsSentBeforeTheDisguiseIsDropped() async {
        let (w, x, doyun, _) = await disguisedWorld()
        var seen: [String?] = []
        let me = w.me.id
        doyun.session.onEmote = { [doyun] _, e in
            if e.kind == .mimicFound { seen.append(doyun.session.members[me]?.mimicOf) }
        }
        w.c.showTackle(from: doyun.id, on: me)
        await waitUntil { !seen.isEmpty }
        XCTAssertEqual(seen, [x.id])
    }

    func testADittosTackleRevealsADisguisedMe() async {
        let (w, _, _, _) = await disguisedWorld()
        let a = await join(w, "에이", Self.ditto, at: row(9))
        let log = emotes(from: a)
        w.c.showMimicTackle(from: a.id, on: w.me.id)
        run(w, 1)
        XCTAssertNil(w.c.mimicking)
        await waitUntil { !self.founds(log).isEmpty }
        XCTAssertEqual(founds(log).first?.targetMemberID, a.id)
    }

    /// A Ditto's tackle on a third member is only a burst here, whether the Ditto is next to them or far away, and a
    /// target this scene doesn't draw is ignored. None of it touches my own disguise.
    func testADittosTackleOnSomeoneElseOnlyBursts() async {
        let (w, _, doyun, _) = await disguisedWorld()
        let a = await join(w, "에이", Self.ditto, at: row(12))   // next to 도윤 (row 11)
        let far = await join(w, "비", Self.ditto, at: row(18))
        let start = w.scene.walker.tile
        var before = w.scene.impactCount
        w.c.showMimicTackle(from: a.id, on: doyun.id)
        run(w, 1)
        XCTAssertEqual(w.scene.impactCount, before + 1, "next to them")
        before = w.scene.impactCount
        w.c.showMimicTackle(from: far.id, on: doyun.id)
        run(w, 1)
        XCTAssertEqual(w.scene.impactCount, before + 1, "from afar")
        before = w.scene.impactCount
        w.c.showMimicTackle(from: a.id, on: "nobody")
        run(w, 1)
        XCTAssertEqual(w.scene.impactCount, before, "a target this scene doesn't draw")
        XCTAssertNotNil(w.c.mimicking)
        XCTAssertEqual(w.scene.walker.tile, start)
    }

    func testADittoOnMyOwnTileStillFindsMe() async {
        let (w, _, _, _) = await disguisedWorld()
        let a = await join(w, "에이", Self.ditto, at: w.scene.walker.tile)
        let log = emotes(from: a)
        w.c.showMimicTackle(from: a.id, on: w.me.id)
        run(w, 1)
        XCTAssertNil(w.c.mimicking)
        await waitUntil { !self.founds(log).isEmpty }
    }

    func testADittosTackleOnAnUndisguisedMePushesNobody() async {
        let (w, _) = await dittoWorld()
        let a = await join(w, "에이", Self.ditto, at: row(11))
        let start = w.scene.walker.tile
        w.c.showMimicTackle(from: a.id, on: w.me.id)
        run(w, 1)
        XCTAssertEqual(w.scene.walker.tile, start)
        XCTAssertEqual(w.scene.impactCount, 1)
    }

    func testATackleFromAfarOnlyShowsTheStar() async {
        let (w, _, doyun, log) = await disguisedWorld(doyunAt: row(7))
        let start = w.scene.walker.tile
        let before = w.scene.impactCount
        w.c.showTackle(from: doyun.id, on: w.me.id)
        run(w, 1)
        XCTAssertNotNil(w.c.mimicking)
        XCTAssertEqual(w.scene.walker.tile, start)
        XCTAssertEqual(w.scene.impactCount, before + 1)
        await settle()
        XCTAssertTrue(founds(log).isEmpty)
    }

    func testASnowballRevealsMeWhenItLands() async {
        now = PlazaSnowballControllerTests.day(6)
        let (w, _, doyun, log) = await disguisedWorld(doyunAt: row(6))   // 4 tiles: a 3-tile ball lands in under 0.3 s
        let start = w.scene.walker.tile
        w.c.showSnowball(from: doyun.id, on: w.me.id, tiles: 2, direction: .right)
        run(w, 0.3)
        XCTAssertNotNil(w.c.mimicking, "still in the air")
        run(w, 0.9)
        XCTAssertNil(w.c.mimicking)
        XCTAssertEqual(w.scene.walker.tile, start)
        await waitUntil { !self.founds(log).isEmpty }
        XCTAssertEqual(founds(log).first?.targetMemberID, doyun.id)
    }

    func testASnowballIDodgeLeavesMeDisguised() async {
        now = PlazaSnowballControllerTests.day(6)
        let (w, _, doyun, log) = await disguisedWorld(doyunAt: row(6))
        w.c.showSnowball(from: doyun.id, on: w.me.id, tiles: 2, direction: .right)
        w.scene.pushMe(.down, tiles: 1)   // gone from the tile it was aimed at before it lands
        run(w, 1.2)
        XCTAssertNotNil(w.c.mimicking, "a miss doesn't find me")
        await settle()
        XCTAssertTrue(founds(log).isEmpty)
    }

    func testMySnowballAsADittoIsAnOrdinarySnowball() async {
        now = PlazaSnowballControllerTests.day(6)
        mySpecies = 132
        let w = await world()
        let x = await join(w, "지아", Self.jia, at: row(13), nameColor: jiaColor)
        let log = emotes(from: x)
        w.scene.face(.right)
        run(w, 0.1)
        w.scene.handleKeyDown(keyCode: 9, characters: "ㅁ", isRepeat: false)
        await waitUntil { log.items.contains { $0.kind == .snowball } }
        XCTAssertEqual(log.items.first { $0.kind == .snowball }?.targetMemberID, x.id)
        XCTAssertNil(w.c.mimicking)
    }

    func testTheGuestCopysPrankDoesNotRevealMe() async {
        let (w, x, _, _) = await disguisedWorld(doyunAt: row(7))
        let state = PlazaDittoState(tile: row(11), facing: .down, isWalking: nil, isRunning: nil, decoyOf: nil, since: now, restUntil: nil)
            .copying(x.id, now: now)
        w.quiet.session.updateDitto(ready: true, state: state)
        await settle()
        w.c.advanceDitto(now: now)
        run(w, 1)
        XCTAssertEqual(w.scene.decoyTile, row(11), "test precondition")
        w.c.showDecoyTackle(from: w.quiet.id, on: w.me.id)
        run(w, 1)
        XCTAssertEqual(w.c.mimicking, x.id)
    }

    // MARK: - Seeing a find

    private func disguisedOther(_ w: World, _ x: Node) async -> Node {
        let m = await join(w, "민수", Self.ditto, at: row(20))
        m.session.updateMimic(x.id)
        await waitUntil { w.c.shownMimics[m.id] == x.id }
        return m
    }

    func testOthersSeeTheRevealBanner() async {
        let (w, x) = await dittoWorld()
        let doyun = await join(w, "도윤", Self.pikachu, at: row(7))
        let m = await disguisedOther(w, x)
        w.c.showMimicFound(from: m.id, finder: doyun.id)
        XCTAssertEqual(w.scene.shownEmote(memberID: m.id), .exclaim)
        XCTAssertEqual(w.c.banner, "도윤님이 민수의 메타몽을 찾았어요!")
        w.c.showMimicFound(from: m.id, finder: w.me.id)
        XCTAssertEqual(w.c.banner, "나님이 민수의 메타몽을 찾았어요!")
    }

    func testAFoundFromSomeoneNotDisguisedIsIgnored() async {
        let (w, x) = await dittoWorld()
        let doyun = await join(w, "도윤", Self.pikachu, at: row(7))
        let plain = await join(w, "민수", Self.ditto, at: row(20))
        w.c.showMimicFound(from: plain.id, finder: doyun.id)
        XCTAssertNil(w.c.banner)
        XCTAssertNil(w.scene.shownEmote(memberID: plain.id))
        let m = await disguisedOther(w, x)
        w.c.showMimicFound(from: m.id, finder: nil)
        XCTAssertNil(w.c.banner)
        XCTAssertNil(w.scene.shownEmote(memberID: m.id))
    }
}
