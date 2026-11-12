import XCTest
import AppKit
import SpriteKit
import SwiftUI
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// F의 keyCode.
private let fireworkKey: UInt16 = 3

@MainActor
final class PlazaFireworksTests: XCTestCase {
    private typealias F = PlazaFireworks
    private let map = PlazaMapData.map
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let night = PlazaDaylight.night

    // MARK: 종류

    /// Teammates look a style up by its ID, so a shipped ID must keep working and two styles must not share one.
    func testShippedStyleIDsStayAndNeverCollide() {
        let ids = F.styles.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(Set(ids).isSuperset(of: ["ring", "double", "heartShape", "willow", "star", "spiral", "crossette",
                                               "salvo"]))
    }

    /// A newer teammate can send a style this version has not heard of: it still gets a firework.
    func testAStyleThisVersionDoesNotKnowBecomesTheRing() {
        XCTAssertEqual(F.style(id: "fromANewerVersion").id, "ring")
        XCTAssertEqual(F.style(id: nil).id, "ring")
        XCTAssertEqual(F.style(id: "star").id, "star")
    }

    func testTheNextStyleIsNeverTheOneJustFired() {
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
    func testEveryStyleFitsTheCap() {
        for style in F.styles {
            XCTAssertFalse(style.pieces.isEmpty, style.id)
            XCTAssertLessThanOrEqual(style.pieces.count, PlazaFireworkLayer.maxPieces, style.id)
        }
    }

    /// Spacing by the curve's parameter bunched the pieces at the heart's dip and tip, which stopped reading as a heart.
    func testHeartPiecesAreEvenlySpaced() {
        let reach = F.style(id: "heartShape").pieces.map(\.reach)
        XCTAssertEqual(F.style(id: "heartShape").id, "heartShape")
        for (i, a) in reach.enumerated() {
            let b = reach[(i + 1) % reach.count]
            XCTAssertGreaterThanOrEqual(hypot(a.dx - b.dx, a.dy - b.dy), 12, "piece \(i)")
        }
    }

    func testTheHeartPointsDown() throws {
        let reach = F.style(id: "heartShape").pieces.map(\.reach)
        let tip = try XCTUnwrap(reach.min { $0.dy < $1.dy })
        XCTAssertEqual(tip.dx, 0, accuracy: 3, "the tip is on the centre line, at the bottom")
    }

    // MARK: 조각 하나

    func testAPieceFliesOutThenDroops() throws {
        let piece = PlazaFireworkPiece(color: .gold, reach: CGVector(dx: 100, dy: 0), droop: 10)
        let start = try XCTUnwrap(piece.offset(at: 0))
        XCTAssertEqual(start.dx, 0, accuracy: 0.001)
        let second = try XCTUnwrap(piece.offset(at: 1))
        XCTAssertEqual(second.dx, 100, accuracy: 0.001)
        XCTAssertEqual(second.dy, -10, accuracy: 0.001, "up is positive, so it falls below where it started")
    }

    func testAPieceSlowsAsItFlies() throws {
        let piece = PlazaFireworkPiece(color: .gold, reach: CGVector(dx: 100, dy: 0))
        let early = try XCTUnwrap(piece.offset(at: 0.2)).dx
        let later = try XCTUnwrap(piece.offset(at: 0.4)).dx
        XCTAssertGreaterThan(early, later - early)
    }

    func testAPieceStartsWhereItWasPut() throws {
        let piece = PlazaFireworkPiece(color: .gold, start: CGVector(dx: -46, dy: 6), reach: CGVector(dx: 10, dy: 0), delay: 0.5)
        XCTAssertNil(piece.offset(at: 0.4), "not out yet")
        let start = try XCTUnwrap(piece.offset(at: 0.5))
        XCTAssertEqual(start.dx, -46, accuracy: 0.001)
        XCTAssertEqual(start.dy, 6, accuracy: 0.001)
    }

    /// Pieces shrink through existing art instead of fading: the faded ones read as flowers on the grass.
    func testAPieceShrinksAndThenEnds() {
        let piece = PlazaFireworkPiece(color: .red, reach: .zero, life: 2, plusAt: 0.5, dotAt: 0.75)
        XCTAssertEqual(piece.glyph(at: 0.5), PlazaFireworkGlyph(shape: .spark, color: .red))
        XCTAssertEqual(piece.glyph(at: 1.1), PlazaFireworkGlyph(shape: .plus, color: .red))
        XCTAssertEqual(piece.glyph(at: 1.6), PlazaFireworkGlyph(shape: .dot, color: .red))
        XCTAssertNil(piece.glyph(at: 2))
    }

    func testAPieceWaitsForItsDelay() {
        let piece = PlazaFireworkPiece(color: .red, reach: .zero, delay: 0.3)
        XCTAssertNil(piece.glyph(at: 0.2))
        XCTAssertNotNil(piece.glyph(at: 0.3))
    }

    func testAStyleLastsUntilItsLastPieceEnds() {
        let style = PlazaFireworkStyle(id: "t", shell: .gold, pieces: [
            PlazaFireworkPiece(color: .gold, reach: .zero, life: 1),
            PlazaFireworkPiece(color: .gold, reach: .zero, delay: 0.5, life: 1),
        ])
        XCTAssertEqual(style.duration, 1.5, accuracy: 0.001)
    }

    // MARK: 터지는 자리

    func testABurstGoesAboveTheHead() {
        let p = F.burstPoint(head: CGPoint(x: 500, y: 400), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 490))
    }

    func testABurstNearTheTopOfTheViewStaysOnScreen() {
        let p = F.burstPoint(head: CGPoint(x: 500, y: 600), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 556))
    }

    func testATeammateFarAwayBurstsAtTheEdgeOfThisView() {
        let p = F.burstPoint(head: CGPoint(x: 2000, y: 3000), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 716, y: 556))
    }

    /// The bottom corners hold the chat log and the minimap, and the sky is up: a teammate far south bursts mid-view.
    func testABurstNeverDropsBelowTheMiddleOfTheView() {
        let p = F.burstPoint(head: CGPoint(x: 500, y: -1000), visible: CGRect(x: 300, y: 300, width: 480, height: 320))
        XCTAssertEqual(p, CGPoint(x: 500, y: 460))
    }

    func testAViewSmallerThanABurstCentresIt() {
        let p = F.burstPoint(head: CGPoint(x: 2000, y: 3000), visible: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(p, CGPoint(x: 50, y: 50))
    }

    func testAShellRisesFromTheHeadToTheBurst() {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 100), burst: CGPoint(x: 0, y: 190)), 90)
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 150), burst: CGPoint(x: 0, y: 190)), 40, "a burst pushed down rises less")
    }

    func testAShellAlwaysRisesAtLeastALittle() {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: 200), burst: CGPoint(x: 0, y: 190)), 24)
    }

    func testAShellFromFarBelowEntersAtTheUsualHeight() {
        XCTAssertEqual(F.rise(head: CGPoint(x: 0, y: -1000), burst: CGPoint(x: 0, y: 190)), 90)
    }

    // MARK: 층

    private func ring() -> PlazaFireworkStyle { F.style(id: "ring") }

    private func advance(_ layer: PlazaFireworkLayer, seconds: TimeInterval) {
        var left = seconds
        while left > 0.0001 { let dt = min(left, 1.0 / 60); layer.advance(by: dt); left -= dt }
    }

    private func lit(_ layer: PlazaFireworkLayer, seconds: TimeInterval, tint: PlazaDaylight.Tint = PlazaDaylight.night,
                     firelight: (CGPoint) -> Double = { _ in 0 }) {
        var left = seconds
        while left > 0.0001 { let dt = min(left, 1.0 / 60); layer.advance(by: dt, tint: tint, firelight: firelight); left -= dt }
    }

    func testAShellRisesAndThenThePiecesBurst() {
        let layer = PlazaFireworkLayer()
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200)))
        advance(layer, seconds: 0.2)
        XCTAssertEqual(layer.shownCount, 3, "the shell and its two trailing sparks")
        advance(layer, seconds: F.riseDuration)
        XCTAssertEqual(layer.shownCount, ring().pieces.count)
    }

    func testTheShellStartsAsFarBelowTheBurstAsItWasTold() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200), rise: 40)
        advance(layer, seconds: 0.02)
        let low = try XCTUnwrap(layer.shownPositions.map(\.y).min())
        XCTAssertEqual(low, 160, accuracy: 2)
    }

    func testTheShellClimbsToTheBurstPoint() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: 0.1)
        let low = try XCTUnwrap(layer.shownPositions.map(\.y).max())
        advance(layer, seconds: 0.3)
        let high = try XCTUnwrap(layer.shownPositions.map(\.y).max())
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThanOrEqual(high, 200)
    }

    func testABurstEndsAndClearsTheSky() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + ring().duration + 0.2)
        XCTAssertEqual(layer.shownCount, 0)
        XCTAssertEqual(layer.styleIDs, [])
        XCTAssertTrue(layer.isActive, "the dark is still lifting")
        advance(layer, seconds: 0.4)
        XCTAssertFalse(layer.isActive)
    }

    func testPiecesAreReusedBetweenBursts() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + ring().duration + 0.2)
        let made = layer.children.count
        XCTAssertGreaterThan(made, 0)
        layer.launch(ring(), at: CGPoint(x: 240, y: 200))
        advance(layer, seconds: F.riseDuration + 0.3)
        XCTAssertEqual(layer.children.count, made)
    }

    func testALaunchPastTheCapIsRefusedUntilTheSkyClears() {
        let layer = PlazaFireworkLayer()
        var launched = 0
        while layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"), launched < 1000 { launched += 1 }
        XCTAssertEqual(launched, PlazaFireworkLayer.maxPieces / ring().pieces.count)
        advance(layer, seconds: F.riseDuration + 0.2)
        XCTAssertLessThanOrEqual(layer.children.count, PlazaFireworkLayer.maxPieces)
        advance(layer, seconds: ring().duration + 0.2)
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"))
    }

    /// Teammates filling the sky must not stop my F. My own are limited by the launch interval, not the cap.
    func testAFullSkyStillTakesMyFirework() {
        let layer = PlazaFireworkLayer()
        while layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가") {}
        XCTAssertTrue(layer.launch(F.style(id: "willow"), at: CGPoint(x: 200, y: 200)))
        advance(layer, seconds: F.riseDuration + 0.2)
        XCTAssertLessThanOrEqual(layer.children.count, PlazaFireworkLayer.maxPieces + F.style(id: "willow").pieces.count + 1)
    }

    /// The Pokémon sprites step at ten frames a second, so a smooth burst would look like it came from another game.
    func testPiecesStepTenTimesASecond() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + 0.25)
        let before = layer.shownPositions
        layer.advance(by: 0.01)
        XCTAssertEqual(layer.shownPositions, before, "same beat")
        layer.advance(by: 0.1)
        XCTAssertNotEqual(layer.shownPositions, before, "next beat")
    }

    func testPiecesSitOnTheTileDotGrid() {
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

    func testEveryStyleDrawsAndEnds() {
        for style in F.styles {
            let layer = PlazaFireworkLayer()
            XCTAssertTrue(layer.launch(style, at: CGPoint(x: 200, y: 200)), style.id)
            advance(layer, seconds: F.riseDuration + 0.3)
            XCTAssertGreaterThan(layer.shownCount, 0, style.id)
            advance(layer, seconds: style.duration + 0.2)
            XCTAssertEqual(layer.shownCount, 0, style.id)
        }
    }

    func testTheSkyDarkensForAShowAndClearsAfterIt() {
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

    func testPhotoPiecesAreInWorldCoordinates() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        advance(layer, seconds: F.riseDuration + 0.3)
        let shown = layer.shownPositions, photo = layer.photoParticles(worldHeight: 1000)
        XCTAssertEqual(photo.count, shown.count)
        let first = try XCTUnwrap(photo.first)
        XCTAssertEqual(first.origin.x, shown[0].x)
        XCTAssertEqual(first.origin.y, 1000 - shown[0].y - first.size.height, "the photo's y runs down from the top")
    }

    // MARK: 장면

    private func scene(at date: Date? = nil) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.size = CGSize(width: 960, height: 640)
        if let date { s.now = { date } }
        return s
    }

    private func noon() -> Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)! }
    private func midnight() -> Date { Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: date)! }

    private func run(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testFFiresOnceAndIsHeldBackLikeTheOtherKeys() {
        let s = scene()
        var fired = 0
        s.onFireworkKey = { fired += 1 }
        s.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        XCTAssertEqual(fired, 1, "the key code decides, so Hangul input works")
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: true)
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: false, modifiers: .command)
        XCTAssertEqual(fired, 1)
        s.isOverlayOpen = true
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: false)
        XCTAssertEqual(fired, 1)
    }

    func testAShowDarkensTheDaytimePlazaAndTheDayComesBack() throws {
        let s = scene(at: noon())
        s.update(0)
        XCTAssertNil(s.shownDaylight)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.5, from: 0)
        let tint = try XCTUnwrap(s.shownDaylight)
        XCTAssertEqual(tint.red, 0.594, accuracy: 0.001)
        XCTAssertEqual(tint.green, 0.636, accuracy: 0.001)
        XCTAssertEqual(tint.blue, 0.846, accuracy: 0.001)
        run(s, seconds: 4, from: 0.5)
        XCTAssertNil(s.shownDaylight)
    }

    func testAShowDoesNotDarkenNightAnyFurther() throws {
        let s = scene(at: midnight())
        s.update(0)
        let night = try XCTUnwrap(s.shownDaylight)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 0.5, from: 0)
        let tint = try XCTUnwrap(s.shownDaylight)
        XCTAssertEqual(tint.red, night.red, accuracy: 0.001)
        XCTAssertEqual(tint.blue, night.blue, accuracy: 0.001)
    }

    /// A hidden background shows the desktop, which a tint would darken. The pieces still fly, like the bubbles.
    func testAHiddenBackgroundGetsThePiecesWithoutTheDark() {
        let s = scene(at: noon())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        XCTAssertNil(s.shownDaylight)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
    }

    /// The pieces are light, so night must not dim them, and the names must stay readable on top.
    func testFireworksDrawAboveTheNightTintAndBelowTheNames() {
        let z = scene().fireworkZ
        XCTAssertGreaterThan(z, 6, "above the daylight (5) and the campfire light (6)")
        XCTAssertLessThan(z, 10, "below the name plates (10)")
    }

    func testAPausedSceneDropsAFirework() {
        let s = scene()
        s.update(0)
        s.isPaused = true
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"))
        s.isPaused = false
        run(s, seconds: 1, from: 0)
        XCTAssertEqual(s.fireworkPieceCount, 0)
    }

    func testAFireworkFromSomeoneNotHereIsIgnored() {
        let s = scene()
        s.update(0)
        XCTAssertFalse(s.playFirework(memberID: "nobody", style: "ring"))
    }

    /// The map is far wider than the view, so most teammates are off screen. Their burst comes to this view's edge, and on
    /// the right that edge is the roster's: the camera counts that column as covered, and a burst there would be hidden.
    func testATeammateFarEastBurstsClearOfTheRoster() throws {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "far", nickname: "가", isAway: false, tile: TilePoint(x: 44, y: 28), facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "far", style: "ring"))
        run(s, seconds: 1, from: 0)
        let v = try XCTUnwrap(s.photoInput()?.visibleRect)
        let height = map.pixelSize.height
        XCTAssertFalse(s.fireworkPositions.isEmpty)
        let clearEdge = v.maxX - PlazaRosterMetrics.coveredWidth / 2   // zoom 2
        for p in s.fireworkPositions {
            XCTAssertLessThan(p.x + 10, clearEdge, "behind the roster")
            XCTAssertTrue(v.insetBy(dx: -10, dy: -10).contains(CGPoint(x: p.x, y: height - p.y)), "off screen")
        }
    }

    /// The same on the left, where the unfolded shortcut guide hides the sky, at every zoom.
    func testATeammateFarWestBurstsClearOfTheGuide() throws {
        for zoom in PlazaCamera.zoomRange {
            let s = scene()
            s.zoom = zoom
            s.update(0)
            s.applyMembers([PlazaSceneMember(memberID: "far", nickname: "가", isAway: false, tile: TilePoint(x: 4, y: 28), facing: .down, isWalking: false)])
            XCTAssertTrue(s.playFirework(memberID: "far", style: "ring"))
            run(s, seconds: 1, from: 0)
            let v = try XCTUnwrap(s.photoInput()?.visibleRect)
            XCTAssertFalse(s.fireworkPositions.isEmpty)
            for p in s.fireworkPositions {
                XCTAssertGreaterThan(p.x, v.minX + PlazaShortcutGuide.coveredWidth / CGFloat(zoom), "behind the guide at zoom \(zoom)")
            }
        }
    }

    private func guideSize(snowDay: Bool = false) throws -> CGSize {
        let model = PlazaShortcutGuideModel()
        model.isSnowDay = snowDay
        let renderer = ImageRenderer(content: PlazaShortcutGuide(model: model, toggle: {}))
        renderer.scale = 1
        return try XCTUnwrap(renderer.nsImage?.size)
    }

    /// `coveredWidth` is written by hand, so a longer row must not outgrow it unnoticed.
    func testTheGuideFitsItsCoveredWidth() throws {
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + (try guideSize()).width, PlazaShortcutGuide.coveredWidth)
    }

    /// Adding the F row made the unfolded guide taller than the smallest window. It sits 46 points below the top.
    func testTheGuideFitsTheSmallestWindow() throws {
        XCTAssertLessThanOrEqual(46 + (try guideSize()).height, PlazaWindowController.minContentSize.height)
    }

    /// The V row of snow days must not outgrow the smallest window or the covered width either.
    func testTheSnowDayGuideFitsTheSmallestWindowAndItsWidth() throws {
        let size = try guideSize(snowDay: true)
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + size.width, PlazaShortcutGuide.coveredWidth)
        XCTAssertLessThanOrEqual(46 + size.height, PlazaWindowController.minContentSize.height)
    }

    /// A burst pushed down by the top of the view must not start its shell under the feet.
    func testAShellLeavesFromTheHeadWhenTheBurstIsPushedDown() throws {
        let s = scene()
        s.zoom = 3
        s.update(0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.1, from: 0)
        let foot = map.pixelSize.height - s.walkerFootY
        let low = try XCTUnwrap(s.fireworkPositions.map(\.y).min())
        XCTAssertGreaterThan(low, foot, "the shell starts above the feet")
    }

    func testAPhotoCatchesTheFireworkAndTheDark() throws {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworks.count, s.fireworkPieceCount)
        XCTAssertEqual(input.tint.red, 0.594, accuracy: 0.001)
    }

    func testATeammatesFireworkDoesNotHoldBackMine() {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "가", nickname: "가", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"), "my own was just fired")
    }

    // MARK: 내 불꽃 간격

    func testMyNextFireworkWaitsHalfASecondOfLayerTime() {
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

    func testASecondOfMineLaunchesWhileTheFirstIsStillInTheAir() {
        let s = scene()
        s.update(0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.4, from: 0)
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"), "0.4 s is too soon")
        run(s, seconds: 0.1, from: 0.4)
        let one = s.fireworkPieceCount
        XCTAssertGreaterThan(one, 0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"), "0.5 s on, with the first still rising")
        run(s, seconds: 1, from: 0.5)
        XCTAssertGreaterThan(s.fireworkPieceCount, one, "both bursts are drawn")
    }

    func testMyIntervalDoesNotGateTeammates() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        XCTAssertFalse(layer.canLaunchOwn)
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"))
        XCTAssertTrue(layer.launch(ring(), at: CGPoint(x: 200, y: 200), owner: "가"), "no per-sender gate on the receiver")
        XCTAssertFalse(layer.canLaunchOwn, "theirs do not restart or clear my wait")
    }

    /// A teammate's Mac decides when they may fire. A slow frame here must not lose their next one.
    func testATeammatesNextFireworkIsNeverHeldBack() {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "가", nickname: "가", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
    }

    // MARK: 불빛

    func testALightLiftsTowardItsOwnColour() {
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 1, color: (r: 0.7, g: 0.8, b: 1))
        XCTAssertEqual(m.r, 0.7 / 0.42, accuracy: 0.001)
        XCTAssertEqual(m.g, 0.8 / 0.48, accuracy: 0.001)
        XCTAssertEqual(m.b, 1 / 0.78, accuracy: 0.001)
    }

    func testTheCampfireKeepsItsWarmLight() {
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 1)
        XCTAssertEqual(m.r, 2, "capped at twice")
        XCTAssertEqual(m.g, 0.84 / 0.48, accuracy: 0.001)
        XCTAssertEqual(m.b, 0.62 / 0.78, accuracy: 0.001)
    }

    func testTheLightIsBrightestAtTheBurstAndStepsDown() {
        XCTAssertEqual(F.lightLevel(age: -0.1, duration: 2), 0, "the shell is still rising")
        XCTAssertEqual(F.lightLevel(age: 0, duration: 2), 1)
        XCTAssertEqual(F.lightLevel(age: 0.5, duration: 2), 0.75)
        XCTAssertEqual(F.lightLevel(age: 1.0, duration: 2), 0.5)
        XCTAssertEqual(F.lightLevel(age: 1.6, duration: 2), 0.25)
        XCTAssertEqual(F.lightLevel(age: 1.9, duration: 2), 0)
    }

    func testEachStyleLightsInItsOwnColour() {
        XCTAssertEqual(F.style(id: "ring").shell.light.r, PlazaCampfireLight.warm.r)
        XCTAssertEqual(F.style(id: "ring").shell.light.b, PlazaCampfireLight.warm.b, "gold matches the campfire")
        let colours = Set(PlazaFireworkColor.allCases.map { "\($0.light)" })
        XCTAssertEqual(colours.count, PlazaFireworkColor.allCases.count)
    }

    func testNoLightUntilTheBurstAndNoneAfterIt() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: 0.3)
        XCTAssertEqual(layer.shownLightCount, 0, "the shell gives no light")
        lit(layer, seconds: F.riseDuration)
        XCTAssertEqual(layer.shownLightCount, 1)
        lit(layer, seconds: ring().duration)
        XCTAssertEqual(layer.shownLightCount, 0)
    }

    func testALightIsAMultiplyingNodeUnderThePieces() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = try XCTUnwrap(layer.children.compactMap { $0 as? SKSpriteNode }.first { $0.blendMode == .multiplyX2 && !$0.isHidden })
        XCTAssertNotNil(node.texture)
        XCTAssertEqual(node.position, CGPoint(x: 200, y: 300))
        XCTAssertEqual(node.size, CGSize(width: 440, height: 320), "twice the radii")
        XCTAssertLessThan(node.zPosition, 0, "under the pieces")
        XCTAssertGreaterThan(scene().fireworkZ + node.zPosition, 5, "above the daylight tint, or it is multiplied away")
    }

    private func lightNode(_ layer: PlazaFireworkLayer) throws -> SKSpriteNode {
        try XCTUnwrap(layer.children.compactMap { $0 as? SKSpriteNode }.first { $0.blendMode == .multiplyX2 && !$0.isHidden })
    }

    /// The red, green and blue of the texel at the middle of a light texture.
    private func centre(_ texture: SKTexture?) throws -> [Int] {
        let image = try XCTUnwrap(texture?.cgImage())
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let o = (image.height / 2 * image.width + image.width / 2) * 4
        return (0..<3).map { Int(data[o + $0]) }
    }

    func testTheScreenLightIsInItsColourAndLevel() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(F.style(id: "spiral"), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.65)
        let m = PlazaCampfireLight.multiplier(tint: night, mix: 0.75, color: PlazaFireworkColor.blue.light)
        let want = [m.r, m.g, m.b].map { Int(($0 / 2 * 255).rounded()) }
        for (got, expected) in zip(try centre(lightNode(layer).texture), want) { XCTAssertEqual(got, expected, accuracy: 2) }
    }

    /// The texture is cached per tint, so the dusk must not keep showing the light drawn for the night.
    func testTheScreenLightFollowsTheTint() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.05)
        let atNight = try centre(lightNode(layer).texture)
        lit(layer, seconds: 0.1, tint: PlazaDaylight.dusk)
        XCTAssertNotEqual(try centre(lightNode(layer).texture), atNight)
    }

    func testThePhotoLightKeepsItsColourAndLevel() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(F.style(id: "spiral"), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.65)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.level, 0.75)
        XCTAssertEqual(light.color.r, 0.7)
        XCTAssertEqual(light.color.b, 1)
    }

    func testThePhotoLightSitsExactlyWhereTheScreenLightDoes() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 201, y: 303))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = try lightNode(layer), light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(node.position, CGPoint(x: 202, y: 304), "on the tile dot grid")
        XCTAssertEqual(light.center, CGPoint(x: 202, y: 696))
    }

    func testDaylightGetsNoLight() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.1, tint: .none)
        XCTAssertEqual(layer.shownCount, ring().pieces.count)
        XCTAssertEqual(layer.shownLightCount, 0)
    }

    func testTheLightSitsOnTheBurst() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.center, CGPoint(x: 200, y: 700), "the photo's y runs down from the top")
        XCTAssertEqual(light.radii, F.lightRadii)
        XCTAssertEqual(light.level, 1)
    }

    /// Lights multiply, so two over one spot push the ground past daylight into neon. The sky gives one light at a time.
    func testOnlyTheBrightestBurstLights() throws {
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
    func testAFadingBurstOutshinesAFreshOneUnderTheFirelight() throws {
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

    func testTheOneLightNodeIsReused() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + ring().duration + 0.2)
        let made = layer.children.count
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        lit(layer, seconds: F.riseDuration + 0.1)
        XCTAssertEqual(layer.children.count, made)
    }

    /// Ground the campfire already lights must not brighten again, or the two multiply past daylight.
    func testABurstLightsOnlyWhatTheFirelightLeaves() throws {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        layer.advance(by: F.riseDuration + 0.1, tint: night) { _ in 0.75 }
        layer.advance(by: 0.01, tint: night) { _ in 0.75 }
        let light = try XCTUnwrap(layer.photoLight(tint: night, worldHeight: 1000))
        XCTAssertEqual(light.level, 0.25, accuracy: 0.001)
    }

    func testABurstFullyInTheFirelightAddsNoLight() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 200))
        layer.advance(by: F.riseDuration + 0.1, tint: night) { _ in 1 }
        XCTAssertEqual(layer.shownLightCount, 0)
        XCTAssertGreaterThan(layer.shownCount, 0, "the pieces still burst")
    }

    private func nightScene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2, nickname: "나")
        s.size = CGSize(width: 960, height: 640)
        let at = midnight()
        s.now = { at }
        s.campfireLit = true
        s.update(0)
        return s
    }

    func testBesideALitCampfireTheFireworkAddsNoLight() throws {
        let fire = try XCTUnwrap(map.campfireTiles.first)
        let s = nightScene(start: TilePoint(x: fire.x, y: fire.y + 3))
        XCTAssertTrue(s.isCampfireLightShown)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }

    func testFarFromALitCampfireTheFireworkLights() {
        let s = nightScene(start: TilePoint(x: 4, y: 28))
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testTheSceneLightsANightFirework() throws {
        let s = scene(at: midnight())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworkLight?.tint, input.tint)
    }

    /// The dark of a daytime show is dark enough for the burst to light the ground.
    func testADaytimeShowIsLitToo() {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testAHiddenBackgroundGetsNoLight() {
        let s = scene(at: midnight())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }

    // MARK: 창과 팀원

    private var suites: [String] = []
    private var dirs: [URL] = []
    /// 세션은 테스트가 끝날 때까지 붙잡아 둔다. 놓으면 그 팀원이 사라진다.
    private var sessions: [TeamSession] = []
    private var clockNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []; sessions = []
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    @MainActor private final class Received { var emotes: [TeamEmote] = [] }

    private func session(_ name: String, code: TeamCode, hub: FakeTransportHub) -> (TeamSession, FakeTeamTransport, TeamSettings, Received) {
        let suite = "plaza.fireworks.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaFireworksTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        sessions.append(session)
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return (session, transport, settings, received)
    }

    private func controller(_ session: TeamSession, _ settings: TeamSettings) -> PlazaWindowController {
        let name = "plaza.fireworks.prefs.\(UUID())"
        suites.append(name)
        return PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: name)),
                                     loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: session, clock: { [unowned self] in clockNow })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    /// 두 Mac을 잇고 팀원이 장면에 나타날 때까지 기다린다.
    private func connected(_ c: PlazaWindowController, _ a: FakeTeamTransport, _ b: FakeTeamTransport, hub: FakeTransportHub,
                           other: TeamSettings) async throws -> PlazaScene {
        hub.connect(a, to: b)
        let scene = try XCTUnwrap(c.scene)
        for _ in 0..<400 where scene.memberTiles[other.memberID] == nil { await Task.yield() }
        XCTAssertNotNil(scene.memberTiles[other.memberID])
        scene.update(0)
        return scene
    }

    func testFFiresHereAndTellsTeammatesWhichStyle() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.map(\.kind), [.firework])
        let sent = try XCTUnwrap(other.emotes.first?.fireworkStyle)
        XCTAssertEqual(scene.fireworkStyleIDs, [sent], "the same style on both screens")
    }

    /// F is held back until 0.5 s after my last firework, so it cannot be spammed. The wait is scene time, not the wall clock:
    /// the show pauses with the window, and so does the wait.
    func testTheNextFireworkWaitsHalfASecondOfSceneTime() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1)

        run(scene, seconds: 0.3, from: 0)
        clockNow = clockNow.addingTimeInterval(3600)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1, "too soon, however long the wall clock says")

        run(scene, seconds: 0.3, from: 0.3)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 2, "0.5 s of scene time passed while the first is still in the air")
    }

    /// One pair of shots differs by chance seven times in eight, so this fires enough of them to catch a repeat.
    func testTheKeyNeverFiresTheSameStyleTwiceInARow() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        var t: TimeInterval = 0
        for _ in 0..<40 {
            scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
            await settle()
            while !scene.fireworkStyleIDs.isEmpty { t += 0.06; scene.update(t) }
        }
        let sent = other.emotes.compactMap(\.fireworkStyle)
        XCTAssertEqual(sent.count, 40)
        for (a, b) in zip(sent, sent.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    /// A launch the scene refuses (a paused window) must not reach teammates or use up the turn.
    func testAKeyTheSceneRefusesTellsNobody() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.isPaused = true
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertTrue(other.emotes.isEmpty)
        scene.isPaused = false
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1, "the turn was not used up")
    }
}
