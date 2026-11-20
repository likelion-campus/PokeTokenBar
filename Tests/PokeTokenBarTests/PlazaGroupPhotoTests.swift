import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Each countdown second waits here until the test lets it go.
@MainActor final class SecondGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func sleep() async { await withCheckedContinuation { waiting.append($0) } }
    func tick() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

/// 단체 사진 (G): a shared countdown that ends in a flash on every open plaza and a photo for those who take part.
@MainActor
final class PlazaGroupPhotoTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    let gate = SecondGate()
    var written: [Data] = []
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var frontmost = true
    var writeSucceeds = true

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        written = []
        writeSucceeds = true
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
    }

    private func node(_ name: String) -> Node {
        let suite = "plaza.groupphoto.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaGroupPhotoTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
        session.updateCharacter(mon)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func controller(_ me: Node) -> PlazaWindowController {
        let name = "plaza.groupphoto.prefs.\(UUID())"
        let gate = gate
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: name)),
                                      loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) }, session: me.session,
                                      clock: { [weak self] in self?.now ?? Date() },
                                      photoWriter: { [weak self] in self?.written.append($0); return self?.writeSucceeds ?? true },
                                      groupPhotoSleep: { _ in await gate.sleep() },
                                      isFrontmost: { [weak self] in self?.frontmost ?? true },
                                      shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
        c.prepareScene()
        c.scene?.backingOverride = 2
        c.scene?.size = CGSize(width: 400, height: 300)
        return c
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Lets one countdown second pass and waits for the controller to take it in.
    func tick() async {
        await waitUntil { gate.count > 0 }
        gate.tick()
        for _ in 0..<10 { await Task.yield() }
    }

    func connected() async -> (me: Node, other: Node, c: PlazaWindowController) {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID]?.nickname == "민수" }
        return (me, other, c)
    }

    func pressG(_ c: PlazaWindowController, isRepeat: Bool = false) {
        c.scene?.handleKeyDown(keyCode: 5, characters: "ㅎ", isRepeat: isRepeat)
    }

    func pressP(_ c: PlazaWindowController) {
        c.scene?.handleKeyDown(keyCode: 35, characters: "ㅔ", isRepeat: false)
    }

    private func pressEsc(_ c: PlazaWindowController) {
        c.scene?.handleKeyDown(keyCode: 53, characters: "\u{1b}", isRepeat: false)
    }


    /// Esc during the countdown leaves the shot: the flash still comes, the clipboard stays.
    func testEscDuringTheCountdownLeavesTheShot() async throws {
        let (_, _, c) = await connected()
        pressG(c)
        await tick()
        pressEsc(c)
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(c.countdown, "단체 사진 4 · P를 누르면 함께 찍어요")
        for _ in 0..<4 { await tick() }
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing)
        XCTAssertTrue(written.isEmpty)
    }

    /// A plaza left behind another app is not photographed, so a teammate's countdown cannot overwrite the clipboard.
    func testBackgroundPlazaIsNotPhotographed() async throws {
        let (_, other, c) = await connected()
        pressP(c)
        c.showGroupPhoto(from: other.settings.memberID)
        frontmost = false
        for _ in 0..<5 { await tick() }
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing)
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(c.isPhotoMode)
    }

    /// In photo mode with the plaza behind another window, the text says the photo needs the window in front; it follows
    /// the window gaining and losing key without waiting for the next second.
    func testTheCountdownSaysWhenThePlazaIsNotInFront() async {
        let (_, other, c) = await connected()
        pressG(c)
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!")
        frontmost = false
        c.handleResignKey()
        XCTAssertEqual(c.countdown, "단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요")
        frontmost = true
        c.handleBecomeKey()
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!")
        c.handleClose()
        c.prepareScene()
        c.showGroupPhoto(from: other.settings.memberID)
        pressP(c)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 5 · 함께 찍는 중")
        frontmost = false
        c.handleResignKey()
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요")
        c.handleClose()
    }


    /// A teammate whose name has not arrived yet (their presence comes after they connect) shows as 팀원.
    func testATeammateWithNoNameYetShowsAsTeammate() async {
        let (_, _, c) = await connected()
        c.showGroupPhoto(from: "not-a-member")
        XCTAssertEqual(c.countdown, "팀원님의 단체 사진 5 · P를 누르면 함께 찍어요")
    }

    /// While a countdown runs, another start (mine or a teammate's) does not restart it.
    func testASecondStartWhileCountingIsIgnored() async {
        let (_, other, c) = await connected()
        c.showGroupPhoto(from: other.settings.memberID)
        await tick()
        c.showGroupPhoto(from: other.settings.memberID)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 4 · P를 누르면 함께 찍어요")
    }


    /// Right after a countdown ends, a late G (meant to take part) does not start a new one for everyone.
    /// After the short pause it does.
    func testALateGRightAfterTheEndStartsNothing() async {
        let (_, other, c) = await connected()
        var received = 0
        other.session.onEmote = { _, _ in received += 1 }
        c.showGroupPhoto(from: other.settings.memberID)
        for _ in 0..<5 { await tick() }
        XCTAssertNil(c.countdown)
        now += PlazaWindowController.groupPhotoCooldown - 0.5
        pressG(c)
        XCTAssertNil(c.countdown, "too soon after the end")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received, 0)
        now += 1
        pressG(c)
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!")
        await waitUntil { received == 1 }
        XCTAssertEqual(received, 1)
    }
}
