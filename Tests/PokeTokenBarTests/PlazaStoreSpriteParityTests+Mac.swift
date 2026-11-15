import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PokeTokenBar

/// The shared sprite loaders (`PlazaStoreSpriteFetcher`, `PlazaStoreIconSource`) over `MacPlazaGraphics` against the
/// Mac's own loaders (`LivePlazaSpriteFetcher`, `PlazaIconLoader`, `SpriteLoader`) on the same cache files: equal
/// `pixels` and delays per frame. GIFs and PNGs are written with `CGImageDestination` from synthetic pictures
/// (fixtures), in a temporary sprite folder; no network (every file the loaders ask for exists).
@MainActor
final class PlazaStoreSpriteParityTests: XCTestCase {
    private let graphics = MacPlazaGraphics()

    private func cgImage(seed: Int, size: Int = 12,
                         alphaOf: (Int, Int) -> UInt8 = { x, y in (x + y) % 3 == 0 ? 0 : UInt8(40 + (x * 17 + y * 5) % 200) }) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            for x in 0..<size {
                let a = alphaOf(x, y), i = y * ctx.bytesPerRow + x * 4
                buffer[i] = UInt8(Int(a) * ((x * 29 + seed * 53) % 256) / 255)
                buffer[i + 1] = UInt8(Int(a) * ((y * 31 + seed * 17) % 256) / 255)
                buffer[i + 2] = UInt8(Int(a) * ((x * y + seed * 91) % 256) / 255)
                buffer[i + 3] = a
            }
        }
        return ctx.makeImage()!
    }

    private func png(_ image: CGImage) -> Data { MacPlazaGraphics.png(image)! }

    private func gif(delays: [Double]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, delay) in delays.enumerated() {
            CGImageDestinationAddImage(dest, cgImage(seed: i + 1), [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeStore() throws -> SpriteStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sprite-parity-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SpriteStore(directory: dir)
    }

    private func put(_ data: Data, _ name: String, in store: SpriteStore) throws {
        try data.write(to: store.directory.appendingPathComponent(name))
    }

    private func assertEqual(_ shared: [(image: PlazaImage, delay: TimeInterval)], _ mac: [(image: PlazaImage, delay: TimeInterval)],
                             _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(shared.count, mac.count, "\(label): frame count", file: file, line: line)
        for (index, (s, m)) in zip(shared, mac).enumerated() {
            XCTAssertEqual(s.delay, m.delay, accuracy: 1e-9, "\(label): delay of frame \(index)", file: file, line: line)
            XCTAssertEqual(s.image.pixels, m.image.pixels, "\(label): pixels of frame \(index)", file: file, line: line)
        }
    }

    func testFrontAndBackFramesMatchTheMacLoaderWithDelays() async throws {
        let store = try makeStore()
        // 0.02 and 0.01 pin the "under 0.02 s becomes 0.1 s" rule; shiny files are absent so the plain ones answer.
        try put(gif(delays: [0.05, 0.3, 0.02, 0.01, 0.7]), "25-a.gif", in: store)
        try put(gif(delays: [0.1, 0.2, 0.4]), "25-back-a.gif", in: store)
        try put(gif(delays: [0.06, 0.08]), "25-sha.gif", in: store)
        let mac = LivePlazaSpriteFetcher(store: store)
        let shared = PlazaStoreSpriteFetcher(store: store, graphics: graphics)
        for back in [false, true] {
            for shiny in [false, true] {
                let m = await mac.animated(speciesID: 25, shiny: shiny, form: nil, back: back)
                let s = await shared.animated(speciesID: 25, shiny: shiny, form: nil, back: back)
                XCTAssertFalse(m.isEmpty)
                assertEqual(s, m, "animated back=\(back) shiny=\(shiny)")
            }
        }
    }

    func testStillsMatchTheMacLoaderFrontAndBack() async throws {
        let store = try makeStore()
        try put(png(cgImage(seed: 4)), "25-s.png", in: store)
        try put(png(cgImage(seed: 5, size: 16)), "25-back-s.png", in: store)
        let mac = LivePlazaSpriteFetcher(store: store)
        let shared = PlazaStoreSpriteFetcher(store: store, graphics: graphics)
        for back in [false, true] {
            for shiny in [false, true] {
                let m = await mac.still(speciesID: 25, shiny: shiny, form: nil, back: back)
                let s = await shared.still(speciesID: 25, shiny: shiny, form: nil, back: back)
                XCTAssertNotNil(m)
                XCTAssertEqual(s?.pixels, m?.pixels, "still back=\(back) shiny=\(shiny)")
            }
        }
    }

    func testEggCropMatchesTheMacCrop() throws {
        let egg = cgImage(seed: 9, size: 40) { x, y in (8..<20).contains(x) && (5..<24).contains(y) ? 255 : 0 }
        let data = png(egg)
        let mac = SpriteLoader.animationPlaceholder(NSImage(data: data)!).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let shared = PlazaEggCrop.square(try XCTUnwrap(graphics.decodeImage(data)))
        XCTAssertEqual(shared.pixels, PlazaImage(cgImage: mac).pixels)
        XCTAssertEqual(shared.width, 19)

        // The alpha threshold: a byte of 2 is below it (nothing opaque, unchanged), 3 is above it.
        for (alpha, side) in [(UInt8(2), 40), (UInt8(3), 1)] {
            let faint = png(cgImage(seed: 1, size: 40) { x, y in x == 20 && y == 11 ? alpha : 0 })
            let macFaint = SpriteLoader.animationPlaceholder(NSImage(data: faint)!).cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let sharedFaint = PlazaEggCrop.square(try XCTUnwrap(graphics.decodeImage(faint)))
            XCTAssertEqual(sharedFaint.width, side)
            XCTAssertEqual(sharedFaint.pixels, PlazaImage(cgImage: macFaint).pixels, "alpha \(alpha)")
        }
    }

    func testIconMatchesTheMacIconLoader() async throws {
        let store = try makeStore()
        let data = png(cgImage(seed: 7, size: 24))
        try put(data, PlazaIconStore.fileName(speciesID: 99_001), in: store)
        // `PlazaIconLoader.icon` is the Mac's path (its memory is keyed by species: an id no other test uses).
        let mac = await PlazaIconLoader.icon(speciesID: 99_001, load: { _ in data })
        let source = PlazaStoreIconSource(store: store, graphics: graphics, fetch: { _ in XCTFail("no download expected"); return nil })
        let shared = await source.icon(speciesID: 99_001)
        let macImage = try XCTUnwrap(mac?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(shared?.pixels, PlazaImage(cgImage: macImage).pixels)
        XCTAssertEqual(PlazaIconStore.url(speciesID: 25), PlazaIconLoader.url(speciesID: 25))
    }

    func testCardSpriteMatchesSpriteLoader() async throws {
        let store = try makeStore()
        try put(png(cgImage(seed: 3, size: 20)), "25-s.png", in: store)
        let mac = await SpriteLoader.image(speciesID: 25, store: store)
        let macImage = try XCTUnwrap(mac?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let shared = await PlazaStoreIconSource(store: store, graphics: graphics).sprite(speciesID: 25, shiny: false, form: nil)
        XCTAssertEqual(shared?.pixels, PlazaImage(cgImage: macImage).pixels)
    }

    /// Every cached sprite on this Mac (read only), the way the render harness reads them: GIF frames and delays through
    /// `GIFDecoder` and the shared decoder, PNGs through ImageIO and `MacPlazaGraphics`.
    func testEveryCachedSpriteDecodesTheSame() throws {
        let dir = try XCTUnwrap(PlazaRenderScenes.spritesDir, "PTB_PLAZA_RENDER_SPRITES not set")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var gifs = 0, pngs = 0
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            switch file.pathExtension {
            case "gif":
                let macFrames: [(image: PlazaImage, delay: TimeInterval)] = GIFDecoder.frames(from: data).compactMap { f in
                    f.image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { (image: PlazaImage(cgImage: $0), delay: f.delay) }
                }
                assertEqual(PlazaStoreGIF.frames(from: data), macFrames, file.lastPathComponent)
                gifs += 1
            case "png":
                guard let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                XCTAssertEqual(graphics.decodeImage(data)?.pixels, PlazaImage(cgImage: cg).pixels, file.lastPathComponent)
                pngs += 1
            default: continue
            }
        }
        print("PLAZA-SPRITE-PARITY: \(gifs) GIFs, \(pngs) PNGs compared")
    }
}
