import Foundation

/// The minimap's map layer as a pixel pass over a `PlazaBitmap` (replacing SwiftUI's `Image.resizable().interpolation(.medium)
/// .colorMultiply(…).saturation(…)`): a box-filter downscale of the plaza map to the minimap's device pixels, then the day's
/// tint multiplied in and the night's saturation applied. Pure Swift, so Windows runs the same pass.
enum PlazaMinimapPixels {
    /// Area-average (box filter) downscale of a premultiplied RGBA bitmap to `width` × `height` pixels. Each destination
    /// pixel is the mean of the source area it covers, partial source pixels weighted by their overlap.
    static func downscaled(_ src: PlazaBitmap, width: Int, height: Int) -> PlazaBitmap {
        precondition(width > 0 && height > 0 && src.width > 0 && src.height > 0)
        var out = PlazaBitmap(width: width, height: height)
        out.alpha = src.alpha
        out.colorSpace = src.colorSpace
        // Horizontal pass into floats (srcHeight rows × width), then vertical.
        func weights(_ srcLen: Int, _ dstLen: Int) -> [[(index: Int, weight: Float)]] {
            let ratio = Double(srcLen) / Double(dstLen)
            return (0..<dstLen).map { d in
                let a = Double(d) * ratio, b = Double(d + 1) * ratio
                var w: [(Int, Float)] = []
                var i = Int(a.rounded(.down))
                while Double(i) < b && i < srcLen {
                    let overlap = min(b, Double(i + 1)) - max(a, Double(i))
                    if overlap > 0 { w.append((i, Float(overlap / ratio))) }
                    i += 1
                }
                return w
            }
        }
        let wx = weights(src.width, width), wy = weights(src.height, height)
        var rows = [Float](repeating: 0, count: src.height * width * 4)
        src.bytes.withUnsafeBufferPointer { s in
            for y in 0..<src.height {
                for x in 0..<width {
                    var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                    for (i, w) in wx[x] {
                        let o = (y * src.width + i) * 4
                        acc.0 += Float(s[o]) * w; acc.1 += Float(s[o + 1]) * w; acc.2 += Float(s[o + 2]) * w; acc.3 += Float(s[o + 3]) * w
                    }
                    let o = (y * width + x) * 4
                    rows[o] = acc.0; rows[o + 1] = acc.1; rows[o + 2] = acc.2; rows[o + 3] = acc.3
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                for (j, w) in wy[y] {
                    let o = (j * width + x) * 4
                    acc.0 += rows[o] * w; acc.1 += rows[o + 1] * w; acc.2 += rows[o + 2] * w; acc.3 += rows[o + 3] * w
                }
                let o = (y * width + x) * 4
                out.bytes[o] = UInt8(max(0, min(255, acc.0.rounded()))); out.bytes[o + 1] = UInt8(max(0, min(255, acc.1.rounded())))
                out.bytes[o + 2] = UInt8(max(0, min(255, acc.2.rounded()))); out.bytes[o + 3] = UInt8(max(0, min(255, acc.3.rounded())))
            }
        }
        return out
    }

    /// The map's own luma weights for the saturation (Rec. 709).
    static let luma: (r: Double, g: Double, b: Double) = (0.2126, 0.7152, 0.0722)

    /// `bitmap` (opaque map pixels) with each colour channel multiplied by `tint` (0…1), then pulled toward its luma by
    /// `saturation` (1 leaves it; 0.65 at night). Alpha is kept.
    static func tinted(_ bitmap: PlazaBitmap, tint: PlazaDaylight.Tint, saturation: Double) -> PlazaBitmap {
        var out = bitmap
        let t = (tint.red, tint.green, tint.blue)
        out.bytes.withUnsafeMutableBufferPointer { p in
            for o in stride(from: 0, to: p.count, by: 4) {
                var r = Double(p[o]) * t.0, g = Double(p[o + 1]) * t.1, b = Double(p[o + 2]) * t.2
                if saturation != 1 {
                    let y = luma.r * r + luma.g * g + luma.b * b
                    r = y + saturation * (r - y); g = y + saturation * (g - y); b = y + saturation * (b - y)
                }
                p[o] = UInt8(max(0, min(255, r.rounded()))); p[o + 1] = UInt8(max(0, min(255, g.rounded()))); p[o + 2] = UInt8(max(0, min(255, b.rounded())))
            }
        }
        return out
    }
}
