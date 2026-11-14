import Foundation

enum PlazaCanvasBlend: Sendable { case normal, multiply, sourceAtop }
enum PlazaLineJoin: Sendable { case miter, round }
enum PlazaTextDrawingMode: Sendable { case fill, stroke }
enum PlazaLineCap: Sendable { case butt, round }

/// A polygon or polyline: straight segments only (the overlay panels' chevron, eye and minimap diamond need nothing
/// else; a curve is sampled into line segments by whoever builds the path). Coordinates are the canvas's.
struct PlazaPath: Equatable, Sendable {
    enum Element: Equatable, Sendable { case move(CGPoint), line(CGPoint), close }
    var elements: [Element] = []

    mutating func move(to p: CGPoint) { elements.append(.move(p)) }
    mutating func line(to p: CGPoint) { elements.append(.line(p)) }
    mutating func close() { elements.append(.close) }

    /// `points` joined by lines, closed when `closed`.
    init(points: [CGPoint], closed: Bool = false) {
        for (i, p) in points.enumerated() { elements.append(i == 0 ? .move(p) : .line(p)) }
        if closed { elements.append(.close) }
    }

    init() {}

    init(rect r: CGRect) { self.init(points: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                              CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)], closed: true) }
}

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
    /// The ellipse's outline stroked with the stroke colour, the line centred on it; the canvas's own line width is
    /// unchanged.
    func strokeEllipse(in rect: CGRect, lineWidth: CGFloat)
    /// `path` filled with the fill colour (non-zero winding).
    func fillPath(_ path: PlazaPath)
    /// `path` stroked with the stroke colour and the canvas's line join, the line centred on it; the canvas's own line
    /// width is unchanged.
    func strokePath(_ path: PlazaPath, lineWidth: CGFloat, cap: PlazaLineCap)
    /// Later drawing is clipped to the rounded rectangle (the same outline as `fillRoundedRect`).
    func clip(toRoundedRect rect: CGRect, radius: CGFloat)
    /// A rectangle with corners of `radius`, filled with the fill colour. The corners are SwiftUI's default
    /// `RoundedRectangle` corners (`.continuous`: the curve starts a little before the radius and eases into the edge;
    /// the Mac uses SwiftUI's own path), which the overlay panels had. A circular corner of the same radius differs by
    /// less than a pixel's coverage at the corner pixels.
    func fillRoundedRect(_ rect: CGRect, radius: CGFloat)
    /// The same outline stroked with the stroke colour, the line centred on it; the canvas's own line width is unchanged.
    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat)
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
