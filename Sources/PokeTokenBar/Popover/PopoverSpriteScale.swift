import Foundation

/// How the popover resamples its sprites (stage 7 Task 9; the Mac is the reference): smoothly, as bilinear. The Mac's
/// `SpriteView` asks SwiftUI for `.interpolation(.none)`, but what it shows is smoothed: a Retina screenshot of the Mac's
/// Pokédex grid (`assets/screenshot-collection-pokedex.png`, converted to sRGB) has 43 % of a sprite's pixels in the source's
/// colours, as a bilinear resize has (45 %) and a nearest one does not (100 %); the Mac's own `SpriteView` rendered offscreen
/// is 1.4 per channel from a bilinear resize on average and 6.0 from a nearest one (`CompanionHeaderRendersMacTests` pins it).
/// The plaza keeps its own pixel-art scaling; this is the popover's only.
enum PopoverSpriteScale {
    /// `bitmap` (RGBA, premultiplied or opaque) resampled to `width` × `height` as premultiplied BGRA rows, top first (what
    /// GDI's `AlphaBlend` takes). A tent filter per axis: an output pixel's centre maps to `(i + 0.5) × source / target − 0.5`
    /// and its weights fall linearly to 0 at `max(1, source / target)` source pixels — bilinear when growing; when shrinking
    /// (a 40-DIP evolution thumbnail of a 96-pixel sprite at 100 %) every source pixel counts instead of being skipped.
    static func scaledBGRA(_ bitmap: PlazaBitmap, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, width) * max(0, height) * 4)
        let sw = bitmap.width, sh = bitmap.height
        guard sw > 0, sh > 0, width > 0, height > 0 else { return out }
        let opaque = bitmap.alpha == .noneSkipLast
        let xs = tent(source: sw, target: width), ys = tent(source: sh, target: height)
        // Across: source rows → `width` columns (RGBA, as Double).
        var across = [Double](repeating: 0, count: width * sh * 4)
        bitmap.bytes.withUnsafeBufferPointer { src in
            for y in 0..<sh {
                for (x, taps) in xs.enumerated() {
                    let o = (y * width + x) * 4
                    for (i, w) in taps {
                        let s = (y * sw + i) * 4
                        across[o] += Double(src[s]) * w
                        across[o + 1] += Double(src[s + 1]) * w
                        across[o + 2] += Double(src[s + 2]) * w
                        across[o + 3] += (opaque ? 255 : Double(src[s + 3])) * w
                    }
                }
            }
        }
        // Down: `sh` rows → `height` rows, RGBA → BGRA.
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for (y, taps) in ys.enumerated() {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for (i, w) in taps {
                    let s = (i * width + x) * 4
                    r += across[s] * w; g += across[s + 1] * w; b += across[s + 2] * w; a += across[s + 3] * w
                }
                let o = (y * width + x) * 4
                out[o] = byte(b); out[o + 1] = byte(g); out[o + 2] = byte(r); out[o + 3] = byte(a)
            }
        }
        return out
    }

    /// The taps of each of `target` output pixels over `source` pixels: (source index, weight), weights summing to 1;
    /// taps past either edge are dropped and the rest renormalised.
    static func tent(source n: Int, target m: Int) -> [[(Int, Double)]] {
        let ratio = Double(n) / Double(m), support = max(1, ratio)
        return (0..<m).map { i in
            let centre = (Double(i) + 0.5) * ratio - 0.5
            let lo = max(0, Int((centre - support).rounded(.up))), hi = min(n - 1, Int((centre + support).rounded(.down)))
            var taps: [(Int, Double)] = []
            for j in stride(from: lo, through: hi, by: 1) {
                let w = 1 - abs(Double(j) - centre) / support
                if w > 0 { taps.append((j, w)) }
            }
            if taps.isEmpty { taps = [(min(n - 1, max(0, Int(centre.rounded()))), 1)] }
            let total = taps.reduce(0) { $0 + $1.1 }
            return taps.map { ($0.0, $0.1 / total) }
        }
    }

    /// Premultiplied BGRA `width` × `height` turned `degrees` clockwise about its centre (the Mac's `.rotationEffect`),
    /// bilinear, into the turned picture's bounding box; outside the source is transparent.
    static func rotateBilinear(_ bytes: [UInt8], width w: Int, height h: Int, degrees: Double) -> ([UInt8], Int, Int) {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        let ow = Int((abs(Double(w) * c) + abs(Double(h) * s)).rounded(.up)), oh = Int((abs(Double(w) * s) + abs(Double(h) * c)).rounded(.up))
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        let cx = Double(w) / 2, cy = Double(h) / 2, ocx = Double(ow) / 2, ocy = Double(oh) / 2
        bytes.withUnsafeBufferPointer { src in
            func at(_ x: Int, _ y: Int, _ k: Int) -> Double {
                x >= 0 && y >= 0 && x < w && y < h ? Double(src[(y * w + x) * 4 + k]) : 0
            }
            for y in 0..<oh {
                for x in 0..<ow {
                    let px = Double(x) + 0.5 - ocx, py = Double(y) + 0.5 - ocy
                    let sx = c * px + s * py + cx - 0.5, sy = -s * px + c * py + cy - 0.5
                    guard sx > -1, sy > -1, sx < Double(w), sy < Double(h) else { continue }
                    let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down)), wx = sx - Double(x0), wy = sy - Double(y0)
                    let o = (y * ow + x) * 4
                    for k in 0..<4 {
                        let v = at(x0, y0, k) * (1 - wx) * (1 - wy) + at(x0 + 1, y0, k) * wx * (1 - wy)
                            + at(x0, y0 + 1, k) * (1 - wx) * wy + at(x0 + 1, y0 + 1, k) * wx * wy
                        out[o + k] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
            }
        }
        return (out, ow, oh)
    }
}
