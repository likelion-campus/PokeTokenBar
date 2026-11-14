import XCTest
@testable import PokeTokenBar

@MainActor
final class PlazaFireworksTests: XCTestCase {
    typealias F = PlazaFireworks
    let map = PlazaMapData.map
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let night = PlazaDaylight.night


    // MARK: 종류
    /// Teammates look a style up by its ID, so a shipped ID must keep working and two styles must not share one.
    func testShippedStyleIDsStayAndNeverCollide() async {
        let ids = F.styles.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(Set(ids).isSuperset(of: ["ring", "double", "heartShape", "willow", "star", "spiral", "crossette",
                                               "salvo"]))
    }

    /// A newer teammate can send a style this version has not heard of: it still gets a firework.
    func testAStyleThisVersionDoesNotKnowBecomesTheRing() async {
        XCTAssertEqual(F.style(id: "fromANewerVersion").id, "ring")
        XCTAssertEqual(F.style(id: nil).id, "ring")
        XCTAssertEqual(F.style(id: "star").id, "star")
    }

    func testTheNextStyleIsNeverTheOneJustFired() async {
        var rng = SystemRandomNumberGenerator()
        var last: String?
        var seen = Set<String>()
        for _ in 0..<1000 {
            let next = F.next(after: last, using: &rng).id
            XCTAssertNotEqual(next, last)
            seen.insert(next)
            last = next
        }
        XCTAssertEqual(seen, Set(F.styles.map(\.id)), "every style comes up")
    }

    /// A style with more pieces than the cap could never be launched.
    func testEveryStyleFitsTheCap() async {
        for style in F.styles {
            XCTAssertFalse(style.pieces.isEmpty, style.id)
            XCTAssertLessThanOrEqual(style.pieces.count, PlazaFireworkLayer.maxPieces, style.id)
        }
    }

    /// Spacing by the curve's parameter bunched the pieces at the heart's dip and tip, which stopped reading as a heart.
    func testHeartPiecesAreEvenlySpaced() async {
        let reach = F.style(id: "heartShape").pieces.map(\.reach)
        XCTAssertEqual(F.style(id: "heartShape").id, "heartShape")
        for (i, a) in reach.enumerated() {
            let b = reach[(i + 1) % reach.count]
            XCTAssertGreaterThanOrEqual(hypot(a.dx - b.dx, a.dy - b.dy), 12, "piece \(i)")
        }
    }

    func testTheHeartPointsDown() async throws {
        let reach = F.style(id: "heartShape").pieces.map(\.reach)
        let tip = try XCTUnwrap(reach.min { $0.dy < $1.dy })
        XCTAssertEqual(tip.dx, 0, accuracy: 3, "the tip is on the centre line, at the bottom")
    }


    // MARK: 조각 하나
    func testAPieceFliesOutThenDroops() async throws {
        let piece = PlazaFireworkPiece(color: .gold, reach: CGVector(dx: 100, dy: 0), droop: 10)
        let start = try XCTUnwrap(piece.offset(at: 0))
        XCTAssertEqual(start.dx, 0, accuracy: 0.001)
        let second = try XCTUnwrap(piece.offset(at: 1))
        XCTAssertEqual(second.dx, 100, accuracy: 0.001)
        XCTAssertEqual(second.dy, -10, accuracy: 0.001, "up is positive, so it falls below where it started")
    }

    func testAPieceSlowsAsItFlies() async throws {
        let piece = PlazaFireworkPiece(color: .gold, reach: CGVector(dx: 100, dy: 0))
        let early = try XCTUnwrap(piece.offset(at: 0.2)).dx
        let later = try XCTUnwrap(piece.offset(at: 0.4)).dx
        XCTAssertGreaterThan(early, later - early)
    }

    func testAPieceStartsWhereItWasPut() async throws {
        let piece = PlazaFireworkPiece(color: .gold, start: CGVector(dx: -46, dy: 6), reach: CGVector(dx: 10, dy: 0), delay: 0.5)
        XCTAssertNil(piece.offset(at: 0.4), "not out yet")
        let start = try XCTUnwrap(piece.offset(at: 0.5))
        XCTAssertEqual(start.dx, -46, accuracy: 0.001)
        XCTAssertEqual(start.dy, 6, accuracy: 0.001)
    }

    /// Pieces shrink through existing art instead of fading: the faded ones read as flowers on the grass.
    func testAPieceShrinksAndThenEnds() async {
        let piece = PlazaFireworkPiece(color: .red, reach: .zero, life: 2, plusAt: 0.5, dotAt: 0.75)
        XCTAssertEqual(piece.glyph(at: 0.5), PlazaFireworkGlyph(shape: .spark, color: .red))
        XCTAssertEqual(piece.glyph(at: 1.1), PlazaFireworkGlyph(shape: .plus, color: .red))
        XCTAssertEqual(piece.glyph(at: 1.6), PlazaFireworkGlyph(shape: .dot, color: .red))
        XCTAssertNil(piece.glyph(at: 2))
    }

    func testAPieceWaitsForItsDelay() async {
        let piece = PlazaFireworkPiece(color: .red, reach: .zero, delay: 0.3)
        XCTAssertNil(piece.glyph(at: 0.2))
        XCTAssertNotNil(piece.glyph(at: 0.3))
    }

    func testAStyleLastsUntilItsLastPieceEnds() async {
        let style = PlazaFireworkStyle(id: "t", shell: .gold, pieces: [
            PlazaFireworkPiece(color: .gold, reach: .zero, life: 1),
            PlazaFireworkPiece(color: .gold, reach: .zero, delay: 0.5, life: 1),
        ])
        XCTAssertEqual(style.duration, 1.5, accuracy: 0.001)
    }


    // MARK: 터지는 자리
    func testABurstGoesAboveTheHead() async {
        let p = F.burstPoint(head: CGPoint(x: 500, y: 400), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 490))
    }

    func testABurstNearTheTopOfTheViewStaysOnScreen() async {
        let p = F.burstPoint(head: CGPoint(x: 500, y: 600), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 556))
    }

    func testATeammateFarAwayBurstsAtTheEdgeOfThisView() async {
        let p = F.burstPoint(head: CGPoint(x: 2000, y: 3000), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 716, y: 556))
    }

    /// The bottom corners hold the chat log and the minimap, and the sky is up: a teammate far south bursts mid-view.
    func testABurstNeverDropsBelowTheMiddleOfTheView() async {
        let p = F.burstPoint(head: CGPoint(x: 500, y: -1000), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 460))
    }

    func testAViewSmallerThanABurstCentresIt() async {
        let p = F.burstPoint(head: CGPoint(x: 2000, y: 3000), visible: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(p, CGPoint(x: 50, y: 50))
    }

    func testAShellRisesFromTheHeadToTheBurst() async {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 100), burst: CGPoint(x: 0, y: 190)), 90)
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 150), burst: CGPoint(x: 0, y: 190)), 40, "a burst pushed down rises less")
    }

    func testAShellAlwaysRisesAtLeastALittle() async {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 200), burst: CGPoint(x: 0, y: 190)), 24)
    }

    func testAShellFromFarBelowEntersAtTheUsualHeight() async {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: -1000), burst: CGPoint(x: 0, y: 190)), 90)
    }


    // MARK: 층
    func ring() -> PlazaFireworkStyle { F.style(id: "ring") }

    func advance(_ layer: PlazaFireworkLayer, seconds: TimeInterval) {
        var left = seconds
        while left > 0.0001 { let dt = min(left, 1.0 / 60); layer.advance(by: dt); left -= dt }
    }

    func lit(_ layer: PlazaFireworkLayer, seconds: TimeInterval, tint: PlazaDaylight.Tint = PlazaDaylight.night,
                     firelight: (CGPoint) -> Double = { _ in 0 }) {
        var left = seconds
        while left > 0.0001 { let dt = min(left, 1.0 / 60); layer.advance(by: dt, tint: tint, firelight: firelight); left -= dt }
    }

    func testAShellRisesAndThenThePiecesBurst() async {
        let layer = PlazaFireworkLayer()
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200)))
        advance(layer, seconds: 0.2)
        XCTAssertEqual(layer.shownCount, 3, "the shell and its two trailing sparks")
        advance(layer, seconds: F.riseDuration)
        XCTAssertEqual(layer.shownCount, ring().pieces.count)
    }

    func testTheShellStartsAsFarBelowTheBurstAsItWasTold() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200), rise: 40)
        advance(layer, seconds: 0.02)
        let low = try XCTUnwrap(layer.shownPositions.map(\.y).min())
        XCTAssertEqual(low, 160, accuracy: 2)
    }

    func testTheShellClimbsToTheBurstPoint() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: 0.1)
        let low = try XCTUnwrap(layer.shownPositions.map(\.y).max())
        advance(layer, seconds: 0.3)
        let high = try XCTUnwrap(layer.shownPositions.map(\.y).max())
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThanOrEqual(high, 200)
    }

    func testABurstEndsAndClearsTheSky() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + ring().duration + 0.2)
        XCTAssertEqual(layer.shownCount, 0)
        XCTAssertEqual(layer.styleIDs, [])
        XCTAssertTrue(layer.isActive, "the dark is still lifting")
        advance(layer, seconds: 0.4)
        XCTAssertFalse(layer.isActive)
    }

    func testPiecesAreReusedBetweenBursts() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + ring().duration + 0.2)
        let made = layer.root.children.count
        XCTAssertGreaterThan(made, 0)
        layer.launch(ring(), at: CGPoint(x: 240, y: 200))
        advance(layer, seconds: F.riseDuration + 0.3)
        XCTAssertEqual(layer.root.children.count, made)
    }

    func testALaunchPastTheCapIsRefusedUntilTheSkyClears() async {
        let layer = PlazaFireworkLayer()
        var launched = 0
        while layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"), launched < 1000 { launched += 1 }
        XCTAssertEqual(launched, PlazaFireworkLayer.maxPieces / ring().pieces.count)
        advance(layer, seconds: F.riseDuration + 0.2)
        XCTAssertLessThanOrEqual(layer.root.children.count, PlazaFireworkLayer.maxPieces)
        advance(layer, seconds: ring().duration + 0.2)
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"))
    }

    /// Teammates filling the sky must not stop my F. My own are limited by the launch interval, not the cap.
    func testAFullSkyStillTakesMyFirework() async {
        let layer = PlazaFireworkLayer()
        while layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가") {}
        XCTAssertTrue(layer.launch(F.style(id: "willow"), at: CGPoint(x: 200, y: 200)))
        advance(layer, seconds: F.riseDuration + 0.2)
        XCTAssertLessThanOrEqual(layer.root.children.count, PlazaFireworkLayer.maxPieces + F.style(id: "willow").pieces.count + 1)
    }

    /// The Pokémon sprites step at ten frames a second, so a smooth burst would look like it came from another game.
    func testPiecesStepTenTimesASecond() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + 0.25)
        let before = layer.shownPositions
        layer.advance(by: 0.01)
        XCTAssertEqual(layer.shownPositions, before, "same beat")
        layer.advance(by: 0.1)
        XCTAssertNotEqual(layer.shownPositions, before, "next beat")
    }

    func testPiecesSitOnTheTileDotGrid() async {
        let layer = PlazaFireworkLayer()
        layer.launch(F.style(id: "star"), at: CGPoint(x: 201, y: 203))
        for _ in 0..<12 {
            advance(layer, seconds: 0.1)
            for p in layer.shownPositions {
                XCTAssertEqual(p.x.truncatingRemainder(dividingBy: 2), 0)
                XCTAssertEqual(p.y.truncatingRemainder(dividingBy: 2), 0)
            }
        }
    }

    func testEveryStyleDrawsAndEnds() async {
        for style in F.styles {
            let layer = PlazaFireworkLayer()
            XCTAssertTrue(layer.launch(style, at: CGPoint(x: 200, y: 200)), style.id)
            advance(layer, seconds: F.riseDuration + 0.3)
            XCTAssertGreaterThan(layer.shownCount, 0, style.id)
            advance(layer, seconds: style.duration + 0.2)
            XCTAssertEqual(layer.shownCount, 0, style.id)
        }
    }

    func testTheSkyDarkensForAShowAndClearsAfterIt() async {
        let layer = PlazaFireworkLayer()
        XCTAssertEqual(layer.dimLevel, 0)
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: 0.4)
        XCTAssertEqual(layer.dimLevel, 0.7, accuracy: 0.001)
        advance(layer, seconds: F.riseDuration + ring().duration - 0.5)
        XCTAssertEqual(layer.dimLevel, 0.7, accuracy: 0.001, "still dark at the last piece")
        advance(layer, seconds: 0.6)
        XCTAssertEqual(layer.dimLevel, 0, accuracy: 0.001)
    }

    func testPhotoPiecesAreInWorldCoordinates() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + 0.3)
        let shown = layer.shownPositions, photo = layer.photoParticles(worldHeight: 1000)
        XCTAssertEqual(photo.count, shown.count)
        let first = try XCTUnwrap(photo.first)
        XCTAssertEqual(first.origin.x, shown[0].x)
        XCTAssertEqual(first.origin.y, 1000 - shown[0].y - first.size.height, "the photo's y runs down from the top")
    }


    // MARK: 내 불꽃 간격
    func testMyNextFireworkWaitsHalfASecondOfLayerTime() async {
        let layer = PlazaFireworkLayer()
        XCTAssertTrue(layer.canLaunchOwn, "nothing fired yet")
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        XCTAssertFalse(layer.canLaunchOwn, "no time has passed")
        layer.advance(by: 0.4)
        XCTAssertFalse(layer.canLaunchOwn)
        layer.advance(by: 0.1)
        XCTAssertTrue(layer.canLaunchOwn, "0.5 s on the layer clock")
        XCTAssertEqual(PlazaFireworkLayer.ownInterval, 0.5)
    }

    func testMyIntervalDoesNotGateTeammates() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        XCTAssertFalse(layer.canLaunchOwn)
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"))
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"), "no per-sender gate on the receiver")
        XCTAssertFalse(layer.canLaunchOwn, "theirs do not restart or clear my wait")
    }

    // MARK: 불빛
    func testALightLiftsTowardItsOwnColour() async {
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 1, color: (r: 0.7, g: 0.8, b: 1))
        XCTAssertEqual(m.r, 0.7 / 0.42, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.8 / 0.48, accuracy: 0.001)
        XCTAssertEqual(m.b, 1 / 0.78, accuracy: 0.001)
    }

    func testTheCampfireKeepsItsWarmLight() async {
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 1)
        XCTAssertEqual(m.r, 2, "capped at twice")
        XCTAssertEqual(m.g, 0.84 / 0.48, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.62 / 0.78, accuracy: 0.001)
    }

    func testTheLightIsBrightestAtTheBurstAndStepsDown() async {
        XCTAssertEqual(F.lightLevel(age: -0.1, duration: 2), 0, "the shell is still rising")
        XCTAssertEqual(F.lightLevel(age: 0, duration: 2), 1)
        XCTAssertEqual(F.lightLevel(age: 0.5, duration: 2), 0.75)
        XCTAssertEqual(F.lightLevel(age: 1.0, duration: 2), 0.5)
        XCTAssertEqual(F.lightLevel(age: 1.6, duration: 2), 0.25)
        XCTAssertEqual(F.lightLevel(age: 1.9, duration: 2), 0)
    }

    func testEachStyleLightsInItsOwnColour() async {
        XCTAssertEqual(F.style(id: "ring").shell.light.r, PlazaCampfireLight.warm.r)
        XCTAssertEqual(F.style(id: "ring").shell.light.b, PlazaCampfireLight.warm.b, "gold matches the campfire")
        let colours = Set(PlazaFireworkColor.allCases.map { "\($0.light)" })
        XCTAssertEqual(colours.count, PlazaFireworkColor.allCases.count)
    }

    func testNoLightUntilTheBurstAndNoneAfterIt() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: 0.3)
        XCTAssertEqual(layer.shownLightCount, 0, "the shell gives no light")
        lit(layer, seconds: F.riseDuration)
        XCTAssertEqual(layer.shownLightCount, 1)
        lit(layer, seconds: ring().duration)
        XCTAssertEqual(layer.shownLightCount, 0)
    }

    func testTheScreenLightIsInItsColourAndLevel() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(F.style(id: "spiral"), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.65)
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 0.75, color: PlazaFireworkColor.blue.light)
        let want = [m.r, m.g, m.b].map { Int(($0 / 2 * 255).rounded()) }
        for (got, expected) in zip(try centre(lightNode(layer).texture), want) { XCTAssertEqual(got, expected, accuracy: 2) }
    }

    /// The texture is cached per tint, so the dusk must not keep showing the light drawn for the night.
    func testTheScreenLightFollowsTheTint() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.05)
        let atNight = try centre(lightNode(layer).texture)
        lit(layer, seconds: 0.1, tint: PlazaDaylight.dusk)
        XCTAssertNotEqual(try centre(lightNode(layer).texture), atNight)
    }

    func testThePhotoLightKeepsItsColourAndLevel() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(F.style(id: "spiral"), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.65)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.level, 0.75)
        XCTAssertEqual(light.color.r, 0.7)
        XCTAssertEqual(light.color.b, 1)
    }

    func testThePhotoLightSitsExactlyWhereTheScreenLightDoes() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 201, y: 303))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = try lightNode(layer), light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(node.position, CGPoint(x: 202, y: 304), "on the tile dot grid")
        XCTAssertEqual(light.center, CGPoint(x: 202, y: 696))
    }

    func testDaylightGetsNoLight() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.1, tint: .none)
        XCTAssertEqual(layer.shownCount, ring().pieces.count)
        XCTAssertEqual(layer.shownLightCount, 0)
    }

    func testTheLightSitsOnTheBurst() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.center, CGPoint(x: 200, y: 700), "the photo's y runs down from the top")
        XCTAssertEqual(light.radii, F.lightRadii)
        XCTAssertEqual(light.level, 1)
    }

    /// Lights multiply, so two over one spot push the ground past daylight into neon. The sky gives one light at a time.
    func testOnlyTheBrightestBurstLights() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 100, y: 100), owner: "가")
        lit(layer, seconds: F.riseDuration + 0.75)
        layer.launch(F.style(id: "double"), at: CGPoint(x: 300, y: 100))
        lit(layer, seconds: F.riseDuration + 0.1)
        XCTAssertEqual(layer.shownLightCount, 1)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.center.x, 300, "the fresh burst, not the fading one")
        XCTAssertEqual(light.level, 1)
    }

    /// The newest burst is not always the brightest: one under the firelight has little left to give.
    func testAFadingBurstOutshinesAFreshOneUnderTheFirelight() async throws {
        let layer = PlazaFireworkLayer()
        let firelight: (CGPoint) -> Double = { $0.x == 300 ? 0.9 : 0 }
        layer.launch(ring(), at: CGPoint(x: 100, y: 100), owner: "가")
        lit(layer, seconds: F.riseDuration + 0.5, firelight: firelight)
        layer.launch(ring(), at: CGPoint(x: 300, y: 100))
        lit(layer, seconds: F.riseDuration + 0.1, firelight: firelight)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.center.x, 100)
        XCTAssertGreaterThanOrEqual(light.level, 0.25, "its own level, not the fresh burst's 0.1")
    }

    func testTheOneLightNodeIsReused() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + ring().duration + 0.2)
        let made = layer.root.children.count
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.1)
        XCTAssertEqual(layer.root.children.count, made)
    }

    /// Ground the campfire already lights must not brighten again, or the two multiply past daylight.
    func testABurstLightsOnlyWhatTheFirelightLeaves() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        layer.advance(by: F.riseDuration + 0.1, tint: night) { _ in 0.75 }
        layer.advance(by: 0.01, tint: night) { _ in 0.75 }
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.level, 0.25, accuracy: 0.001)
    }

    func testABurstFullyInTheFirelightAddsNoLight() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        layer.advance(by: F.riseDuration + 0.1, tint: night) { _ in 1 }
        XCTAssertEqual(layer.shownLightCount, 0)
        XCTAssertGreaterThan(layer.shownCount, 0, "the pieces still burst")
    }

    func testALightIsAMultiplyingNodeUnderThePieces() async throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = try XCTUnwrap(layer.root.children.compactMap { $0 as? PlazaSprite }.first { $0.blendMode == .multiplyX2 && !$0.isHidden })
        XCTAssertNotNil(node.texture)
        XCTAssertEqual(node.position, CGPoint(x: 200, y: 300))
        XCTAssertEqual(node.size, CGSize(width: 440, height: 320), "twice the radii")
        XCTAssertLessThan(node.zPosition, 0, "under the pieces")
    }

    private func lightNode(_ layer: PlazaFireworkLayer) throws -> PlazaSprite {
        try XCTUnwrap(layer.root.children.compactMap { $0 as? PlazaSprite }.first { $0.blendMode == .multiplyX2 && !$0.isHidden })
    }

    /// The red, green and blue of the texel at the middle of a light texture.
    private func centre(_ texture: PlazaTexture?) throws -> [Int] {
        let image = try XCTUnwrap(texture?.image)
        let o = (image.height / 2 * image.width + image.width / 2) * 4
        return (0..<3).map { Int(image.pixels.bytes[o + $0]) }
    }

    // MARK: 창과 팀원
    var dirs: [URL] = []

    /// 세션은 테스트가 끝날 때까지 붙잡아 둔다. 놓으면 그 팀원이 사라진다.
    var sessions: [TeamSession] = []

    var clockNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []; sessions = []
    }
}
