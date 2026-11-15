#if os(Windows)
import CPlazaD2D
import Foundation

/// `PlazaCanvas` on Direct2D over a WIC bitmap (stage 6, Task 8). The canvas state (CTM, clips, alpha, blend, colours, shadow,
/// antialias flags) lives in C++ behind `handle` (`Sources/CPlazaD2D/canvas_*.cpp`); each method here is one call.
///
/// Conventions, as CoreGraphics: origin bottom-left, y up; images upright in user space; pixels premultiplied, row 0 at the top
/// (the target is 32bpp PBGRA inside, `withPixels` and `makeImage` hand out RGBA).
///
/// Text: drawing a line or a paragraph is unavailable until the DirectWrite engine (Task 9) is plugged in; it draws nothing, logs
/// one line, and `imageBounds` is `.zero`. Task 9 draws into the same target through `ptb::Canvas::paint` (canvas.h).
final class WinPlazaCanvas: PlazaCanvas {
    let width: Int, height: Int
    let colorSpace: PlazaColorSpace
    private var handle: OpaquePointer?
    /// Uploaded images by identity; the image is held so the identity stays valid for the canvas's life.
    private var uploaded: [ObjectIdentifier: (image: PlazaImage, id: UInt32)] = [:]

    /// Nil (and one log line) when Direct2D or WIC cannot make the target.
    init?(width: Int, height: Int, colorSpace: PlazaColorSpace) {
        guard width > 0, height > 0 else { return nil }
        var made: OpaquePointer?
        let code = ptb_canvas_create(UInt32(width), UInt32(height), &made)
        guard code >= 0, let made else {
            Self.logOnce("plaza canvas unavailable: \(WinPlazaCodecs.lastError())")
            return nil
        }
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        handle = made
    }

    deinit { ptb_canvas_release(handle) }

    /// Draw calls that failed inside Direct2D (each is skipped). Tests assert 0.
    var failureCount: Int { Int(ptb_canvas_failures(handle)) }
    /// Bytes the canvas holds: its pixel surfaces plus the images it uploaded.
    var bytesHeld: Int { Int(ptb_canvas_bytes(handle)) }

    private static let logLock = NSLock()
    nonisolated(unsafe) private static var logged = Set<String>()
    private static func logOnce(_ line: String) {
        logLock.lock()
        let first = logged.count < 16 && logged.insert(line).inserted
        logLock.unlock()
        if first { AppLog.write(line) }
    }

    // MARK: state

    func saveState() { ptb_canvas_save(handle) }
    func restoreState() { ptb_canvas_restore(handle) }
    func translate(x: CGFloat, y: CGFloat) { ptb_canvas_translate(handle, Double(x), Double(y)) }
    func scale(x: CGFloat, y: CGFloat) { ptb_canvas_scale(handle, Double(x), Double(y)) }
    func rotate(by radians: CGFloat) { ptb_canvas_rotate(handle, Double(radians)) }
    func setAlpha(_ a: CGFloat) { ptb_canvas_set_alpha(handle, Double(a)) }

    func setBlend(_ b: PlazaCanvasBlend) {
        switch b {
        case .normal: ptb_canvas_set_blend(handle, 0)
        case .multiply: ptb_canvas_set_blend(handle, 1)
        case .sourceAtop: ptb_canvas_set_blend(handle, 2)
        }
    }

    func setFillColor(_ c: PlazaColor) { ptb_canvas_set_fill(handle, c.red, c.green, c.blue, c.alpha) }
    func setStrokeColor(_ c: PlazaColor) { ptb_canvas_set_stroke(handle, c.red, c.green, c.blue, c.alpha) }

    /// What CoreGraphics writes for `CGColor(gray:)` into an RGB canvas, measured by Task 1 (`fill-gray.json`): gray 0.55 -> 158,
    /// not 140. Between the golden's steps (every 0.05) the byte is interpolated.
    static let grayBytes: [Double] = [0, 14, 34, 51, 66, 81, 95, 108, 121, 134, 146, 158, 169, 181, 192, 203, 214, 224, 235, 245, 255]

    static func deviceGrayByte(_ gray: Double) -> Double {
        let g = min(1, max(0, gray)) * 20
        let i = min(19, Int(g.rounded(.down)))
        let t = g - Double(i)
        return (grayBytes[i] + (grayBytes[i + 1] - grayBytes[i]) * t).rounded()
    }

    func setFillGray(_ gray: CGFloat) {
        let v = Self.deviceGrayByte(Double(gray)) / 255
        ptb_canvas_set_fill(handle, v, v, v, 1)
    }

    func setLineWidth(_ w: CGFloat) { ptb_canvas_set_line_width(handle, Double(w)) }

    func setLineJoin(_ j: PlazaLineJoin) {
        switch j {
        case .miter: ptb_canvas_set_line_join(handle, 0)
        case .round: ptb_canvas_set_line_join(handle, 1)
        }
    }

    func setShadow(_ s: PlazaShadow?) {
        if let s {
            ptb_canvas_set_shadow(handle, 1, Double(s.offset.width), Double(s.offset.height), Double(s.blur),
                                  s.color.red, s.color.green, s.color.blue, s.color.alpha)
        } else {
            ptb_canvas_set_shadow(handle, 0, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    func setShouldAntialias(_ on: Bool) { ptb_canvas_set_should_antialias(handle, on ? 1 : 0) }
    func setAllowsAntialiasing(_ on: Bool) { ptb_canvas_set_allows_antialiasing(handle, on ? 1 : 0) }
    func setShouldSmoothFonts(_ on: Bool) { ptb_canvas_set_should_smooth_fonts(handle, on ? 1 : 0) }
    func setInterpolationNone() { ptb_canvas_set_interpolation_none(handle) }

    func setTextDrawingMode(_ m: PlazaTextDrawingMode) {
        switch m {
        case .fill: ptb_canvas_set_text_stroke(handle, 0)
        case .stroke: ptb_canvas_set_text_stroke(handle, 1)
        }
    }

    // MARK: paths

    private struct Ops {
        var kinds: [UInt8] = []
        var coords: [Double] = []

        mutating func add(_ kind: UInt8, _ p: CGPoint = .zero, _ c1: CGPoint = .zero, _ c2: CGPoint = .zero) {
            kinds.append(kind)
            coords += [Double(p.x), Double(p.y), Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y)]
        }

        init(_ path: PlazaPath) {
            for e in path.elements {
                switch e {
                case .move(let p): add(0, p)
                case .line(let p): add(1, p)
                case .close: add(3)
                }
            }
        }

        init(_ elements: [PlazaCurveElement]) {
            for e in elements {
                switch e {
                case .move(let p): add(0, p)
                case .line(let p): add(1, p)
                case .curve(let p, let c1, let c2): add(2, p, c1, c2)
                case .close: add(3)
                }
            }
        }

        func use<R>(_ body: (UnsafePointer<UInt8>, Int32, UnsafePointer<Double>) -> R) -> R? {
            guard !kinds.isEmpty else { return nil }
            return kinds.withUnsafeBufferPointer { k in
                coords.withUnsafeBufferPointer { c in body(k.baseAddress!, Int32(kinds.count), c.baseAddress!) }
            }
        }
    }

    private func fill(_ ops: Ops) { _ = ops.use { ptb_canvas_fill_path(handle, $0, $1, $2) } }
    private func stroke(_ ops: Ops, lineWidth: CGFloat, cap: Int32) {
        _ = ops.use { ptb_canvas_stroke_path(handle, $0, $1, $2, Double(lineWidth), cap) }
    }
    private func clip(_ ops: Ops) { _ = ops.use { ptb_canvas_clip_path(handle, $0, $1, $2) } }

    private static func rounded(_ rect: CGRect, _ radius: CGFloat) -> Ops { Ops(PlazaContinuousCorners.roundedRect(rect, radius: radius)) }
    private static func uneven(_ rect: CGRect, _ radii: PlazaCornerRadii) -> Ops {
        Ops(PlazaContinuousCorners.unevenRoundedRect(rect, radii: radii))
    }

    // MARK: drawing

    func clip(to rect: CGRect) { ptb_canvas_clip_rect(handle, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)) }
    func fill(_ rect: CGRect) { ptb_canvas_fill_rect(handle, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)) }
    func fillEllipse(in rect: CGRect) {
        ptb_canvas_fill_ellipse(handle, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
    }
    func strokeEllipse(in rect: CGRect, lineWidth: CGFloat) {
        ptb_canvas_stroke_ellipse(handle, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height), Double(lineWidth))
    }

    func fillPath(_ path: PlazaPath) { fill(Ops(path)) }
    func strokePath(_ path: PlazaPath, lineWidth: CGFloat, cap: PlazaLineCap) { stroke(Ops(path), lineWidth: lineWidth, cap: cap == .round ? 1 : 0) }

    func clip(toRoundedRect rect: CGRect, radius: CGFloat) { clip(Self.rounded(rect, radius)) }
    func fillRoundedRect(_ rect: CGRect, radius: CGFloat) { fill(Self.rounded(rect, radius)) }
    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat) { stroke(Self.rounded(rect, radius), lineWidth: lineWidth, cap: 0) }

    func clip(toUnevenRoundedRect rect: CGRect, radii: PlazaCornerRadii) { clip(Self.uneven(rect, radii)) }
    func fillUnevenRoundedRect(_ rect: CGRect, radii: PlazaCornerRadii) { fill(Self.uneven(rect, radii)) }
    func strokeUnevenRoundedRect(_ rect: CGRect, radii: PlazaCornerRadii, lineWidth: CGFloat) {
        stroke(Self.uneven(rect, radii), lineWidth: lineWidth, cap: 0)
    }

    func draw(_ image: PlazaImage, in rect: CGRect) {
        guard let id = imageID(image) else { return }
        _ = ptb_canvas_draw_image(handle, id, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
    }

    private func imageID(_ image: PlazaImage) -> UInt32? {
        if let known = uploaded[ObjectIdentifier(image)] { return known.id }
        let bitmap = image.pixels
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        var id: UInt32 = 0
        let opaque: Int32 = bitmap.alpha == .noneSkipLast ? 1 : 0
        let code = bitmap.bytes.withUnsafeBufferPointer {
            ptb_canvas_upload_image(handle, UInt32(bitmap.width), UInt32(bitmap.height), $0.baseAddress, opaque, &id)
        }
        guard code >= 0 else {
            Self.logOnce("plaza canvas image upload failed: \(WinPlazaCodecs.lastError())")
            return nil
        }
        uploaded[ObjectIdentifier(image)] = (image, id)
        return id
    }

    // MARK: text (Task 9)

    func draw(_ line: PlazaTextLine, at textPosition: CGPoint) { Self.logOnce("plaza canvas: text drawing unavailable until the DirectWrite engine") }
    func draw(_ paragraph: PlazaParagraph, in rect: CGRect) { Self.logOnce("plaza canvas: text drawing unavailable until the DirectWrite engine") }
    func imageBounds(of line: PlazaTextLine) -> CGRect { .zero }

    // MARK: pixels

    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let rowBytes = width * 4
        buffer.withUnsafeMutableBufferPointer { p in
            guard ptb_canvas_read_pixels(handle, p.baseAddress) >= 0 else { return }
            body(p.baseAddress!, rowBytes)
            _ = ptb_canvas_write_pixels(handle, p.baseAddress)
        }
    }

    func makeImage() -> PlazaImage? {
        var bitmap = PlazaBitmap(width: width, height: height)
        bitmap.colorSpace = colorSpace
        let code = bitmap.bytes.withUnsafeMutableBufferPointer { ptb_canvas_read_pixels(handle, $0.baseAddress) }
        guard code >= 0 else { return nil }
        return PlazaImage(bitmap: bitmap, origin: ptb_canvas_drew_text(handle) != 0 ? .canvasWithText : .canvas)
    }
}
#endif
