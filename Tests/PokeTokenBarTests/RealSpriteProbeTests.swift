import Foundation
import XCTest
@testable import PokeTokenBar

/// DIAGNOSTIC (diag/real-sprite-probe, not for merge): the real sprite path with the REAL network and a clean folder, as the
/// app takes it on a fresh install: `SpriteStore` (the app's URLs; WinHTTP on Windows) → the file on disk → the shared GIF
/// decoder → frames, delays, the frame cap at each animation quality; then `PlazaStoreSpriteFetcher` (what the pet and the
/// popover use) over the same folder. Runs only with PTB_REAL_SPRITE_PROBE=1; prints one line per step.
final class RealSpriteProbeTests: XCTestCase {
    func testTheRealSpritePathForDittoBulbasaurAndPikachu() async throws {
        guard ProcessInfo.processInfo.environment["PTB_REAL_SPRITE_PROBE"] == "1" else { throw XCTSkip("set PTB_REAL_SPRITE_PROBE=1") }
        for id in [132, 1, 25] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-real-sprites-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SpriteStore(directory: dir)
            let url = SpriteStore.spriteURL(speciesID: id, animated: true, shiny: false)
            print("PROBE #\(id) hasAnimatedSprite=\(PokemonAssets.hasAnimatedSprite(speciesID: id)) url=\(url.absoluteString)")
            // The raw request, to see the status and headers the store's own call does not report.
            do {
                let (body, response) = try await PlatformCompat.oneShotData(from: url)
                let http = response as? HTTPURLResponse
                print("PROBE #\(id) raw: status=\(http?.statusCode ?? -1) bytes=\(body.count) type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "-") "
                      + "encoding=\(http?.value(forHTTPHeaderField: "Content-Encoding") ?? "-") final url=\(response.url?.absoluteString ?? "-") "
                      + "head=\(body.prefix(6).map { String(format: "%02X", $0) }.joined())")
            } catch {
                print("PROBE #\(id) raw: THREW \(error)")
            }
            let started = Date()
            let gif = await store.data(speciesID: id, animated: true, shiny: false)
            let key = SpriteStore.cacheKey(speciesID: id, animated: true, shiny: false)
            let file = dir.appendingPathComponent("\(key).gif")
            print("PROBE #\(id) store.data(animated): \(gif.map { "\($0.count) bytes" } ?? "nil") in \(Int(Date().timeIntervalSince(started) * 1000)) ms; "
                  + "file \(file.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: file.path))")
            if let gif {
                let bitmaps = PlazaGIFDecoder.frames(from: gif)
                let delays = PlazaStoreGIF.delays(in: gif)
                let frames = PlazaStoreGIF.frames(from: gif)
                let loop = frames.reduce(0) { $0 + $1.delay }
                print("PROBE #\(id) decode: bitmaps=\(bitmaps.count) delays=\(delays.count) frames=\(frames.count) loop=\(String(format: "%.2f", loop)) s "
                      + "delays=\(delays.prefix(40).map { String(format: "%.2f", $0) }) size=\(bitmaps.first.map { "\($0.width)x\($0.height)" } ?? "-")")
                for floor in [0.0, 0.1, 0.2, 0.4] {
                    let capped = PopoverSpriteFrameCap.capFrameRate(frames, floor: floor)
                    print("PROBE #\(id) cap floor \(floor): \(capped.count) frames \(capped.prefix(12).map { String(format: "%.2f", $0.delay) })")
                }
            }
            let png = await store.data(speciesID: id, animated: false, shiny: false)
            print("PROBE #\(id) store.data(still): \(png.map { "\($0.count) bytes" } ?? "nil")")
            let fetched = await PlazaStoreSpriteFetcher(source: store).animated(speciesID: id, shiny: false, form: nil, back: false)
            print("PROBE #\(id) PlazaStoreSpriteFetcher.animated: \(fetched.count) frames")
        }
    }
}
