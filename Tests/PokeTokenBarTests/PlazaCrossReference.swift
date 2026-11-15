import Foundation
@testable import PokeTokenBar

/// The Mac's renders as the Windows runner reads them, without ~126 PNGs in the repository: the frames are cut into 16 x 16
/// blocks, every distinct block is stored once (`atlas.bin`, RGBA premultiplied, 1024 bytes each, zero-padded at the right and
/// bottom edge) and each capture is a list of block numbers (`index.bin`, UInt32 little endian, row-major). The harness scenes
/// repeat their map tiles from capture to capture, so the lossless set is small once it is compressed (the committed form is a
/// `tar.gz` of this directory: `Tests/PlazaCrossReference/mac-reference.tar.gz`). Per capture a text file next to them: the
/// node tree (`<stem>.tree`, `PlazaCrossLine.encoded` lines) or, for a photo, its plate rectangles (`<stem>.rects`).
///
///     manifest.tsv   stem  kind  width  height  blockOffset  blockCount  sha256(rgba)
@MainActor
enum PlazaCrossReference {
    static let block = 16
    static let blockBytes = block * block * 4

    struct Entry {
        let stem: String
        let kind: PlazaCrossCapture.Kind
        let width: Int
        let height: Int
        let offset: Int
        let blocks: Int
        let sha256: String
    }

    // MARK: Writing

    /// `sha256: false` skips hashing the frames (the Windows harness, where a debug build hashes slowly): the manifest then says `-`.
    static func write(_ captures: [PlazaCrossCapture], to dir: URL, sha256: Bool = true) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var atlas: [UInt8] = []
        var ids: [[UInt8]: UInt32] = [:]
        var index: [UInt8] = []
        var manifest: [String] = []
        var blockCount = 0
        for c in captures.sorted(by: { $0.stem < $1.stem }) {
            precondition(c.rgba.count == c.width * c.height * 4, "\(c.stem): \(c.rgba.count) bytes for \(c.width)x\(c.height)")
            let columns = (c.width + block - 1) / block, rows = (c.height + block - 1) / block
            let start = blockCount
            for by in 0..<rows {
                for bx in 0..<columns {
                    var scratch = [UInt8](repeating: 0, count: blockBytes)
                    let x0 = bx * block, w = min(block, c.width - x0)
                    for y in 0..<min(block, c.height - by * block) {
                        let from = ((by * block + y) * c.width + x0) * 4
                        scratch.replaceSubrange((y * block * 4)..<(y * block * 4 + w * 4), with: c.rgba[from..<(from + w * 4)])
                    }
                    let id: UInt32
                    if let known = ids[scratch] {
                        id = known
                    } else {
                        id = UInt32(ids.count)
                        ids[scratch] = id
                        atlas.append(contentsOf: scratch)
                    }
                    withUnsafeBytes(of: id.littleEndian) { index.append(contentsOf: $0) }
                    blockCount += 1
                }
            }
            manifest.append([c.stem, c.kind.rawValue, "\(c.width)", "\(c.height)", "\(start)", "\(blockCount - start)", sha256 ? PlazaTreeDump.sha256Hex(c.rgba) : "-"].joined(separator: "\t"))
            switch c.kind {
            case .scene:
                try (c.lines.map(\.encoded).joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(c.stem).tree"), atomically: true, encoding: .utf8)
            case .photo:
                try (c.photoRects.map(\.text).joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(c.stem).rects"), atomically: true, encoding: .utf8)
            }
        }
        try Data(atlas).write(to: dir.appendingPathComponent("atlas.bin"))
        try Data(index).write(to: dir.appendingPathComponent("index.bin"))
        try (manifest.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    struct ReadError: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor final class Reader {
        let directory: URL
        let entries: [String: Entry]
        private let atlas: [UInt8]
        private let index: [UInt32]

        init(directory: URL) throws {
            self.directory = directory
            let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.tsv"), encoding: .utf8)
            var entries: [String: Entry] = [:]
            for line in manifest.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 7, let kind = PlazaCrossCapture.Kind(rawValue: f[1]), let w = Int(f[2]), let h = Int(f[3]),
                      let o = Int(f[4]), let n = Int(f[5]) else { throw ReadError(description: "bad manifest line: \(line)") }
                entries[f[0]] = Entry(stem: f[0], kind: kind, width: w, height: h, offset: o, blocks: n, sha256: f[6])
            }
            self.entries = entries
            atlas = [UInt8](try Data(contentsOf: directory.appendingPathComponent("atlas.bin")))
            let raw = [UInt8](try Data(contentsOf: directory.appendingPathComponent("index.bin")))
            var index = [UInt32](repeating: 0, count: raw.count / 4)
            for i in 0..<index.count {
                index[i] = UInt32(raw[i * 4]) | UInt32(raw[i * 4 + 1]) << 8 | UInt32(raw[i * 4 + 2]) << 16 | UInt32(raw[i * 4 + 3]) << 24
            }
            self.index = index
        }

        var stems: [String] { entries.keys.sorted() }

        func capture(_ stem: String) throws -> PlazaCrossCapture {
            guard let e = entries[stem] else { throw ReadError(description: "no reference capture \(stem)") }
            let columns = (e.width + PlazaCrossReference.block - 1) / PlazaCrossReference.block
            let rows = (e.height + PlazaCrossReference.block - 1) / PlazaCrossReference.block
            guard e.blocks == columns * rows, e.offset + e.blocks <= index.count else { throw ReadError(description: "\(stem): the block index is damaged") }
            let b = PlazaCrossReference.block
            var rgba = [UInt8](repeating: 0, count: e.width * e.height * 4)
            for by in 0..<rows {
                for bx in 0..<columns {
                    let id = Int(index[e.offset + by * columns + bx]) * PlazaCrossReference.blockBytes
                    guard id + PlazaCrossReference.blockBytes <= atlas.count else { throw ReadError(description: "\(stem): a block is missing from the atlas") }
                    let x0 = bx * b, w = min(b, e.width - x0)
                    for y in 0..<min(b, e.height - by * b) {
                        let to = ((by * b + y) * e.width + x0) * 4
                        rgba.replaceSubrange(to..<(to + w * 4), with: atlas[(id + y * b * 4)..<(id + y * b * 4 + w * 4)])
                    }
                }
            }
            var c = PlazaCrossCapture(stem: stem, kind: e.kind, width: e.width, height: e.height, rgba: rgba)
            switch e.kind {
            case .scene:
                let text = try String(contentsOf: directory.appendingPathComponent("\(stem).tree"), encoding: .utf8)
                c.lines = try text.split(separator: "\n", omittingEmptySubsequences: true).map {
                    guard let line = PlazaCrossLine(encoded: String($0)) else { throw ReadError(description: "\(stem): bad tree line") }
                    return line
                }
            case .photo:
                let text = try String(contentsOf: directory.appendingPathComponent("\(stem).rects"), encoding: .utf8)
                c.photoRects = text.split(separator: "\n").compactMap { PlazaCrossRect(text: String($0)) }
            }
            return c
        }
    }
}
