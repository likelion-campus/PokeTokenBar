import Foundation

/// A drawn part's layers (`PlazaPanelDrawing.layers`) as one premultiplied BGRA picture, row 0 at the top: the bytes of
/// the 32-bpp top-down DIB the Windows host blits with `AlphaBlend` (stage 7 D7). Layer frames are in DIP; the picture is
/// at `scale` device pixels per DIP, and the parts rasterize their images at that scale, so an image lands 1:1.
enum PopoverComposite {
    /// A bitmap's bytes as premultiplied BGRA: R and B swapped; a `noneSkipLast` bitmap's padding byte becomes opaque alpha.
    static func bgra(_ bitmap: PlazaBitmap) -> [UInt8] {
        var out = bitmap.bytes
        let opaque = bitmap.alpha == .noneSkipLast
        var i = 0
        while i + 3 < out.count {
            out.swapAt(i, i + 2)
            if opaque { out[i + 3] = 255 }
            i += 4
        }
        return out
    }

    /// A DIP frame in device pixels: the edges rounded, so neighbouring layers meet without a gap.
    static func pixelRect(_ frame: CGRect, scale: CGFloat) -> PlazaPixelRect {
        let x0 = Int((frame.minX * scale).rounded()), y0 = Int((frame.minY * scale).rounded())
        let x1 = Int((frame.maxX * scale).rounded()), y1 = Int((frame.maxY * scale).rounded())
        return PlazaPixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Every layer, bottom first, drawn source-over (premultiplied) into a transparent `width` x `height` picture. An image
    /// whose size is not its pixel frame's is scaled nearest (sprites stay crisp, as `.interpolation(.none)` on the Mac).
    static func compose(_ layers: [PlazaPanelLayer], width: Int, height: Int, scale: CGFloat) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, width) * max(0, height) * 4)
        guard width > 0, height > 0 else { return out }
        for layer in layers {
            switch layer {
            case let .color(color, frame):
                let r = pixelRect(frame, scale: scale)
                let a = UInt8((min(max(color.alpha, 0), 1) * 255).rounded())
                guard a > 0 else { continue }
                let px = (b: premultiply(color.blue, a), g: premultiply(color.green, a), r: premultiply(color.red, a), a: a)
                fill(&out, width: width, height: height, rect: r) { _, _ in px }
            case let .image(image, frame):
                let r = pixelRect(frame, scale: scale)
                let bitmap = image.pixels
                guard bitmap.width > 0, bitmap.height > 0 else { continue }
                let src = bgra(bitmap)
                let sw = bitmap.width, sh = bitmap.height
                fill(&out, width: width, height: height, rect: r) { x, y in
                    let sx = r.width == sw ? x : min(sw - 1, x * sw / max(1, r.width))
                    let sy = r.height == sh ? y : min(sh - 1, y * sh / max(1, r.height))
                    let s = (sy * sw + sx) * 4
                    return (b: src[s], g: src[s + 1], r: src[s + 2], a: src[s + 3])
                }
            }
        }
        return out
    }

    private static func premultiply(_ c: Double, _ a: UInt8) -> UInt8 {
        UInt8((min(max(c, 0), 1) * Double(a)).rounded())
    }

    /// Source-over of `pixel(x, y)` (coordinates inside `rect`) onto `out`, clipped to the picture.
    private static func fill(_ out: inout [UInt8], width: Int, height: Int, rect: PlazaPixelRect,
                             _ pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixel(x - rect.x, y - rect.y)
                guard p.a > 0 else { continue }
                let o = (y * width + x) * 4
                if p.a == 255 {
                    out[o] = p.b; out[o + 1] = p.g; out[o + 2] = p.r; out[o + 3] = 255
                } else {
                    let keep = 255 - Int(p.a)
                    out[o] = UInt8(min(255, Int(p.b) + (Int(out[o]) * keep + 127) / 255))
                    out[o + 1] = UInt8(min(255, Int(p.g) + (Int(out[o + 1]) * keep + 127) / 255))
                    out[o + 2] = UInt8(min(255, Int(p.r) + (Int(out[o + 2]) * keep + 127) / 255))
                    out[o + 3] = UInt8(min(255, Int(p.a) + (Int(out[o + 3]) * keep + 127) / 255))
                }
            }
        }
    }
}
