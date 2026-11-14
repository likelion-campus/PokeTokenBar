import Foundation

/// Logs one line the first time it fires, then stays quiet (the stage 1 stub contract).
private final class PlazaLogOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let line: String
    private let sink: @Sendable (String) -> Void
    init(_ line: String, sink: @escaping @Sendable (String) -> Void) { self.line = line; self.sink = sink }
    func fire() {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { sink(line) }
    }
}

/// Headless graphics (Windows until stage 6, and the Mac checking the shared set). Canvases record their calls and
/// return a transparent image of their size; text is deterministic monospace; assets and codecs are unavailable
/// (nil / empty) and log once.
struct PlazaStubGraphics: PlazaGraphics {
    let text: any PlazaTextEngine = PlazaStubTextEngine()
    private let once: PlazaLogOnce

    /// `log` is injectable so a test can count lines without touching the real log.
    init(log: @escaping @Sendable (String) -> Void) {
        once = PlazaLogOnce("Plaza stub: bundled assets and image codecs unavailable", sink: log)
    }

    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
        guard width > 0, height > 0 else { return nil }
        return PlazaStubCanvas(width: width, height: height, colorSpace: colorSpace)
    }

    func assetURL(_ name: String, ext: String) -> URL? { once.fire(); return nil }
    func decodeImage(at url: URL) -> PlazaImage? { once.fire(); return nil }
    func decodeImage(_ data: Data) -> PlazaImage? { once.fire(); return nil }
    func decodeImageFrames(at url: URL) -> [PlazaImage] { once.fire(); return [] }
    func encodePNG(_ image: PlazaImage) -> Data? { once.fire(); return nil }
}

/// Records every call as one line of text; `makeImage` is always transparent (pixel writes go to a scratch buffer).
final class PlazaStubCanvas: PlazaCanvas {
    let width: Int, height: Int
    let colorSpace: PlazaColorSpace
    private(set) var calls: [String] = []

    init(width: Int, height: Int, colorSpace: PlazaColorSpace) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
    }

    private func record(_ call: String) { calls.append(call) }
    private static func f(_ v: CGFloat) -> String { String(describing: Double(v)) }
    private static func r(_ r: CGRect) -> String { "(\(f(r.minX)), \(f(r.minY)), \(f(r.width)), \(f(r.height)))" }
    private static func c(_ c: PlazaColor) -> String { "(\(c.red), \(c.green), \(c.blue), \(c.alpha))" }

    func saveState() { record("saveState") }
    func restoreState() { record("restoreState") }
    func translate(x: CGFloat, y: CGFloat) { record("translate \(Self.f(x)) \(Self.f(y))") }
    func scale(x: CGFloat, y: CGFloat) { record("scale \(Self.f(x)) \(Self.f(y))") }
    func rotate(by radians: CGFloat) { record("rotate \(Self.f(radians))") }
    func setAlpha(_ a: CGFloat) { record("alpha \(Self.f(a))") }
    func setBlend(_ b: PlazaCanvasBlend) { record("blend \(b)") }
    func setFillColor(_ c: PlazaColor) { record("fillColor \(Self.c(c))") }
    func setStrokeColor(_ c: PlazaColor) { record("strokeColor \(Self.c(c))") }
    func setLineWidth(_ w: CGFloat) { record("lineWidth \(Self.f(w))") }
    func setLineJoin(_ j: PlazaLineJoin) { record("lineJoin \(j)") }
    func setShadow(_ s: PlazaShadow?) {
        record(s.map { "shadow \(Self.f($0.offset.width)) \(Self.f($0.offset.height)) \(Self.f($0.blur)) \(Self.c($0.color))" } ?? "shadow off")
    }
    func setShouldAntialias(_ on: Bool) { record("shouldAntialias \(on)") }
    func setAllowsAntialiasing(_ on: Bool) { record("allowsAntialiasing \(on)") }
    func setShouldSmoothFonts(_ on: Bool) { record("shouldSmoothFonts \(on)") }
    func setInterpolationNone() { record("interpolation none") }
    func setTextDrawingMode(_ m: PlazaTextDrawingMode) { record("textMode \(m)") }
    func clip(to rect: CGRect) { record("clip \(Self.r(rect))") }
    func fill(_ rect: CGRect) { record("fill \(Self.r(rect))") }
    func fillEllipse(in rect: CGRect) { record("fillEllipse \(Self.r(rect))") }
    func draw(_ image: PlazaImage, in rect: CGRect) { record("image \(image.width)x\(image.height) \(Self.r(rect))") }
    func draw(_ line: PlazaTextLine, at textPosition: CGPoint) {
        record("line \(Self.text(line)) at \(Self.f(textPosition.x)) \(Self.f(textPosition.y))")
    }
    func draw(_ paragraph: PlazaParagraph, in rect: CGRect) {
        record("paragraph \((paragraph.native as! PlazaStubText).text.debugDescription) \(Self.r(rect))")
    }
    func imageBounds(of line: PlazaTextLine) -> CGRect {
        record("imageBounds \(Self.text(line))")
        return CGRect(x: 0, y: -line.descent, width: line.width, height: line.ascent + line.descent)
    }
    func withPixels(_ body: (_ bytes: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) {
        record("withPixels")
        var scratch = [UInt8](repeating: 0, count: width * height * 4)
        let rowBytes = width * 4
        scratch.withUnsafeMutableBufferPointer { body($0.baseAddress!, rowBytes) }   // makeCanvas never makes an empty one
    }
    func makeImage() -> PlazaImage? {
        record("makeImage")
        var bitmap = PlazaBitmap(width: width, height: height)
        bitmap.colorSpace = colorSpace
        return PlazaImage(bitmap: bitmap)
    }

    /// Text comes from `PlazaStubTextEngine` (the stub graphics' own `text`).
    private static func text(_ line: PlazaTextLine) -> String { (line.native as! PlazaStubText).text.debugDescription }
}

/// The stub engine's native line/paragraph: the text and the font size it was made with.
final class PlazaStubText: @unchecked Sendable {
    let text: String
    let size: CGFloat
    init(text: String, size: CGFloat) { self.text = text; self.size = size }
}

/// Deterministic monospace: every `Character` advances 0.6 × size; ascender 0.8 × size, descender −0.2 × size,
/// leading 0. Paragraphs break between characters (no word wrap).
struct PlazaStubTextEngine: PlazaTextEngine {
    static func size(_ font: PlazaFont) -> CGFloat {
        switch font {
        case .plaza(let s): s.points
        case .system(let size, _): size
        case .emoji(let size): size
        }
    }

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics {
        let s = Self.size(font)
        return PlazaFontMetrics(ascender: 0.8 * s, descender: -0.2 * s, leading: 0)
    }

    func line(_ text: String, font: PlazaFont) -> PlazaTextLine {
        Self.line(text, size: Self.size(font))
    }

    private static func line(_ text: String, size: CGFloat) -> PlazaTextLine {
        PlazaTextLine(width: 0.6 * size * CGFloat(text.count), ascent: 0.8 * size, descent: 0.2 * size, leading: 0,
                      native: PlazaStubText(text: text, size: size))
    }

    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? {
        let l = line.native as! PlazaStubText, e = ellipsis.native as! PlazaStubText
        if line.width <= width { return line }
        let room = width - ellipsis.width
        guard room >= 0 else { return nil }
        let kept = Int((room / (0.6 * l.size)).rounded(.down))
        return Self.line(String(l.text.prefix(kept)) + e.text, size: l.size)
    }

    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph {
        let size = Self.size(font)
        let advance = 0.6 * size, lineHeight = size   // ascender − descender + leading
        let count = text.count
        func perLine(_ width: CGFloat) -> Int { max(1, Int((width / advance).rounded(.down))) }
        func linesThatFit(_ height: CGFloat) -> Int { max(0, Int((height / lineHeight).rounded(.down))) }
        return PlazaParagraph(
            native: PlazaStubText(text: text, size: size),
            suggestedSize: { limit in
                let per = perLine(limit.width)
                let lines = min((count + per - 1) / per, linesThatFit(limit.height))
                guard lines > 0 else { return .zero }
                return CGSize(width: CGFloat(min(count, per)) * advance, height: CGFloat(lines) * lineHeight)
            },
            visibleLength: { size in
                let shown = min(count, perLine(size.width) * linesThatFit(size.height))
                return text.prefix(shown).utf16.count
            })
    }
}
