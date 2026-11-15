import XCTest
@testable import PokeTokenBar

/// Pictures as fixture bytes: `[width, height]` then RGBA, decoded by `FixtureGraphics` (no codec, no network).
private enum Fixture {
    static func bytes(_ w: Int, _ h: Int, _ rgba: [UInt8]? = nil, opaque: [(Int, Int)] = []) -> Data {
        var px = rgba ?? [UInt8](repeating: 0, count: w * h * 4)
        for (x, y) in opaque { let i = (y * w + x) * 4; px[i] = 255; px[i + 3] = 255 }
        return Data([UInt8(w), UInt8(h)] + px)
    }
}

private struct FixtureGraphics: PlazaGraphics {
    private let base = PlazaStubGraphics(log: { _ in })
    var text: any PlazaTextEngine { base.text }
    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? { nil }
    func assetURL(_ name: String, ext: String) -> URL? { nil }
    func decodeImage(at url: URL) -> PlazaImage? { (try? Data(contentsOf: url)).flatMap(decodeImage) }
    func decodeImage(_ data: Data) -> PlazaImage? {
        let b = [UInt8](data)
        guard b.count >= 2, b.count == 2 + Int(b[0]) * Int(b[1]) * 4 else { return nil }
        var bitmap = PlazaBitmap(width: Int(b[0]), height: Int(b[1]))
        bitmap.bytes = Array(b[2...])
        return PlazaImage(bitmap: bitmap)
    }
    func decodeImageFrames(at url: URL) -> [PlazaImage] { [] }
    func encodePNG(_ image: PlazaImage) -> Data? { nil }
}

/// A sprite source answering from a table of `key -> bytes`, recording every ask. A missing key is a failure.
private final class FakeSource: PlazaSpriteSource, @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var table: [String: Data]
    private var asks: [String] = []
    init(directory: URL = URL(fileURLWithPath: "/fake"), table: [String: Data] = [:]) { self.directory = directory; self.table = table }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return asks }

    func data(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm?, back: Bool) async -> Data? {
        let key = SpriteStore.cacheKey(speciesID: speciesID, animated: animated, shiny: shiny, form: form, back: back)
        return record(key)
    }
    func eggData() async -> Data? {
        return record("egg")
    }

    private func record(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        asks.append(key)
        return table[key]
    }
}

/// Two GIF frames named by the first byte of the "GIF" data: the test decoder reads `[count, delay-in-hundredths...]`.
private let decoder: PlazaGIFFrameDecoder = { data in
    let b = [UInt8](data)
    guard b.count >= 1 else { return [] }
    return (0..<Int(b[0])).map { i in
        (PlazaImage(bitmap: PlazaBitmap(width: 2 + i, height: 2)), Double(b[1 + i]) / 100)
    }
}

@MainActor
final class PlazaStoreSpriteFetcherTests: XCTestCase {
    private func fetcher(_ source: FakeSource) -> PlazaStoreSpriteFetcher {
        PlazaStoreSpriteFetcher(source: source, graphics: FixtureGraphics(), decodeGIF: decoder)
    }

    func testFrontFramesKeepTheirDelays() async {
        let source = FakeSource(table: ["25-a": Data([3, 5, 10, 25])])
        let frames = await fetcher(source).animated(speciesID: 25, shiny: false, form: nil, back: false)
        XCTAssertEqual(frames.map(\.delay), [0.05, 0.10, 0.25])
        XCTAssertEqual(frames.map { $0.image.width }, [2, 3, 4])
    }

    func testShinyFrontFallsBackToPlainButOnlyWhenShinyIsMissing() async {
        let source = FakeSource(table: ["25-a": Data([1, 10])])
        let plain = await fetcher(source).animated(speciesID: 25, shiny: true, form: nil, back: false)
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(source.calls, ["25-sha", "25-a"])

        let both = FakeSource(table: ["25-sha": Data([2, 10, 10]), "25-a": Data([1, 10])])
        let shiny = await fetcher(both).animated(speciesID: 25, shiny: true, form: nil, back: false)
        XCTAssertEqual(shiny.count, 2)
        XCTAssertEqual(both.calls, ["25-sha"])
    }

    func testBackFramesTryShinyBackThenPlainBackAndNeverTheFront() async {
        let source = FakeSource(table: ["25-back-a": Data([2, 10, 10]), "25-a": Data([4, 10, 10, 10, 10])])
        let frames = await fetcher(source).animated(speciesID: 25, shiny: true, form: nil, back: true)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(source.calls, ["25-back-sha", "25-back-a"])
    }

    func testMissingOrFailedBackGivesNothingSoTheLoaderStandsTheFrontIn() async {
        let source = FakeSource(table: ["25-a": Data([2, 10, 10]), "25-s": Data([2, 2, 0, 0])])
        let fetcher = fetcher(source)
        let animated = await fetcher.animated(speciesID: 25, shiny: false, form: nil, back: true)
        let still = await fetcher.still(speciesID: 25, shiny: false, form: nil, back: true)
        XCTAssertTrue(animated.isEmpty)
        XCTAssertNil(still)
        XCTAssertEqual(source.calls, ["25-back-a", "25-back-s"], "a back ask never reads the front files")
    }

    func testAnUndecodableGIFFallsThroughToThePlainOne() async {
        let source = FakeSource(table: ["25-sha": Data(), "25-a": Data([1, 10])])
        let frames = await fetcher(source).animated(speciesID: 25, shiny: true, form: nil, back: false)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(source.calls, ["25-sha", "25-a"])
    }

    func testStillWalksShinyThenPlainAndSkipsBytesThatDoNotDecode() async {
        let png = Fixture.bytes(2, 2, opaque: [(1, 1)])
        let source = FakeSource(table: ["25-shs": Data([9]), "25-s": png])
        let image = await fetcher(source).still(speciesID: 25, shiny: true, form: nil, back: false)
        XCTAssertEqual(image?.pixels[1, 1].a, 255)
        XCTAssertEqual(source.calls, ["25-shs", "25-s"])
    }

    func testEggIsCroppedToASquareAndDecodedOnce() async {
        let egg = Fixture.bytes(20, 20, opaque: (5..<9).flatMap { y in (8..<12).map { ($0, y) } })
        let source = FakeSource(table: ["egg": egg])
        let fetcher = fetcher(source)
        XCTAssertNil(fetcher.cachedEgg)
        let first = await fetcher.egg()
        XCTAssertEqual(first?.width, 4)
        XCTAssertEqual(first?.height, 4)
        XCTAssertTrue(fetcher.cachedEgg === first)
        let second = await fetcher.egg()
        XCTAssertTrue(second === first)
        XCTAssertEqual(source.calls, ["egg"])
    }

    func testDecodedFramesAreKeptAndBoundedAtSixteenSets() async {
        var table: [String: Data] = [:]
        for id in 1...17 { table["\(id)-a"] = Data([2, 10, 10]) }
        let source = FakeSource(table: table)
        let fetcher = fetcher(source)
        for id in 1...17 { _ = await fetcher.animated(speciesID: id, shiny: false, form: nil, back: false) }
        XCTAssertEqual(source.calls.count, 17)
        _ = await fetcher.animated(speciesID: 17, shiny: false, form: nil, back: false)
        XCTAssertEqual(source.calls.count, 17, "the newest set is served from memory")
        _ = await fetcher.animated(speciesID: 1, shiny: false, form: nil, back: false)
        XCTAssertEqual(source.calls.count, 18, "the oldest set was dropped at 16")
    }

    func testARealSpriteStoreServesCacheFilesWithoutTheNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sprites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpriteStore(directory: dir)
        // Pikachu: front still, plus an egg; both files exist, so the store never downloads.
        try Fixture.bytes(2, 2, opaque: [(0, 0)]).write(to: dir.appendingPathComponent("25-s.png"))
        try Fixture.bytes(6, 6, opaque: [(2, 2), (3, 3)]).write(to: dir.appendingPathComponent("egg.png"))
        let fetcher = PlazaStoreSpriteFetcher(source: store, graphics: FixtureGraphics(), decodeGIF: decoder)
        let still = await fetcher.still(speciesID: 25, shiny: false, form: nil, back: false)
        XCTAssertEqual(still?.pixels[0, 0].a, 255)
        let egg = await fetcher.egg()
        XCTAssertEqual(egg?.width, 2)
    }

    func testGIFDelaysFollowTheMacRule() async {
        typealias Fx = PlazaGIFFixtures
        func frame(_ delay: Int) -> Fx.Frame { var f = Fx.Frame(width: 1, height: 1, indices: [0]); f.delay = delay; return f }
        let data = Data(Fx.gif(width: 1, height: 1, frames: [frame(0), frame(1), frame(5), frame(10), frame(25)]))
        XCTAssertEqual(PlazaStoreGIF.delays(in: data), [0.1, 0.1, 0.05, 0.1, 0.25])
        XCTAssertEqual(PlazaStoreGIF.delays(in: Data([1, 2, 3])), [])
    }

    func testOneFrameGIFIsNoAnimation() async {
        typealias Fx = PlazaGIFFixtures
        let data = Data(Fx.gif(width: 1, height: 1, frames: [Fx.Frame(width: 1, height: 1, indices: [0])]))
        XCTAssertTrue(PlazaStoreGIF.frames(from: data).isEmpty)
    }

    func testDefaultDecoderPairsEachFrameWithItsDelay() async {
        typealias Fx = PlazaGIFFixtures
        var a = Fx.Frame(width: 1, height: 1, indices: [0]); a.delay = 5
        var b = Fx.Frame(width: 1, height: 1, indices: [1]); b.delay = 30
        let frames = PlazaStoreGIF.frames(from: Data(Fx.gif(width: 1, height: 1, frames: [a, b])))
        XCTAssertEqual(frames.map(\.delay), [0.05, 0.3])
        XCTAssertEqual(frames.map { $0.image.pixels[0, 0].r }, [255, 0])
    }
}

// MARK: - Icons

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var urls: [URL] = []
    func hit(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; n += 1; urls.append(url); return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var seen: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

@MainActor
final class PlazaStoreIconSourceTests: XCTestCase {
    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-icons-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testCacheFileIsUsedWithoutDownloading() async throws {
        let dir = makeDir()
        try Fixture.bytes(2, 2, opaque: [(1, 0)]).write(to: dir.appendingPathComponent("icon-25.png"))
        let counter = Counter()
        let source = PlazaStoreIconSource(source: FakeSource(directory: dir), graphics: FixtureGraphics(),
                                          fetch: { url in _ = counter.hit(url); return nil })
        XCTAssertNil(source.cachedIcon(speciesID: 25))
        let icon = await source.icon(speciesID: 25)
        XCTAssertEqual(icon?.pixels[1, 0].a, 255)
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(source.cachedIcon(speciesID: 25) === icon)
    }

    func testDownloadIsSavedAsIconFileInTheSpriteFolderOnlyWhenItDecodes() async throws {
        let dir = makeDir()
        let good = Fixture.bytes(2, 2, opaque: [(0, 0)])
        let counter = Counter()
        let source = PlazaStoreIconSource(source: FakeSource(directory: dir), graphics: FixtureGraphics(),
                                          fetch: { url in _ = counter.hit(url); return url.lastPathComponent == "7.png" ? Data([1, 2, 3]) : good })
        let bad = await source.icon(speciesID: 7)
        XCTAssertNil(bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("icon-7.png").path))
        let icon = await source.icon(speciesID: 25)
        XCTAssertNotNil(icon)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("icon-25.png")), good)
        XCTAssertEqual(counter.seen.map(\.absoluteString), [PlazaIconStore.url(speciesID: 7).absoluteString,
                                                              PlazaIconStore.url(speciesID: 25).absoluteString])
        XCTAssertEqual(dir.appendingPathComponent("icon-25.png").lastPathComponent, PlazaIconStore.fileName(speciesID: 25))
    }

    func testUndecodableCacheFileIsReplacedByTheDownload() async throws {
        let dir = makeDir()
        try Data([9, 9]).write(to: dir.appendingPathComponent("icon-25.png"))
        let good = Fixture.bytes(2, 2, opaque: [(0, 1)])
        let source = PlazaStoreIconSource(source: FakeSource(directory: dir), graphics: FixtureGraphics(), fetch: { _ in good })
        let icon = await source.icon(speciesID: 25)
        XCTAssertEqual(icon?.pixels[0, 1].a, 255)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("icon-25.png")), good)
    }

    func testPictureCacheRetriesAFailedIconOnceAndThenGivesUp() async {
        let counter = Counter()
        let source = PlazaStoreIconSource(source: FakeSource(directory: makeDir()), graphics: FixtureGraphics(),
                                          fetch: { _ in _ = counter.hit(URL(string: "x:")!); return nil })
        let cache = PlazaPictureCache(source: source)
        cache.retryDelay = .milliseconds(10)
        XCTAssertNil(cache.icon(25))
        for _ in 0..<100 where counter.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(cache.icon(25))
        XCTAssertEqual(counter.count, 2, "one try, one retry, then settled as failed")
    }

    func testPictureCacheRetrySucceedsWhenTheSecondTryDoes() async {
        let counter = Counter()
        let good = Fixture.bytes(2, 2, opaque: [(0, 0)])
        let source = PlazaStoreIconSource(source: FakeSource(directory: makeDir()), graphics: FixtureGraphics(),
                                          fetch: { _ in counter.hit(URL(string: "x:")!) == 1 ? nil : good })
        let cache = PlazaPictureCache(source: source)
        cache.retryDelay = .milliseconds(10)
        var arrived = 0
        cache.onArrival = { arrived += 1 }
        XCTAssertNil(cache.icon(25))
        for _ in 0..<100 where arrived == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(arrived, 1)
        XCTAssertNotNil(cache.icon(25))
    }

    func testEggComesFromTheEggFileCroppedAndTheNilSpeciesPictureIsTheEgg() async {
        let egg = Fixture.bytes(10, 10, opaque: [(4, 4), (5, 6)])
        let source = PlazaStoreIconSource(source: FakeSource(table: ["egg": egg]), graphics: FixtureGraphics())
        XCTAssertNil(source.cachedIcon(speciesID: nil))
        let icon = await source.icon(speciesID: nil)
        XCTAssertEqual(icon?.width, 3)
        XCTAssertTrue(source.cachedIcon(speciesID: nil) === icon)
        let sprite = await source.sprite(speciesID: nil, shiny: false, form: nil)
        XCTAssertTrue(sprite === icon)
    }

    func testCardSpriteIsTheFrontStillWithShinyThenPlain() async {
        let png = Fixture.bytes(2, 2, opaque: [(1, 1)])
        let fake = FakeSource(table: ["25-s": png])
        let source = PlazaStoreIconSource(source: fake, graphics: FixtureGraphics())
        let sprite = await source.sprite(speciesID: 25, shiny: true, form: nil)
        XCTAssertEqual(sprite?.pixels[1, 1].a, 255)
        XCTAssertEqual(fake.calls, ["25-shs", "25-s"])
    }
}
