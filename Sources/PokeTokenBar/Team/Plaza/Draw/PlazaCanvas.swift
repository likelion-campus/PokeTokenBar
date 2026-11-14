import Foundation

enum PlazaCanvasBlend: Sendable { case normal, multiply, sourceAtop }
enum PlazaLineJoin: Sendable { case miter, round }
enum PlazaTextDrawingMode: Sendable { case fill, stroke }

/// A drop shadow. Offset and blur are in device pixels: like `CGContext.setShadow`, the CTM does not scale them.
struct PlazaShadow: Sendable {
    var offset: CGSize
    var blur: CGFloat
    var color: PlazaColor
}

/// A drawing surface with CoreGraphics conventions: origin bottom-left, y up, a CTM and a save/restore state stack.
/// Converted art is the old `CGContext` code with `context.` replaced by `canvas.`; on the Mac every method is exactly
/// one `CGContext` / CoreText call (`CGPlazaCanvas`), so the pixels are the old pixels.
protocol PlazaCanvas: AnyObject {
    var width: Int { get }
    var height: Int { get }
    func saveState()
    func restoreState()
    func translate(x: CGFloat, y: CGFloat)
    func scale(x: CGFloat, y: CGFloat)
    func rotate(by radians: CGFloat)
    func setAlpha(_ a: CGFloat)
    func setBlend(_ b: PlazaCanvasBlend)
    func setFillColor(_ c: PlazaColor)
    /// An opaque device-gray fill (`CGColor(gray:alpha: 1)`), for the one fill that is not sRGB: the character
    /// placeholder, a gray in a device RGB canvas. On the Mac gray 0.55 lands on 158 per channel (sRGB 0.55 would be
    /// 140); a Windows canvas writes that byte value (158) for 0.55 so the placeholder looks the same.
    func setFillGray(_ gray: CGFloat)
    func setStrokeColor(_ c: PlazaColor)
    func setLineWidth(_ w: CGFloat)
    func setLineJoin(_ j: PlazaLineJoin)
    /// nil turns the shadow off (`setShadow(offset: .zero, blur: 0, color: nil)`).
    func setShadow(_ s: PlazaShadow?)
    func setShouldAntialias(_ on: Bool)
    func setAllowsAntialiasing(_ on: Bool)
    func setShouldSmoothFonts(_ on: Bool)
    func setInterpolationNone()
    func setTextDrawingMode(_ m: PlazaTextDrawingMode)
    func clip(to rect: CGRect)
    func fill(_ rect: CGRect)
    func fillEllipse(in rect: CGRect)
    func draw(_ image: PlazaImage, in rect: CGRect)
    /// Sets the text position, then draws the line (which moves the text position on, as `CTLineDraw` does).
    func draw(_ line: PlazaTextLine, at textPosition: CGPoint)
    /// Lays the paragraph out in `rect` and draws it (`CTFramesetterCreateFrame` + `CTFrameDraw`).
    func draw(_ paragraph: PlazaParagraph, in rect: CGRect)
    /// The line's glyph bounds as this canvas would draw them (`CTLineGetImageBounds(line, context)`), relative to the
    /// origin: the same whatever was drawn before.
    func imageBounds(of line: PlazaTextLine) -> CGRect
    /// The canvas's own premultiplied RGBA8 bytes, row 0 at the top. `bytesPerRow` may be larger than `width * 4`.
    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void)
    func makeImage() -> PlazaImage?
}
