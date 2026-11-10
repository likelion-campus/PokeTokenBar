import XCTest
import AppKit
import CoreGraphics
@testable import PokeTokenBar

/// D 춤: 박자·동작표·키·멈춤 조건·팀원 춤·♪·사진.
@MainActor
final class PlazaDanceTests: XCTestCase {
    private typealias Style = PlazaDance.Style
    private let map = PlazaMapData.map
    private let dKey: UInt16 = 2
    private let leftKey: UInt16 = 123
    private let photoKey: UInt16 = 35
    /// 0.4초 격자 위의 시각(10000박자째).
    private let grid = 4000.0
    /// 테스트마다 새 인스턴스라 0에서 시작한다. 동기 `setUp`에서 되돌리지 않는다(CI의 Xcode 16.4에서는 비격리다).
    private var clockTime: TimeInterval = 0
    private var wall: TimeInterval = 4000.0
    private let dt = 0.05

    // MARK: 도우미

    private func frames(isEgg: Bool = false) -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
        var result = PlazaCharacterFrames(front: f, back: f)
        result.isEgg = isEgg
        return result
    }

    private func scene(start: TilePoint? = nil, pond: Bool = false) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start ?? map.spawn, zoom: 2, nickname: "나",
                           pondVisuals: pond)
        s.size = CGSize(width: 960, height: 640)
        s.backingOverride = 2
        s.now = { [unowned self] in Date(timeIntervalSince1970: wall) }
        s.setCharacter(frames())
        s.update(clockTime)
        return s
    }

    /// 장면 시계와 벽시계를 함께 만큼 흘린다.
    private func run(_ s: PlazaScene, _ seconds: TimeInterval) {
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n {
            clockTime += dt
            wall += dt
            s.update(clockTime)
        }
    }

    private func press(_ s: PlazaScene, _ code: UInt16? = nil, repeats: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        s.handleKeyDown(keyCode: code ?? dKey, characters: "d", isRepeat: repeats, modifiers: modifiers)
    }

    private func member(_ id: String, _ tile: TilePoint, walking: Bool = false) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: walking)
    }

    private func add(_ s: PlazaScene, _ members: [PlazaSceneMember]) {
        s.applyMembers(members)
        for m in members { s.setMemberFrames(m.memberID, frames()) }
        s.update(clockTime)
    }

    /// 걸어 다닐 수 있는 가로 일곱 칸이 이어진 줄의 왼쪽 끝.
    private func openRow() throws -> TilePoint {
        for y in 0..<map.height {
            for x in 0..<(map.width - 7) where (0..<7).allSatisfy({ map.isWalkable(TilePoint(x: x + $0, y: y)) }) {
                return TilePoint(x: x, y: y)
            }
        }
        throw XCTSkip("no open row")
    }

    private func recordRounds(_ s: PlazaScene) -> Recorder {
        let r = Recorder()
        s.onDanceRound = { r.ids.append($0) }
        return r
    }

    @MainActor final class Recorder { var ids: [String] = [] }

    // MARK: 동작표

    private struct P: Equatable {
        let lift: CGFloat, x: CGFloat, flip: Bool, back: Bool?, squash: CGFloat, tilt: CGFloat
        init(_ lift: CGFloat, _ x: CGFloat, _ flip: Bool, _ back: Bool?, _ squash: CGFloat, _ tilt: CGFloat) {
            self.lift = lift; self.x = x; self.flip = flip; self.back = back; self.squash = squash; self.tilt = tilt
        }
    }

    /// 승인된 미리보기의 값. 구현과 따로 손으로 옮긴 표라 구현을 바꾸면 여기서 걸린다.
    private let table: [Style: [P]] = [
        .sway: [
            P(0, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(5, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(0, 0, true, nil, 1, 0),
            P(3, 0, true, nil, 1, 0),
            P(5, 0, true, nil, 1, 0),
            P(3, 0, true, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(5, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(0, 0, true, nil, 1, 0),
            P(3, 0, true, nil, 1, 0),
            P(5, 0, true, nil, 1, 0),
            P(3, 0, true, nil, 1, 0),
        ],
        .bounce: [
            P(0, 0, false, nil, 0.84, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(7, 0, false, nil, 1.06, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(0, 0, false, nil, 0.84, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(7, 0, false, nil, 1.06, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(0, 0, false, nil, 0.84, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(7, 0, false, nil, 1.06, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(0, 0, false, nil, 0.84, 0),
            P(4, 0, false, nil, 1.06, 0),
            P(7, 0, false, nil, 1.06, 0),
            P(4, 0, false, nil, 1.06, 0),
        ],
        .spin: [
            P(0, 0, false, false, 1, 0),
            P(2, 0, false, false, 1, 0),
            P(3, 0, false, false, 1, 0),
            P(2, 0, false, false, 1, 0),
            P(0, 0, true, false, 1, 0),
            P(2, 0, true, false, 1, 0),
            P(3, 0, true, false, 1, 0),
            P(2, 0, true, false, 1, 0),
            P(0, 0, true, true, 1, 0),
            P(2, 0, true, true, 1, 0),
            P(3, 0, true, true, 1, 0),
            P(2, 0, true, true, 1, 0),
            P(0, 0, false, true, 1, 0),
            P(2, 0, false, true, 1, 0),
            P(3, 0, false, true, 1, 0),
            P(2, 0, false, true, 1, 0),
        ],
        .shuffle: [
            P(0, 0, false, nil, 1, 0),
            P(3, 1, false, nil, 1, 0),
            P(4, 3, false, nil, 1, 0),
            P(2, 4, false, nil, 1, 0),
            P(0, 4, false, nil, 1, 0),
            P(3, 5, false, nil, 1, 0),
            P(4, 7, false, nil, 1, 0),
            P(2, 8, false, nil, 1, 0),
            P(0, 8, true, nil, 1, 0),
            P(3, 7, true, nil, 1, 0),
            P(4, 5, true, nil, 1, 0),
            P(2, 4, true, nil, 1, 0),
            P(0, 4, true, nil, 1, 0),
            P(3, 3, true, nil, 1, 0),
            P(4, 1, true, nil, 1, 0),
            P(2, 0, true, nil, 1, 0),
        ],
        .wiggle: [
            P(0, 0, false, nil, 1, 0.2),
            P(0, 0, false, nil, 1, 0.2),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, -0.2),
            P(0, 0, false, nil, 1, -0.2),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0.2),
            P(0, 0, false, nil, 1, 0.2),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, -0.2),
            P(0, 0, false, nil, 1, -0.2),
            P(0, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
        ],
        .bigHop: [
            P(0, 0, false, nil, 0.82, 0),
            P(2, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(2, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 1, 0),
            P(2, 0, false, nil, 1, 0),
            P(3, 0, false, nil, 1, 0),
            P(2, 0, false, nil, 1, 0),
            P(0, 0, false, nil, 0.82, 0),
            P(7, 0, false, nil, 1, 0),
            P(12, 0, false, nil, 1, 0),
            P(15, 0, false, nil, 1, 0),
            P(16, 0, false, nil, 1, 0),
            P(15, 0, false, nil, 1, 0),
            P(12, 0, false, nil, 1, 0),
            P(7, 0, false, nil, 1, 0),
        ],
        .twirl: [
            P(3, 0, false, false, 1, 0),
            P(3, 0, true, false, 1, 0),
            P(3, 0, true, true, 1, 0),
            P(3, 0, false, true, 1, 0),
            P(3, 0, false, false, 1, 0),
            P(3, 0, true, false, 1, 0),
            P(3, 0, true, true, 1, 0),
            P(3, 0, false, true, 1, 0),
            P(3, 0, false, false, 1, 0),
            P(3, 0, true, false, 1, 0),
            P(3, 0, true, true, 1, 0),
            P(3, 0, false, true, 1, 0),
            P(3, 0, false, false, 1, 0),
            P(3, 0, true, false, 1, 0),
            P(3, 0, true, true, 1, 0),
            P(3, 0, false, true, 1, 0),
        ]
    ]

    func testEveryStyleMatchesTheApprovedPoseTable() {
        XCTAssertEqual(Set(table.keys), Set(Style.allCases))
        for style in Style.allCases {
            let rows = table[style]!
            XCTAssertEqual(rows.count, PlazaDance.ticksPerRound)
            for (tick, want) in rows.enumerated() {
                let p = PlazaDancePose.pose(style, tick: tick)
                let got = P(p.lift, p.offsetX, p.flipped, p.back, p.squash, p.tilt)
                XCTAssertEqual(got, want, "\(style) tick \(tick)")
            }
        }
    }

    func testTheBeatAndStepAreTheApprovedOnes() {
        XCTAssertEqual(PlazaDance.beat, 0.4)
        XCTAssertEqual(PlazaDance.step, 0.1)
        XCTAssertEqual(PlazaDance.round, 1.6, accuracy: 1e-12)
        XCTAssertEqual(PlazaDance.ticksPerRound, 16)
    }

    func testThePoseIsConstantWithinAStepAndChangesAtTheBoundary() {
        for k in 0..<16 {
            let start = Double(k) * 0.1
            let a = PlazaDancePose.pose(.bigHop, tick: PlazaDance.tick(elapsed: start + 0.001))
            let b = PlazaDancePose.pose(.bigHop, tick: PlazaDance.tick(elapsed: start + 0.099))
            XCTAssertEqual(a, b, "step \(k)")
            XCTAssertEqual(PlazaDance.tick(elapsed: start + 0.001), k)
        }
        XCTAssertEqual(PlazaDance.tick(elapsed: 0.1 * 3), 3, "a sum that lands a hair under the boundary still counts as the step")
        XCTAssertEqual(PlazaDance.tick(elapsed: 0.1 + 0.2 - 1e-12), 3)
    }

    func testUnknownStyleIDsPlayTheFirstStyle() {
        XCTAssertEqual(Style.style(id: nil), .sway)
        XCTAssertEqual(Style.style(id: "fromANewerVersion"), .sway)
        XCTAssertEqual(Style.style(id: String(repeating: "x", count: 200_000)), .sway)
        for style in Style.allCases { XCTAssertEqual(Style.style(id: style.id), style) }
    }

    /// 팀원의 화면이 이름으로 찾으니 내보낸 이름은 바뀌지 않는다.
    func testShippedStyleIDsAreStable() {
        XCTAssertEqual(Style.allCases.map(\.id), ["sway", "bounce", "spin", "shuffle", "wiggle", "bigHop", "twirl"])
    }

    func testTheNextStyleDiffersFromTheLastAndEveryStyleComesUp() {
        var rng = SystemRandomNumberGenerator()
        var last: Style?
        var seen = Set<Style>()
        for _ in 0..<2000 {
            let next = Style.next(after: last, using: &rng)
            XCTAssertNotEqual(next, last)
            seen.insert(next)
            last = next
        }
        XCTAssertEqual(seen, Set(Style.allCases))
    }

    // MARK: 박자 격자

    func testGridOffsetIsTheTimePastTheBeatGrid() {
        func offset(_ t: Double) -> Double { PlazaDance.gridOffset(at: Date(timeIntervalSince1970: t)) }
        XCTAssertEqual(offset(4000.0), 0, accuracy: 1e-9, "on the grid")
        XCTAssertEqual(offset(4000.25), 0.25, accuracy: 1e-6)
        XCTAssertEqual(offset(4000.4), 0, accuracy: 1e-9)
        XCTAssertEqual(offset(4000.399), 0.399, accuracy: 1e-6)
        XCTAssertEqual(offset(-0.1), 0.3, accuracy: 1e-6, "before 1970 the offset is still inside the beat")
        XCTAssertEqual(offset(.nan), 0)
        XCTAssertEqual(offset(.infinity), 0)
    }

    func testARoundStartedMidBeatEndsItsFirstBeatOnTheGrid() throws {
        let s = scene()
        wall = grid + 0.25
        press(s)
        let style = try XCTUnwrap(s.danceStyle(memberID: nil))
        XCTAssertEqual(s.myActor.dance?.elapsed ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(s.dancePose(memberID: nil), PlazaDancePose.pose(style, tick: 2))
        run(s, 0.05)   // 0.30
        XCTAssertEqual(s.dancePose(memberID: nil), PlazaDancePose.pose(style, tick: 3))
        run(s, 0.05)   // 0.35
        XCTAssertEqual(s.dancePose(memberID: nil), PlazaDancePose.pose(style, tick: 3))
        run(s, 0.05)   // 0.40: the grid
        XCTAssertEqual(s.dancePose(memberID: nil), PlazaDancePose.pose(style, tick: 4), "the second beat starts on the grid")
    }

    func testTheRoundEndsOnTheGridToo() {
        let s = scene()
        wall = grid + 0.25
        press(s)
        s.handleKeyUp(keyCode: dKey)
        run(s, 1.30)   // elapsed 1.55
        XCTAssertTrue(s.isDancing(memberID: nil))
        run(s, 0.05)   // 1.60
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    func testDancersStartedAtDifferentTimesChangePosesOnTheSameFrames() throws {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 1, y: map.spawn.y))])
        s.pickDanceStyle = { _ in .bigHop }
        wall = grid + 0.05
        press(s)
        s.handleKeyUp(keyCode: dKey)
        run(s, 0.15)
        XCTAssertTrue(s.playDance(memberID: "a", style: "bigHop"), "0.15 s after mine")
        for frame in 0..<25 {
            XCTAssertEqual(s.dancePose(memberID: nil), s.dancePose(memberID: "a"), "frame \(frame)")
            XCTAssertEqual(s.myActor.dance?.elapsed ?? -1, s.memberActor("a")?.dance?.elapsed ?? -2, accuracy: 1e-6)
            run(s, 0.05)
        }
    }

    // MARK: 키

    func testDStartsARoundAndReportsItsStyle() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [s.danceStyle(memberID: nil)?.id])
    }

    func testTheKeyCodeDecidesSoHangulInputWorks() {
        let s = scene()
        s.handleKeyDown(keyCode: dKey, characters: "ㅇ", isRepeat: false)
        XCTAssertTrue(s.isDancing(memberID: nil))
    }

    func testRepeatsAndModifiedPressesDoNothing() {
        let s = scene()
        let r = recordRounds(s)
        press(s, repeats: true)
        for m: NSEvent.ModifierFlags in [.command, .control, .option] { press(s, modifiers: m) }
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
        press(s, modifiers: .shift)
        XCTAssertTrue(s.isDancing(memberID: nil), "Shift still dances")
    }

    func testAnOpenOverlaySwallowsD() {
        let s = scene()
        s.isOverlayOpen = true
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    func testDWorksInPhotoModeToo() {
        let s = scene()
        let r = recordRounds(s)
        s.enterPhotoMode()
        press(s)
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids.count, 1)
    }

    func testEachPressPicksAStyleThatDiffersFromMyPreviousOne() {
        let s = scene()
        var asked: [Style?] = []
        var seen = Set<Style>()
        for _ in 0..<300 {
            let before = s.danceStyle(memberID: nil)
            wall += PlazaDance.beat
            press(s)
            let now = s.danceStyle(memberID: nil)
            XCTAssertNotEqual(before, now)
            seen.insert(now!)
            asked.append(before)
        }
        XCTAssertEqual(seen, Set(Style.allCases))
        let previous = s.danceStyle(memberID: nil)
        s.pickDanceStyle = { last in asked.append(last); return .spin }
        asked = []
        wall += PlazaDance.beat
        press(s)
        XCTAssertEqual(asked, [previous], "the previous style is passed in")
    }

    // MARK: 누르고 있기

    func testHoldingDStartsAnotherRoundWithAnotherStyleWhenTheFirstEnds() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        let first = s.danceStyle(memberID: nil)
        run(s, PlazaDance.round + 0.1)
        XCTAssertEqual(r.ids.count, 2, "a second round, a second emote")
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertNotEqual(s.danceStyle(memberID: nil), first)
        XCTAssertEqual(r.ids.last, s.danceStyle(memberID: nil)?.id)
        run(s, PlazaDance.round)
        XCTAssertEqual(r.ids.count, 3)
    }

    func testReleasingDLetsTheRoundFinishThenStops() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        run(s, 0.5)
        s.handleKeyUp(keyCode: dKey)
        run(s, 0.5)
        XCTAssertTrue(s.isDancing(memberID: nil), "the round is not cut short")
        run(s, 1.0)
        XCTAssertFalse(s.isDancing(memberID: nil))
        run(s, 2)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids.count, 1)
    }

    func testAutoRepeatDoesNotStartRoundsByItself() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        for _ in 0..<40 { press(s, repeats: true); run(s, 0.05) }
        XCTAssertEqual(r.ids.count, 2, "only the hold carries on, not the repeats (2 s: one follow-up round)")
    }

    func testReleasingEveryKeyOrOpeningAnOverlayEndsTheHold() {
        for release in [{ (s: PlazaScene) in s.releaseAllKeys() }, { (s: PlazaScene) in s.clearInput() },
                        { (s: PlazaScene) in s.isOverlayOpen = true }] {
            let s = scene()
            let r = recordRounds(s)
            press(s)
            release(s)
            run(s, 2.2)
            XCTAssertEqual(r.ids.count, 1)
            XCTAssertFalse(s.isDancing(memberID: nil))
            clockTime = 0; wall = grid
        }
    }

    func testCommandHeldDropsTheHoldBecauseTheKeyUpNeverArrives() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        s.currentModifiers = { .command }
        run(s, 2.2)
        XCTAssertEqual(r.ids.count, 1)
    }

    func testAPressInTheMiddleOfARoundStartsANewOneNow() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        run(s, 0.5)
        s.handleKeyUp(keyCode: dKey)
        press(s)
        XCTAssertEqual(r.ids.count, 2)
        XCTAssertEqual(s.myActor.dance?.elapsed ?? -1, PlazaDance.gridOffset(at: Date(timeIntervalSince1970: wall)), accuracy: 1e-6)
    }

    // MARK: 멈춤

    func testAnArrowKeyStopsMyDanceAndTheHoldDoesNotResumeIt() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        run(s, 0.3)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        XCTAssertFalse(s.isDancing(memberID: nil), "at once, before the next frame")
        s.handleKeyUp(keyCode: leftKey)
        run(s, 3)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids.count, 1, "D is still down, but a stopped round is not an ended one")
    }

    func testAnEggKeepsDancingWhenAnArrowIsPressedBecauseItCannotMove() {
        let s = scene()
        s.setCharacter(frames(isEgg: true))
        s.canWalk = false
        press(s)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        run(s, 0.2)
        XCTAssertTrue(s.isDancing(memberID: nil))
    }

    func testDDoesNothingWhileIAmWalking() {
        let s = scene()
        let r = recordRounds(s)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        run(s, 0.1)
        XCTAssertTrue(s.walker.isWalking)
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    func testBeingPushedStopsTheDance() {
        let s = scene()
        press(s)
        run(s, 0.2)
        s.pushMe(.left)
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    func testWalkingToAMemberAndFollowingStopTheDance() {
        for follow in [false, true] {
            let s = scene()
            add(s, [member("a", TilePoint(x: map.spawn.x + 4, y: map.spawn.y))])
            press(s)
            XCTAssertTrue(follow ? s.follow(member: "a") : s.walk(toMember: "a"))
            XCTAssertFalse(s.isDancing(memberID: nil), follow ? "follow" : "walk")
            clockTime = 0; wall = grid
        }
    }

    func testSittingAtTheCampfireStopsTheDance() {
        let s = scene()
        press(s)
        s.sit(at: PlazaCampfire.seats[0])
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    /// 따라가는 중 가만히 서서 춤출 수 있지만, 따라가는 팀원이 떠나 내가 걷기 시작하면 다음 프레임에 멈춘다.
    func testAFollowerWhoStartsWalkingAgainStopsDancing() {
        let s = scene()
        let next = TilePoint(x: map.spawn.x + 1, y: map.spawn.y)
        add(s, [member("a", next)])
        XCTAssertTrue(s.follow(member: "a"))
        run(s, dt)
        press(s)
        XCTAssertTrue(s.isDancing(memberID: nil), "standing beside who I follow")
        add(s, [member("a", TilePoint(x: next.x + 4, y: next.y))])
        run(s, 0.3)
        XCTAssertTrue(s.walker.isWalking || s.walker.tile != map.spawn)
        XCTAssertFalse(s.isDancing(memberID: nil))
    }

    func testARemoteThatStartsMovingStopsDancingOnMyScreen() {
        let s = scene()
        let here = TilePoint(x: map.spawn.x + 1, y: map.spawn.y)
        add(s, [member("a", here)])
        XCTAssertTrue(s.playDance(memberID: "a", style: "sway"))
        run(s, 0.2)
        XCTAssertTrue(s.isDancing(memberID: "a"))
        add(s, [member("a", TilePoint(x: here.x + 1, y: here.y), walking: true)])
        run(s, dt)
        XCTAssertFalse(s.isDancing(memberID: "a"))
    }

    func testPausingTheSceneEndsEveryDanceAndTheHold() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 1, y: map.spawn.y))])
        let r = recordRounds(s)
        press(s)
        s.playDance(memberID: "a", style: "bounce")
        s.isPaused = true
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertFalse(s.isDancing(memberID: "a"))
        s.isPaused = false
        run(s, 3)
        XCTAssertEqual(r.ids.count, 1, "the hold did not survive the pause")
    }

    // MARK: 못 추는 때

    func testNothingStartsOrIsSentWhileSwimming() {
        let s = scene(start: TilePoint(x: 34, y: 16), pond: true)
        XCTAssertTrue(s.isMeInWater)
        let r = recordRounds(s)
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    func testNothingStartsOrIsSentWhileDiving() {
        let s = scene(start: TilePoint(x: 34, y: 16), pond: true)
        s.setDiving(true)
        XCTAssertTrue(s.isDiving)
        let r = recordRounds(s)
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    func testNothingStartsOrIsSentWhileFocusing() {
        let s = scene()
        s.isFocusing = { true }
        let r = recordRounds(s)
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    func testNothingStartsOrIsSentWhilePaused() {
        let s = scene()
        s.isPaused = true
        let r = recordRounds(s)
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    func testAnEggDances() {
        let s = scene()
        s.setCharacter(frames(isEgg: true))
        s.canWalk = false
        let r = recordRounds(s)
        press(s)
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids.count, 1)
    }

    // MARK: 팀원의 춤

    func testAReceivedDancePlaysExactlyOneRoundOfThatStyle() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 2, y: map.spawn.y))])
        let r = recordRounds(s)
        XCTAssertTrue(s.playDance(memberID: "a", style: "twirl"))
        XCTAssertEqual(s.danceStyle(memberID: "a"), .twirl)
        run(s, PlazaDance.round + 0.5)
        XCTAssertFalse(s.isDancing(memberID: "a"), "one round, no repeat")
        XCTAssertEqual(r.ids, [], "a teammate's dance never goes back out")
    }

    func testAnUnknownStyleIDPlaysSway() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 2, y: map.spawn.y))])
        XCTAssertTrue(s.playDance(memberID: "a", style: "moonwalk"))
        XCTAssertEqual(s.danceStyle(memberID: "a"), .sway)
        XCTAssertTrue(s.playDance(memberID: "a", style: nil))
        XCTAssertEqual(s.danceStyle(memberID: "a"), .sway)
    }

    func testADanceFromAnUnknownMemberIsIgnored() {
        let s = scene()
        XCTAssertFalse(s.playDance(memberID: "ghost", style: "sway"))
    }

    func testADanceFromSomeoneInTheWaterIsIgnored() {
        let s = scene(pond: true)
        add(s, [member("swimmer", TilePoint(x: 34, y: 16))])
        XCTAssertEqual(s.memberIsInWater("swimmer"), true)
        XCTAssertFalse(s.playDance(memberID: "swimmer", style: "sway"))
        XCTAssertFalse(s.isDancing(memberID: "swimmer"))
    }

    func testADanceOnAPausedSceneIsIgnored() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 2, y: map.spawn.y))])
        s.isPaused = true
        XCTAssertFalse(s.playDance(memberID: "a", style: "sway"))
        XCTAssertFalse(s.isDancing(memberID: "a"))
    }

    func testADanceFromSomeoneWalkingIsIgnored() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 2, y: map.spawn.y))])
        add(s, [member("a", TilePoint(x: map.spawn.x + 3, y: map.spawn.y), walking: true)])
        run(s, dt)
        XCTAssertFalse(s.playDance(memberID: "a", style: "sway"))
    }

    /// 변조된 앱이 춤을 쉼 없이 보내도 노드는 늘지 않고 한 판을 다시 시작할 뿐이다.
    func testAFloodOfDancesOnlyRestartsTheRound() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 2, y: map.spawn.y))])
        run(s, dt)
        let nodes = s.children.count
        let huge = String(repeating: "x", count: 500_000)
        for i in 0..<5000 {
            XCTAssertTrue(s.playDance(memberID: "a", style: i.isMultiple(of: 2) ? huge : Style.allCases[i % 7].id))
            if i % 100 == 0 { run(s, dt) }
        }
        XCTAssertEqual(s.children.count, nodes)
        XCTAssertTrue(s.isDancing(memberID: "a"))
        run(s, PlazaDance.round + 0.2)
        XCTAssertFalse(s.isDancing(memberID: "a"))
        XCTAssertEqual(s.children.count, nodes)
    }

    // MARK: ♪

    private func dancersOnARow(_ s: PlazaScene, xs: [Int], order: [Int]) throws -> [String] {
        let row = try openRow()
        let ids = xs.map { "m\($0)" }
        s.applyMembers([])
        add(s, zip(ids, xs).map { member($0, TilePoint(x: row.x + $1, y: row.y)) })
        for i in order { XCTAssertTrue(s.playDance(memberID: ids[i], style: "sway")) }
        return ids
    }

    private func notes(_ s: PlazaScene, _ ids: [String]) -> [Bool] { ids.map { s.shownEmote(memberID: $0) == .dance } }

    func testOnlyTheMiddleOfThreeInARowSpacedByThreeShowsNotes() throws {
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [2, 1, 0]] {
            let s = scene(start: map.spawn)
            let ids = try dancersOnARow(s, xs: [0, 3, 6], order: order)
            XCTAssertEqual(notes(s, ids), [false, true, false], "start order \(order): the outer ones have one other dancer in reach")
        }
    }

    func testFourDancersWithinFiveTilesAllShowNotes() throws {
        let s = scene()
        let ids = try dancersOnARow(s, xs: [0, 1, 4, 5], order: [0, 1, 2, 3])
        XCTAssertEqual(notes(s, ids), [true, true, true, true])
    }

    func testTwoDancersShowNoNotes() throws {
        let s = scene()
        let ids = try dancersOnARow(s, xs: [0, 2], order: [0, 1])
        XCTAssertEqual(notes(s, ids), [false, false])
    }

    func testFiveTilesIsInAndSixIsOut() throws {
        let s = scene()
        let near = try dancersOnARow(s, xs: [0, 5, 3], order: [0, 1, 2])
        XCTAssertEqual(notes(s, near), [true, true, true], "5 apart counts")
        let s2 = scene()
        let far = try dancersOnARow(s2, xs: [0, 6, 3], order: [0, 1, 2])
        XCTAssertEqual(notes(s2, far), [false, false, true], "6 apart does not, but 3 reaches both")
    }

    /// 거리는 칸 수의 큰 쪽이다(체비쇼프). 대각선으로 4칸씩 떨어진 둘은 가깝다.
    func testDistanceIsTheLargerAxisNotTheSum() throws {
        var origin: TilePoint?
        search: for y in 0..<(map.height - 6) {
            for x in 0..<(map.width - 6) where (0...5).allSatisfy({ dy in (0...5).allSatisfy { map.isWalkable(TilePoint(x: x + $0, y: y + dy)) } }) {
                origin = TilePoint(x: x, y: y)
                break search
            }
        }
        let o = try XCTUnwrap(origin)
        let s = scene()
        add(s, [member("a", o), member("b", TilePoint(x: o.x + 4, y: o.y + 4)), member("c", TilePoint(x: o.x + 5, y: o.y))])
        for id in ["a", "b", "c"] { s.playDance(memberID: id, style: "sway") }
        XCTAssertEqual(notes(s, ["a", "b", "c"]), [true, true, true])
    }

    func testIAmCountedAmongTheDancers() throws {
        let row = try openRow()
        let s = scene(start: TilePoint(x: row.x + 3, y: row.y))
        add(s, [member("a", row), member("b", TilePoint(x: row.x + 6, y: row.y))])
        s.playDance(memberID: "a", style: "sway")
        s.playDance(memberID: "b", style: "sway")
        press(s)
        XCTAssertEqual(s.shownEmote(memberID: nil), .dance)
        XCTAssertEqual(notes(s, ["a", "b"]), [false, false])
    }

    func testNotesAreTheLolStyleBubbleAtTheGreetingSize() throws {
        let s = scene()
        let ids = try dancersOnARow(s, xs: [0, 1, 2], order: [0, 1, 2])
        run(s, dt)
        let frame = try XCTUnwrap(s.emoteFrame(memberID: ids[1]))
        XCTAssertEqual(frame.size, PlazaEmoteArt.size(large: true))
        XCTAssertNotEqual(PlazaEmoteArt.image(.dance, scale: 2, large: true).dataProvider?.data as Data?,
                          PlazaEmoteArt.image(.lol, scale: 2, large: true).dataProvider?.data as Data?)
    }

    func testNotesLastForTheRoundOnly() throws {
        let s = scene()
        let ids = try dancersOnARow(s, xs: [0, 1, 2], order: [0, 1, 2])
        run(s, 1.0)
        XCTAssertEqual(notes(s, ids), [true, true, true])
        run(s, 0.7)
        XCTAssertEqual(notes(s, ids), [false, false, false])
        XCTAssertFalse(ids.contains { s.isDancing(memberID: $0) })
    }

    func testNotesDoNotReplaceAChatOrEmoteBubble() throws {
        let s = scene()
        let row = try openRow()
        add(s, (0..<3).map { member("m\($0)", TilePoint(x: row.x + $0, y: row.y)) })
        s.showChat(memberID: "m2", text: "안녕")
        s.showEmote(memberID: "m1", kind: .heart)
        for i in 0..<3 { s.playDance(memberID: "m\(i)", style: "sway") }
        XCTAssertEqual(s.shownChat(memberID: "m2"), "안녕")
        XCTAssertNil(s.shownEmote(memberID: "m2"))
        XCTAssertEqual(s.shownEmote(memberID: "m1"), .heart)
        XCTAssertEqual(s.shownEmote(memberID: "m0"), .dance)
    }

    func testNotesBuildNoNodesAndStopWithThePause() throws {
        let s = scene()
        let row = try openRow()
        add(s, (0..<3).map { member("m\($0)", TilePoint(x: row.x + $0, y: row.y)) })
        run(s, dt)
        let nodes = s.children.count
        for i in 0..<3 { s.playDance(memberID: "m\(i)", style: "sway") }
        XCTAssertEqual(s.children.count, nodes, "the bubble node is the actor's own")
        s.isPaused = true
        XCTAssertNil(s.shownEmote(memberID: "m1"), "the pause cleared the notes with the dance")
    }

    func testAStoppedDancerTakesItsNotesAway() throws {
        let s = scene()
        let ids = try dancersOnARow(s, xs: [0, 1, 2], order: [0, 1, 2])
        s.stopDance(memberID: ids[1])
        XCTAssertNil(s.shownEmote(memberID: ids[1]))
    }

    // MARK: 화면의 노드

    private func plain(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlazaFrame {
        PlazaFrame(image: solid(32, 48, r: r, g: g, b: b), delay: 1)
    }

    /// 눌림은 박자마다 한 번 바뀌는 것이지 프레임마다 지워졌다 걸리는 것이 아니다. 이름표는 눌리지 않은 높이에 놓인다.
    func testSquashHoldsAcrossFramesAndThePlateIgnoresIt() {
        let s = scene()
        let full = s.myActor.characterSize.height
        XCTAssertEqual(full, 72)
        s.pickDanceStyle = { _ in .bounce }
        wall = grid
        press(s)
        s.handleKeyUp(keyCode: dKey)
        let plateAtRest0 = s.myNamePlateTop
        XCTAssertEqual(s.myActor.characterSize.height, full * 0.84, accuracy: 0.01, "tick 0 squashes")
        run(s, 0.1)   // tick 1
        let a = s.myActor.characterSize.height, plateA = s.myNamePlateTop
        run(s, 0.05)  // still tick 1
        let b = s.myActor.characterSize.height, plateB = s.myNamePlateTop
        XCTAssertEqual(a, full * 1.06, accuracy: 0.01)
        XCTAssertEqual(b, full * 1.06, accuracy: 0.01, "the second frame of a step keeps the squash")
        XCTAssertEqual(plateA, plateB, "the plate does not twitch inside a step")
        XCTAssertEqual(plateA - plateAtRest0, 4 * CGFloat(s.zoom), accuracy: 1.5, "it only follows the 4 px lift of tick 1")
    }

    func testTheNodeFollowsTheLiftAndTheSidestep() {
        let s = scene()
        let y0 = s.myActor.characterY, x0 = s.myActor.characterX
        s.pickDanceStyle = { _ in .shuffle }
        press(s)
        s.handleKeyUp(keyCode: dKey)
        run(s, 0.7)   // tick 7: lift 2, sidestep 8
        XCTAssertEqual(s.myActor.characterY - y0, 2, accuracy: 0.01)
        XCTAssertEqual(s.myActor.characterX - x0, 8, accuracy: 0.5)
    }

    func testSpinAndTwirlTurnToTheBackFrameAndComeBack() throws {
        let front = plain(1, 0, 0), back = plain(0, 0, 1)
        let s = scene()
        s.setCharacter(PlazaCharacterFrames(front: [front], back: [back]))
        s.pickDanceStyle = { _ in .spin }
        wall = grid
        press(s)
        s.handleKeyUp(keyCode: dKey)
        func shown() throws -> CGImage { try XCTUnwrap(s.photoInput()?.actors.first).image }
        XCTAssertTrue(try shown() === front.image, "tick 0")
        run(s, 0.8)   // tick 8: the back
        XCTAssertTrue(try shown() === back.image)
        run(s, 0.8)   // the round is over
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertTrue(try shown() === front.image, "facing front again")
        wall += PlazaDance.beat
        s.pickDanceStyle = { _ in .twirl }
        press(s)
        s.handleKeyUp(keyCode: dKey)
        run(s, 0.2)   // tick 2 of the next round: the back
        XCTAssertTrue(try shown() === back.image)
    }

    // MARK: 연타 제한

    func testNewRoundsAreLimitedToOnePerBeatButTheHoldStillFollows() {
        let s = scene()
        let r = recordRounds(s)
        wall = grid
        press(s)
        let first = s.danceStyle(memberID: nil)
        run(s, 0.2)
        s.handleKeyUp(keyCode: dKey)
        press(s)   // inside the beat: no restart, nothing sent
        XCTAssertEqual(r.ids.count, 1)
        XCTAssertEqual(s.danceStyle(memberID: nil), first)
        run(s, PlazaDance.round)   // D is down again, so the hold follows the dancing round
        XCTAssertEqual(r.ids.count, 2, "the hold still carries on")
        s.handleKeyUp(keyCode: dKey)
        run(s, PlazaDance.round)
        wall += 0.5
        press(s)
        XCTAssertEqual(r.ids.count, 3, "after a beat a press starts a new round")
    }

    func testAPressAfterABeatSendsAnotherRoundWithAnotherStyle() {
        let s = scene()
        let r = recordRounds(s)
        press(s)
        let first = s.danceStyle(memberID: nil)
        run(s, 0.45)
        s.handleKeyUp(keyCode: dKey)
        press(s)
        XCTAssertEqual(r.ids.count, 2)
        XCTAssertNotEqual(s.danceStyle(memberID: nil), first)
    }

    // MARK: 걸을 참

    func testDIsRefusedWhileAMoveIsPending() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 5, y: map.spawn.y))])
        let r = recordRounds(s)
        s.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)   // a tap waiting for the next frame
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        run(s, 1)
        s.handleKeyUp(keyCode: leftKey)
        XCTAssertEqual(r.ids, [])
    }

    /// 걸어가는 도중 한 걸음이 막 끝나고 다음 걸음이 시작되기 전의 틈: 걷지 않지만 걸을 참이다.
    func testDIsRefusedBetweenTwoStepsOfAWalkToAMember() {
        let s = scene()
        add(s, [member("a", TilePoint(x: map.spawn.x + 6, y: map.spawn.y))])
        let r = recordRounds(s)
        XCTAssertTrue(s.walk(toMember: "a"))
        var gap = false
        for _ in 0..<40 {
            run(s, dt)
            if !s.walker.isWalking, s.walker.tile != map.spawn, s.walkingToMember != nil { gap = true; break }
        }
        XCTAssertTrue(gap, "the harness reached the gap between two steps")
        press(s)
        XCTAssertFalse(s.isDancing(memberID: nil))
        XCTAssertEqual(r.ids, [])
    }

    // MARK: 걷다 멈춘 팀원의 춤

    private func walkingRemote(_ s: PlazaScene) -> (here: TilePoint, next: TilePoint) {
        let here = TilePoint(x: map.spawn.x + 2, y: map.spawn.y), next = TilePoint(x: here.x + 1, y: here.y)
        add(s, [member("a", here)])
        add(s, [member("a", next, walking: true)])
        return (here, next)
    }

    func testADanceReceivedWhileTheSenderIsStillWalkingStartsWhenItStops() {
        let s = scene()
        let (_, next) = walkingRemote(s)
        wall = grid + 0.2
        XCTAssertFalse(s.playDance(memberID: "a", style: "twirl"), "not started yet")
        XCTAssertFalse(s.isDancing(memberID: "a"))
        add(s, [member("a", next)])   // the presence that says it stopped
        run(s, 0.3)
        XCTAssertTrue(s.isDancing(memberID: "a"))
        XCTAssertEqual(s.danceStyle(memberID: "a"), .twirl)
        let drift = ((s.memberActor("a")?.dance?.elapsed ?? -1) - PlazaDance.gridOffset(at: Date(timeIntervalSince1970: wall)))
            .truncatingRemainder(dividingBy: PlazaDance.beat)
        XCTAssertTrue(abs(drift) < 1e-3 || abs(drift - PlazaDance.beat) < 1e-3, "aligned to the grid like any other round: \(drift)")
    }

    func testAPendingDanceIsDroppedAfterABeatAndANewerOneReplacesIt() {
        let s = scene()
        let (_, next) = walkingRemote(s)
        s.playDance(memberID: "a", style: "twirl")
        s.playDance(memberID: "a", style: "bounce")   // replaces the pending one
        add(s, [member("a", next)])
        run(s, 0.3)
        XCTAssertEqual(s.danceStyle(memberID: "a"), .bounce)
        let s2 = scene()
        _ = walkingRemote(s2)
        s2.playDance(memberID: "a", style: "twirl")
        run(s2, 0.5)   // still walking for more than a beat
        add(s2, [member("a", TilePoint(x: map.spawn.x + 3, y: map.spawn.y))])
        run(s2, 0.2)
        XCTAssertFalse(s2.isDancing(memberID: "a"), "too late: dropped")
    }

    func testAPendingDanceIsNotKeptForWaterAnUnknownMemberOrAPausedScene() {
        let s = scene(pond: true)
        XCTAssertFalse(s.playDance(memberID: "ghost", style: "sway"))
        add(s, [member("swimmer", TilePoint(x: 34, y: 16))])
        XCTAssertFalse(s.playDance(memberID: "swimmer", style: "sway"))
        s.isPaused = true
        XCTAssertFalse(s.playDance(memberID: "swimmer", style: "sway"))
        s.isPaused = false
        run(s, 0.3)
        XCTAssertFalse(s.isDancing(memberID: "swimmer"))
    }

    func testPausingForgetsAPendingDance() {
        let s = scene()
        let (_, next) = walkingRemote(s)
        s.playDance(memberID: "a", style: "twirl")
        s.isPaused = true
        s.isPaused = false
        add(s, [member("a", next)])
        run(s, 0.2)
        XCTAssertFalse(s.isDancing(memberID: "a"))
    }

    // MARK: 순간이동

    func testARemoteThatSnapsToAnotherTileStopsDancing() {
        let s = scene()
        let here = TilePoint(x: map.spawn.x + 2, y: map.spawn.y)
        add(s, [member("a", here)])
        s.playDance(memberID: "a", style: "sway")
        s.applyMembers([member("a", here)])
        XCTAssertTrue(s.isDancing(memberID: "a"), "same tile: no move")
        s.applyMembers([member("a", TilePoint(x: here.x + 5, y: here.y))])   // a snap, not a one-tile step
        XCTAssertFalse(s.isDancing(memberID: "a"))
    }

    // MARK: ♪의 가장자리

    func testAnEarlierDancerGetsNotesOnlyWithABeatLeft() throws {
        let row = try openRow()
        func trio(joinAfter: TimeInterval) -> [Bool] {
            clockTime = 0; wall = grid
            let s = scene()
            add(s, (0..<3).map { member("m\($0)", TilePoint(x: row.x + $0, y: row.y)) })
            s.playDance(memberID: "m0", style: "sway")
            s.playDance(memberID: "m1", style: "sway")
            run(s, joinAfter)
            s.playDance(memberID: "m2", style: "sway")
            return notes(s, ["m0", "m1", "m2"])
        }
        XCTAssertEqual(trio(joinAfter: 0.8), [true, true, true], "0.8 s left: the group completes for everyone")
        XCTAssertEqual(trio(joinAfter: 1.3), [false, false, true], "0.3 s left: not worth a flicker, but the new one gets it")
    }

    func testASkippedNotesRoundStaysDecided() throws {
        let row = try openRow()
        let s = scene()
        add(s, (0..<3).map { member("m\($0)", TilePoint(x: row.x + $0, y: row.y)) })
        s.playDance(memberID: "m0", style: "sway")
        s.showEmote(memberID: "m0", kind: .heart)   // shown after the dance began
        s.playDance(memberID: "m1", style: "sway")
        s.playDance(memberID: "m2", style: "sway")
        XCTAssertEqual(s.shownEmote(memberID: "m0"), .heart)
        XCTAssertEqual(s.memberActor("m0")?.danceNotesDecided, true, "a bubble skipped this round's notes for good")
    }

    // MARK: 사진

    func testThePhotoCarriesTheDancePoseOfThatInstant() throws {
        let s = scene()
        s.pickDanceStyle = { _ in .shuffle }
        press(s)
        run(s, 0.7)   // tick 7: lift 2, x 8, not yet flipped
        let pose = try XCTUnwrap(s.dancePose(memberID: nil))
        XCTAssertEqual(pose, PlazaDancePose.pose(.shuffle, tick: PlazaDance.tick(elapsed: s.myActor.dance?.elapsed ?? 0)))
        let resting = try XCTUnwrap(scene().photoInput()?.actors.first)
        let photo = try XCTUnwrap(s.photoInput()?.actors.first)
        XCTAssertEqual(photo.lift, pose.lift)
        XCTAssertEqual(photo.foot.x - resting.foot.x, pose.offsetX, "the sidestep moves the photo's foot")
        XCTAssertEqual(photo.flipped, pose.flipped)
        XCTAssertEqual(photo.squash, pose.squash)
        XCTAssertEqual(photo.tilt, pose.tilt)
    }

    func testThePhotoCarriesTiltAndSquash() throws {
        let s = scene()
        s.pickDanceStyle = { _ in .wiggle }
        press(s)
        var photo = try XCTUnwrap(s.photoInput()?.actors.first)
        XCTAssertEqual(photo.tilt, 0.2, accuracy: 1e-9)
        s.handleKeyUp(keyCode: dKey)
        s.pickDanceStyle = { _ in .bounce }
        wall += PlazaDance.beat
        press(s)
        photo = try XCTUnwrap(s.photoInput()?.actors.first)
        XCTAssertEqual(photo.squash, PlazaDancePose.pose(.bounce, tick: PlazaDance.tick(elapsed: s.myActor.dance?.elapsed ?? 0)).squash)
        XCTAssertEqual(try XCTUnwrap(scene().photoInput()?.actors.first).tilt, 0)
        XCTAssertEqual(try XCTUnwrap(scene().photoInput()?.actors.first).squash, 1)
    }

    func testAPhotoInPhotoModeShowsTheDancer() throws {
        let s = scene()
        s.enterPhotoMode()
        s.pickDanceStyle = { _ in .bigHop }
        wall = grid + 0.2
        press(s)
        run(s, 0.4)
        let photo = try XCTUnwrap(s.photoInput()?.actors.first)
        XCTAssertGreaterThan(photo.lift, 0)
    }

    // MARK: 사진 합성

    private func solid(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func redness(_ img: CGImage, _ x: Int, _ y: Int) -> Bool {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let o = (y * img.width + x) * 4
        return d[o] > 200 && d[o + 1] < 60
    }

    private func render(lift: CGFloat = 0, squash: CGFloat = 1, tilt: CGFloat = 0) throws -> CGImage {
        var a = PlazaPhotoActor(image: solid(10, 20, r: 1, g: 0, b: 0), flipped: false, foot: CGPoint(x: 50, y: 60), scale: 1,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        a.lift = lift; a.squash = squash; a.tilt = tilt
        let input = PlazaPhotoInput(mapImage: solid(100, 100, r: 0, g: 0.6, b: 0), visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    pixelsPerWorld: 1, actors: [a])
        return try XCTUnwrap(PlazaPhotoRenderer.render(input))
    }

    func testTheRendererDrawsASquashedDancerShorter() throws {
        let plain = try render()
        XCTAssertTrue(redness(plain, 50, 60 - 18), "20 tall: reaches row 42")
        let squashed = try render(squash: 0.5)
        XCTAssertTrue(redness(squashed, 50, 60 - 8), "10 tall")
        XCTAssertFalse(redness(squashed, 50, 60 - 14), "the top is lower than the plain one")
        let tall = try render(squash: 1.5)
        XCTAssertTrue(redness(tall, 50, 60 - 28), "30 tall")
    }

    func testTheRendererTiltsADancerOnItsFeet() throws {
        let tilted = try render(tilt: .pi / 2)   // 반시계 90도: 위로 선 몸이 왼쪽으로 눕는다
        XCTAssertTrue(redness(tilted, 50 - 12, 59), "the body lies to the left of the feet")
        XCTAssertFalse(redness(tilted, 50, 60 - 12), "nothing is left standing above")
        let upright = try render()
        XCTAssertFalse(redness(upright, 50 - 12, 59))
    }

    func testTheRendererLiftsADancerOffTheGround() throws {
        let up = try render(lift: 10)
        XCTAssertFalse(redness(up, 50, 59), "the feet left the ground")
        XCTAssertTrue(redness(up, 50, 49))
    }

    // MARK: 안내

    func testTheShortcutGuideListsD() {
        XCTAssertTrue(PlazaShortcutGuide.entries.contains { $0.key == "D" && $0.label == "춤" })
    }
}
