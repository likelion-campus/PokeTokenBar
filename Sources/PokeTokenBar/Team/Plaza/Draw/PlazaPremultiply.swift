import Foundation

/// CoreGraphics' byte rounding for straight ↔ premultiplied RGBA8, so a decoder that is not CoreGraphics (Windows:
/// WIC) gives the same `PlazaImage.pixels` as the Mac. Both formulas were measured against CoreGraphics over every
/// (colour, alpha) pair: `Tests/PlazaParityGoldens/premultiply.json` holds the 256 × 256 table, and
/// `PlazaParityGoldensMacTests` re-measures it on every Mac run.
enum PlazaPremultiply {
    /// What a premultiplied sRGB RGBA context makes of a straight colour byte `c` with alpha `a`: `(c·a + 127) / 255`.
    @inline(__always) static func premultiplied(_ c: UInt8, alpha a: UInt8) -> UInt8 {
        UInt8((Int(c) * Int(a) + 127) / 255)
    }

    /// What ImageIO writes for a premultiplied colour byte (alpha 0 gives 0): `(c·255 + a/2) / a`, capped at 255.
    @inline(__always) static func straight(_ c: UInt8, alpha a: UInt8) -> UInt8 {
        a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a)))
    }

    /// Straight RGBA8 (row 0 top, packed rows) → premultiplied, with CoreGraphics' rounding.
    static func bitmap(straight bytes: [UInt8], width: Int, height: Int) -> PlazaBitmap {
        precondition(bytes.count == width * height * 4, "PlazaPremultiply.bitmap: \(bytes.count) bytes for \(width)x\(height)")
        var out = PlazaBitmap(width: width, height: height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = bytes[i + 3]
            out.bytes[i] = premultiplied(bytes[i], alpha: a)
            out.bytes[i + 1] = premultiplied(bytes[i + 1], alpha: a)
            out.bytes[i + 2] = premultiplied(bytes[i + 2], alpha: a)
            out.bytes[i + 3] = a
        }
        return out
    }

    /// The inverse CoreGraphics applies when ImageIO writes a PNG. An opaque (`noneSkipLast`) bitmap is written with
    /// alpha 255 and its colour bytes as they are.
    static func straight(_ bitmap: PlazaBitmap) -> [UInt8] {
        var out = bitmap.bytes
        if bitmap.alpha == .noneSkipLast {
            for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 }
            return out
        }
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = out[i + 3]
            out[i] = straight(out[i], alpha: a)
            out[i + 1] = straight(out[i + 1], alpha: a)
            out[i + 2] = straight(out[i + 2], alpha: a)
        }
        return out
    }
}
