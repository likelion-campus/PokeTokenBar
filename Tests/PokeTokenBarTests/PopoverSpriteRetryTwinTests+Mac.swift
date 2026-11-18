import AppKit
import XCTest
@testable import PokeTokenBar

/// fix/windows-pet-still: the shared sprite model asks for a missing GIF again on the Mac's own schedule. The Mac's
/// `SpriteLoader.recoveringAnimationFrames` runs here over a sprite folder holding a one-frame GIF (no animation, no network:
/// the file answers), its waits recorded; the shared `PopoverSpriteModel` runs over a fetcher whose GIF never comes. Both
/// show the still once, wait 2, 4, 8, 16, 30, 30… seconds, and leave a species without a GIF at its still.
@MainActor
final class PopoverSpriteRetryTwinTests: XCTestCase {
    /// A GIF of one 1×1 frame: decodes, but is no animation.
    private static let oneFrameGIF = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
                                          0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
                                          0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B])

    private struct NoGIF: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
            PlazaImage(bitmap: PlazaBitmap(width: 2, height: 2))
        }
        func egg() async -> PlazaImage? { nil }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [TimeInterval] = []
        let limit: Int
        init(limit: Int) { self.limit = limit }
        var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return seen }
        private func record(_ d: TimeInterval) -> Int { lock.withLock { seen.append(d); return seen.count } }
        var wait: @Sendable (TimeInterval) async throws -> Void {
            { [self] d in
                if record(d) >= limit { throw CancellationError() }
            }
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        TimeInterval(d.components.seconds) + TimeInterval(d.components.attoseconds) / 1e18
    }

    private func folder(withOneFrameGIFFor species: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sprite-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = SpriteStore.cacheKey(speciesID: species, animated: true, shiny: false)
        try Self.oneFrameGIF.write(to: dir.appendingPathComponent("\(key).gif"))
        return dir
    }

    func testTheWaitsAreTheMacsRecoveringLoop() async throws {
        let rounds = 8
        let dir = try folder(withOneFrameGIFFor: 25)
        defer { try? FileManager.default.removeItem(at: dir) }
        var macWaits: [TimeInterval] = []
        var macStills = 0
        let macFrames = await SpriteLoader.recoveringAnimationFrames(
            speciesID: 25, shiny: false, store: SpriteStore(directory: dir),
            waitBeforeRetry: { d in
                macWaits.append(Self.seconds(d))
                if macWaits.count >= rounds { throw CancellationError() }
            },
            onUnavailable: { macStills += 1 })
        XCTAssertTrue(macFrames.isEmpty)

        let recorder = Recorder(limit: rounds)
        let model = PopoverSpriteModel(fetcher: NoGIF(), memory: PopoverSpriteMemory())
        model.waitBeforeRetry = recorder.wait
        model.show(PlazaSpriteSubjectKey(speciesID: 25), animated: true, bob: false)
        for _ in 0..<2_000 where recorder.delays.count < rounds { await Task.yield() }
        defer { model.release() }
        XCTAssertEqual(recorder.delays, macWaits, "the shared model waits as the Mac's loop does")
        XCTAssertEqual(macWaits, [2, 4, 8, 16, 30, 30, 30, 30])
        XCTAssertEqual(macStills, 1, "the Mac shows the still once")
        XCTAssertNotNil(model.subject.image, "the shared model shows the still meanwhile")
        XCTAssertEqual(model.gifAsks, rounds)
    }

    func testASpeciesWithoutAGIFStopsAtItsStillOnBoth() async throws {
        var macWaits = 0, macStills = 0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sprite-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = await SpriteLoader.recoveringAnimationFrames(
            speciesID: 700, shiny: false, store: SpriteStore(directory: dir),
            waitBeforeRetry: { _ in macWaits += 1 }, onUnavailable: { macStills += 1 })
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(macWaits, 0)
        XCTAssertEqual(macStills, 1)

        let recorder = Recorder(limit: 1)
        let model = PopoverSpriteModel(fetcher: NoGIF(), memory: PopoverSpriteMemory())
        model.waitBeforeRetry = recorder.wait
        model.show(PlazaSpriteSubjectKey(speciesID: 700), animated: true, bob: false)
        for _ in 0..<500 where model.subject.image == nil || model.isLoading { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        defer { model.release() }
        XCTAssertNotNil(model.subject.image)
        XCTAssertEqual(recorder.delays, [])
        XCTAssertEqual(model.gifAsks, 1)
        XCTAssertFalse(PokemonAssets.hasAnimatedSprite(speciesID: 700))
    }
}
