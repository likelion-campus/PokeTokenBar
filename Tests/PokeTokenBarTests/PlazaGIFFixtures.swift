import Foundation

/// Builds tiny GIF files byte by byte for the decoder tests: no sprite or other asset is committed.
/// The LZW encoder here is independent of the decoder under test.
enum PlazaGIFFixtures {
    struct Frame {
        var left = 0, top = 0, width: Int, height: Int
        /// Palette indices in picture order (row 0 first); the builder reorders them for `interlaced`.
        var indices: [UInt8]
        var palette: [[UInt8]]?
        var interlaced = false
        var disposal = 0
        var transparent: Int?
        var minCode = 2
        var clearAtFull = true
        var delay = 10

        init(left: Int = 0, top: Int = 0, width: Int, height: Int, indices: [UInt8]) {
            self.left = left; self.top = top; self.width = width; self.height = height; self.indices = indices
        }
    }

    /// red, green, blue, white
    static let palette4: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]

    static func gif(width: Int, height: Int, global: [[UInt8]]? = palette4, version: String = "GIF89a",
                    prefix: [UInt8] = [], frames: [Frame], trailer: Bool = true) -> [UInt8] {
        var out = Array(version.utf8)
        out += le16(width) + le16(height)
        if let global {
            out += [0x80 | UInt8(tableBits(global.count)), 0, 0]
            out += tableBytes(global)
        } else {
            out += [0, 0, 0]
        }
        out += prefix
        for f in frames {
            if f.disposal != 0 || f.transparent != nil || f.delay != 0 {
                let packed = UInt8(f.disposal << 2) | (f.transparent != nil ? 1 : 0)
                out += [0x21, 0xF9, 4, packed] + le16(f.delay) + [UInt8(f.transparent ?? 0), 0]
            }
            out += [0x2C] + le16(f.left) + le16(f.top) + le16(f.width) + le16(f.height)
            var flags: UInt8 = f.interlaced ? 0x40 : 0
            if let local = f.palette { flags |= 0x80 | UInt8(tableBits(local.count)) }
            out.append(flags)
            if let local = f.palette { out += tableBytes(local) }
            out.append(UInt8(f.minCode))
            let stored = f.interlaced ? interlace(f.indices, width: f.width, height: f.height) : f.indices
            out += subBlocks(lzw(stored, minCode: f.minCode, clearAtFull: f.clearAtFull))
        }
        if trailer { out.append(0x3B) }
        return out
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }

    /// GIF's "size" field: the table has 2^(bits+1) entries.
    static func tableBits(_ count: Int) -> Int {
        var bits = 0
        while (2 << bits) < count { bits += 1 }
        return bits
    }

    static func tableBytes(_ table: [[UInt8]]) -> [UInt8] {
        var out = table.flatMap { $0 }
        out += [UInt8](repeating: 0, count: (2 << tableBits(table.count)) * 3 - out.count)
        return out
    }

    static func subBlocks(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let n = min(255, data.count - i)
            out.append(UInt8(n))
            out += data[i..<i + n]
            i += n
        }
        out.append(0)
        return out
    }

    /// Stored (interlaced) order: passes of rows 0/8/..., 4/12/..., 2/6/..., 1/3/...
    static func interlace(_ indices: [UInt8], width: Int, height: Int) -> [UInt8] {
        var order: [Int] = []
        for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] { order += stride(from: start, to: height, by: step) }
        return order.flatMap { indices[$0 * width..<($0 + 1) * width] }
    }

    static func lzw(_ indices: [UInt8], minCode: Int, clearAtFull: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var bits = 0, bitCount = 0
        let clear = 1 << minCode, end = clear + 1
        var codeSize = minCode + 1
        var next = end + 1
        var dict: [Int: Int] = [:]
        func emit(_ code: Int) {
            bits |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 { out.append(UInt8(bits & 255)); bits >>= 8; bitCount -= 8 }
        }
        emit(clear)
        guard var current = indices.first.map(Int.init) else { emit(end); return finish() }
        for byte in indices.dropFirst() {
            let key = current << 8 | Int(byte)
            if let code = dict[key] { current = code; continue }
            emit(current)
            if clearAtFull && next == 4095 {
                emit(clear)
                dict = [:]
                next = end + 1
                codeSize = minCode + 1
            } else if next < 4096 {
                dict[key] = next
                next += 1
                if next - 1 == 1 << codeSize && codeSize < 12 { codeSize += 1 }
            }
            current = Int(byte)
        }
        emit(current)
        emit(end)
        return finish()

        func finish() -> [UInt8] {
            if bitCount > 0 { out.append(UInt8(bits & 255)) }
            return out
        }
    }

    /// A deterministic pseudo-random index sequence below `limit`.
    static func noise(count: Int, limit: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) % UInt64(limit))
        }
    }
}
