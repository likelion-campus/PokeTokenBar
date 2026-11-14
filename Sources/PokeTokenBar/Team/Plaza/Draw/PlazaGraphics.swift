import Foundation

/// What plaza art needs from the platform's graphics: canvases, text, bundled assets and image codecs.
/// `PlatformPlaza.graphics` is the Mac's CoreGraphics/CoreText/ImageIO implementation or the headless stub.
protocol PlazaGraphics: Sendable {
    var text: any PlazaTextEngine { get }
    /// A transparent premultiplied RGBA8 canvas, CG conventions (`PlazaCanvas`); nil when it cannot be made.
    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)?
    /// A bundled plaza resource (`Resources/Plaza`). Nil on Windows until stage 6 ships the resources.
    func assetURL(_ name: String, ext: String) -> URL?
    /// The first image in the file.
    func decodeImage(at url: URL) -> PlazaImage?
    func decodeImage(_ data: Data) -> PlazaImage?
    /// Every frame of a GIF, in order; empty when the file cannot be read.
    func decodeImageFrames(at url: URL) -> [PlazaImage]
    func encodePNG(_ image: PlazaImage) -> Data?
}
