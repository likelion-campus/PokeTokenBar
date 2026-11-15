import Foundation

/// `SpriteLoader.cropToContent` over `PlazaImage`: the egg's 96x96 canvas holds a 28x30 egg, so it is cut to the box of
/// pixels with alpha above 0.01 (a byte of 3 or more), widened to a square on the longer side and centred, so a
/// square frame does not stretch it. Nothing opaque, or an image that cannot be cut, comes back unchanged.
enum PlazaEggCrop {
    static func square(_ image: PlazaImage) -> PlazaImage {
        let w = image.width, h = image.height
        let bytes = image.pixels.bytes
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where bytes[(y * w + x) * 4 + 3] >= 3 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let side = min(max(bw, bh), min(w, h))
        let sx = max(0, min(minX - (side - bw) / 2, w - side))
        let sy = max(0, min(minY - (side - bh) / 2, h - side))
        return image.cropping(to: PlazaPixelRect(x: sx, y: sy, width: side, height: side)) ?? image
    }
}
