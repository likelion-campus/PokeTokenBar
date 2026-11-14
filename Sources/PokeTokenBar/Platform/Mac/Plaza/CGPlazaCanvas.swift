import CoreGraphics
import CoreText
import SwiftUI   // only for the continuous rounded rectangle's path (`Path(roundedRect:cornerRadius:style:)`)

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
    func setFillGray(_ gray: CGFloat) { context.setFillColor(CGColor(gray: gray, alpha: 1)) }
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

    func strokeEllipse(in rect: CGRect, lineWidth: CGFloat) {
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    private static func cgPath(_ path: PlazaPath) -> CGPath {
        let p = CGMutablePath()
        for e in path.elements {
            switch e {
            case .move(let point): p.move(to: point)
            case .line(let point): p.addLine(to: point)
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    func fillPath(_ path: PlazaPath) {
        context.addPath(Self.cgPath(path))
        context.fillPath()
    }

    func strokePath(_ path: PlazaPath, lineWidth: CGFloat, cap: PlazaLineCap) {
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(cap == .round ? .round : .butt)
        context.addPath(Self.cgPath(path))
        context.strokePath()
        context.restoreGState()
    }

    func clip(toRoundedRect rect: CGRect, radius: CGFloat) {
        context.addPath(Self.roundedRect(rect, radius: radius))
        context.clip()
    }

    /// SwiftUI's own path for `RoundedRectangle(cornerRadius:)` (its default `.continuous` corners), so a panel's pill has
    /// the corners the SwiftUI view had.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
    }

    func fillRoundedRect(_ rect: CGRect, radius: CGFloat) {
        context.addPath(Self.roundedRect(rect, radius: radius))
        context.fillPath()
    }

    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.addPath(Self.roundedRect(rect, radius: radius))
        context.strokePath()
        context.restoreGState()
    }
    func draw(_ image: PlazaImage, in rect: CGRect) { context.draw(image.cgImage, in: rect) }

    func draw(_ line: PlazaTextLine, at textPosition: CGPoint) {
        context.textPosition = textPosition
        CTLineDraw(CoreTextPlazaEngine.ctLine(line)!, context)
    }

    func draw(_ paragraph: PlazaParagraph, in rect: CGRect) {
        CTFrameDraw(CTFramesetterCreateFrame(CoreTextPlazaEngine.framesetter(paragraph)!, CFRange(), CGPath(rect: rect, transform: nil), nil),
                    context)
    }

    /// `CTLineGetImageBounds` shifts its result by the context's text position, which `draw(_:at:)` leaves moved past the
    /// line. Measure from the origin so the result does not depend on what was drawn before.
    func imageBounds(of line: PlazaTextLine) -> CGRect {
        let saved = context.textPosition
        context.textPosition = .zero
        defer { context.textPosition = saved }
        return CTLineGetImageBounds(CoreTextPlazaEngine.ctLine(line)!, context)
    }

    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) {
        body(context.data!.assumingMemoryBound(to: UInt8.self), context.bytesPerRow)
    }

    func makeImage() -> PlazaImage? { context.makeImage().map(PlazaImage.init(cgImage:)) }
}
