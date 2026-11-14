import Foundation

/// The colour space a bitmap's bytes are meant in. Plaza art is sRGB; the character placeholder is device RGB.
enum PlazaColorSpace: Sendable { case sRGB, deviceRGB }

/// What the fourth byte of a pixel is: premultiplied alpha, or padding the image ignores (an opaque image).
enum PlazaAlphaLayout: Sendable { case premultipliedLast, noneSkipLast }

/// One pixel, in the bitmap's byte order (R, G, B, A).
struct PlazaRGBA: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

/// A pixel rectangle. Origin top-left, like `CGImage.cropping(to:)`.
struct PlazaPixelRect: Hashable, Sendable {
    var x: Int, y: Int, width: Int, height: Int
}

/// A shared RGBA8 image: 4 bytes per pixel, rows packed (`width * 4` bytes per row), row 0 at the top. With
/// `.premultipliedLast` the colour bytes are already multiplied by alpha, as in every plaza art buffer today.
struct PlazaBitmap: Hashable, Sendable {
    let width: Int, height: Int
    var bytes: [UInt8]
    var alpha: PlazaAlphaLayout = .premultipliedLast
    var colorSpace: PlazaColorSpace = .sRGB

    init(width: Int, height: Int, fill: PlazaRGBA = .init(r: 0, g: 0, b: 0, a: 0)) {
        precondition(width >= 0 && height >= 0, "negative bitmap size \(width)x\(height)")
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if fill != PlazaRGBA(r: 0, g: 0, b: 0, a: 0) {
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i] = fill.r; bytes[i + 1] = fill.g; bytes[i + 2] = fill.b; bytes[i + 3] = fill.a
            }
        }
        self.bytes = bytes
    }

    subscript(x: Int, y: Int) -> PlazaRGBA {
        get {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
            let i = (y * width + x) * 4
            return PlazaRGBA(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }
        set {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
            let i = (y * width + x) * 4
            bytes[i] = newValue.r; bytes[i + 1] = newValue.g; bytes[i + 2] = newValue.b; bytes[i + 3] = newValue.a
        }
    }

    /// The part of `rect` inside the bitmap, rows copied. Like `CGImage.cropping(to:)` the rectangle is clipped to the
    /// bitmap; outside it the result is 0×0. Alpha layout and colour space are kept.
    func cropped(to rect: PlazaPixelRect) -> PlazaBitmap {
        let x0 = max(rect.x, 0), y0 = max(rect.y, 0)
        let x1 = min(rect.x + rect.width, width), y1 = min(rect.y + rect.height, height)
        var out = PlazaBitmap(width: max(0, x1 - x0), height: max(0, y1 - y0))
        out.alpha = alpha
        out.colorSpace = colorSpace
        let rowBytes = out.width * 4
        for row in 0..<out.height {
            let from = ((y0 + row) * width + x0) * 4
            out.bytes.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: bytes[from..<from + rowBytes])
        }
        return out
    }
}
