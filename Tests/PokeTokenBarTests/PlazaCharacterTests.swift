import XCTest
import AppKit
@testable import PokeTokenBar

private struct FakeFetcher: PlazaSpriteFetching {
    var animatedResult: [(image: NSImage, delay: TimeInterval)] = []
    var stillFront: NSImage?
    var stillBack: NSImage?
    var eggImage: NSImage?
    /// 참이면 이로치 요청은 항상 실패한다.
    var failShiny = false
    let calls = Calls()

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        calls.add("animated:\(shiny ? "shiny" : "normal"):\(back ? "back" : "front")")
        return failShiny && shiny ? [] : animatedResult
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? {
        calls.add("still:\(shiny ? "shiny" : "normal"):\(back ? "back" : "front")")
        if failShiny && shiny { return nil }
        return back ? stillBack : stillFront
    }
    func egg() async -> NSImage? { calls.add("egg"); return eggImage }
}

private func makeCG(width: Int = 10, height: Int = 10, opaque: [(Int, Int)]) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    // (x, y)는 위에서부터 센 좌표
    for (x, y) in opaque { ctx.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1)) }
    return ctx.makeImage()!
}

private func makeNS(_ opaque: [(Int, Int)] = [(3, 3), (5, 5)]) -> NSImage {
    let cg = makeCG(opaque: opaque)
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

@MainActor
final class PlazaCharacterTests: XCTestCase {
    func testPoseMapping() {
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .up, isWalking: false, clock: 0), .init(useBack: true, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .left, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .right, isWalking: false, clock: 0), .init(useBack: false, flipped: true, bob: 0))
    }

    func testBobAlternatesOnlyWhileWalking() {
        let bobs = Set(stride(from: 0.0, to: 1.0, by: 0.05).map { PlazaPose.choice(facing: .down, isWalking: true, clock: $0).bob })
        XCTAssertEqual(bobs, [0, 2])
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0.13).bob, 0)
    }

    func testTrimUsesUnionBounds() {
        let a = makeCG(opaque: [(2, 2)])
        let b = makeCG(opaque: [(6, 7)])
        let out = PlazaSpriteCrop.trimmed([a, b])
        XCTAssertEqual(out.count, 2)
        for img in out {
            XCTAssertEqual(img.width, 5)
            XCTAssertEqual(img.height, 6)
        }
    }

    func testMissingBackFallsBackToFront() async {
        var f = FakeFetcher()
        f.stillFront = makeNS()
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: false))
        XCTAssertFalse(frames.back.isEmpty)
        XCTAssertEqual(frames.back.count, frames.front.count)
        XCTAssertTrue(frames.back[0].image === frames.front[0].image)
        XCTAssertTrue(frames.backIsFront)
        XCTAssertFalse(frames.isPlaceholder)
        XCTAssertTrue(f.calls.all.contains("still:normal:back"))
    }

    func testAnimatedMissingUsesStill() async {
        var f = FakeFetcher()
        f.stillFront = makeNS()
        f.stillBack = makeNS()
        XCTAssertTrue(PokemonAssets.hasAnimatedSprite(speciesID: 25))
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 25, isShiny: false))
        XCTAssertEqual(frames.front.count, 1)
        XCTAssertEqual(frames.back.count, 1)
        XCTAssertTrue(f.calls.all.contains("animated:normal:front"))
        XCTAssertTrue(f.calls.all.contains("still:normal:front"))
    }

    func testAllFetchesFailUsesPlaceholder() async {
        let frames = await PlazaCharacterLoader(fetcher: FakeFetcher()).frames(for: .init(speciesID: 25, isShiny: true))
        XCTAssertFalse(frames.front.isEmpty)
        XCTAssertFalse(frames.back.isEmpty)
        XCTAssertGreaterThan(frames.front[0].image.width, 0)
        XCTAssertGreaterThan(frames.back[0].image.height, 0)
    }

    func testEggUsesEggImageBothSides() async {
        var f = FakeFetcher()
        f.eggImage = makeNS()
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: nil, isShiny: false))
        XCTAssertEqual(f.calls.all, ["egg"])
        XCTAssertFalse(frames.front.isEmpty)
        XCTAssertTrue(frames.back[0].image === frames.front[0].image)
    }

    func testShinyFailureRetriesNormalColor() async {
        var f = FakeFetcher()
        f.failShiny = true
        f.stillFront = makeNS([(1, 1), (2, 2)])
        f.stillBack = makeNS([(1, 1), (4, 4)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: true))
        // 자리표시 그림은 16x16이고, 일반 색 그림은 잘리면 2x2 / 4x4이다.
        XCTAssertEqual(frames.front[0].image.width, 2)
        XCTAssertEqual(frames.back[0].image.width, 4)
        XCTAssertTrue(f.calls.all.contains("still:shiny:front"))
        XCTAssertTrue(f.calls.all.contains("still:normal:front"))
    }

    func testNonAnimatedSpeciesNeverCallsAnimated() async {
        var f = FakeFetcher()
        f.animatedResult = [(makeNS(), 0.1)]
        f.stillFront = makeNS([(1, 1), (2, 2)])
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 906))
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 906, isShiny: false))
        XCTAssertFalse(f.calls.all.contains { $0.hasPrefix("animated") })
        XCTAssertEqual(frames.front.count, 1)
        XCTAssertEqual(frames.front[0].image.width, 2)
    }

    func testAnimatedSuccessTrimsToUnionAndKeepsDelays() async {
        var f = FakeFetcher()
        f.animatedResult = [(makeNS([(2, 2)]), 0.1), (makeNS([(6, 7)]), 0.25), (makeNS([(4, 4)]), 0.3)]
        f.stillFront = makeNS([(0, 0)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 25, isShiny: false))
        XCTAssertEqual(frames.front.map(\.delay), [0.1, 0.25, 0.3])
        for fr in frames.front {
            XCTAssertEqual(fr.image.width, 5)
            XCTAssertEqual(fr.image.height, 6)
        }
        XCTAssertFalse(f.calls.all.contains { $0.hasPrefix("still:normal:front") })
    }

    func testFrontFailsBackSucceedsKeepsRealBack() async {
        var f = FakeFetcher()
        f.stillBack = makeNS([(1, 1), (3, 3)])
        let frames = await PlazaCharacterLoader(fetcher: f).frames(for: .init(speciesID: 400, isShiny: false))
        XCTAssertEqual(frames.front[0].image.width, 16)
        XCTAssertEqual(frames.back[0].image.width, 3)
        XCTAssertTrue(frames.isPlaceholder)
        XCTAssertFalse(frames.backIsFront, "only a real front can stand in for the back")
    }
}
