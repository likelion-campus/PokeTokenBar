import XCTest
@testable import PokeTokenBar

/// The Pokémon item pictures the plaza throws in spring and summer (`PlazaThrowItems`): which items, how a downloaded
/// picture becomes the thrown ones, and how they reach the scene from the controller.
@MainActor
final class PlazaThrowItemsTests: XCTestCase {
    let map = PlazaMapData.map

    /// A 30×30 item picture like the downloaded ones: empty all round, a red body with a dark outline, a white shine and
    /// one half-clear pixel.
    private func item() -> PlazaImage {
        var b = PlazaBitmap(width: 30, height: 30)
        for y in 4..<26 { for x in 5..<23 { b[x, y] = PlazaRGBA(r: 232, g: 72, b: 72, a: 255) } }
        for x in 5..<23 { b[x, 4] = PlazaRGBA(r: 41, g: 41, b: 41, a: 255) }
        b[8, 8] = PlazaRGBA(r: 255, g: 255, b: 255, a: 255)
        b[9, 9] = PlazaRGBA(r: 100, g: 20, b: 20, a: 128)
        return PlazaImage(bitmap: b)
    }

    func testSpringAndSummerThrowItemsAndTheOtherSeasonsDoNot() async {
        XCTAssertEqual(PlazaThrowItems.itemName(.spring), "pink-petal")
        XCTAssertEqual(PlazaThrowItems.itemName(.summer), "air-balloon")
        XCTAssertNil(PlazaThrowItems.itemName(.autumn))
        XCTAssertNil(PlazaThrowItems.itemName(.winter))
    }

    func testTheEmptyBorderIsCutOffAndAnEmptyPictureGivesNothing() async throws {
        let cut = try XCTUnwrap(PlazaThrowItems.trimmed(item().pixels))
        XCTAssertEqual([cut.width, cut.height], [18, 22])
        XCTAssertEqual(cut[0, 0], PlazaRGBA(r: 41, g: 41, b: 41, a: 255), "the top-left pixel of the picture")
        XCTAssertEqual(cut[17, 21], PlazaRGBA(r: 232, g: 72, b: 72, a: 255), "the bottom-right pixel of the picture")
        XCTAssertNil(PlazaThrowItems.trimmed(PlazaBitmap(width: 30, height: 30)))
        XCTAssertTrue(PlazaThrowItems.balls(.summer, item: PlazaImage(bitmap: PlazaBitmap(width: 30, height: 30))).isEmpty)
    }

    func testOnlyTheHueOfColouredOpaquePixelsTurns() async {
        var b = PlazaBitmap(width: 4, height: 1)
        b[0, 0] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255)
        b[1, 0] = PlazaRGBA(r: 41, g: 41, b: 41, a: 255)      // outline: no colour to turn
        b[2, 0] = PlazaRGBA(r: 255, g: 230, b: 230, a: 255)   // shine: too pale
        b[3, 0] = PlazaRGBA(r: 100, g: 20, b: 20, a: 128)     // not opaque
        let green = PlazaThrowItems.hueShifted(b, degrees: 120), blue = PlazaThrowItems.hueShifted(b, degrees: 225)
        XCTAssertEqual(green[0, 0], PlazaRGBA(r: 0, g: 255, b: 0, a: 255))
        XCTAssertEqual(blue[0, 0], PlazaRGBA(r: 0, g: 64, b: 255, a: 255))
        for x in 1..<4 { XCTAssertEqual(green[x, 0], b[x, 0], "pixel \(x)") }
        // Saturation and brightness stay: a duller red turns into as dull a green.
        var dull = PlazaBitmap(width: 1, height: 1)
        dull[0, 0] = PlazaRGBA(r: 232, g: 72, b: 72, a: 255)
        XCTAssertEqual(PlazaThrowItems.hueShifted(dull, degrees: 120)[0, 0], PlazaRGBA(r: 72, g: 232, b: 72, a: 255))
        XCTAssertEqual(PlazaThrowItems.hueShifted(dull, degrees: 360)[0, 0], dull[0, 0], "a full turn")
    }

    func testTheBalloonComesInFiveColoursOfOneShapeAndThePetalAsItIs() async throws {
        let balloons = PlazaThrowItems.balls(.summer, item: item()).map(\.pixels)
        XCTAssertEqual(balloons.count, 5)
        XCTAssertEqual(balloons[0], try XCTUnwrap(PlazaThrowItems.trimmed(item().pixels)), "the first is the picture as it came")
        XCTAssertEqual(Set(balloons.map { $0[10, 10] }).count, 5, "five body colours")
        let body = balloons.map { $0[10, 10] }
        XCTAssertTrue(body[1].b > body[1].r && body[1].b > body[1].g, "blue \(body[1])")
        XCTAssertTrue(body[2].g > body[2].r && body[2].g > body[2].b, "green \(body[2])")
        XCTAssertTrue(body[3].r > 200 && body[3].g > 200 && body[3].b < 100, "yellow \(body[3])")
        XCTAssertTrue(body[4].b > body[4].g && body[4].r > body[4].g, "purple \(body[4])")
        for b in balloons {
            XCTAssertEqual([b.width, b.height], [18, 22])
            XCTAssertEqual(stride(from: 3, to: b.bytes.count, by: 4).map { b.bytes[$0] },
                           stride(from: 3, to: balloons[0].bytes.count, by: 4).map { balloons[0].bytes[$0] }, "the same shape")
            XCTAssertEqual(b[0, 0], PlazaRGBA(r: 41, g: 41, b: 41, a: 255), "the outline keeps its colour")
            XCTAssertEqual(b[3, 4], PlazaRGBA(r: 255, g: 255, b: 255, a: 255), "the shine keeps its colour")
        }
        let petal = PlazaThrowItems.balls(.spring, item: item()).map(\.pixels)
        XCTAssertEqual(petal, [balloons[0]], "one picture, as it came")
    }

    // MARK: - The scene

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나", pondVisuals: false)
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        return s
    }

    private func throwOne(_ s: PlazaScene) {
        s.playSnowball(by: nil, shot: PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))) {}
    }

    func testItemBallsReplaceTheBundledPictureOfTheirSeasonOnly() async throws {
        let s = scene()
        s.seasonChoice = .summer
        s.refreshSnowDay()
        s.update(0)
        throwOne(s)
        let bundled = try XCTUnwrap(s.snowballBallImages.last)
        let balloons = PlazaThrowItems.balls(.summer, item: item())
        s.setItemBalls(balloons, for: .summer)
        XCTAssertTrue(s.snowballBallImages[0] === balloons[0], "the ball already in the air turns too")
        for _ in 0..<5 { throwOne(s) }
        XCTAssertTrue(zip(s.snowballBallImages, (0..<6).map { balloons[$0 % 5] }).allSatisfy { $0 === $1 }, "one colour after another")
        XCTAssertEqual(s.snowballBallSizes, Array(repeating: CGSize(width: 18, height: 22), count: 6))
        s.seasonChoice = .autumn
        XCTAssertFalse(s.snowballBallImages.contains { image in balloons.contains { $0 === image } }, "autumn keeps its own picture")
        s.seasonChoice = .summer
        XCTAssertTrue(s.snowballBallImages[0] === balloons[0], "and summer has the balloons again")
        XCTAssertFalse(s.snowballBallImages.contains { $0 === bundled })
        // Nothing to throw is not a change.
        s.setItemBalls([], for: .summer)
        XCTAssertTrue(s.snowballBallImages[0] === balloons[0])
    }

    /// Set while another season shows: nothing changes now, and the season throws them when it comes.
    func testItemBallsSetInAnotherSeasonWaitForTheirSeason() async {
        let s = scene()
        s.refreshSnowDay()
        s.update(0)
        XCTAssertEqual(s.shownSeason, .winter)
        throwOne(s)
        let snowball = s.snowballBallImages[0]
        let petal = PlazaThrowItems.balls(.spring, item: item())
        s.setItemBalls(petal, for: .spring)
        XCTAssertTrue(s.snowballBallImages[0] === snowball)
        s.seasonChoice = .spring
        XCTAssertTrue(s.snowballBallImages[0] === petal[0])
    }

    // MARK: - The controller

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ name: String) { lock.lock(); list.append(name); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private struct NoSprites: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
        func egg() async -> PlazaImage? { nil }
    }

    private func controller(throwItem: @escaping (String) async -> PlazaImage?) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "ptb.test.throwitems.\(UUID().uuidString)")),
                                     loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                     nickname: { "나" }, memberID: { "me" },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     throwItem: throwItem,
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    func testTheControllerLoadsBothItemsAndTheSceneThrowsThem() async throws {
        let asked = Asked(), picture = item()
        let c = controller { asked.add($0); return picture }
        c.prepareScene()
        await settle()
        XCTAssertEqual(asked.names.sorted(), ["air-balloon", "pink-petal"])
        let s = try XCTUnwrap(c.scene)
        s.seasonChoice = .summer
        s.update(0)
        XCTAssertEqual(s.shownSeason, .summer, "test precondition")
        for _ in 0..<2 { throwOne(s) }
        let want = PlazaThrowItems.balls(.summer, item: picture).map { $0.pixels.bytes }
        XCTAssertEqual(s.snowballBallImages.map { $0.pixels.bytes }, [want[0], want[1]])
        // Opened again: the pictures are there at once, and nothing is asked for a second time.
        c.handleClose()
        c.prepareScene()
        let again = try XCTUnwrap(c.scene)
        XCTAssertFalse(again === s, "test precondition: a new scene")
        again.seasonChoice = .summer
        again.update(0)
        throwOne(again)
        XCTAssertEqual(again.snowballBallImages.map { $0.pixels.bytes }, [want[0]])
        await settle()
        XCTAssertEqual(asked.names.count, 2)
        c.handleClose()
    }

    /// Offline, or the server has no such picture: the bundled picture is thrown, and the next opening asks again.
    func testWithoutTheItemTheBundledPictureIsThrownAndTheNextOpeningAsksAgain() async throws {
        let asked = Asked()
        let c = controller { asked.add($0); return nil }
        c.prepareScene()
        await settle()
        let s = try XCTUnwrap(c.scene)
        s.seasonChoice = .summer
        s.update(0)
        throwOne(s)
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 14, height: 18)], "the bundled water balloon")
        c.handleClose()
        c.prepareScene()
        await settle()
        XCTAssertEqual(asked.names.count, 4)
        c.handleClose()
    }
}
