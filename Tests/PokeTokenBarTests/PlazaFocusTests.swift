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
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
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
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
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
        return PlazaPreferences(defaults: TestDefaults.make(suite: name))
    }

    private func controller(_ me: Node, prefs: PlazaPreferences? = nil, start: TilePoint? = TilePoint(x: 23, y: 14),
                            speciesID: Int? = 25, myEntry: PlazaRosterEntry? = nil,
                            onEnd: ((PlazaFocusEnd) -> Void)? = nil, dittoSeed: UInt64? = nil) -> PlazaWindowController {
        let prefs = prefs ?? self.prefs()
        if let start { prefs.saveLastTile(start) }
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: speciesID, isShiny: false) },
                                      myRosterEntry: { myEntry }, session: me.session, clock: { [unowned self] in now },
                                      focusTickSleep: { [gate] in await gate.sleep($0) },
                                      dittoLoopSleep: ParkedDitto.loopSleep,
                                      dittoSeed: { dittoSeed ?? ParkedDitto.seed })
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

    private func pair(start: TilePoint? = TilePoint(x: 23, y: 14), speciesID: Int? = 25,
                      onEnd: ((PlazaFocusEnd) -> Void)? = nil, dittoSeed: UInt64? = nil) async -> (me: Node, other: Node, c: PlazaWindowController) {
        let me = node("나"), other = node("가")
        let c = controller(me, start: start, speciesID: speciesID, onEnd: onEnd, dittoSeed: dittoSeed)
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
        XCTAssertEqual(menu.selection, 3, "up from the first wraps to the fire row")
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
        let seat = TilePoint(x: 22, y: 13)
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
        // 앉은 자리에서는 스페이스 대상이 없다(불은 어느 자리에서도 대상이 아니다). 불을 켜고 끄는 줄만 있는 메뉴가 열리고,
        // 다시 시작해도 바뀌지 않는다.
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [], selection: 0, isLit: true, isSeated: true)))
        key(scene, 53)
        c.startFocus(minutes: 25)
        XCTAssertEqual(c.focus, expected)
        c.handleClose()
    }

    func testJoiningALitFireUsesMyOwnDuration() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        await place(other, at: TilePoint(x: 22, y: 13), focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertTrue(c.isCampfireLit)
        XCTAssertTrue(scene.campfireLit)
        XCTAssertEqual(c.hint, "스페이스바를 눌러 같이 집중하기")
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [25, 50, 480], selection: 0, isLit: true)))
        key(scene, spaceKey)
        XCTAssertEqual(c.focus, PlazaFocus(endsAt: now.addingTimeInterval(1500), minutes: 25, seat: TilePoint(x: 25, y: 13)))
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
        XCTAssertEqual(PlazaCampfireMenuView.notice(menu), "자리가 없어요")
        XCTAssertEqual(PlazaCampfireMenuView.rows(menu), ["불 켜기"])
        XCTAssertNil(PlazaCampfireMenuView.notice(.init(isJoin: false, minutes: [], selection: 0, isSeated: true)), "I already sit")
        XCTAssertEqual(PlazaCampfireMenuView.rows(.init(isJoin: false, minutes: [25, 480], selection: 0, isLit: true)),
                       ["25분 집중", "8시간 집중", "불 끄기"])
        key(scene, downKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(menu), "the fire row is the only row")
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertTrue(c.isCampfireLit, "the only row lights the fire")
        XCTAssertFalse(c.isFocusing)
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

    func testArrowsInPhotoModeDoNotEndAFocus() async {
        var ends: [PlazaFocusEnd] = []
        let (_, _, c) = await pair { ends.append($0) }
        let scene = c.scene!
        c.startFocus(minutes: 25)
        key(scene, 35)
        XCTAssertTrue(c.isPhotoMode)
        key(scene, leftKey)
        XCTAssertEqual(ends, [])
        XCTAssertNotNil(c.focus)
        key(scene, 53)
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertNotNil(c.focus)
        key(scene, leftKey)
        XCTAssertEqual(ends.count, 1)
        XCTAssertNil(c.focus)
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

    func testDisplayTickEndsADueFocusOnItsOwn() async {
        var ends: [PlazaFocusEnd] = []
        let (_, other, c) = await pair { ends.append($0) }
        let scene = c.scene!
        c.startFocus(minutes: 25)
        await gate.tick()
        XCTAssertEqual(ends, [])
        now = now.addingTimeInterval(1501)
        await gate.tick()
        XCTAssertEqual(ends, [PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true)])
        XCTAssertNil(c.focus)
        XCTAssertEqual(scene.shownEmote(memberID: nil), .party)
        await waitUntil { !other.received.emotes.isEmpty }
        await gate.tick()
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(other.received.emotes.count, 1)
        c.handleClose()
        await gate.tick()
    }

    func testArrowKeyAfterTheEndTimeCountsAsCompleted() async {
        var ends: [PlazaFocusEnd] = []
        let (_, _, c) = await pair { ends.append($0) }
        let scene = c.scene!
        c.startFocus(minutes: 25)
        now = now.addingTimeInterval(1501)
        key(scene, leftKey)
        XCTAssertEqual(ends, [PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true)])
        XCTAssertEqual(scene.shownEmote(memberID: nil), .party)
        c.handleClose()
    }

    func testMyRosterEntryShowsFocusWhileSeated() async {
        let me = node("나")
        let mine = PlazaRosterEntry(id: me.settings.memberID, nickname: "나", speciesID: 25, speciesName: "Pikachu",
                                    gender: nil, isShiny: false, presence: .online, isMe: true)
        let c = controller(me, myEntry: mine)
        c.prepareScene()
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .online)
        c.startFocus(minutes: 25)
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .focus)
        key(c.scene!, leftKey)
        XCTAssertEqual(c.rosterEntries.first { $0.isMe }?.presence, .online)
        c.handleClose()
    }

    func testCAndSpaceKeepASeatedUserFacingTheFire() async {
        let (_, other, c) = await pair()
        c.startFocus(minutes: 25)
        let scene = c.scene!
        let seat = scene.walker.tile
        let facing = scene.walker.facing
        XCTAssertEqual(facing, .down, "the teammate stands to the side, not ahead")
        await place(other, at: TilePoint(x: seat.x + 1, y: seat.y), in: c)
        scene.onTackleKey?()
        XCTAssertEqual(scene.walker.facing, facing)
        key(scene, spaceKey)
        XCTAssertNotNil(menu(c), "the member menu still opens")
        XCTAssertEqual(scene.walker.facing, facing)
        c.handleClose()
        await gate.tick()
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
        p.focus = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 22, y: 13))
        let c = controller(me, prefs: p, speciesID: nil) { ends.append($0) }
        c.prepareScene()
        let scene = c.scene!
        XCTAssertEqual(scene.walker.tile, TilePoint(x: 22, y: 13))
        key(scene, downKey)
        XCTAssertNil(c.focus)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(scene.walker.tile, TilePoint(x: 22, y: 13), "an egg cannot walk off")
        c.handleClose()
    }

    // MARK: - 창을 닫거나 다시 켤 때

    func testClosingWhileFocusingKeepsMeSeatedAndReopeningStartsOnTheSeat() async {
        let (me, other, c) = await pair()
        c.startFocus(minutes: 25)
        let seat = TilePoint(x: 22, y: 13)
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
        let saved = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 25, y: 13))
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
    }

    /// v2.5.614 에서 저장한 자리(모닥불이 오른쪽 아래였을 때)는 집중을 잃지 않고 가장 가까운 새 자리로 옮겨 앉는다.
    func testAFocusSavedAtAnOldSeatMovesToTheNearestNewSeat() async {
        let me = node("나"), other = node("가")
        await connect(me, other)
        let p = prefs()
        let old = PlazaFocus(endsAt: now.addingTimeInterval(600), minutes: 25, seat: TilePoint(x: 35, y: 21))
        p.focus = old
        let c = controller(me, prefs: p)
        let seat = PlazaCampfire.nearestSeat(to: old.seat)!
        XCTAssertNotEqual(seat.tile, old.seat)
        XCTAssertTrue(c.isFocusing, "the focus survives the upgrade")
        XCTAssertEqual(c.focus, PlazaFocus(endsAt: old.endsAt, minutes: 25, seat: seat.tile))
        XCTAssertEqual(p.focus, c.focus, "the new seat is saved, so the next launch restores it as is")
        await waitUntil { seen(other, me)?.focusEndsAt == old.endsAt }
        XCTAssertEqual(seen(other, me)?.tile, seat.tile)
        XCTAssertEqual(seen(other, me)?.facing, seat.facing)

        // 끝난 집중은 자리와 상관없이 조용히 버린다.
        now = now.addingTimeInterval(601)
        var ends: [PlazaFocusEnd] = []
        XCTAssertFalse(controller(me, prefs: p) { ends.append($0) }.isFocusing)
        XCTAssertNil(p.focus)
        XCTAssertEqual(ends, [])
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

    // MARK: - 스위치

    private func chooseFireRow(_ c: PlazaWindowController, line: UInt = #line) {
        key(c.scene!, spaceKey)
        guard case .campfireMenu(let menu) = c.overlayContent else { return XCTFail("no menu", line: line) }
        c.chooseCampfire(index: menu.toggleIndex)
    }

    func testTheFireRowLightsAndPutsOutAFireNobodyFocusesAt() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        chooseFireRow(c)
        XCTAssertTrue(scene.campfireLit)
        XCTAssertFalse(c.isFocusing, "lighting the fire does not sit me down")
        XCTAssertEqual(c.hint, "스페이스바를 눌러 모닥불 피우기", "nobody to join")
        await waitUntil { other.session.members[self.seenID(c)]?.campfire?.lit == true }
        now = now.addingTimeInterval(86_400)
        await gate.tick()
        XCTAssertTrue(scene.campfireLit, "it burns until someone puts it out")
        chooseFireRow(c)
        XCTAssertFalse(scene.campfireLit)
        c.handleClose()
        await gate.tick()
    }

    private func seenID(_ c: PlazaWindowController) -> String { c.memberIDForTesting }

    func testTheFireCanBePutOutWhileATeammateFocusesAndANewFocusRelightsIt() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        await place(other, at: PlazaCampfire.seats[0].tile, focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertTrue(scene.campfireLit)
        chooseFireRow(c)
        XCTAssertFalse(scene.campfireLit)
        XCTAssertNotNil(c.scene?.memberTiles[other.settings.memberID], "the teammate keeps focusing")
        now = now.addingTimeInterval(5)
        key(scene, spaceKey)
        c.chooseCampfire(index: 0)
        XCTAssertTrue(c.isFocusing)
        XCTAssertTrue(scene.campfireLit, "my new focus lights it again")
        c.handleClose()
        await gate.tick()
    }

    func testPuttingOutMyOwnFireKeepsMyFocus() async {
        let (_, _, c) = await pair()
        let scene = c.scene!
        key(scene, spaceKey)
        c.chooseCampfire(index: 0)
        XCTAssertTrue(scene.campfireLit)
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [], selection: 0, isLit: true, isSeated: true)))
        c.chooseCampfire(index: 0)
        XCTAssertFalse(scene.campfireLit)
        XCTAssertTrue(c.isFocusing)
        XCTAssertEqual(scene.campfireTimerText, "25:00")
        c.handleClose()
        await gate.tick()
    }

    func testAHandLitFireStaysWhileATeammateStillFocusesThenGoesOut() async {
        let (_, other, c) = await pair()
        let scene = c.scene!
        chooseFireRow(c)
        key(scene, spaceKey)
        c.chooseCampfire(index: 0)
        await place(other, at: PlazaCampfire.seats[5].tile, focusEnds: now.addingTimeInterval(3000), in: c)
        now = now.addingTimeInterval(1501)
        await gate.tick()
        XCTAssertFalse(c.isFocusing)
        XCTAssertTrue(scene.campfireLit, "a teammate still focuses")
        now = now.addingTimeInterval(1500)
        await gate.tick()
        XCTAssertFalse(scene.campfireLit, "it goes out with the last focus, even if that Mac never says so")
        c.handleClose()
        await gate.tick()
    }

    func testAHandLitFireGoesOutWhenMyFocusWasTheLast() async {
        let (_, _, c) = await pair()
        let scene = c.scene!
        chooseFireRow(c)
        key(scene, spaceKey)
        c.chooseCampfire(index: 0)
        now = now.addingTimeInterval(1501)
        await gate.tick()
        XCTAssertFalse(c.isFocusing)
        XCTAssertFalse(scene.campfireLit)
        c.handleClose()
        await gate.tick()
    }

    func testATeammatesSwitchIsLearnedKeptAndOnlyTheLaterOneWins() async {
        let me = node("나"), other = node("가")
        let prefs = prefs()
        let c = controller(me, prefs: prefs)
        c.prepareScene()
        await connect(me, other)
        let t = now.timeIntervalSince1970
        other.session.updateCampfire(PlazaCampfireSwitch(lit: true, at: t - 10))
        await waitUntil { c.isCampfireLit }
        XCTAssertTrue(c.scene!.campfireLit)
        XCTAssertEqual(prefs.campfire, PlazaCampfireSwitch(lit: true, at: t - 10))
        other.session.updateCampfire(PlazaCampfireSwitch(lit: false, at: t - 20))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(c.isCampfireLit, "an earlier switch loses")
        other.session.updateCampfire(PlazaCampfireSwitch(lit: false, at: t + 61))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(c.isCampfireLit, "a switch from too far ahead is dropped")
        other.session.updateCampfire(PlazaCampfireSwitch(lit: false, at: t + 50))
        await waitUntil { !c.isCampfireLit }
        c.setCampfire(lit: true)
        XCTAssertTrue(c.isCampfireLit, "my own switch wins over a clock that runs ahead")
        c.handleClose()
        await gate.tick()
        let again = controller(me, prefs: prefs)
        XCTAssertTrue(again.isCampfireLit, "kept across a restart")
    }

    func testMinimapShowsTheFireOnlyWhileLit() async {
        let (_, other, c) = await pair()
        XCTAssertNil(c.minimapCampfire)
        await place(other, at: PlazaMapData.map.spawn, focusEnds: now.addingTimeInterval(600), in: c)
        XCTAssertEqual(c.minimapCampfire, TilePoint(x: 23, y: 15))
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
        c.scene!.face(.right)
        key(c.scene!, spaceKey)
        XCTAssertEqual(menu(c)?.actions, [.greet, .viewCard])
        XCTAssertEqual(menu(c)?.status, "🔥 집중 중 · 18분 남음")
        c.handleClose()
    }

    func testWhileFocusingMyMenuHasNoTackleOrFollow() async {
        let (_, other, c) = await pair(start: spawn)
        await place(other, at: beside, in: c)
        c.scene!.face(.right)
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

    /// The Ditto is on the tile I face, and the teammate is beside me. Facing the teammate picks the teammate; the
    /// Ditto's `[.tackle]` menu must not replace the teammate's (the v2.5.632 gate flake: the Ditto sat at (10, 11)).
    func testFacingTheTeammateOpensTheirMenuWithTheDittoAhead() async {
        let ahead = TilePoint(x: spawn.x, y: spawn.y + 1)
        let (_, other, c) = await pair(start: spawn, dittoSeed: ParkedDitto.seed(landingOn: ahead))
        await place(other, at: beside, in: c)
        XCTAssertEqual(c.scene!.dittoTile, ahead, "test precondition: the Ditto stands where I would face by default")
        c.scene!.face(.right)
        key(c.scene!, spaceKey)
        XCTAssertEqual(menu(c)?.memberID, other.settings.memberID)
        XCTAssertEqual(menu(c)?.actions, [.greet, .tackle, .follow, .viewCard])
        c.handleClose()
    }

    func testTheHarnessParksTheDittoAwayFromEveryTestTile() async {
        let (_, _, c) = await pair(start: spawn)
        let ditto = c.scene!.dittoTile
        XCTAssertNotNil(ditto, "test precondition: the Ditto is on the map")
        XCTAssertGreaterThan(abs((ditto?.x ?? 0) - spawn.x) + abs((ditto?.y ?? 0) - spawn.y), 8)
        c.handleClose()
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

    // MARK: - 춤

    private let dKey: UInt16 = 2

    /// 집중 중에는 D가 춤도 소식도 만들지 않고, 일어서면 춘다. 한 판마다 팀원에게 한 번씩 춤을 보낸다.
    func testDWhileFocusingDoesNothingAndThenDancesAndSendsOneEmotePerRound() async {
        let (me, other, c) = await pair()
        let scene = c.scene!
        c.startFocus(minutes: 25)
        await waitUntil { seen(other, me)?.focusEndsAt != nil }
        key(scene, dKey)
        XCTAssertFalse(scene.isDancing(memberID: nil))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(other.received.emotes.filter { $0.emote.kind == .dance }.count, 0, "nothing was sent")
        key(scene, leftKey)   // 일어선다
        scene.handleKeyUp(keyCode: leftKey)
        XCTAssertNil(c.focus)
        for i in 1...20 { scene.update(Double(i) * 0.05) }   // 걸음을 마친다
        key(scene, dKey)
        let style = scene.danceStyle(memberID: nil)
        XCTAssertNotNil(style)
        await waitUntil { other.received.emotes.contains { $0.emote.kind == .dance } }
        let sent = other.received.emotes.filter { $0.emote.kind == .dance }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.emote.danceStyle, style?.id)
        XCTAssertNil(sent.first?.emote.targetMemberID)
        c.handleClose()
        await gate.tick()
    }

    /// 말풍선·점프·인사·몸통박치기·불꽃놀이·글은 실제로 일어날 때 내 춤을 멈추고, 연타 제한에 걸려 아무 일도 없으면 멈추지 않는다.
    func testEachLocalActionStopsMyDance() async {
        var sceneClock = 4000.0
        let actions: [(String, (PlazaWindowController) -> Void)] = [
            ("bubble", { $0.scene!.onEmoteKey?(.heart) }),
            ("jump", { $0.scene!.onJumpKey?() }),
            ("greet", { $0.scene!.onGreetKey?() }),
            ("tackle", { $0.scene!.onTackleKey?() }),
            ("firework", { $0.scene!.onFireworkKey?() }),
            ("chat", { _ = $0.chatInputForTesting.onSubmit?("안녕") }),
        ]
        for (name, act) in actions {
            let (_, other, c) = await pair(start: spawn)
            let scene = c.scene!
            scene.now = { Date(timeIntervalSince1970: sceneClock) }
            await place(other, at: beside, in: c)
            key(scene, dKey)
            XCTAssertTrue(scene.isDancing(memberID: nil), name)
            act(c)
            XCTAssertFalse(scene.isDancing(memberID: nil), "\(name) stops the dance")
            XCTAssertNotEqual(scene.shownEmote(memberID: nil), .dance, "\(name): the notes went too")
            c.handleClose()
            await gate.tick()
        }
        // A rate-limited repeat does nothing, so it leaves the next dance alone.
        let (_, _, c) = await pair(start: spawn)
        let scene = c.scene!
        scene.now = { Date(timeIntervalSince1970: sceneClock) }
        scene.onEmoteKey?(.heart)
        sceneClock += 1
        key(scene, dKey)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        scene.onEmoteKey?(.lol)   // same controller clock: too soon, ignored
        XCTAssertTrue(scene.isDancing(memberID: nil), "a bubble that was refused does not stop the dance")
        c.handleClose()
        await gate.tick()
    }

    /// 사진 모드와 단체 사진은 춤을 멈추지 않는다.
    func testPhotoModeAndGroupPhotoDoNotStopMyDance() async {
        let (_, other, c) = await pair(start: spawn)
        let scene = c.scene!
        key(scene, dKey)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        key(scene, 35)   // P
        XCTAssertTrue(scene.isPhotoMode)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        scene.onGroupPhotoKey?()
        XCTAssertTrue(scene.isDancing(memberID: nil))
        for i in 1...50 { scene.update(Double(i) * 0.05) }   // 2.5 s: past a round
        XCTAssertTrue(scene.isDancing(memberID: nil))
        await waitUntil { other.received.emotes.filter { $0.emote.kind == .dance }.count >= 2 }
        c.handleClose()
        await gate.tick()
    }

    /// 자리비움이 아직 안 풀렸을 때(주기 점검 전) 시작한 새 춤은 팀원 소식이 와도 멈추지 않는다. 멈추는 것은 막 자리를 비운 순간뿐이다.
    func testAnIdleFlagThatHasNotRefreshedDoesNotStopANewDance() async {
        let (me, other, c) = await pair(start: spawn)
        let scene = c.scene!
        me.session.updateIdle(true)
        for _ in 0..<40 { await Task.yield() }
        key(scene, dKey)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        await place(other, at: beside, in: c)   // a teammate update while `isIdle` is still true
        XCTAssertTrue(scene.isDancing(memberID: nil), "level-triggered idle would stop it here")
        c.handleClose()
        await gate.tick()
    }

    /// 자리비움이 되면 춤이 멈춘다.
    func testGoingIdleStopsMyDance() async {
        let (me, _, c) = await pair(start: spawn)
        let scene = c.scene!
        key(scene, dKey)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        me.session.updateIdle(true)
        await waitUntil { !scene.isDancing(memberID: nil) }
        c.handleClose()
        await gate.tick()
    }

    /// 앉아서 집중하는 팀원의 춤은 이 화면에서 무시한다.
    func testADanceFromAFocusingTeammateIsIgnored() async {
        let (_, other, c) = await pair()
        await place(other, at: TilePoint(x: 22, y: 13), focusEnds: now.addingTimeInterval(600), in: c)
        let id = other.settings.memberID
        c.showDance(memberID: id, style: "sway")
        XCTAssertFalse(c.scene!.isDancing(memberID: id))
        await place(other, at: TilePoint(x: 22, y: 13), in: c)
        other.session.updateFocus(endsAt: nil)
        for _ in 0..<40 { await Task.yield() }
        c.showDance(memberID: id, style: "sway")
        XCTAssertTrue(c.scene!.isDancing(memberID: id), "control: the same teammate dances once the focus is over")
        c.handleClose()
        await gate.tick()
    }
}
