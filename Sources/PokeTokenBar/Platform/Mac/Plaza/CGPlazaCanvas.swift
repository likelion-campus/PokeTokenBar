import CoreGraphics
import CoreText

/// `PlazaCanvas` over a `CGContext`: each method is exactly the one CoreGraphics / CoreText call the art files made.
/// Text must come from `CoreTextPlazaEngine` (the Mac's `PlatformPlaza.graphics.text`).
final class CGPlazaCanvas: PlazaCanvas {
    let context: CGContext

    init(context: CGContext) { self.context = context }

    var width: Int { context.width }
    var height: Int { context.height }

    func saveState() { context.saveGState() }
    func restoreState() { context.restoreGState() }
    func translate(x: CGFloat, y: CGFloat) { context.translateBy(x: x, y: y) }
    func scale(x: CGFloat, y: CGFloat) { context.scaleBy(x: x, y: y) }
    func rotate(by radians: CGFloat) { context.rotate(by: radians) }
    func setAlpha(_ a: CGFloat) { context.setAlpha(a) }

    func setBlend(_ b: PlazaCanvasBlend) {
        switch b {
        case .normal: context.setBlendMode(.normal)
        case .multiply: context.setBlendMode(.multiply)
        case .sourceAtop: context.setBlendMode(.sourceAtop)
        }
    }

    func setFillColor(_ c: PlazaColor) { context.setFillColor(c.cgColor) }
    func setStrokeColor(_ c: PlazaColor) { context.setStrokeColor(c.cgColor) }
    func setLineWidth(_ w: CGFloat) { context.setLineWidth(w) }

    func setLineJoin(_ j: PlazaLineJoin) {
        switch j {
        case .miter: context.setLineJoin(.miter)
        case .round: context.setLineJoin(.round)
        }
    }

    func setShadow(_ s: PlazaShadow?) {
        if let s {
            context.setShadow(offset: s.offset, blur: s.blur, color: s.color.cgColor)
        } else {
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
    }

    func setShouldAntialias(_ on: Bool) { context.setShouldAntialias(on) }
    func setAllowsAntialiasing(_ on: Bool) { context.setAllowsAntialiasing(on) }
    func setShouldSmoothFonts(_ on: Bool) { context.setShouldSmoothFonts(on) }
    func setInterpolationNone() { context.interpolationQuality = .none }

    func setTextDrawingMode(_ m: PlazaTextDrawingMode) {
        switch m {
        case .fill: context.setTextDrawingMode(.fill)
        case .stroke: context.setTextDrawingMode(.stroke)
        }
    }

    func clip(to rect: CGRect) { context.clip(to: rect) }
    func fill(_ rect: CGRect) { context.fill(rect) }
    func fillEllipse(in rect: CGRect) { context.fillEllipse(in: rect) }
    func draw(_ image: PlazaImage, in rect: CGRect) { context.draw(image.cgImage, in: rect) }

    func draw(_ line: PlazaTextLine, at textPosition: CGPoint) {
        context.textPosition = textPosition
        CTLineDraw(CoreTextPlazaEngine.ctLine(line)!, context)
    }

    func draw(_ paragraph: PlazaParagraph, in rect: CGRect) {
        CTFrameDraw(CTFramesetterCreateFrame(CoreTextPlazaEngine.framesetter(paragraph)!, CFRange(), CGPath(rect: rect, transform: nil), nil),
                    context)
    }

    func imageBounds(of line: PlazaTextLine) -> CGRect {
        CTLineGetImageBounds(CoreTextPlazaEngine.ctLine(line)!, context)
    }

    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) {
        body(context.data!.assumingMemoryBound(to: UInt8.self), context.bytesPerRow)
    }

    func makeImage() -> PlazaImage? { context.makeImage().map(PlazaImage.init(cgImage:)) }
}
