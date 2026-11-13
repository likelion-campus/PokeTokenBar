import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// The ice rules in the scene, on the real map. Ponds: L (5,13) 10x3, R (32,14) 7x7, B (20,24) 3x3.
/// (4,14) is shore west of L, (6,12) land north of it, (15,14) shore east of it.
@MainActor
final class PlazaIceSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let rightKey: UInt16 = 124, upKey: UInt16 = 126
    private var nowSeconds = 1_800_000_000.0
    private var t: TimeInterval = 0
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private var L: TilePoint { p(5, 13) }
    private var R: TilePoint { p(32, 14) }
    private var B: TilePoint { p(20, 24) }
    private func brk(_ pond: TilePoint, ago: Double = 0) -> PlazaIceBreak { PlazaIceBreak(at: nowSeconds - ago, pond: pond) }

    private func scene(start: TilePoint, ice: Bool = true) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true, iceArt: ice ? PlazaIceArt.none : nil)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.setCharacter(frames())
        s.now = { [unowned self] in Date(timeIntervalSince1970: self.nowSeconds) }
        // The controller stand-in: a landed break is what the scene is then told.
        s.onIceLanding = { [unowned s] in s.setIceBreak($0, hit: $1) }
        t = 0
        crowd = [:]
        diving = []
        return s
    }

    private func frames() -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, _ tile: TilePoint, diving: Bool = false) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false, isDiving: diving)
    }

    private var crowd: [String: SIMD2<Int>] = [:]
    private var diving: Set<String> = []

    /// Puts the member there (the others stay where they were).
    private func add(_ s: PlazaScene, _ id: String, _ tile: TilePoint, diving isDiving: Bool = false) {
        let known = crowd[id] != nil
        crowd[id] = SIMD2(tile.x, tile.y)
        if isDiving { diving.insert(id) } else { diving.remove(id) }
        s.applyMembers(crowd.map { member($0.key, p($0.value.x, $0.value.y), diving: diving.contains($0.key)) })
        if !known { s.setMemberFrames(id, frames()) }
    }

    private func move(_ s: PlazaScene, _ id: String, _ tile: TilePoint) { add(s, id, tile) }

    /// Runs `seconds` in 0.05 s frames from where the last call stopped.
    private func run(_ s: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        while t < end - 1e-9 { t = min(t + 0.05, end); s.update(t) }
    }

    private func breakL(_ s: PlazaScene, hit: TilePoint?) {
        s.update(t)
        s.setIceBreak(brk(L), hit: hit)
    }

    private func tap(_ s: PlazaScene, _ key: UInt16) {
        s.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        s.handleKeyUp(keyCode: key)
    }

    private func isStandingAt(_ s: PlazaScene, _ tile: TilePoint) -> Bool {
        s.myFootPoint == PlazaWalker.footPoint(from: tile, to: tile, progress: 0)
    }

    func testWithoutIceArtNothingFreezes() {
        let s = scene(start: p(4, 14), ice: false)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertTrue(s.isWaterNow(p(6, 14)))
        XCTAssertFalse(s.isIce(p(6, 14)))
    }

    func testASceneWithoutIceArtDropsBreaksAndDrawsNothing() {
        let s = scene(start: p(4, 14), ice: false)
        s.update(0)
        s.setIceBreak(brk(L))
        XCTAssertNil(s.iceBreak)
        s.setIceBreak(nil)
        s.queueIceLanding(brk(L), jumper: nil)
        s.isPaused = true
        XCTAssertEqual(s.iceDrawCount, 0, "setIceBreak(nil) reaches drawIce, which stops at the missing layer")
        XCTAssertEqual([s.shownCrackCount, s.shownShardCount, s.iceLayerNodeCount], [0, 0, 0])
    }

    func testTheSceneItselfDropsAFutureBreak() {
        let s = scene(start: p(4, 14))
        s.update(0)
        s.setIceBreak(brk(L, ago: -61))
        XCTAssertNil(s.iceBreak)
        XCTAssertEqual(s.frozenPondAnchor, L)
        s.setIceBreak(brk(p(6, 13)))
        XCTAssertNil(s.iceBreak)
    }

    func testALandingOnAnUnknownPondIsDropped() {
        let s = scene(start: p(4, 14))
        s.update(0)
        var landed = 0
        s.onIceLanding = { _, _ in landed += 1 }
        s.queueIceLanding(brk(p(6, 13)), jumper: nil)
        run(s, 0.4)
        XCTAssertEqual(s.iceLandingCount, 0)
        XCTAssertEqual(landed, 0)
    }

    func testAFreshSceneFreezesTheFirstPond() {
        let s = scene(start: p(4, 14))
        XCTAssertEqual(s.frozenPondAnchor, L)
        XCTAssertTrue(s.isIce(p(6, 14)))
        XCTAssertTrue(s.isWalkableNow(p(6, 14)))
        XCTAssertFalse(s.isWaterNow(p(6, 14)))
        XCTAssertTrue(s.isWaterNow(p(34, 17)))
    }

    func testTheLastBreakDecidesTheFrozenPond() {
        let s = scene(start: p(4, 14))
        s.setIceBreak(brk(L))
        XCTAssertNil(s.frozenPondAnchor)
        nowSeconds += 59.9
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor)
        nowSeconds += 0.1
        s.update(0.1)
        XCTAssertEqual(s.frozenPondAnchor, B)
        s.setIceBreak(brk(B, ago: 200))
        XCTAssertEqual(s.frozenPondAnchor, L)
    }

    func testArrowKeysWalkOntoTheIceAndAcrossIt() {
        let s = scene(start: p(4, 14))
        s.update(0)
        tap(s, rightKey)
        run(s, 0.16)
        XCTAssertTrue(isStandingAt(s, p(5, 14)), "a land step, not a 0.36 s plunge")
        tap(s, rightKey)
        run(s, 0.16)
        XCTAssertTrue(isStandingAt(s, p(6, 14)))
        XCTAssertFalse(s.isMeInWater)
        XCTAssertEqual(s.myVisibleHeight, 72)
    }

    func testZOnTheIceBreaksItAndEveryoneOnItSinksAt600ms() {
        let s = scene(start: p(6, 13))
        add(s, "a", p(8, 14))
        add(s, "c", p(6, 12))
        s.update(0)
        XCTAssertEqual(s.pondAction(canMove: true), .breakIce)
        s.playJump(memberID: nil)
        s.queueIceLanding(brk(L), jumper: nil)
        run(s, 0.35)
        XCTAssertEqual(s.iceLandingCount, 1)
        XCTAssertNil(s.breakingPondAnchor)
        run(s, 0.05)
        XCTAssertEqual(s.breakingPondAnchor, L)
        XCTAssertEqual(s.breakingHit, p(6, 13))
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertEqual(s.pondAction(canMove: true), .jump, "breaking ice")
        run(s, 0.50)
        XCTAssertFalse(s.isMeInWater)
        XCTAssertTrue(s.isWaterNow(p(34, 17)), "no other pond is frozen during the break")
        XCTAssertEqual(s.pondLayer!.dropletCount, 0, "no splash before the 0.6 s sink")
        XCTAssertNotEqual(s.isWet(memberID: "c"), true)
        run(s, 0.12)
        XCTAssertTrue(s.isMeInWater)
        XCTAssertEqual(s.memberIsInWater("a"), true)
        XCTAssertEqual(s.pondLayer!.dropletCount, 2 * PlazaPondLayer.bigDroplets)
        XCTAssertEqual(s.isWet(memberID: "c"), true)
        XCTAssertNil(s.frozenPondAnchor, "nothing is frozen for a minute after the break")
        XCTAssertTrue(s.isWaterNow(p(34, 17)))
    }

    /// Runs with the wall clock moving along with the scene.
    private func runClock(_ s: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        while t < end - 1e-9 {
            let step = min(0.05, end - t)
            t += step
            nowSeconds += step
            s.update(t)
        }
    }

    func testTheNextPondFreezesAMinuteAfterTheBreakAndFadesInFromThere() throws {
        let s = scene(start: p(6, 13))
        let at = nowSeconds
        breakL(s, hit: p(6, 13))
        runClock(s, 1)
        XCTAssertTrue(s.isWaterNow(p(6, 14)), "the left pond sank")
        XCTAssertNil(s.frozenPondAnchor)
        func advance(to seconds: Double) { runClock(s, at + seconds - nowSeconds) }
        advance(to: 59.9)
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertTrue(s.isWaterNow(p(34, 17)))
        advance(to: 60.05)
        XCTAssertEqual(s.frozenPondAnchor, B)
        XCTAssertTrue(s.isWalkableNow(p(21, 25)))
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 0.05, accuracy: 0.03)
        advance(to: 60.5)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 0.5, accuracy: 0.03)
        advance(to: 61.1)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 1, accuracy: 1e-6)
    }

    func testOpeningOrResumingLongAfterTheBreakShowsTheFrozenPondOpaque() throws {
        let s = scene(start: p(4, 14))
        s.setIceBreak(brk(L, ago: 300))
        XCTAssertEqual(s.frozenPondAnchor, B)
        s.update(0)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 1, accuracy: 1e-6)
        let p = scene(start: p(4, 14))
        p.update(0)
        p.setIceBreak(brk(L))
        p.isPaused = true
        nowSeconds += 300
        p.isPaused = false
        p.update(1)
        XCTAssertEqual(p.frozenPondAnchor, B)
        XCTAssertEqual(try XCTUnwrap(p.iceAlpha(pondAnchor: B)), 1, accuracy: 1e-6, "no fade replay")
    }

    func testABreakDatedInTheFutureFreezesAMinuteAfterItsAtOnMyClock() {
        let s = scene(start: p(4, 14))
        s.update(0)
        s.setIceBreak(brk(L, ago: -30))
        XCTAssertEqual(s.iceBreak?.pond, L)
        nowSeconds += 89.9
        s.update(1)
        XCTAssertNil(s.frozenPondAnchor)
        nowSeconds += 0.2
        s.update(2)
        XCTAssertEqual(s.frozenPondAnchor, R)
    }

    func testStepsDuringTheBreakDecideWhoSinks() {
        let s = scene(start: p(9, 14))
        add(s, "a", p(5, 14))
        add(s, "d", p(15, 14))
        breakL(s, hit: p(9, 14))
        run(s, 0.1)
        move(s, "a", p(4, 14))
        move(s, "d", p(14, 14))
        run(s, 0.6)
        XCTAssertEqual(s.memberIsInWater("a"), false)
        XCTAssertEqual(s.memberIsInWater("d"), true)
        XCTAssertTrue(s.isMeInWater)
    }

    func testLeapingFromTheShoreTakesAPlungeLongAndLandsOnTheIce() {
        let s = scene(start: p(4, 14))
        s.update(0)
        s.face(.right)
        XCTAssertEqual(s.pondAction(canMove: true), .leapOntoIce(.right))
        s.leapOntoIce(.right)
        run(s, 0.30)
        XCTAssertGreaterThan(s.jumpLift(memberID: nil) ?? 0, 0)
        XCTAssertFalse(isStandingAt(s, p(5, 14)), "still walking")
        run(s, 0.10)
        XCTAssertTrue(isStandingAt(s, p(5, 14)))
        XCTAssertFalse(s.isMeInWater)
    }

    func testFacingTakenIceOrBeingAnEggIsAPlainJump() {
        let s = scene(start: p(4, 14))
        add(s, "m", p(5, 14))
        s.update(0)
        XCTAssertEqual(s.pondAction(canMove: true), .jump)
        let e = scene(start: p(4, 14))
        e.update(0)
        XCTAssertEqual(e.pondAction(canMove: false), .jump)
        let on = scene(start: p(6, 14))
        on.update(0)
        XCTAssertEqual(on.pondAction(canMove: false), .jump)
    }

    func testABreakOfAnotherPondTurnsMyIceToWaterAtOnce() {
        let s = scene(start: p(6, 14))
        s.update(0)
        var changes = 0
        s.onIceChange = { changes += 1 }
        s.setIceBreak(brk(R))
        XCTAssertNil(s.breakingPondAnchor)
        XCTAssertTrue(s.isMeInWater)
        XCTAssertEqual(changes, 1)
    }

    func testAPresenceOnlyBreakRunsFromTheCentre() {
        let s = scene(start: p(4, 14))
        breakL(s, hit: nil)
        XCTAssertEqual(s.breakingHit, p(9, 14))
    }

    func testOpeningAppliesTheStateWithoutABreak() {
        let s = scene(start: p(6, 14))
        s.setIceBreak(brk(L))
        XCTAssertNil(s.breakingPondAnchor)
        XCTAssertTrue(s.isMeInWater)
    }

    func testPausingMidBreakSinksAtOnceAndLeavesNoBreak() {
        let s = scene(start: p(6, 14))
        breakL(s, hit: p(6, 14))
        run(s, 0.2)
        XCTAssertFalse(s.isMeInWater)
        let drops = s.pondLayer!.dropletCount
        s.isPaused = true
        XCTAssertTrue(s.isMeInWater)
        XCTAssertNil(s.breakingPondAnchor)
        XCTAssertEqual(s.pondLayer!.dropletCount, drops)
    }

    func testPausingFlushesQueuedLandings() {
        let s = scene(start: p(4, 14))
        s.update(0)
        var landed = 0
        s.onIceLanding = { _, _ in landed += 1 }
        s.queueIceLanding(brk(L), jumper: nil)
        s.queueIceLanding(brk(L, ago: 100), jumper: nil)
        XCTAssertEqual(s.iceLandingCount, 2)
        s.isPaused = true
        XCTAssertEqual(landed, 2)
        XCTAssertEqual(s.iceLandingCount, 0)
        s.queueIceLanding(brk(L), jumper: nil)
        XCTAssertEqual(landed, 3)
        XCTAssertEqual(s.iceLandingCount, 0)
    }

    func testALandingFloodIsCappedAndAPausedFloodMakesNoNodes() {
        let s = scene(start: p(4, 14))
        s.update(0)
        var landed = 0
        s.onIceLanding = { _, _ in landed += 1 }
        for _ in 0..<20 { s.queueIceLanding(brk(L), jumper: "x") }
        XCTAssertEqual(s.iceLandingCount, PlazaScene.maxIceLandings)
        XCTAssertEqual(landed, 20 - PlazaScene.maxIceLandings)
        s.isPaused = true
        s.onIceLanding = { [unowned s] in s.setIceBreak($0, hit: $1) }
        let before = s.children.count
        for i in 0..<50 {
            s.queueIceLanding(brk(i.isMultiple(of: 2) ? L : R, ago: Double(i)), jumper: nil)
            s.setIceBreak(brk(i.isMultiple(of: 2) ? B : L, ago: Double(i)))
        }
        XCTAssertEqual(s.children.count, before)
    }

    func testFreezingUnderASwimmerAndADiverStandsThemOnTheIce() {
        let s = scene(start: p(34, 17))
        add(s, "s", p(35, 17), diving: true)
        s.update(0)
        s.setIceBreak(brk(L, ago: 1))
        XCTAssertTrue(s.isMeInWater)
        s.setDiving(true)
        var saw: [Bool] = []
        s.onDivingChange = { saw.append($0) }
        nowSeconds += 60
        run(s, 0.05)
        XCTAssertFalse(s.isMeInWater)
        XCTAssertFalse(s.isDiving)
        XCTAssertEqual(saw, [false])
        XCTAssertEqual(s.memberIsDiving("s"), false)
        run(s, 0.1)
        XCTAssertEqual(s.memberVisibleHeight("s"), 72)
    }

    func testAnEggOnBreakingIceClimbsOut() {
        let s = scene(start: p(6, 14))
        s.canWalk = false
        breakL(s, hit: p(6, 14))
        run(s, 2)
        XCTAssertTrue(map.isWalkable(TilePoint(x: Int(s.myFootPoint.x) / PlazaMap.tileSize, y: Int(s.myFootPoint.y) / PlazaMap.tileSize)))
    }

    func testAPausedBreakPutsAnEggStandingOnTheIceAshore() {
        let s = scene(start: p(6, 14))
        s.canWalk = false
        s.update(0)
        XCTAssertTrue(s.isMeOnIce, "test precondition")
        s.isPaused = true
        s.setIceBreak(brk(L))
        XCTAssertNil(s.breakingPondAnchor)
        XCTAssertFalse(s.isMeInWater)
        XCTAssertTrue(map.isWalkable(TilePoint(x: Int(s.myFootPoint.x) / PlazaMap.tileSize, y: Int(s.myFootPoint.y) / PlazaMap.tileSize)))
    }

    func testAJumperWhoLeavesBeforeTheLandingHitsThePondCentre() {
        let s = scene(start: p(20, 10))
        add(s, "a", p(8, 14))
        s.update(0)
        var hits: [TilePoint] = []
        s.onIceLanding = { hits.append($1) }
        s.queueIceLanding(brk(L), jumper: "a")
        crowd = [:]
        s.applyMembers([])
        run(s, 0.4)
        XCTAssertEqual(hits, [p(9, 14)])
    }

    func testAPushSlidesAcrossTheIce() {
        let s = scene(start: p(4, 14))
        s.update(0)
        s.pushMe(.right, tiles: 3)
        run(s, 1)
        XCTAssertTrue(isStandingAt(s, p(7, 14)))
        XCTAssertFalse(s.isMeInWater)
    }

    func testWalkingToAMemberCrossesTheIce() {
        let s = scene(start: p(4, 14))
        add(s, "m", p(16, 14))
        s.update(0)
        XCTAssertTrue(s.walk(toMember: "m"))
        for _ in 0..<5 { t += 1.0 / 30; s.update(t) }   // 0.167 s: the first step is done, the next is not yet issued
        XCTAssertTrue(isStandingAt(s, p(5, 14)))
    }

    func testASnowballThatLandsOnTheIceBurstsLikeGround() {
        let s = scene(start: p(10, 10))
        add(s, "a", p(6, 11))
        s.update(0)
        let shot = PlazaSnowballShot(from: p(6, 11), direction: .down, end: .ground(p(6, 14)))
        var landed = false
        s.playSnowball(by: "a", shot: shot) { landed = true }
        while !landed && t < 2 { run(s, 1.0 / 30) }
        XCTAssertTrue(landed)
        XCTAssertEqual(s.pondLayer!.dropletCount, 0)
        XCTAssertGreaterThanOrEqual(s.snowballSpriteCount, 5)
    }

    func testTheIceTakesNoFootprints() {
        nowSeconds = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!.timeIntervalSince1970
        let s = scene(start: p(4, 14))
        let plain = PlazaTileArt.plainGrassImage(map)
        s.seasonLook = { _ in PlazaSnowLook(mapImage: plain, tallGrass: nil) }
        s.refreshSnowDay()
        s.update(0)
        tap(s, rightKey)
        run(s, 0.16)
        tap(s, rightKey)
        run(s, 0.2)
        XCTAssertEqual(s.footprintCount, 0)
        let land = scene(start: p(4, 14))
        land.seasonLook = { _ in PlazaSnowLook(mapImage: plain, tallGrass: nil) }
        land.refreshSnowDay()
        land.update(0)
        tap(land, upKey)
        run(land, 0.2)
        XCTAssertEqual(land.footprintCount, 2)
    }
}
