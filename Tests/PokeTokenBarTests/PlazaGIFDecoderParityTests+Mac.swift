import XCTest
@testable import PokeTokenBar

/// The shared decoder against ImageIO (what `MacPlazaGraphics.decodeImageFrames` returns): same frame count, same size,
/// same bytes. ImageIO frames are read through `PlazaImage.pixels` (premultiplied sRGB), the form shared code sees.
final class PlazaGIFDecoderParityTests: XCTestCase {
    typealias Fx = PlazaGIFFixtures

    private struct Difference: CustomStringConvertible {
        let name: String, detail: String
        var description: String { "\(name): \(detail)" }
    }

    private func compare(_ data: Data, name: String, graphics: MacPlazaGraphics) throws -> (frames: Int, difference: Difference?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-gif-parity-\(UUID().uuidString).gif")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mac = graphics.decodeImageFrames(at: url)
        let shared = PlazaGIFDecoder.frames(from: data)
        guard mac.count == shared.count else {
            return (mac.count, Difference(name: name, detail: "frame count ImageIO \(mac.count), shared \(shared.count)"))
        }
        for (index, (m, s)) in zip(mac, shared).enumerated() {
            let pixels = m.pixels
            guard pixels.width == s.width, pixels.height == s.height else {
                return (mac.count, Difference(name: name, detail: "frame \(index) size ImageIO \(pixels.width)x\(pixels.height), shared \(s.width)x\(s.height)"))
            }
            if pixels.bytes != s.bytes {
                let at = zip(pixels.bytes, s.bytes).enumerated().first { $0.element.0 != $0.element.1 }!.offset / 4
                let (x, y) = (at % s.width, at / s.width)
                return (mac.count, Difference(name: name, detail: "frame \(index) pixel (\(x), \(y)) ImageIO \(pixels[x, y]), shared \(s[x, y])"))
            }
        }
        return (mac.count, nil)
    }

    private func syntheticFixtures() -> [(String, [UInt8])] {
        func solid(_ i: UInt8, _ w: Int, _ h: Int) -> [UInt8] { [UInt8](repeating: i, count: w * h) }
        var out: [(String, [UInt8])] = []
        for disposal in 0...3 {
            var base = Fx.Frame(width: 4, height: 4, indices: solid(0, 4, 4)); base.disposal = 1
            var middle = Fx.Frame(left: 1, top: 1, width: 2, height: 2, indices: solid(1, 2, 2)); middle.disposal = disposal
            var last = Fx.Frame(left: 3, top: 0, width: 1, height: 1, indices: [2]); last.transparent = 3
            out.append(("disposal \(disposal)", Fx.gif(width: 4, height: 4, frames: [base, middle, last])))
        }
        var first = Fx.Frame(width: 2, height: 1, indices: [0, 1]); first.disposal = 3
        out.append(("restore previous first", Fx.gif(width: 2, height: 1, frames: [first, Fx.Frame(width: 1, height: 1, indices: [2])])))
        var transparentFirst = first; transparentFirst.transparent = 3
        out.append(("restore previous first, transparent", Fx.gif(width: 2, height: 1, frames: [transparentFirst, Fx.Frame(width: 1, height: 1, indices: [2])])))
        var interlaced = Fx.Frame(width: 3, height: 10, indices: Fx.noise(count: 30, limit: 4, seed: 3)); interlaced.interlaced = true
        out.append(("interlaced", Fx.gif(width: 3, height: 10, frames: [interlaced, interlaced])))
        var local = Fx.Frame(left: 1, top: 1, width: 2, height: 2, indices: [0, 1, 1, 0]); local.palette = [[9, 8, 7], [1, 2, 3]]
        out.append(("local palette and offset", Fx.gif(width: 5, height: 5, frames: [Fx.Frame(width: 5, height: 5, indices: solid(2, 5, 5)), local])))
        var transparent = Fx.Frame(width: 3, height: 1, indices: [0, 1, 2]); transparent.transparent = 1
        out.append(("transparent first", Fx.gif(width: 3, height: 1, frames: [transparent, transparent])))
        var cleared = Fx.Frame(width: 2, height: 2, indices: solid(0, 2, 2)); cleared.disposal = 2
        out.append(("restore background", Fx.gif(width: 2, height: 2, frames: [cleared, Fx.Frame(width: 1, height: 1, indices: [1])])))
        var outside = Fx.Frame(left: 3, top: 1, width: 3, height: 3, indices: solid(2, 3, 3))
        outside.disposal = 2
        out.append(("frame past the canvas", Fx.gif(width: 4, height: 3, frames: [outside, Fx.Frame(width: 1, height: 1, indices: [1])])))
        out.append(("single frame", Fx.gif(width: 3, height: 2, frames: [Fx.Frame(width: 3, height: 2, indices: [0, 1, 2, 3, 2, 1])])))
        return out
    }

    func testSyntheticGIFsDecodeLikeImageIO() throws {
        let graphics = MacPlazaGraphics()
        var frames = 0, differences: [Difference] = []
        for (name, bytes) in syntheticFixtures() {
            let r = try compare(Data(bytes), name: name, graphics: graphics)
            frames += r.frames
            if let d = r.difference { differences.append(d) }
        }
        print("PlazaGIFDecoder vs ImageIO (synthetic): \(syntheticFixtures().count) files, \(frames) frames, \(differences.count) differ")
        for d in differences { print("  DIFF \(d)") }
        XCTAssertTrue(differences.isEmpty, differences.map(\.description).joined(separator: "\n"))
    }

    /// Every GIF in the local sprite cache (read-only). Skips when the directory is absent, so CI passes.
    func testEveryCachedSpriteDecodesLikeImageIO() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PokeTokenBar/sprites")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("no local sprite cache at \(dir.path)")
        }
        let files = names.filter { $0.hasSuffix(".gif") }.sorted()
        guard !files.isEmpty else { throw XCTSkip("no GIFs in \(dir.path)") }
        let graphics = MacPlazaGraphics()
        var frames = 0, empty = 0, differences: [Difference] = []
        for name in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let r = try compare(data, name: name, graphics: graphics)
            frames += r.frames
            if r.frames == 0 { empty += 1 }
            if let d = r.difference { differences.append(d) }
        }
        print("PlazaGIFDecoder vs ImageIO (sprite cache): \(files.count) files, \(frames) frames, \(empty) files with no frames, \(differences.count) differ")
        for d in differences.prefix(40) { print("  DIFF \(d)") }
        XCTAssertTrue(differences.isEmpty, "\(differences.count) of \(files.count) files differ; first: \(differences.first.map(\.description) ?? "")")
    }
}
