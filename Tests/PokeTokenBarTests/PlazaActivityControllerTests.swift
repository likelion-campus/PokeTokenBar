import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// The one-second tick, handed on by the test.
@MainActor private final class TickGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { waiters.append($0) } }
    func tick() async {
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Counting what I do in the plaza today: each action once per real action, time only while open and not away,
/// saved across a restart, rolled over at midnight, and told to teammates.
@MainActor
final class PlazaActivityControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = PlazaActivityControllerTests.day(6)
    private var t: TimeInterval = 0
    private let gate = TickGate()
    private let map = PlazaMapData.map
    private let zKey: UInt16 = 6, xKey: UInt16 = 7, cKey: UInt16 = 8, vKey: UInt16 = 9, fKey: UInt16 = 3, rightKey: UInt16 = 124

    static func day(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Self.day(6)
        t = 0
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.activity.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaActivityControllerTests-\(UUID())")
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

    private func makePrefs(start: TilePoint, iceBroken: Bool) -> PlazaPreferences {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.activity.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        // The left pond broken (the next one is the far right pond), unless a test breaks ice itself.
        if iceBroken { prefs.iceBreak = PlazaIceBreak(at: now.timeIntervalSince1970, pond: TilePoint(x: 5, y: 13)) }
        return prefs
    }

    private func controller(_ me: Node, prefs: PlazaPreferences, stage: Int = 1) -> PlazaWindowController {
        let entry = PlazaRosterEntry(id: me.settings.memberID, nickname: "나", speciesID: 25, speciesName: "Pikachu",
                                     gender: nil, isShiny: false, presence: .online, isMe: true)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                              nickname: { "나" }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { entry }, evolutionStage: { stage }, session: me.session, clock: { [unowned self] in now },
                              focusTickSleep: { [gate] in await gate.sleep($0) },
                              dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    private func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
    }

    @MainActor private struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    private func world(me mine: TilePoint, b bTile: TilePoint? = nil, facing: PlazaDirection = .right, iceBroken: Bool = true,
                       stage: Int = 1, prefs given: PlazaPreferences? = nil) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, prefs: given ?? makePrefs(start: mine, iceBroken: iceBroken), stage: stage)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b)
        w.scene.face(facing)
        if let bTile { await place(w, bTile) }
        run(w.scene, 0.1)
        return w
    }

    private func place(_ w: World, _ tile: TilePoint) async {
        w.b.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private var today: String { PlazaActivity.dayKey(now) }

    // MARK: - Each action counts once per real action

    func testFireworksCountOnePerShellAndARefusedShellDoesNot() async {
        let w = await world(me: p(10, 12))
        press(w.scene, fKey)
        XCTAssertEqual(w.c.activity.fireworks, 1)
        press(w.scene, fKey)
        XCTAssertEqual(w.c.activity.fireworks, 1, "the scene refuses a second shell within half a second")
        run(w.scene, 0.6)
        press(w.scene, fKey)
        XCTAssertEqual(w.c.activity.fireworks, 2)
        XCTAssertEqual(w.c.activity.tackles + w.c.activity.greetings + w.c.activity.snowballHits, 0)
    }

    func testTacklesCountWhenIHitSomeoneAndNotWithNobodyBesideOrTooSoon() async {
        let lonely = await world(me: p(10, 12))
        press(lonely.scene, cKey)
        XCTAssertEqual(lonely.c.activity.tackles, 0, "nobody beside me")
        let w = await world(me: p(10, 12), b: p(11, 12))
        press(w.scene, cKey)
        XCTAssertEqual(w.c.activity.tackles, 1)
        now = now.addingTimeInterval(0.29)
        press(w.scene, cKey)
        XCTAssertEqual(w.c.activity.tackles, 1, "the press limit holds back a second one")
        now = now.addingTimeInterval(0.02)
        press(w.scene, cKey)
        XCTAssertEqual(w.c.activity.tackles, 2)
        XCTAssertEqual(w.c.activity.greetings, 0)
    }

    func testATackleFromTheFocusSeatIsRefusedAndNotCounted() async {
        let w = await world(me: p(10, 12), b: p(11, 12))
        w.c.startFocus(minutes: 25)
        XCTAssertTrue(w.c.isFocusing, "test precondition")
        press(w.scene, cKey)
        XCTAssertEqual(w.c.activity.tackles, 0)
    }

    func testGreetingsCountWhenIGreetSomeoneAndNotWithNobodyBesideOrTooSoon() async {
        let lonely = await world(me: p(10, 12))
        press(lonely.scene, xKey)
        XCTAssertEqual(lonely.c.activity.greetings, 0)
        let w = await world(me: p(10, 12), b: p(11, 12))
        press(w.scene, xKey)
        XCTAssertEqual(w.c.activity.greetings, 1)
        now = now.addingTimeInterval(0.29)
        press(w.scene, xKey)
        XCTAssertEqual(w.c.activity.greetings, 1)
        now = now.addingTimeInterval(0.02)
        press(w.scene, xKey)
        XCTAssertEqual(w.c.activity.greetings, 2)
        XCTAssertEqual(w.c.activity.tackles, 0)
    }

    func testASnowballCountsWhenItHitsAndNotWhenItFliesAtNobody() async {
        let w = await world(me: p(10, 12), b: p(14, 12))
        press(w.scene, vKey)
        XCTAssertEqual(w.c.activity.snowballHits, 0, "still in the air")
        run(w.scene, 1.5)
        XCTAssertEqual(w.c.activity.snowballHits, 1)
        let miss = await world(me: p(10, 12), b: p(10, 8))
        press(miss.scene, vKey)
        run(miss.scene, 1.5)
        XCTAssertEqual(miss.scene.snowballFlightCount, 0, "the ball has landed")
        XCTAssertEqual(miss.c.activity.snowballHits, 0, "it flew past nobody")
    }

    func testASnowballThatTheTargetWalkedOutOfDoesNotCount() async {
        let w = await world(me: p(10, 12), b: p(14, 12))
        press(w.scene, vKey)
        await place(w, p(14, 13))
        run(w.scene, 1.5)
        XCTAssertEqual(w.c.activity.snowballHits, 0)
    }

    func testAThrownSnowballTooSoonAfterAnotherActionDoesNotCount() async {
        let w = await world(me: p(10, 12), b: p(14, 12))
        press(w.scene, vKey)
        press(w.scene, vKey)
        run(w.scene, 1.5)
        XCTAssertEqual(w.c.activity.snowballHits, 1, "the second press was held back")
    }

    // MARK: - Ice: counted when my break lands

    private func onIce() async -> World {
        let w = await world(me: p(4, 14), iceBroken: false)
        press(w.scene, rightKey)
        run(w.scene, 0.5)
        XCTAssertTrue(w.scene.isMeOnIce, "test precondition")
        return w
    }

    func testABreakingJumpCountsAtTheLandingNotAtThePress() async {
        let w = await onIce()
        press(w.scene, zKey)
        await settle()
        XCTAssertEqual(w.c.activity.iceBreaks, 0, "pressed, still in the air")
        run(w.scene, 0.3)
        XCTAssertEqual(w.c.activity.iceBreaks, 0)
        run(w.scene, 0.1)
        XCTAssertEqual(w.c.activity.iceBreaks, 1)
        run(w.scene, 1.0)
        XCTAssertEqual(w.c.activity.iceBreaks, 1, "once")
    }

    func testAPlainJumpOnLandAndATeammatesBreakAreNotMine() async {
        let w = await world(me: p(20, 10), b: p(8, 14), iceBroken: false)
        press(w.scene, zKey)
        run(w.scene, 0.6)
        XCTAssertEqual(w.c.activity.iceBreaks, 0, "an ordinary jump")
        w.c.showJump(memberID: w.b.id, iceBreak: PlazaIceBreak(at: now.timeIntervalSince1970, pond: p(5, 13)))
        run(w.scene, 0.6)
        XCTAssertNotNil(w.c.iceBreak, "test precondition: the break landed and was learned")
        XCTAssertEqual(w.c.activity.iceBreaks, 0, "their break")
    }

    func testABreakThatAnEarlierLandingMadeRedundantDoesNotCount() async {
        let w = await onIce()
        let theirs = PlazaIceBreak(at: now.timeIntervalSince1970 + 30, pond: p(5, 13))
        w.c.showJump(memberID: w.b.id, iceBreak: theirs)
        run(w.scene, 0.1)
        press(w.scene, zKey)
        run(w.scene, 1.0)
        XCTAssertEqual(w.c.iceBreak, theirs, "test precondition: theirs landed first and is the newer one")
        XCTAssertEqual(w.c.activity.iceBreaks, 0, "my break was not learned")
    }

    func testClosingBeforeTheLandingStillCountsMyBreakAndSavesIt() async {
        let prefs = makePrefs(start: p(4, 14), iceBroken: false)
        let w = await world(me: p(4, 14), iceBroken: false, prefs: prefs)
        press(w.scene, rightKey)
        run(w.scene, 0.5)
        press(w.scene, zKey)
        XCTAssertEqual(w.c.activity.iceBreaks, 0)
        w.c.handleClose()
        XCTAssertEqual(w.c.activity.iceBreaks, 1, "the waiting break lands as the scene stops")
        XCTAssertEqual(prefs.activity?.iceBreaks, 1)
    }

    // MARK: - Time

    func testTimeAccruesOneSecondPerTickWhileOpenAndNotAway() async {
        let w = await world(me: p(10, 12))
        XCTAssertEqual(w.c.activity.seconds, 0)
        await gate.tick()
        await gate.tick()
        await gate.tick()
        XCTAssertEqual(w.c.activity.seconds, 3)
        w.me.session.updateIdle(true)
        await gate.tick()
        await gate.tick()
        XCTAssertEqual(w.c.activity.seconds, 3, "away time is not counted")
        w.me.session.updateIdle(false)
        await gate.tick()
        XCTAssertEqual(w.c.activity.seconds, 4)
        w.c.handleClose()
        await gate.tick()
        await gate.tick()
        XCTAssertEqual(w.c.activity.seconds, 4, "a closed plaza counts nothing")
    }

    // MARK: - Midnight, saving, sharing

    func testMidnightWhileOpenRollsEverythingOverToZero() async {
        now = Self.day(6, 23, 59, 58)
        let w = await world(me: p(10, 12))
        press(w.scene, fKey)
        await gate.tick()
        XCTAssertEqual(w.c.activity.fireworks, 1)
        XCTAssertEqual(w.c.activity.seconds, 1)
        let before = w.c.activity.day
        now = Self.day(7, 0, 0, 1)
        await gate.tick()
        XCTAssertNotEqual(w.c.activity.day, before)
        XCTAssertEqual(w.c.activity.day, PlazaActivity.dayKey(now))
        XCTAssertEqual(w.c.activity.fireworks, 0)
        XCTAssertEqual(w.c.activity.seconds, 1, "the new day's first second")
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.activity?.day, PlazaActivity.dayKey(now), "teammates hear about the new day")
    }

    func testActionsAfterMidnightCountForTheNewDayEvenBeforeTheTick() async {
        now = Self.day(6, 23, 59, 59)
        let w = await world(me: p(10, 12))
        press(w.scene, fKey)
        now = Self.day(7, 0, 0, 1)
        run(w.scene, 0.6)
        press(w.scene, fKey)
        XCTAssertEqual(w.c.activity.day, PlazaActivity.dayKey(now))
        XCTAssertEqual(w.c.activity.fireworks, 1, "yesterday's shell is not today's")
    }

    func testTodaysCountersSurviveARestartAndAnOldDaysDoNot() async {
        let prefs = makePrefs(start: p(10, 12), iceBroken: true)
        let first = await world(me: p(10, 12), prefs: prefs)
        press(first.scene, fKey)
        await gate.tick()
        first.c.handleClose()
        XCTAssertEqual(prefs.activity?.fireworks, 1)
        XCTAssertEqual(prefs.activity?.seconds, 1)

        let sameDay = controller(node("나"), prefs: prefs)
        XCTAssertEqual(sameDay.activity.fireworks, 1)
        XCTAssertEqual(sameDay.activity.seconds, 1)

        now = Self.day(7, 8)
        let nextDay = controller(node("나"), prefs: prefs)
        XCTAssertEqual(nextDay.activity, PlazaActivity(day: PlazaActivity.dayKey(now)))
    }

    func testEveryCountIsToldToTeammatesAtOnce() async {
        let w = await world(me: p(10, 12), b: p(11, 12))
        press(w.scene, fKey)
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.activity?.fireworks, 1)
        press(w.scene, xKey)
        await settle()
        XCTAssertEqual(w.b.session.members[w.me.id]?.activity?.greetings, 1)
        XCTAssertEqual(w.b.session.members[w.me.id]?.activity?.day, today)
    }

    func testTheRosterShowsMyNumbersAndATeammatesOnlyForToday() async {
        let w = await world(me: p(10, 12), b: p(11, 12))
        press(w.scene, fKey)
        w.c.refreshRoster()
        XCTAssertEqual(w.c.rosterEntries.first { $0.isMe }?.activity?.fireworks, 1)
        var theirs = PlazaActivity(day: today)
        theirs.record(.pickup)
        w.b.session.updateActivity(theirs)
        await settle()
        w.c.refreshRoster()
        XCTAssertEqual(w.c.rosterEntries.first { $0.id == w.b.id }?.activity, theirs)
        w.b.session.updateActivity(PlazaActivity(day: "1999-01-01"))
        await settle()
        w.c.refreshRoster()
        XCTAssertNil(w.c.rosterEntries.first { $0.id == w.b.id }?.activity, "their day is not mine: no record")
    }
}
