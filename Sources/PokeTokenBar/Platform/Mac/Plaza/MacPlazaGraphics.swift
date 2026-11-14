import CoreGraphics
import Foundation
import ImageIO

/// The Mac's plaza graphics: CoreGraphics canvases, CoreText text, ImageIO codecs, the SwiftPM resource bundle.
struct MacPlazaGraphics: PlazaGraphics {
    let text: any PlazaTextEngine = CoreTextPlazaEngine()

    /// `bytesPerRow: 0` like every canvas-drawn art file but one (`PlazaPondArt.wetImage` passed `side * 4`, which
    /// equals CoreGraphics' 32-byte-aligned choice for its sides; `PlazaArtParityTests` checks the bytes).
    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
        let space = colorSpace == .sRGB ? CGColorSpace(name: CGColorSpace.sRGB) : CGColorSpaceCreateDeviceRGB()
        guard let space, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return CGPlazaCanvas(context: context)
    }

    func assetURL(_ name: String, ext: String) -> URL? {
        PlazaResources.resourceURL(name, ext, in: PlazaResources.resourceBundle())
    }

    func decodeImage(at url: URL) -> PlazaImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PlazaImage(cgImage: image)
    }

    func decodeImage(_ data: Data) -> PlazaImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PlazaImage(cgImage: image)
    }

    func decodeImageFrames(at url: URL) -> [PlazaImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
            .map(PlazaImage.init(cgImage:))
    }

    func encodePNG(_ image: PlazaImage) -> Data? { PlazaPhotoRenderer.png(image.cgImage) }
}
