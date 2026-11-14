import CoreGraphics
import Foundation

/// A `CGImage` as a plaza native image. It reaches SpriteKit unchanged (`PlazaImage.cgImage`), so the colour space
/// and alpha handling of decoded, cropped and canvas-made images stay exactly what they were.
final class CGImagePayload: PlazaNativeImage, @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) { self.image = image }

    var width: Int { image.width }
    var height: Int { image.height }

    /// Drawn into a premultiplied sRGB buffer with no interpolation, as `SheetPixels` and `PlazaSnowSheet.recolored`
    /// read sheets.
    func pixels() -> PlazaBitmap {
        var bitmap = PlazaBitmap(width: width, height: height)
        let (w, h) = (width, height)
        bitmap.bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bitmap
    }

    func cropping(to rect: PlazaPixelRect) -> (any PlazaNativeImage)? {
        image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)).map(CGImagePayload.init)
    }

    /// A bitmap as a `CGImage`, built the way the art files build theirs: packed rows, one `CGDataProvider` over a copy
    /// of the bytes, no interpolation, default intent.
    static func makeImage(_ bitmap: PlazaBitmap) -> CGImage {
        let space = bitmap.colorSpace == .sRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = bitmap.alpha == .premultipliedLast ? .premultipliedLast : .noneSkipLast
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bitmap.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                       provider: CGDataProvider(data: Data(bitmap.bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}

extension PlazaImage {
    convenience init(cgImage: CGImage) { self.init(native: CGImagePayload(cgImage)) }

    /// What SpriteKit and CoreGraphics get: the native `CGImage` itself, or one built from the bitmap once and kept
    /// in `backendCache`.
    var cgImage: CGImage {
        if let payload = native as? CGImagePayload { return payload.image }
        if let cached = backendCache as? CGImagePayload { return cached.image }
        // The Mac never rebuilds a native image from pixels: a native image here is always a CGImagePayload.
        guard let bitmap else { preconditionFailure("PlazaImage.cgImage: a native image that is not a CGImage (\(String(describing: native)))") }
        let made = CGImagePayload.makeImage(bitmap)
        backendCache = CGImagePayload(made)
        return made
    }
}
