import XCTest
import AppKit
@testable import PokeTokenBar

private final class NoSprites: PlazaSpriteFetching, @unchecked Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaPullUnderTests {

    /// Me at `myTile` with the plaza open, and a teammate standing at `theirTile`.
    private func open(me myTile: TilePoint, plunging: PlazaDirection? = nil, teammate theirTile: TilePoint) async throws
        -> (c: PlazaWindowController, scene: PlazaScene, me: Node, other: Node, heard: Heard) {
        let me = node("나"), other = node("민수")
        hub.connect(me.transport, to: other.transport)
        await settle()
        let heard = Heard()
        other.session.onEmote = { _, emote in heard.emotes.append(emote) }
        let prefs = PlazaPreferences(defaults: defaults())
        prefs.saveLastTile(myTile)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in self.now },
                                      spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                      dittoLoopSleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                      dittoSeed: { 7 })
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        XCTAssertEqual(scene.walker.tile, myTile)
        if let plunging {
            scene.plunge(plunging)
            run(scene, 1)
            XCTAssertTrue(scene.isMeInWater)
        }
        other.session.updatePlazaPosition(inPlaza: true, tile: theirTile, facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(scene.memberTiles[other.id], theirTile)
        return (c, scene, me, other, heard)
    }

    func testCWhileDivingSurfacesBacksOffAndTellsTheShoreTeammate() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(31, 16), plunging: .right, teammate: p(31, 16))
        scene.setDiving(true)
        XCTAssertTrue(scene.isDiving)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(scene.isDiving)
        XCTAssertFalse(c.isPhotoMode)   // the controller must outlive the key press
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        XCTAssertEqual(heard.emotes.first?.targetMemberID, other.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(33, 16), "I made room")
    }

    func testCWhileDivingWithNobodyOnTheShoreDoesNothing() async throws {
        let (c, scene, _, _, heard) = try await open(me: p(31, 16), plunging: .right, teammate: p(29, 16))
        scene.setDiving(true)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertTrue(scene.isDiving, "still under")
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(heard.emotes.count, 0)
    }

    func testAPullDragsMeIntoTheWaterTheDiverLeft() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(32, 16))
        c.showPull(from: other.id, on: me.id)   // the diver's step back has not arrived yet
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(32, 16))
        XCTAssertTrue(scene.isMeInWater)
    }

    func testAPullOnSomeoneElseOrFromTheWrongPlaceDoesNotMoveMe() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(36, 16))
        c.showPull(from: other.id, on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16), "the sender is five tiles off")
        other.session.updatePlazaPosition(inPlaza: true, tile: p(32, 16), facing: .down, isWalking: false)
        await settle()
        c.showPull(from: other.id, on: "someone-else")
        c.showPull(from: other.id, on: nil)
        c.showPull(from: "nobody", on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16))
    }

    func testNoPullInPhotoMode() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(32, 16))
        _ = scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(c.isPhotoMode)
        c.showPull(from: other.id, on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16))
    }

    func testCWhileSwimmingPullsAMateThreeTilesAheadWithoutSteppingBack() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(40, 17))
        swimOut(scene, extra: 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17))
        XCTAssertFalse(scene.isDiving)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        XCTAssertEqual(heard.emotes.first?.targetMemberID, other.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17), "the landing is the water tile in front, so I stay")
        XCTAssertFalse(scene.isDiving)
        withExtendedLifetime(c) {}
    }

    func testCWhileSwimmingPullsOntoMyTileAndStepsBack() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17), "I made room")
        withExtendedLifetime((c, other)) {}
    }

    func testCWhileDivingPullsFromRangeAndSurfaces() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        scene.setDiving(true)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(scene.isDiving)
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17))
        withExtendedLifetime((c, other)) {}
    }

    func testCAtAnotherSwimmerStillTackles() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(37, 17))
        scene.face(.left)
        run(scene, 0.1)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(heard.emotes.isEmpty)
        XCTAssertFalse(heard.emotes.map(\.kind).contains(.pull), "nobody is on the shore")
        withExtendedLifetime((c, other)) {}
    }

    func testAFarPullSlidesMeThreeTilesAndSplashesBig() async throws {
        let (c, scene, me, other, _) = try await open(me: p(41, 17), teammate: p(38, 17))
        c.showPull(from: other.id, on: me.id)
        run(scene, 0.25)
        XCTAssertFalse(scene.isMeInWater, "still sliding")
        var splashed = 0
        for _ in 0..<30 { run(scene, 0.1); splashed = max(splashed, try XCTUnwrap(scene.pondLayer).dropletCount) }
        XCTAssertEqual(scene.walker.tile, p(38, 17), "the puller's own tile does not stop me")
        XCTAssertTrue(scene.isMeInWater)
        XCTAssertEqual(splashed, PlazaPondLayer.bigDroplets, "a big splash")
        withExtendedLifetime(c) {}
    }

    func testAPullStopsAtTheFirstWaterTileWhenThePullerIsFurtherOut() async throws {
        let (c, scene, me, other, _) = try await open(me: p(40, 17), teammate: p(36, 17))
        c.showPull(from: other.id, on: me.id)
        run(scene, 2)
        XCTAssertEqual(scene.walker.tile, p(38, 17))
    }

    func testNoFarPullInPhotoMode() async throws {
        let (c, scene, me, other, _) = try await open(me: p(41, 17), teammate: p(38, 17))
        _ = scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(c.isPhotoMode)
        c.showPull(from: other.id, on: me.id)
        run(scene, 2)
        XCTAssertEqual(scene.walker.tile, p(41, 17))
    }

    // MARK: - Hints

    func testDivingAloneShowsHowToPull() async throws {
        let (c, scene, _, _, _) = try await open(me: p(31, 16), plunging: .right, teammate: p(29, 16))
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaDivingHint)
    }

    func testDivingUnderATeammateNamesWhoCWouldPull() async throws {
        let (c, scene, _, _, _) = try await open(me: p(31, 16), plunging: .right, teammate: p(31, 16))
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"))
        scene.setDiving(false)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"), "swimming pulls too now")
    }
}

extension PlazaPullUnderTests {
    func testSwimmingWithAShoreMateAheadShowsThePullHint() async throws {
        let (c, scene, _, _, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"))
        XCTAssertFalse(scene.isDiving)
    }

    func testSwimmingWithNobodyToPullAddsNoHintButDivingStillTeaches() async throws {
        let (c, scene, _, _, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(30, 17))
        swimOut(scene)
        c.refreshHintForTesting()
        XCTAssertNil(c.hint)
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaDivingHint)
    }

    func testCWhileDivingWithNothingToPullDoesNotEvenTurnMe() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(37, 17))
        scene.face(.right)
        scene.setDiving(true)
        run(scene, 0.1)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(scene.walker.facing, .right, "a swimmer beside me is no pull target and a diver cannot tackle")
        XCTAssertTrue(scene.isDiving)
        XCTAssertTrue(heard.emotes.isEmpty)
        withExtendedLifetime((c, other)) {}
    }

    func testThePullHintFollowsAMateWalkingIntoAndOutOfRange() async throws {
        let (c, scene, _, other, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(40, 10))
        swimOut(scene, extra: 1)   // (37,17), facing the shore
        run(scene, 0.2)
        XCTAssertNil(c.hint)
        other.session.updatePlazaPosition(inPlaza: true, tile: p(40, 17), facing: .down, isWalking: false)
        await settle()
        run(scene, 6)
        XCTAssertEqual(scene.memberTiles[other.id], p(40, 17))
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"), "no key press needed")
        other.session.updatePlazaPosition(inPlaza: true, tile: p(40, 10), facing: .down, isWalking: false)
        await settle()
        run(scene, 6)
        XCTAssertEqual(scene.memberTiles[other.id], p(40, 10))
        XCTAssertNil(c.hint)
    }
}
