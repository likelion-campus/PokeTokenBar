import XCTest
import SwiftUI
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// 키 1–5의 keyCode. 순서는 ♥, ㅋㅋ, 🎉, !, ?.
private let heartKey: UInt16 = 18, lolKey: UInt16 = 19, partyKey: UInt16 = 20, exclaimKey: UInt16 = 21, questionKey: UInt16 = 23

@MainActor
final class PlazaEmoteTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
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
        /// 이 세션이 받은 말풍선(보낸 멤버 ID, 내용)
        let received: Received
    }

    @MainActor final class Received {
        var emotes: [(from: String, emote: TeamEmote)] = []
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let suite = "plaza.emote.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaEmoteTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] id, emote in received.emotes.append((id, emote)) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    private func defaults() -> UserDefaults {
        let name = "plaza.emote.prefs.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func controller(_ me: Node, start: TilePoint? = nil, speciesID: Int? = 25) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        if let start { prefs.saveLastTile(start) }
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    private func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    /// 시작 칸에서 바라보는 칸이 갈 수 있는 칸인 시작 칸.
    private func startFacingDown() -> TilePoint { map.spawn }

    private func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    // MARK: - 인사하기

    /// A greeting between two teammates shows over both of them here.
    func testGreetingShowsOverTheSenderAndTheTarget() async {
        let me = node("나"), b = node("가"), d = node("다")
        let c = controller(me)
        c.prepareScene()
        await connect(me, b)
        await connect(me, d)
        let scene = c.scene!, bID = b.settings.memberID, dID = d.settings.memberID
        for _ in 0..<200 where scene.memberTiles[bID] == nil || scene.memberTiles[dID] == nil { await Task.yield() }
        c.showEmote(memberID: bID, kind: .heart, alsoOver: dID)
        XCTAssertEqual(scene.shownEmote(memberID: bID), .heart)
        XCTAssertEqual(scene.shownEmote(memberID: dID), .heart)
        XCTAssertNil(scene.shownEmote(memberID: nil), "not over me")
    }

    // MARK: - 키와 그림

    func testEmoteKeysWorkWithHangulInput() {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [TeamEmoteKind] = []
        scene.onEmoteKey = { pressed.append($0) }
        // 한글 입력기에서는 characters가 "1"이 아니다. keyCode로만 판정한다.
        for key in [heartKey, lolKey, partyKey, exclaimKey, questionKey] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false), .swallowed)
        }
        XCTAssertEqual(pressed, [.heart, .lol, .party, .exclaim, .question])
        pressed = []
        for key: UInt16 in [0, 22, 24, 49] { scene.handleKeyDown(keyCode: key, characters: "1", isRepeat: false) }
        XCTAssertEqual(pressed, [], "other keys, even with a '1' character, are not emotes")
    }

    /// Z jumps, X greets and C tackles, also with Hangul input (the characters are "ㅋ", "ㅌ", "ㅊ"); not with
    /// Cmd/Ctrl/Opt or when held. J no longer jumps.
    func testZXCKeysWorkWithHangulInputOnly() {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [String] = []
        scene.onJumpKey = { pressed.append("jump") }
        scene.onGreetKey = { pressed.append("greet") }
        scene.onTackleKey = { pressed.append("tackle") }
        scene.onGroupPhotoKey = { pressed.append("groupPhoto") }
        for (code, hangul) in [(UInt16(6), "ㅋ"), (7, "ㅌ"), (8, "ㅊ"), (5, "ㅎ")] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: false), .swallowed)
            scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: true)
            for mod: NSEvent.ModifierFlags in [.command, .control, .option] {
                scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: false, modifiers: mod)
            }
        }
        XCTAssertEqual(pressed, ["jump", "greet", "tackle", "groupPhoto"])
        scene.handleKeyDown(keyCode: 38, characters: "j", isRepeat: false)
        XCTAssertEqual(pressed, ["jump", "greet", "tackle", "groupPhoto"], "J is not a shortcut any more")
    }

    /// The top-left guide lists every key the plaza answers to.
    func testShortcutGuideListsEveryKey() {
        XCTAssertEqual(PlazaShortcutGuide.entries.map(\.key),
                       ["방향키", "Shift", "Space", "Enter", "1–5", "Z", "X", "C", "D", "F", "P", "G", "−/+"])
        XCTAssertEqual(PlazaShortcutGuide.entries.map(\.label),
                       ["걷기", "달리기", "말 걸기", "한마디", "말풍선", "점프 · 물놀이", "인사하기", "몸통박치기", "춤", "불꽃놀이", "사진 모드", "단체 사진", "확대·축소"])
    }

    /// The guide's rows are identified by key, so a repeated key would draw the first row twice.
    func testShortcutGuideKeysAreUnique() {
        let keys = PlazaShortcutGuide.entries.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "repeated keys: \(keys)")
    }

    /// Folded, the guide is only its title line; unfolded it shows every key.
    func testFoldedShortcutGuideIsOnlyTheTitle() throws {
        func height(folded: Bool) throws -> CGFloat {
            let model = PlazaShortcutGuideModel()
            model.isFolded = folded
            let r = ImageRenderer(content: PlazaShortcutGuide(model: model, toggle: {}))
            return try XCTUnwrap(r.nsImage).size.height
        }
        let folded = try height(folded: true), open = try height(folded: false)
        XCTAssertLessThan(folded, 40, "one line")
        XCTAssertGreaterThan(open, folded + CGFloat(PlazaShortcutGuide.entries.count) * 16)
    }

    func testModifiedOrRepeatedEmoteKeysDoNotFire() {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [TeamEmoteKind] = []
        scene.onEmoteKey = { pressed.append($0) }
        for mod: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: heartKey, characters: "1", isRepeat: false, modifiers: mod), .swallowed)
        }
        XCTAssertEqual(pressed, [], "Cmd, Ctrl and Opt combinations are not emotes")
        XCTAssertEqual(scene.handleKeyDown(keyCode: heartKey, characters: "1", isRepeat: true), .swallowed)
        XCTAssertEqual(pressed, [], "auto-repeat is not an emote")
        scene.handleKeyDown(keyCode: heartKey, characters: "!", isRepeat: false, modifiers: .shift)
        XCTAssertEqual(pressed, [.heart], "Shift still works")
    }

    func testEachEmoteHasArt() {
        var pixels: [Data] = []
        // The decoy kinds and the pull are protocol messages, never bubbles; a new kind must be listed on purpose.
        let decoyKinds: [TeamEmoteKind] = [.decoyFound, .decoyJump, .decoyTackle, .pull, .snowball]
        let bubbleKinds: [TeamEmoteKind] = [.heart, .lol, .party, .exclaim, .question, .tackle, .jump, .groupPhoto, .pickup,
                                            .firework, .dance]
        XCTAssertEqual(Set(bubbleKinds + decoyKinds), Set(TeamEmoteKind.allCases), "every kind is sorted into bubble or message")
        for kind in bubbleKinds {
            let one = PlazaEmoteArt.image(kind, scale: 1)
            let two = PlazaEmoteArt.image(kind, scale: 2)
            XCTAssertGreaterThan(one.width, 0)
            XCTAssertEqual(two.width, one.width * 2, "\(kind)")
            XCTAssertEqual(two.height, one.height * 2, "\(kind)")
            let data = one.dataProvider?.data as Data? ?? Data()
            XCTAssertTrue(data.contains { $0 != 0 }, "\(kind) draws something")
            pixels.append(data)
        }
        XCTAssertEqual(Set(pixels).count, bubbleKinds.count, "every kind looks different")
        XCTAssertEqual(L(.ko).plazaEmoteLol, "ㅋㅋ")
    }

    func testDecoyKindsDrawNoBubble() {
        let map = PlazaMapData.map
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        for kind in [TeamEmoteKind.decoyFound, .decoyJump] {
            scene.showEmote(memberID: nil, kind: kind)
            XCTAssertNil(scene.shownEmote(memberID: nil), "\(kind)")
        }
    }

    /// The greeting bubble is the same art with 3-point dots: exactly 1.5 times as big, and every dot is still a
    /// whole block of one colour. The content sits half a dot off the bubble grid, so compare at 2x, where half a
    /// dot is 2 pixels in the normal bubble and 3 in the large one.
    func testGreetingBubbleIsTheSameArtOneAndAHalfTimesAsBig() {
        func pixels(_ image: CGImage) -> [UInt8] {
            var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return raw
        }
        XCTAssertEqual(PlazaEmoteArt.size(large: true).width, PlazaEmoteArt.size.width * 1.5)
        XCTAssertEqual(PlazaEmoteArt.size(large: true).height, PlazaEmoteArt.size.height * 1.5)
        for kind in [TeamEmoteKind.heart, .party, .exclaim, .question] {
            let small = PlazaEmoteArt.image(kind, scale: 2), large = PlazaEmoteArt.image(kind, scale: 2, large: true)
            XCTAssertEqual(large.width * 2, small.width * 3, "\(kind)")
            let s = pixels(small), l = pixels(large)
            // Half-dot blocks: 3x3 pixels in the large bubble map to 2x2 in the normal one.
            var same = true
            for y in 0..<(large.height) where same {
                for x in 0..<(large.width) {
                    let li = (y * large.width + x) * 4, si = ((y / 3 * 2) * small.width + x / 3 * 2) * 4
                    if l[li..<li + 4] != s[si..<si + 4] { same = false; break }
                }
            }
            XCTAssertTrue(same, "\(kind) is the same dots, only bigger")
        }
    }

    /// Reads the bubble's inside (the cells clear of border and tail) as ink/white pixels at 1 px per point.
    private func interiorInk(_ kind: TeamEmoteKind) -> (ink: Set<[Int]>, onlyInkAndWhite: Bool) {
        let image = PlazaEmoteArt.image(kind, scale: 1)
        var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var ink = Set<[Int]>()
        var clean = true
        for y in 2..<20 {          // buffer row 0 is the top
            for x in 4..<24 {
                let i = (y * image.width + x) * 4
                let rgb = (Int(raw[i]), Int(raw[i + 1]), Int(raw[i + 2]))
                if rgb == (255, 255, 255) { continue }
                if rgb == (0x14, 0x16, 0x1F), raw[i + 3] == 255 { ink.insert([x, y]) } else { clean = false }
            }
        }
        return (ink, clean)
    }

    func testExclaimAndQuestionAreDotGridsLikeTheHeart() {
        for kind in [TeamEmoteKind.exclaim, .question] {
            let (ink, clean) = interiorInk(kind)
            XCTAssertTrue(clean, "\(kind): only whole ink or white dots, no smoothed font edge")
            XCTAssertFalse(ink.isEmpty, "\(kind)")
            let xs = ink.map { $0[0] }
            XCTAssertEqual(xs.min()! + xs.max()!, 27, "\(kind) is centred in the 28 px bubble")
            XCTAssertEqual(xs.min()! % 2, 0, "\(kind) sits on the 2 px dot grid")
            for y in Set(ink.map { $0[1] }) {
                let row = ink.filter { $0[1] == y }.map { $0[0] }.sorted()
                var runs: [Int] = [], length = 1
                for (a, b) in zip(row, row.dropFirst()) { if b == a + 1 { length += 1 } else { runs.append(length); length = 1 } }
                runs.append(length)
                XCTAssertTrue(runs.allSatisfy { $0 >= 4 && $0 % 2 == 0 }, "\(kind) strokes are whole 2-cell wide dots (row \(y): \(runs))")
            }
        }
    }

    // MARK: - 보내기와 표적

    func testHeartAtFacingMemberTargetsThem() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: PlazaTargeting.facingTile(from: start, facing: .down),
                                          facing: .down, isWalking: false)
        await settle()
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.count, 1)
        XCTAssertEqual(other.received.emotes.first?.from, me.settings.memberID)
        XCTAssertEqual(other.received.emotes.first?.emote, TeamEmote(kind: .heart, targetMemberID: other.settings.memberID))
        XCTAssertEqual(c.scene?.shownEmote(memberID: nil), .heart, "my own bubble shows at once")
    }

    func testHeartAtAwayMemberTargetsThem() async {
        let me = node("나")
        // 자리 비움 팀원은 멤버 ID로 정해진 쉼터 칸에 선다. 멤버 ID는 매번 달라서, 그 위쪽 칸을 걸을 수 있는 팀원이 나올 때까지 만든다.
        var candidate = node("민수")
        for _ in 0..<100 {
            let tile = PlazaShelterWanderer(memberID: candidate.settings.memberID, shelter: map.shelterTiles).tile
            if map.isWalkable(TilePoint(x: tile.x, y: tile.y - 1)) { break }
            candidate = node("민수")
        }
        let other = candidate
        let id = other.settings.memberID
        let shelter = PlazaShelterWanderer(memberID: id, shelter: map.shelterTiles).tile
        let above = TilePoint(x: shelter.x, y: shelter.y - 1)
        XCTAssertTrue(map.isWalkable(above), "test precondition")
        let c = controller(me, start: above)
        c.prepareScene()
        await connect(me, other)   // 접속 직후에는 자리 비움
        XCTAssertEqual(c.scene?.memberTiles[id], shelter)
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.first?.emote, TeamEmote(kind: .heart, targetMemberID: id))
    }

    func testHeartWithNobodyNearHasNoTarget() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        let far = TilePoint(x: start.x + 6, y: start.y)
        XCTAssertTrue(map.isWalkable(far), "test precondition")
        other.session.updatePlazaPosition(inPlaza: true, tile: far, facing: .down, isWalking: false)
        await settle()
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.count, 1, "still sent, to everyone")
        XCTAssertNil(other.received.emotes.first?.emote.targetMemberID)
        XCTAssertEqual(other.received.emotes.first?.emote.kind, .heart)
    }

    func testExclaimNeverTargets() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: PlazaTargeting.facingTile(from: start, facing: .down),
                                          facing: .down, isWalking: false)
        await settle()
        press(c.scene!, exclaimKey)
        now += 1
        press(c.scene!, questionKey)
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote), [TeamEmote(kind: .exclaim, targetMemberID: nil),
                                                            TeamEmote(kind: .question, targetMemberID: nil)])
    }

    func testKeyMashIsLimited() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: startFacingDown())
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        press(scene, heartKey)
        for _ in 0..<2 {
            now += 0.1
            press(scene, partyKey)   // 0.1초, 0.2초: 막힌다
        }
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart])
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart, "a limited press does not replace my bubble")
        now += 0.15   // 처음 누른 뒤 0.35초. 막힌 키는 제한 시계를 늦추지 않는다.
        press(scene, lolKey)
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart, .lol])
    }

    // MARK: - 받기와 보이기

    func testReceivedEmoteShowsOverThatMember() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .party)
        let scene = c.scene!
        XCTAssertEqual(scene.shownEmote(memberID: id), .party)
        XCTAssertNil(scene.shownEmote(memberID: nil), "not over me")
        c.showEmote(memberID: "nobody", kind: .party)   // 모르는 팀원은 조용히 넘어간다
        // 이름표 위에 놓이고 기기 픽셀 격자에 맞는다.
        scene.backingOverride = 2
        step(scene, seconds: 0.1)
        let frame = scene.emoteFrame(memberID: id)!
        XCTAssertEqual(frame.minX * 2, (frame.minX * 2).rounded(), accuracy: 0.0001)
        XCTAssertEqual(frame.minY * 2, (frame.minY * 2).rounded(), accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(frame.minY, scene.memberNamePlateTop(id)!)
    }

    func testReceivedEmoteDoesNothingWhenClosed() {
        let me = node("나")
        let c = controller(me)
        c.showEmote(memberID: "anyone", kind: .heart)
        XCTAssertNil(c.scene, "no scene is created just to show a bubble")
    }

    func testEmoteExpires() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 2.4)
        XCTAssertEqual(scene.shownEmote(memberID: id), .heart)
        step(scene, seconds: 0.3, from: 2.4)
        XCTAssertNil(scene.shownEmote(memberID: id))
        XCTAssertNil(scene.emoteFrame(memberID: id))
    }

    func testNewEmoteReplacesOldAndRestartsTimer() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 1.5)
        c.showEmote(memberID: id, kind: .question)
        XCTAssertEqual(scene.shownEmote(memberID: id), .question)
        step(scene, seconds: 2.3, from: 1.5)   // 처음 것이었다면 이미 사라졌을 때
        XCTAssertEqual(scene.shownEmote(memberID: id), .question)
        step(scene, seconds: 0.5, from: 3.8)
        XCTAssertNil(scene.shownEmote(memberID: id))
    }

    func testEggCanStillEmote() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: startFacingDown(), speciesID: nil)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        XCTAssertFalse(scene.canWalk)
        press(scene, heartKey)
        await settle()
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart)
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart])
        step(scene, seconds: 0.1)
        XCTAssertNotNil(scene.emoteFrame(memberID: nil))
    }
}
