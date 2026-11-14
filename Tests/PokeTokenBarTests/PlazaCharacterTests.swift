import XCTest
@testable import PokeTokenBar

struct CharacterFakeFetcher: PlazaSpriteFetching {
    var animatedResult: [(image: PlazaImage, delay: TimeInterval)] = []
    var stillFront: PlazaImage?
    var stillBack: PlazaImage?
    var eggImage: PlazaImage?
    /// 참이면 이로치 요청은 항상 실패한다.
    var failShiny = false
    let calls = Calls()

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        calls.add("animated:\(shiny ? "shiny" : "normal"):\(back ? "back" : "front")")
        return failShiny && shiny ? [] : animatedResult
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        calls.add("still:\(shiny ? "shiny" : "normal"):\(back ? "back" : "front")")
        if failShiny && shiny { return nil }
        return back ? stillBack : stillFront
    }
    func egg() async -> PlazaImage? { calls.add("egg"); return eggImage }
}

/// A fully transparent image with opaque red pixels at the given (x, y) (counted from the top).
func characterTestImage(width: Int = 10, height: Int = 10, opaque: [(Int, Int)] = [(3, 3), (5, 5)]) -> PlazaImage {
    var bitmap = PlazaBitmap(width: width, height: height)
    for (x, y) in opaque { bitmap[x, y] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255) }
    return PlazaImage(bitmap: bitmap)
}

@MainActor
final class PlazaCharacterTests: XCTestCase {
    func testPoseMapping() async {
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .up, isWalking: false, clock: 0), .init(useBack: true, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .left, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .right, isWalking: false, clock: 0), .init(useBack: false, flipped: true, bob: 0))
    }

    func testBobAlternatesOnlyWhileWalking() async {
        let bobs = Set(stride(from: 0.0, to: 1.0, by: 0.05).map { PlazaPose.choice(facing: .down, isWalking: true, clock: $0).bob })
        XCTAssertEqual(bobs, [0, 2])
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0.13).bob, 0)
    }

    func testTrimUsesUnionBounds() async {
        let a = characterTestImage(opaque: [(2, 2)])
        let b = characterTestImage(opaque: [(6, 7)])
        let out = PlazaSpriteCrop.trimmed([a, b])
        XCTAssertEqual(out.count, 2)
        for img in out {
            XCTAssertEqual(img.width, 5)
            XCTAssertEqual(img.height, 6)
        }
    }

    func testMissingBackFallsBackToFront() async {
        var f = CharacterFakeFetcher()
        f.stillFront = characterTestImage()
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: false))
        XCTAssertFalse(frames.back.isEmpty)
        XCTAssertEqual(frames.back.count, frames.front.count)
        XCTAssertTrue(frames.back[0].image === frames.front[0].image)
        XCTAssertTrue(frames.backIsFront)
        XCTAssertFalse(frames.isPlaceholder)
        XCTAssertTrue(f.calls.all.contains("still:normal:back"))
    }

    func testAnimatedMissingUsesStill() async {
        var f = CharacterFakeFetcher()
        f.stillFront = characterTestImage()
        f.stillBack = characterTestImage()
        XCTAssertTrue(PokemonAssets.hasAnimatedSprite(speciesID: 25))
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 25, isShiny: false))
        XCTAssertEqual(frames.front.count, 1)
        XCTAssertEqual(frames.back.count, 1)
        XCTAssertTrue(f.calls.all.contains("animated:normal:front"))
        XCTAssertTrue(f.calls.all.contains("still:normal:front"))
    }

    func testAllFetchesFailUsesPlaceholder() async {
        let frames = await PlazaCharacterLoader(fetcher: CharacterFakeFetcher()).frames(for: .init(speciesID: 25, isShiny: true))
        XCTAssertFalse(frames.front.isEmpty)
        XCTAssertFalse(frames.back.isEmpty)
        XCTAssertGreaterThan(frames.front[0].image.width, 0)
        XCTAssertGreaterThan(frames.back[0].image.height, 0)
    }

    func testEggUsesEggImageBothSides() async {
        var f = CharacterFakeFetcher()
        f.eggImage = characterTestImage()
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: nil, isShiny: false))
        XCTAssertEqual(f.calls.all, ["egg"])
        XCTAssertFalse(frames.front.isEmpty)
        XCTAssertTrue(frames.back[0].image === frames.front[0].image)
        XCTAssertTrue(frames.isEgg)
        let failed = await PlazaCharacterLoader(fetcher: CharacterFakeFetcher()).frames(for: .init(speciesID: nil, isShiny: false))
        XCTAssertTrue(failed.isEgg, "an egg whose picture failed still sits on a nest")
    }

    /// The front rim is the lower part of the nest only, and never covers the hollow the egg sits in.
    func testNestFrontIsTheLowerRimOnly() async {
        XCTAssertTrue(PlazaNestArt.grid.allSatisfy { $0.count == PlazaNestArt.cols })
        let front = PlazaNestArt.frontImage(), back = PlazaNestArt.image()
        XCTAssertEqual(front.width, back.width)
        XCTAssertEqual(front.height, back.height)
        let px = { (image: PlazaImage) -> [UInt8] in image.pixels.bytes }
        let f = px(front), cell = front.width / PlazaNestArt.cols
        var frontCells = 0
        for (y, row) in PlazaNestArt.grid.enumerated() {
            for (x, ch) in row.enumerated() {
                let alpha = f[((y * cell) * front.width + x * cell) * 4 + 3]
                let expected = y >= PlazaNestArt.frontFromRow && ch != "." && ch != "H" && ch != "K"
                XCTAssertEqual(alpha == 255, expected, "cell \(x),\(y) '\(ch)'")
                if expected { frontCells += 1 }
            }
        }
        XCTAssertGreaterThan(frontCells, PlazaNestArt.cols, "a real rim, not a few dots")
    }

    func testNestHasAHollowForTheEgg() async {
        let image = PlazaNestArt.image()
        XCTAssertEqual(image.width, PlazaNestArt.size.width)
        XCTAssertNil(PlazaNestArt.color(0, 0), "corners stay clear")
        XCTAssertNotNil(PlazaNestArt.color(PlazaNestArt.cols / 2, 3))
        XCTAssertNotEqual(PlazaNestArt.color(PlazaNestArt.cols / 2, 3), PlazaNestArt.color(PlazaNestArt.cols / 2, PlazaNestArt.rows - 1))
    }

    func testShinyFailureRetriesNormalColor() async {
        var f = CharacterFakeFetcher()
        f.failShiny = true
        f.stillFront = characterTestImage(opaque: [(1, 1), (2, 2)])
        f.stillBack = characterTestImage(opaque: [(1, 1), (4, 4)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: true))
        // 자리표시 그림은 16x16이고, 일반 색 그림은 잘리면 2x2 / 4x4이다.
        XCTAssertEqual(frames.front[0].image.width, 2)
        XCTAssertEqual(frames.back[0].image.width, 4)
        XCTAssertTrue(f.calls.all.contains("still:shiny:front"))
        XCTAssertTrue(f.calls.all.contains("still:normal:front"))
    }

    func testNonAnimatedSpeciesNeverCallsAnimated() async {
        var f = CharacterFakeFetcher()
        f.animatedResult = [(characterTestImage(), 0.1)]
        f.stillFront = characterTestImage(opaque: [(1, 1), (2, 2)])
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 906))
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 906, isShiny: false))
        XCTAssertFalse(f.calls.all.contains { $0.hasPrefix("animated") })
        XCTAssertEqual(frames.front.count, 1)
        XCTAssertEqual(frames.front[0].image.width, 2)
    }

    func testAnimatedSuccessTrimsToUnionAndKeepsDelays() async {
        var f = CharacterFakeFetcher()
        f.animatedResult = [(characterTestImage(opaque: [(2, 2)]), 0.1), (characterTestImage(opaque: [(6, 7)]), 0.25), (characterTestImage(opaque: [(4, 4)]), 0.3)]
        f.stillFront = characterTestImage(opaque: [(0, 0)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 25, isShiny: false))
        XCTAssertEqual(frames.front.map(\.delay), [0.1, 0.25, 0.3])
        for fr in frames.front {
            XCTAssertEqual(fr.image.width, 5)
            XCTAssertEqual(fr.image.height, 6)
        }
        XCTAssertFalse(f.calls.all.contains { $0.hasPrefix("still:normal:front") })
    }

    func testFrontFailsBackSucceedsKeepsRealBack() async {
        var f = CharacterFakeFetcher()
        f.stillBack = characterTestImage(opaque: [(1, 1), (3, 3)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: false))
        XCTAssertEqual(frames.front[0].image.width, 16)
        XCTAssertEqual(frames.back[0].image.width, 3)
        XCTAssertTrue(frames.isPlaceholder)
        XCTAssertFalse(frames.backIsFront, "only a real front can stand in for the back")
    }
}
