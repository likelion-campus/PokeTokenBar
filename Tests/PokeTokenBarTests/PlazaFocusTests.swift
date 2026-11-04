import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private let spaceKey: UInt16 = 49, upKey: UInt16 = 126, downKey: UInt16 = 125, leftKey: UInt16 = 123, returnKey: UInt16 = 36

/// 1초 틱을 테스트가 손으로 넘긴다.
@MainActor private final class TickGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { waiters.append($0) } }
    /// 기다리는 틱을 풀고 그 뒤 일이 끝나도록 양보한다.
    func tick() async {
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
final class PlazaFocusTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let gate = TickGate()

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
        let received: Received
    }

    @MainActor final class Received { var emotes: [(from: String, emote: TeamEmote)] = [] }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let suite = "plaza.focus.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaFocusTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) },
                                  clock: { [unowned self] in now })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] id, emote in received.emotes.append((id, emote)) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    private func prefs() -> PlazaPreferences {
        let name = "plaza.focus.prefs.\(UUID())"
        suites.append(name)
        return PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
    }

    private func controller(_ me: Node, prefs: PlazaPreferences? = nil, start: TilePoint? = TilePoint(x: 36, y: 22),
                            speciesID: Int? = 25, onEnd: ((PlazaFocusEnd) -> Void)? = nil) -> PlazaWindowController {
        let prefs = prefs ?? self.prefs()
        if let start { prefs.saveLastTile(start) }
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: speciesID, isShiny: false) },
                                      myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now },
                                      focusTickSleep: { [gate] in await gate.sleep($0) })
        c.onFocusEnd = onEnd
        return c
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", line: line)
    }

    private func key(_ scene: PlazaScene, _ code: UInt16) {
        scene.handleKeyDown(keyCode: code, characters: "", isRepeat: false)
    }

    private func pair(start: TilePoint? = TilePoint(x: 36, y: 22), speciesID: Int? = 25,
                      onEnd: ((PlazaFocusEnd) -> Void)? = nil) async -> (me: Node, other: Node, c: PlazaWindowController) {
        let me = node("나"), other = node("가")
        let c = controller(me, start: start, speciesID: speciesID, onEnd: onEnd)
        c.prepareScene()
        await connect(me, other)
        return (me, other, c)
    }

    /// 팀원이 그 칸에 서 있고 내 장면이 그걸 본다.
    private func place(_ other: Node, at tile: TilePoint, focusEnds: Date? = nil, in c: PlazaWindowController) async {
        other.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        other.session.updateFocus(endsAt: focusEnds)
        await waitUntil { c.scene?.memberTiles[other.settings.memberID] == tile }
        for _ in 0..<20 { await Task.yield() }
    }

    private func seen(_ other: Node, _ me: Node) -> TeamMemberState? { other.session.members[me.settings.memberID] }

    // MARK: - 메뉴

    func testSpaceAtTheUnlitPitOffersTheThreeDurations() async {
        let (_, _, c) = await pair()
        let scene = c.scene!
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: [25, 50, 480], selection: 0)))
        XCTAssertTrue(c.isCampfireMenuOpen)
        c.handleClose()
        c.prepareScene()
        XCTAssertEqual(c.hint, "스페이스바를 눌러 모닥불 피우기")
        key(c.scene!, spaceKey)
        key(c.scene!, upKey)
        guard case .campfireMenu(let menu) = c.overlayContent else { return XCTFail("no menu") }
        XCTAssertEqual(menu.selection, 2, "up from the first wraps to the last")
        key(c.scene!, downKey)
        key(c.scene!, downKey)
        guard case .campfireMenu(let menu2) = c.overlayContent else { return XCTFail("no menu") }
        XCTAssertEqual(menu2.selection, 1)
        key(c.scene!, 53)
        XCTAssertEqual(c.overlayContent, .none, "escape closes")
        c.handleClose()
    }

    func testChoosingADurationSitsMeAndLightsTheFire() async {
        let (me, other, c) = await pair()
        let scene = c.scene!
        XCTAssertFalse(scene.campfireLit)
        key(scene, spaceKey)
        key(scene, downKey)
        key(scene, spaceKey)
        let seat = TilePoint(x: 35, y: 21)
        let expected = PlazaFocus(endsAt: now.addingTimeInterval(3000), minutes: 50, seat: seat)
        XCTAssertEqual(c.focus, expected)
        XCTAssertTrue(c.isFocusing)
        XCTAssertEqual(scene.walker.tile, seat)
        XCTAssertEqual(scene.walker.facing, .down)
        XCTAssertTrue(scene.campfireLit)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertEqual(scene.campfireTimerText, "50:00")
        await waitUntil { seen(other, me)?.focusEndsAt != nil }
        let state = seen(other, me)
        XCTAssertEqual(state?.inPlaza, true)
        XCTAssertEqual(state?.tile, seat)
        XCTAssertEqual(state?.focusEndsAt, now.addingTimeInterval(3000))
        XCTAssertEqual(c.hint, "🔥 50분 남음 · 방향키로 일어나기")
        // 앉아 있는 동안 스페이스는 메뉴를 다시 열지 않고, 다시 시작해도 바뀌지 않는다.
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .none)
        c.startFocus(minutes: 25)
        XCTAssertEqual(c.focus, expected)
        c.handleClose()
    }

    func testJoiningALitFireUsesMyOwnDuration() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        await place(other, at: TilePoint(x: 35, y: 21), focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertTrue(c.isCampfireLit)
        XCTAssertTrue(scene.campfireLit)
        XCTAssertEqual(c.hint, "스페이스바를 눌러 같이 집중하기")
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [25, 50, 480], selection: 0)))
        key(scene, spaceKey)
        XCTAssertEqual(c.focus, PlazaFocus(endsAt: now.addingTimeInterval(1500), minutes: 25, seat: TilePoint(x: 38, y: 21)))
        c.handleClose()
    }

    func testNoFreeSeatShowsOnlyTheNotice() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        var others: [Node] = []
        for (i, seat) in PlazaCampfire.seats.enumerated() {
            let n = node("팀\(i)")
            others.append(n)
            await connect(me, n)
            await place(n, at: seat.tile, in: c)
        }
        let scene = c.scene!
        key(scene, spaceKey)
        let menu = PlazaCampfireMenu(isJoin: false, minutes: [], selection: 0)
        XCTAssertEqual(c.overlayContent, .campfireMenu(menu))
        XCTAssertEqual(PlazaCampfireMenuView.rows(menu), ["자리가 없어요"])
        XCTAssertEqual(PlazaCampfireMenuView.rows(.init(isJoin: false, minutes: [25, 480], selection: 0)), ["25분 집중", "8시간 집중"])
        key(scene, downKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(menu), "arrows do nothing without rows")
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertNil(c.focus)
        key(scene, spaceKey)
        key(scene, returnKey)
        XCTAssertEqual(c.overlayContent, .none, "enter closes it too")
        XCTAssertNil(c.focus)
        c.startFocus(minutes: 25)
        XCTAssertNil(c.focus, "a seat taken after the menu opened still starts nothing")
        c.handleClose()
    }

    // MARK: - 일어서기와 끝

    func testArrowKeyStandsMeUp() async {
        var ends: [PlazaFocusEnd] = []
        let (me, other, c) = await pair { ends.append($0) }
        let scene = c.scene!
        c.startFocus(minutes: 25)
        await waitUntil { seen(other, me)?.focusEndsAt != nil }
        now = now.addingTimeInterval(600)
        key(scene, leftKey)
        XCTAssertEqual(ends, [PlazaFocusEnd(minutes: 25, elapsedMinutes: 10, completed: false)])
        XCTAssertNil(c.focus)
        XCTAssertNil(c.preferencesFocusForTesting)
        await waitUntil { seen(other, me)?.focusEndsAt == nil }
        key(scene, leftKey)
        XCTAssertEqual(ends.count, 1, "not focusing: an arrow key ends nothing")
        c.handleClose()
    }

    func testDueFocusEndsOnceWithACelebration() async {
        var ends: [PlazaFocusEnd] = []
        let (_, other, c) = await pair { ends.append($0) }
        let scene = c.scene!
        c.startFocus(minutes: 25)
        c.endFocusIfDue()
        XCTAssertEqual(ends, [], "not due yet")
        now = now.addingTimeInterval(1501)
        c.endFocusIfDue()
        c.endFocusIfDue()
        XCTAssertEqual(ends, [PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true)])
        XCTAssertEqual(scene.shownEmote(memberID: nil), .party)
        await waitUntil { !other.received.emotes.isEmpty }
        XCTAssertEqual(other.received.emotes.count, 1)
        XCTAssertEqual(other.received.emotes.first?.emote.kind, .party)
        XCTAssertNil(other.received.emotes.first?.emote.targetMemberID)
        c.handleClose()
    }

    func testSilentEndSkipsCallbackAndParty() async {
        var ends: [PlazaFocusEnd] = []
        let (_, other, c) = await pair { ends.append($0) }
        c.endFocusSilently()
        c.startFocus(minutes: 25)
        now = now.addingTimeInterval(1501)
        c.endFocusSilently()
        XCTAssertNil(c.focus)
        XCTAssertEqual(ends, [])
        XCTAssertNil(c.scene!.shownEmote(memberID: nil))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(other.received.emotes.isEmpty)
        c.handleClose()
    }

    func testWalkingToATeammateFromTheListStandsMeUp() async {
        var ends: [PlazaFocusEnd] = []
        let (_, other, c) = await pair { ends.append($0) }
        await place(other, at: PlazaMapData.map.spawn, in: c)
        c.startFocus(minutes: 25)
        c.walkToMember(other.settings.memberID)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends.first?.completed, false)
        XCTAssertEqual(c.scene?.walkingToMember, other.settings.memberID)
        c.handleClose()
    }

    func testAnEggOnASeatCanStandUp() async {
        var ends: [PlazaFocusEnd] = []
        let me = node("나")
        let p = prefs()
        p.focus = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 35, y: 21))
        let c = controller(me, prefs: p, speciesID: nil) { ends.append($0) }
        c.prepareScene()
        let scene = c.scene!
        XCTAssertEqual(scene.walker.tile, TilePoint(x: 35, y: 21))
        key(scene, downKey)
        XCTAssertNil(c.focus)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(scene.walker.tile, TilePoint(x: 35, y: 21), "an egg cannot walk off")
        c.handleClose()
    }

    // MARK: - 창을 닫거나 다시 켤 때

    func testClosingWhileFocusingKeepsMeSeatedAndReopeningStartsOnTheSeat() async {
        let (me, other, c) = await pair()
        c.startFocus(minutes: 25)
        let seat = TilePoint(x: 35, y: 21)
        c.handleClose()
        for _ in 0..<20 { await Task.yield() }
        let state = seen(other, me)
        XCTAssertEqual(state?.inPlaza, true)
        XCTAssertEqual(state?.tile, seat)
        XCTAssertEqual(state?.facing, .down)
        XCTAssertTrue(c.isFocusing)
        c.prepareScene()
        XCTAssertEqual(c.scene?.walker.tile, seat, "reopening starts on the seat, not the last tile")
        XCTAssertEqual(c.scene?.walker.facing, .down)
        XCTAssertEqual(c.scene?.campfireTimerText, "25:00")
        c.handleClose()
        now = now.addingTimeInterval(1501)
        c.endFocusIfDue()
        await waitUntil { seen(other, me)?.inPlaza == false }
        XCTAssertNil(seen(other, me)?.focusEndsAt)
    }

    func testRelaunchResumesOrDropsTheSavedFocus() async {
        let me = node("나"), other = node("가")
        await connect(me, other)
        let p = prefs()
        let saved = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 38, y: 21))
        p.focus = saved
        let c = controller(me, prefs: p)
        XCTAssertTrue(c.isFocusing)
        XCTAssertNil(c.scene)
        await waitUntil { seen(other, me)?.focusEndsAt == saved.endsAt }
        XCTAssertEqual(seen(other, me)?.tile, saved.seat)
        XCTAssertEqual(seen(other, me)?.inPlaza, true)
        XCTAssertEqual(seen(other, me)?.facing, .down)

        var ends: [PlazaFocusEnd] = []
        now = now.addingTimeInterval(601)
        let late = controller(me, prefs: p) { ends.append($0) }
        XCTAssertFalse(late.isFocusing)
        XCTAssertNil(p.focus)
        XCTAssertEqual(ends, [])

        // 자리 목록에 없는 칸에 저장돼 있으면 되살리지 않는다.
        p.focus = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 1, y: 1))
        XCTAssertFalse(controller(me, prefs: p).isFocusing)
        XCTAssertNil(p.focus)
    }

    // MARK: - 불과 타이머

    func testTimerUnderThePitCountsDown() async {
        let (_, _, c) = await pair()
        let scene = c.scene!
        XCTAssertNil(scene.campfireTimerText)
        c.startFocus(minutes: 25)
        XCTAssertEqual(scene.campfireTimerText, "25:00")
        now = now.addingTimeInterval(90)
        await gate.tick()
        XCTAssertEqual(scene.campfireTimerText, PlazaCampfire.clock(1410))
        XCTAssertEqual(c.hint, "🔥 24분 남음 · 방향키로 일어나기")
        key(scene, leftKey)
        XCTAssertNil(scene.campfireTimerText)
        c.handleClose()
        await gate.tick()
    }

    func testFireLightsFromTeammatesAndGoesOut() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        await place(other, at: PlazaMapData.map.spawn, focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertTrue(scene.campfireLit)
        now = now.addingTimeInterval(601)
        XCTAssertFalse(c.isCampfireLit)
        await gate.tick()
        XCTAssertFalse(scene.campfireLit)
        c.handleClose()
        await gate.tick()
    }

    func testMinimapShowsTheFireOnlyWhileLit() async {
        let (_, other, c) = await pair()
        XCTAssertNil(c.minimapCampfire)
        await place(other, at: PlazaMapData.map.spawn, focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertEqual(c.minimapCampfire, TilePoint(x: 36, y: 23))
        now = now.addingTimeInterval(601)
        await gate.tick()
        XCTAssertNil(c.minimapCampfire, "the 1 s tick alone puts the fire out")
        c.handleClose()
        await gate.tick()
    }

    func testRosterBadgeExpiresOnTheTickAlone() async {
        let (_, other, c) = await pair()
        let id = other.settings.memberID
        await place(other, at: PlazaMapData.map.spawn, focusEnds: now.addingTimeInterval(600), in: c)
        await gate.tick()
        XCTAssertEqual(c.rosterEntries.first { $0.id == id }?.presence, .focus)
        now = now.addingTimeInterval(601)
        await gate.tick()
        XCTAssertEqual(c.rosterEntries.first { $0.id == id }?.presence, .online)
        c.handleClose()
        await gate.tick()
    }

    // MARK: - 몸통박치기와 따라가기

    private var spawn: TilePoint { TilePoint(x: 10, y: 10) }
    private var beside: TilePoint { TilePoint(x: 11, y: 10) }

    private func menu(_ c: PlazaWindowController) -> PlazaMemberMenu? {
        if case .memberMenu(let m) = c.overlayContent { m } else { nil }
    }

    private func tackles(_ n: Node) -> Int { n.received.emotes.filter { $0.emote.kind == .tackle }.count }

    func testFocusingTeammateMenuHasNoTackleOrFollow() async {
        let (_, other, c) = await pair(start: spawn)
        XCTAssertTrue(PlazaMapData.map.isWalkable(beside), "test precondition")
        await place(other, at: beside, focusEnds: now.addingTimeInterval(1080), in: c)
        key(c.scene!, spaceKey)
        XCTAssertEqual(menu(c)?.actions, [.greet, .viewCard])
        XCTAssertEqual(menu(c)?.status, "🔥 집중 중 · 18분 남음")
        c.handleClose()
    }

    func testWhileFocusingMyMenuHasNoTackleOrFollow() async {
        let (_, other, c) = await pair(start: spawn)
        await place(other, at: beside, in: c)
        key(c.scene!, spaceKey)
        XCTAssertEqual(menu(c)?.actions, [.greet, .tackle, .follow, .viewCard], "baseline: not focusing")
        XCTAssertNil(menu(c)?.status)
        key(c.scene!, 53)
        c.startFocus(minutes: 25)
        let seat = c.scene!.walker.tile
        await place(other, at: TilePoint(x: seat.x + 1, y: seat.y), in: c)
        key(c.scene!, spaceKey)
        XCTAssertEqual(menu(c)?.actions, [.greet, .viewCard])
        XCTAssertNil(menu(c)?.status)
        c.handleClose()
        await gate.tick()
    }

    func testCDoesNothingAroundAFocus() async {
        let (_, other, c) = await pair(start: spawn)
        await place(other, at: beside, focusEnds: now.addingTimeInterval(600), in: c)
        c.scene!.onTackleKey?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(tackles(other), 0, "teammate is focusing")
        // 끝 시각이 지난 팀원은 더는 집중 중이 아니다(받을 때만 걸러지므로 지금과 다시 견준다).
        now = now.addingTimeInterval(601)
        c.scene!.onTackleKey?()
        await waitUntil { tackles(other) == 1 }
        c.handleClose()

        let (_, other2, c2) = await pair(start: spawn)
        c2.startFocus(minutes: 25)
        let seat = c2.scene!.walker.tile
        await place(other2, at: TilePoint(x: seat.x + 1, y: seat.y), in: c2)
        c2.scene!.onTackleKey?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(tackles(other2), 0, "I am focusing")
        c2.handleClose()
        await gate.tick()
    }

    func testFollowStopsWhenEitherSideStartsFocusing() async {
        let (_, other, c) = await pair(start: spawn)
        let scene = c.scene!
        await place(other, at: beside, in: c)
        XCTAssertTrue(scene.follow(member: other.settings.memberID))
        c.startFocus(minutes: 25)
        XCTAssertNil(scene.followingMember)
        c.handleClose()
        await gate.tick()

        let (_, other2, c2) = await pair(start: spawn)
        await place(other2, at: beside, in: c2)
        XCTAssertTrue(c2.scene!.follow(member: other2.settings.memberID))
        other2.session.updateFocus(endsAt: now.addingTimeInterval(600))
        await waitUntil { c2.scene?.followingMember == nil }
        c2.handleClose()
    }

    /// 모닥불 곁에서 팀원이 바로 옆에서 박치기를 했을 때 내가 밀리는지. 밀릴 수 있는 방향(양쪽 칸이 걸을 수 있음)을 골라 쓴다.
    private func pushed(focusing: Bool, menuOpen: Bool) async -> Bool {
        let map = PlazaMapData.map
        let (me, other, c) = await pair()
        let scene = c.scene!
        if focusing { c.startFocus(minutes: 25) }
        if menuOpen { key(scene, spaceKey) }
        XCTAssertEqual(c.isFocusing, focusing)
        XCTAssertEqual(c.isCampfireMenuOpen, menuOpen)
        let spot = scene.walker.tile
        let adjacent = [PlazaDirection.left, .right, .up, .down].map { PlazaWalker.offset(spot, $0) }
        guard let from = adjacent.first(where: { a in
            map.isWalkable(a) && map.isWalkable(TilePoint(x: 2 * spot.x - a.x, y: 2 * spot.y - a.y))
        }) else { XCTFail("no pushable side"); return false }
        await place(other, at: from, in: c)
        let before = scene.walker.tile
        c.showTackle(from: other.settings.memberID, on: me.settings.memberID)
        XCTAssertEqual(scene.impactCount, 1, "the impact always plays")
        for i in 1...20 { scene.update(Double(i) * 0.05) }
        c.handleClose()
        await gate.tick()
        return scene.walker.tile != before
    }

    func testTackleStillPushesWhenNotFocusingAndMenuClosed() async {
        let moved = await pushed(focusing: false, menuOpen: false)
        XCTAssertTrue(moved, "control: the harness really pushes")
    }

    func testFocusingMeIsNotPushedByATackle() async {
        let moved = await pushed(focusing: true, menuOpen: false)
        XCTAssertFalse(moved)
    }

    func testCampfireMenuOpenBlocksThePush() async {
        let moved = await pushed(focusing: false, menuOpen: true)
        XCTAssertFalse(moved)
    }
}
