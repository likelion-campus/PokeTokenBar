import Foundation

/// A pure-Swift animated-GIF decoder (GIF87a / GIF89a) for systems without ImageIO. Every frame comes back composited
/// at the full logical-screen size (disposal methods and transparency applied) as a premultiplied sRGB `PlazaBitmap`,
/// the shape the Mac's `decodeImageFrames` hands shared code. Frame delays are not part of that interface and are not
/// returned.
///
/// The bytes come from the network, so every count is bounded: see `Limits`. Anything malformed ends the decode;
/// frames completed before the fault are kept, and a file with no complete frame gives `[]`.
enum PlazaGIFDecoder {
    enum Limits {
        /// Logical screen width and height.
        static let maxDimension = 4096
        static let maxFrames = 1000
        /// Total output bytes over all frames (canvas bytes x frames).
        static let maxOutputBytes = 256 << 20
        /// Total sub-image pixels decoded over all frames.
        static let maxDecodedPixels = 64 << 20
    }

    /// Every frame in order, `[]` when `data` is not a decodable GIF.
    ///
    /// Where no frame paints (outside the first frame, or after "restore to background") the canvas is transparent. ImageIO
    /// does that only for a GIF that declares a transparent colour somewhere; a GIF that never does gets opaque black
    /// there. The decoder follows ImageIO, so it decodes such a file a second time with a black blank.
    static func frames(from data: Data) -> [PlazaBitmap] {
        let bytes = [UInt8](data)
        var decoder = Decoder(bytes: bytes, blank: PlazaRGBA(r: 0, g: 0, b: 0, a: 0))
        let frames = decoder.run()
        guard !decoder.sawTransparency, !frames.isEmpty else { return frames }
        var opaque = Decoder(bytes: bytes, blank: PlazaRGBA(r: 0, g: 0, b: 0, a: 255))
        return opaque.run()
    }

    private struct Decoder {
        let bytes: [UInt8]
        var pos = 0
        var frames: [PlazaBitmap] = []
        let blank: PlazaRGBA
        /// Whether any graphic control extension carried a transparent colour index.
        var sawTransparency = false

        init(bytes: [UInt8], blank: PlazaRGBA) {
            self.bytes = bytes
            self.blank = blank
        }

        mutating func u8() -> Int? {
            guard pos < bytes.count else { return nil }
            defer { pos += 1 }
            return Int(bytes[pos])
        }

        mutating func u16() -> Int? {
            guard pos + 2 <= bytes.count else { return nil }
            defer { pos += 2 }
            return Int(bytes[pos]) | Int(bytes[pos + 1]) << 8
        }

        /// `count` entries of RGB.
        mutating func colorTable(_ count: Int) -> [UInt8]? {
            guard pos + count * 3 <= bytes.count else { return nil }
            defer { pos += count * 3 }
            return Array(bytes[pos..<pos + count * 3])
        }

        /// Skips data sub-blocks up to and including the zero terminator. False when the file ends first.
        mutating func skipSubBlocks() -> Bool {
            while let size = u8() {
                if size == 0 { return true }
                guard pos + size <= bytes.count else { return false }
                pos += size
            }
            return false
        }

        /// The concatenated payload of the sub-blocks, nil when truncated.
        mutating func readSubBlocks() -> [UInt8]? {
            var out: [UInt8] = []
            while let size = u8() {
                if size == 0 { return out }
                guard pos + size <= bytes.count else { return nil }
                out.append(contentsOf: bytes[pos..<pos + size])
                pos += size
            }
            return nil
        }

        mutating func run() -> [PlazaBitmap] {
            guard bytes.count >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38,
                  bytes[4] == 0x37 || bytes[4] == 0x39, bytes[5] == 0x61 else { return [] }
            pos = 6
            guard let width = u16(), let height = u16(), let screenFlags = u8(), u8() != nil, u8() != nil,
                  width > 0, height > 0, width <= Limits.maxDimension, height <= Limits.maxDimension else { return [] }
            var global: [UInt8]?
            if screenFlags & 0x80 != 0 {
                guard let table = colorTable(1 << ((screenFlags & 7) + 1)) else { return [] }
                global = table
            }
            let canvasBytes = width * height * 4
            let frameCap = min(Limits.maxFrames, Limits.maxOutputBytes / canvasBytes)

            var canvas = PlazaBitmap(width: width, height: height, fill: blank)
            var disposal = 0
            var transparent: Int?
            var decodedPixels = 0

            blocks: while let introducer = u8() {
                switch introducer {
                case 0x21:
                    guard let label = u8() else { break blocks }
                    if label == 0xF9 {
                        // Graphic control extension: a 4-byte block, then the terminator.
                        guard let size = u8(), size >= 4, pos + size <= bytes.count else { break blocks }
                        let packed = Int(bytes[pos])
                        disposal = (packed >> 2) & 7
                        transparent = packed & 1 != 0 ? Int(bytes[pos + 3]) : nil
                        if transparent != nil { sawTransparency = true }
                        pos += size
                        guard skipSubBlocks() else { break blocks }
                    } else if !skipSubBlocks() {
                        break blocks
                    }
                case 0x2C:
                    guard frames.count < frameCap,
                          let left = u16(), let top = u16(), let w = u16(), let h = u16(), let flags = u8() else { break blocks }
                    var table = global
                    if flags & 0x80 != 0 {
                        guard let local = colorTable(1 << ((flags & 7) + 1)) else { break blocks }
                        table = local
                    }
                    guard let minCode = u8(), (1...8).contains(minCode), let data = readSubBlocks() else { break blocks }
                    let count = w * h
                    decodedPixels += count
                    guard count <= Limits.maxDimension * Limits.maxDimension, decodedPixels <= Limits.maxDecodedPixels,
                          let indices = Self.lzw(data, minCode: minCode, count: count) else { break blocks }

                    let before = disposal == 3 ? canvas : nil
                    Self.draw(into: &canvas, indices: indices, left: left, top: top, width: w, height: h,
                              interlaced: flags & 0x40 != 0, table: table ?? [], transparent: transparent)
                    frames.append(canvas)
                    switch disposal {
                    case 2: Self.clear(&canvas, left: left, top: top, width: w, height: h, to: blank)
                    case 3: canvas = before!
                    default: break
                    }
                    disposal = 0
                    transparent = nil
                case 0x3B:
                    break blocks
                default:
                    break blocks   // trailing garbage
                }
            }
            return frames
        }

        /// GIF LZW (variable code size, clear and end codes). Nil when the stream is bad or ends before `count` indices.
        static func lzw(_ data: [UInt8], minCode: Int, count: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: count)
            if count == 0 { return out }
            let clear = 1 << minCode, end = clear + 1
            var prefix = [UInt16](repeating: 0, count: 4096)
            var suffix = [UInt8](repeating: 0, count: 4096)
            for i in 0..<clear { suffix[i] = UInt8(truncatingIfNeeded: i) }
            var stack = [UInt8](repeating: 0, count: 4097)
            var codeSize = minCode + 1
            var next = end + 1
            var previous = -1
            var first: UInt8 = 0
            var written = 0
            var bits = 0, bitCount = 0, at = 0

            while written < count {
                while bitCount < codeSize {
                    guard at < data.count else { return nil }
                    bits |= Int(data[at]) << bitCount
                    at += 1
                    bitCount += 8
                }
                var code = bits & ((1 << codeSize) - 1)
                bits >>= codeSize
                bitCount -= codeSize

                if code == clear {
                    codeSize = minCode + 1
                    next = end + 1
                    previous = -1
                    continue
                }
                if code == end { return nil }
                if previous < 0 {
                    guard code < clear else { return nil }
                    out[written] = UInt8(truncatingIfNeeded: code)
                    written += 1
                    previous = code
                    first = UInt8(truncatingIfNeeded: code)
                    continue
                }
                let incoming = code
                var top = 0
                if code >= next {
                    guard code == next, next < 4096 else { return nil }
                    stack[top] = first
                    top += 1
                    code = previous
                }
                while code >= clear {
                    stack[top] = suffix[code]
                    top += 1
                    code = Int(prefix[code])
                }
                first = suffix[code]
                stack[top] = first
                top += 1
                while top > 0 && written < count {
                    top -= 1
                    out[written] = stack[top]
                    written += 1
                }
                if next < 4096 {
                    prefix[next] = UInt16(previous)
                    suffix[next] = first
                    next += 1
                    if next == 1 << codeSize && codeSize < 12 { codeSize += 1 }
                }
                previous = incoming
            }
            return out
        }

        /// Composites the sub-image onto the canvas, clipped to it. Index `transparent` and indices past the palette leave
        /// the canvas as it is.
        static func draw(into canvas: inout PlazaBitmap, indices: [UInt8], left: Int, top: Int, width: Int, height: Int,
                         interlaced: Bool, table: [UInt8], transparent: Int?) {
            guard width > 0, height > 0 else { return }
            let entries = table.count / 3
            let canvasWidth = canvas.width, canvasHeight = canvas.height
            canvas.bytes.withUnsafeMutableBufferPointer { out in
                for row in 0..<height {
                    let y = top + (interlaced ? interlacedRow(row, height: height) : row)
                    guard y < canvasHeight else { continue }
                    let base = row * width
                    let xEnd = min(width, canvasWidth - left)
                    guard xEnd > 0 else { continue }
                    for x in 0..<xEnd {
                        let index = Int(indices[base + x])
                        if index == transparent || index >= entries { continue }
                        let o = (y * canvasWidth + left + x) * 4
                        out[o] = table[index * 3]
                        out[o + 1] = table[index * 3 + 1]
                        out[o + 2] = table[index * 3 + 2]
                        out[o + 3] = 255
                    }
                }
            }
        }

        /// The picture row the `n`-th stored row belongs to (passes: every 8th from 0, every 8th from 4, every 4th from 2,
        /// every 2nd from 1).
        static func interlacedRow(_ n: Int, height: Int) -> Int {
            var n = n
            let pass0 = (height + 7) / 8
            if n < pass0 { return n * 8 }
            n -= pass0
            let pass1 = (height + 3) / 8
            if n < pass1 { return 4 + n * 8 }
            n -= pass1
            let pass2 = (height + 1) / 4
            if n < pass2 { return 2 + n * 4 }
            return 1 + (n - pass2) * 2
        }

        static func clear(_ canvas: inout PlazaBitmap, left: Int, top: Int, width: Int, height: Int, to blank: PlazaRGBA) {
            let x1 = min(left + width, canvas.width), y1 = min(top + height, canvas.height)
            guard left < x1, top < y1 else { return }
            for y in top..<y1 {
                for x in left..<x1 { canvas[x, y] = blank }
            }
        }
    }
}
