import XCTest
import AppKit
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// Each countdown second waits here until the test lets it go.
@MainActor private final class SecondGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func sleep() async { await withCheckedContinuation { waiting.append($0) } }
    func tick() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

/// 단체 사진 (G): a shared countdown that ends in a flash on every open plaza and a photo for those who take part.
@MainActor
final class PlazaGroupPhotoTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private let gate = SecondGate()
    private var written: [Data] = []
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        written = []
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

    private func node(_ name: String) -> Node {
        let suite = "plaza.groupphoto.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
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
        suites.append(name)
        let gate = gate
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: name)!),
                                      loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) }, session: me.session,
                                      clock: { [weak self] in self?.now ?? Date() },
                                      photoWriter: { [weak self] in self?.written.append($0); return true },
                                      groupPhotoSleep: { _ in await gate.sleep() })
        c.prepareScene()
        c.scene?.backingOverride = 2
        c.scene?.size = CGSize(width: 400, height: 300)
        return c
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Lets one countdown second pass and waits for the controller to take it in.
    private func tick() async {
        await waitUntil { gate.count > 0 }
        gate.tick()
        for _ in 0..<10 { await Task.yield() }
    }

    private func connected() async -> (me: Node, other: Node, c: PlazaWindowController) {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID]?.nickname == "민수" }
        return (me, other, c)
    }

    private func pressG(_ c: PlazaWindowController, isRepeat: Bool = false) {
        c.scene?.handleKeyDown(keyCode: 5, characters: "ㅎ", isRepeat: isRepeat)
    }

    /// G starts a five-second countdown here and on teammates' plazas, then flashes and puts my photo on the clipboard.
    func testGStartsACountdownThatEndsInMyPhoto() async throws {
        let (_, other, c) = await connected()
        var received: [TeamEmote] = []
        other.session.onEmote = { received.append($1) }
        pressG(c)
        pressG(c, isRepeat: true)
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!")
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received, [TeamEmote(kind: .groupPhoto, targetMemberID: nil)])
        for left in [4, 3, 2, 1] {
            await tick()
            XCTAssertEqual(c.countdown, "단체 사진 \(left) · 모두 모여요!")
        }
        XCTAssertTrue(written.isEmpty)
        await tick()
        XCTAssertNil(c.countdown)
        XCTAssertEqual(written.count, 1, "one photo")
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing)
        XCTAssertEqual(received.count, 1, "the held G sent nothing more")
    }

    /// A teammate's countdown flashes my plaza too but leaves my clipboard alone, unless I press G to take part,
    /// which sends nothing.
    func testTeammatesCountdownTakesMyPhotoOnlyWhenIJoin() async throws {
        let (_, other, c) = await connected()
        let id = other.settings.memberID
        var received = 0
        other.session.onEmote = { _, _ in received += 1 }
        c.showGroupPhoto(from: id)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 5 · G를 누르면 함께 찍어요")
        for _ in 0..<5 { await tick() }
        XCTAssertNil(c.countdown)
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing, "everyone sees the flash")
        XCTAssertTrue(written.isEmpty, "my clipboard is not touched")

        c.showGroupPhoto(from: id)
        await tick()
        pressG(c)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 4 · 함께 찍는 중")
        for _ in 0..<4 { await tick() }
        XCTAssertNil(c.countdown)
        XCTAssertEqual(written.count, 1, "joined, so my photo is taken")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received, 0, "taking part sends nothing")
    }

    /// A teammate whose name has not arrived yet (their presence comes after they connect) shows as 팀원.
    func testATeammateWithNoNameYetShowsAsTeammate() async {
        let (_, _, c) = await connected()
        c.showGroupPhoto(from: "not-a-member")
        XCTAssertEqual(c.countdown, "팀원님의 단체 사진 5 · G를 누르면 함께 찍어요")
    }

    /// While a countdown runs, another start (mine or a teammate's) does not restart it.
    func testASecondStartWhileCountingIsIgnored() async {
        let (_, other, c) = await connected()
        c.showGroupPhoto(from: other.settings.memberID)
        await tick()
        c.showGroupPhoto(from: other.settings.memberID)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 4 · G를 누르면 함께 찍어요")
    }

    /// Closing the plaza mid-countdown cancels it. Reopened and started again within the five seconds, the old
    /// countdown's next second does nothing: the new one keeps its own count, and only it takes the photo.
    func testClosingThePlazaCancelsTheCountdown() async {
        let (_, _, c) = await connected()
        pressG(c)
        await tick()
        await waitUntil { gate.count > 0 }   // the old countdown waits on its second second
        c.handleClose()
        XCTAssertNil(c.countdown)
        c.prepareScene()
        pressG(c)
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!", "a new one starts")
        gate.tick()   // the old countdown wakes first
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!", "the old countdown does not count the new one down")
        for left in [4, 3, 2, 1] {
            await tick()
            XCTAssertEqual(c.countdown, "단체 사진 \(left) · 모두 모여요!")
        }
        XCTAssertTrue(written.isEmpty)
        await tick()
        XCTAssertEqual(written.count, 1, "one photo, from the new countdown")
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
