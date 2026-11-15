#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 8: the Direct2D / WIC canvas against CoreGraphics. Parity numbers are printed as `CANVAS-PARITY` lines; the
/// Windows renders and side-by-sides (Mac | Windows | difference x4) go to `PTB_CANVAS_OUT` when it is set (CI uploads it).
final class WindowsPlazaCanvasTests: XCTestCase {
    private let graphics = WinPlazaGraphics.shared

    // MARK: helpers

    private func canvas(_ w: Int, _ h: Int) throws -> WinPlazaCanvas {
        try XCTUnwrap(graphics.makeCanvas(width: w, height: h, colorSpace: .sRGB) as? WinPlazaCanvas, "a Direct2D canvas")
    }

    private func pixel(_ image: PlazaImage, _ x: Int, _ y: Int) -> PlazaRGBA { image.pixels[x, y] }

    private func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> PlazaColor {
        PlazaColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: a)
    }

    private func assertPixel(_ image: PlazaImage, _ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, _ a: Int, tol: Int = 0,
                             note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let p = pixel(image, x, y)
        let ok = abs(Int(p.r) - r) <= tol && abs(Int(p.g) - g) <= tol && abs(Int(p.b) - b) <= tol && abs(Int(p.a) - a) <= tol
        XCTAssertTrue(ok, "\(note) pixel (\(x), \(y)) = \(p.r),\(p.g),\(p.b),\(p.a), expected \(r),\(g),\(b),\(a) +-\(tol)", file: file, line: line)
    }

    struct Diff {
        var over1 = 0, over8 = 0, over64 = 0, maxDiff = 0, pixels = 0, firstBad = ""
        var line: String { "over1=\(over1) over8=\(over8) over64=\(over64) max=\(maxDiff) of \(pixels) px" }
    }

    private func diff(_ a: PlazaBitmap, _ b: PlazaBitmap) -> Diff {
        var d = Diff()
        guard a.width == b.width, a.height == b.height else { d.maxDiff = 255; d.firstBad = "size"; return d }
        d.pixels = a.width * a.height
        for i in 0..<d.pixels {
            var m = 0
            for c in 0..<4 { m = max(m, abs(Int(a.bytes[i * 4 + c]) - Int(b.bytes[i * 4 + c]))) }
            if m > 1 { d.over1 += 1 }
            if m > 8 { d.over8 += 1 }
            if m > 64 { d.over64 += 1 }
            if m > d.maxDiff { d.maxDiff = m }
            if m > 1, d.firstBad.isEmpty { d.firstBad = "(\(i % a.width), \(i / a.width))" }
        }
        return d
    }

    private func golden(_ path: String) throws -> PlazaBitmap {
        let data = try Data(contentsOf: PlazaParityGoldens.url(path))
        return try XCTUnwrap(graphics.decodeImage(data), path).pixels
    }

    private var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PTB_CANVAS_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ bitmap: PlazaBitmap, as name: String) {
        guard let dir = outputDirectory, let png = graphics.encodePNG(PlazaImage(bitmap: bitmap)) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }

    /// Mac | Windows | |difference| x 4, each blown up 4x, flattened on white.
    private func sideBySide(mac: PlazaBitmap, windows: PlazaBitmap) -> PlazaBitmap {
        let z = 4, gap = 4
        let w = mac.width * z, h = mac.height * z
        var out = PlazaBitmap(width: w * 3 + gap * 2, height: h, fill: PlazaRGBA(r: 90, g: 90, b: 90, a: 255))
        func flat(_ b: PlazaBitmap, _ x: Int, _ y: Int) -> PlazaRGBA {
            let p = b[x, y], k = 255 - Int(p.a)
            return PlazaRGBA(r: UInt8(min(255, Int(p.r) + k)), g: UInt8(min(255, Int(p.g) + k)), b: UInt8(min(255, Int(p.b) + k)), a: 255)
        }
        for y in 0..<h {
            for x in 0..<w {
                let sx = x / z, sy = y / z
                guard sx < windows.width, sy < windows.height else { continue }
                out[x, y] = flat(mac, sx, sy)
                out[w + gap + x, y] = flat(windows, sx, sy)
                let a = mac[sx, sy], b = windows[sx, sy]
                func d(_ p: UInt8, _ q: UInt8) -> UInt8 { UInt8(min(255, abs(Int(p) - Int(q)) * 4)) }
                out[2 * (w + gap) + x, y] = PlazaRGBA(r: d(a.r, b.r), g: d(a.g, b.g), b: d(a.b, b.b), a: 255)
            }
        }
        return out
    }

    // MARK: pixel format, origin

    func testPixelFormatAndWithPixelsAreRowTopRGBA() throws {
        let c = try canvas(4, 3)
        c.setFillColor(rgb(255, 0, 0)); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))          // bottom-left of the user space
        c.setFillColor(rgb(0, 0, 255, 0.5)); c.fill(CGRect(x: 3, y: 2, width: 1, height: 1))      // top-right
        var seenRowBytes = 0
        c.withPixels { bytes, bytesPerRow in
            seenRowBytes = bytesPerRow
            XCTAssertEqual([bytes[2 * bytesPerRow], bytes[2 * bytesPerRow + 1], bytes[2 * bytesPerRow + 2], bytes[2 * bytesPerRow + 3]], [255, 0, 0, 255], "red is R,G,B,A in the last row")
            let q = 3 * 4
            XCTAssertTrue(abs(Int(bytes[q + 2]) - 128) <= 1 && abs(Int(bytes[q + 3]) - 128) <= 1, "half-blue is premultiplied: \(bytes[q]),\(bytes[q + 1]),\(bytes[q + 2]),\(bytes[q + 3])")
            XCTAssertEqual(bytes[q], 0)
            bytes[4] = 200; bytes[7] = 255   // row 0, x = 1: R = 200, A = 255
        }
        XCTAssertEqual(seenRowBytes, 16)
        let image = try XCTUnwrap(c.makeImage())
        XCTAssertEqual(image.width, 4); XCTAssertEqual(image.height, 3)
        assertPixel(image, 1, 0, 200, 0, 0, 255, note: "written through withPixels")
        assertPixel(image, 0, 2, 255, 0, 0, 255, note: "survives the write-back")
        XCTAssertEqual(pixel(image, 0, 0), PlazaRGBA(r: 0, g: 0, b: 0, a: 0))
        XCTAssertEqual(c.failureCount, 0)
    }

    func testMakeImageOrigin() throws {
        let c = try canvas(8, 6)
        c.setFillColor(rgb(10, 200, 30)); c.fill(CGRect(x: 0, y: 5, width: 1, height: 1))        // user top-left = image pixel (0, 0)
        let image = try XCTUnwrap(c.makeImage())
        XCTAssertEqual(image.origin, .canvas)
        XCTAssertEqual(image.pixels.alpha, .premultipliedLast)
        assertPixel(image, 0, 0, 10, 200, 30, 255)
        assertPixel(image, 0, 5, 0, 0, 0, 0)
        assertPixel(image, 7, 0, 0, 0, 0, 0)
    }

    func testFillGrayMatchesTheMacGolden() throws {
        let gray = try PlazaParityGoldens.load(PlazaFillGrayGolden.self, "fill-gray.json")
        for space in [PlazaColorSpace.deviceRGB, .sRGB] {
            let table = space == .deviceRGB ? gray.deviceRGB : gray.sRGB
            for (i, g) in gray.steps.enumerated() {
                let c = try XCTUnwrap(graphics.makeCanvas(width: 1, height: 1, colorSpace: space))
                c.setFillGray(CGFloat(g))
                c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                var px: [Int] = []
                c.withPixels { b, _ in px = (0..<4).map { Int(b[$0]) } }
                XCTAssertEqual(px, table[i], "gray \(g)")
            }
        }
        XCTAssertEqual(WinPlazaCanvas.deviceGrayByte(0.55), 158)
    }

    // MARK: state and transforms

    func testStateStackRestoresClipsColourAndTransform() throws {
        let c = try canvas(20, 10)
        c.setFillColor(rgb(255, 0, 0))
        c.saveState()
        c.clip(to: CGRect(x: 0, y: 0, width: 5, height: 10))
        c.translate(x: 10, y: 0)
        c.setFillColor(rgb(0, 0, 255))
        c.saveState()
        c.clip(to: CGRect(x: -10, y: 0, width: 2, height: 10))      // user x -10..-8 = device 0..2
        c.fill(CGRect(x: -10, y: 0, width: 20, height: 10))
        c.restoreState()                                            // the inner clip goes, the outer stays
        c.fill(CGRect(x: -10, y: 0, width: 4, height: 2))           // device x 0..4 inside the outer clip, rows 8..10
        c.restoreState()                                            // clip, translate and blue are all gone
        c.fill(CGRect(x: 15, y: 4, width: 3, height: 1))            // red again, no clip, no translate
        let image = try XCTUnwrap(c.makeImage())
        assertPixel(image, 0, 2, 0, 0, 255, 255, note: "inner clip")
        assertPixel(image, 3, 2, 0, 0, 0, 0, note: "outside the inner clip, inside the outer: not filled by the first fill")
        assertPixel(image, 3, 9, 0, 0, 255, 255, note: "second fill under the outer clip")
        assertPixel(image, 5, 9, 0, 0, 0, 0, note: "outer clip edge")
        assertPixel(image, 16, 5, 255, 0, 0, 255, note: "restored fill colour and transform")
        XCTAssertEqual(c.failureCount, 0)
    }

    func testTransformOrderIsCoreGraphics() throws {
        let a = try canvas(40, 10)   // translate then scale: the unit square lands at x = 10 ... 12
        a.setFillColor(rgb(255, 0, 0)); a.translate(x: 10, y: 0); a.scale(x: 2, y: 2)
        a.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let ia = try XCTUnwrap(a.makeImage())
        assertPixel(ia, 10, 9, 255, 0, 0, 255); assertPixel(ia, 11, 8, 255, 0, 0, 255)
        assertPixel(ia, 9, 9, 0, 0, 0, 0); assertPixel(ia, 12, 9, 0, 0, 0, 0)
        let b = try canvas(40, 10)   // scale then translate: the translation is scaled, x = 20 ... 22
        b.setFillColor(rgb(255, 0, 0)); b.scale(x: 2, y: 2); b.translate(x: 10, y: 0)
        b.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let ib = try XCTUnwrap(b.makeImage())
        assertPixel(ib, 20, 9, 255, 0, 0, 255); assertPixel(ib, 21, 8, 255, 0, 0, 255)
        assertPixel(ib, 19, 9, 0, 0, 0, 0); assertPixel(ib, 22, 9, 0, 0, 0, 0)
        let r = try canvas(20, 20)   // a quarter turn counter-clockwise (y up): the point (5, 0) goes to (0, 5)
        r.setFillColor(rgb(255, 0, 0)); r.translate(x: 10, y: 10); r.rotate(by: .pi / 2)
        r.fill(CGRect(x: 4, y: -1, width: 2, height: 2))
        let ir = try XCTUnwrap(r.makeImage())
        assertPixel(ir, 9, 4, 255, 0, 0, 255, tol: 1, note: "rotated counter-clockwise: up on the screen")
        assertPixel(ir, 14, 9, 0, 0, 0, 0)
    }

    func testAlphaIsPerCallAndRestored() throws {
        let c = try canvas(6, 2)
        c.setFillColor(rgb(255, 0, 0))
        c.saveState(); c.setAlpha(0.5); c.fill(CGRect(x: 0, y: 0, width: 2, height: 2)); c.restoreState()
        c.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        c.setFillColor(rgb(255, 0, 0, 0.5)); c.setAlpha(0.5); c.fill(CGRect(x: 4, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(c.makeImage())
        assertPixel(image, 0, 0, 128, 0, 0, 128, tol: 1, note: "alpha 0.5")
        assertPixel(image, 2, 0, 255, 0, 0, 255, note: "restored to 1")
        assertPixel(image, 4, 0, 64, 0, 0, 64, tol: 1, note: "colour alpha x call alpha")
    }

    // MARK: blends (CoreGraphics' premultiplied formulas)

    private func expectedBlend(_ mode: PlazaCanvasBlend, src: (Double, Double, Double), alpha sa: Double, dst: (Double, Double, Double), dstAlpha da: Double) -> [Int] {
        func channel(_ s: Double, _ d: Double) -> Double {
            let sp = s * sa, dp = d * da
            switch mode {
            case .normal: return sp + dp * (1 - sa)
            case .multiply: return sp * (1 - da) + dp * (1 - sa) + sp * dp
            case .sourceAtop: return sp * da + dp * (1 - sa)
            }
        }
        let ra = mode == .sourceAtop ? da : sa + da * (1 - sa)
        return [Int((channel(src.0, dst.0) * 255).rounded()), Int((channel(src.1, dst.1) * 255).rounded()),
                Int((channel(src.2, dst.2) * 255).rounded()), Int((ra * 255).rounded())]
    }

    func testBlendsMatchCoreGraphicsFormulas() throws {
        let bg = (100.0 / 255, 150.0 / 255, 200.0 / 255)
        let fg = (1.0, 128.0 / 255, 0.0)
        for mode in [PlazaCanvasBlend.normal, .multiply, .sourceAtop] {
            for (alpha, bgAlpha) in [(1.0, 1.0), (0.5, 1.0), (0.5, 0.5), (0.7, 0.0)] {
                let c = try canvas(2, 1)
                if bgAlpha > 0 { c.setFillColor(rgb(100, 150, 200, bgAlpha)); c.fill(CGRect(x: 0, y: 0, width: 2, height: 1)) }
                c.setBlend(mode); c.setAlpha(CGFloat(alpha)); c.setFillColor(rgb(255, 128, 0))
                c.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
                let image = try XCTUnwrap(c.makeImage())
                let want = expectedBlend(mode, src: fg, alpha: alpha, dst: bg, dstAlpha: bgAlpha)
                // the background was stored premultiplied by its own alpha, so the formula's destination is that premultiplied value
                assertPixel(image, 0, 0, want[0], want[1], want[2], want[3], tol: 2, note: "\(mode) alpha \(alpha) on bg alpha \(bgAlpha):")
                XCTAssertEqual(c.failureCount, 0)
            }
        }
    }

    func testBlendIsClippedAndCoveredByTheClip() throws {
        let c = try canvas(10, 4)
        c.setFillColor(rgb(100, 100, 100)); c.fill(CGRect(x: 0, y: 0, width: 10, height: 4))
        c.saveState(); c.clip(to: CGRect(x: 2, y: 0, width: 3, height: 4)); c.setBlend(.multiply); c.setFillColor(rgb(0, 0, 0))
        c.fill(CGRect(x: 0, y: 0, width: 10, height: 4)); c.restoreState()
        let image = try XCTUnwrap(c.makeImage())
        assertPixel(image, 1, 1, 100, 100, 100, 255); assertPixel(image, 2, 1, 0, 0, 0, 255)
        assertPixel(image, 4, 1, 0, 0, 0, 255); assertPixel(image, 5, 1, 100, 100, 100, 255)
    }

    // MARK: strokes

    func testStrokesAreCentredOnThePath() throws {
        let line = PlazaPath(points: [CGPoint(x: 5, y: 10), CGPoint(x: 25, y: 10)])
        let a = try canvas(30, 30)   // width 4 on y = 10: user rows 8 ... 12 = device rows 18 ... 22
        a.setStrokeColor(rgb(0, 0, 0)); a.strokePath(line, lineWidth: 4, cap: .butt)
        let ia = try XCTUnwrap(a.makeImage())
        for y in 18..<22 { assertPixel(ia, 15, y, 0, 0, 0, 255, note: "inside") }
        assertPixel(ia, 15, 17, 0, 0, 0, 0); assertPixel(ia, 15, 22, 0, 0, 0, 0)
        assertPixel(ia, 4, 19, 0, 0, 0, 0, note: "butt cap ends at x = 5"); assertPixel(ia, 5, 19, 0, 0, 0, 255)
        let b = try canvas(30, 30)   // width 1 on a pixel boundary: two half rows; on a half: one full row
        b.setStrokeColor(rgb(0, 0, 0)); b.strokePath(line, lineWidth: 1, cap: .butt)
        let ib = try XCTUnwrap(b.makeImage())
        assertPixel(ib, 15, 19, 0, 0, 0, 128, tol: 2, note: "upper half"); assertPixel(ib, 15, 20, 0, 0, 0, 128, tol: 2, note: "lower half")
        let c = try canvas(30, 30)
        c.setStrokeColor(rgb(0, 0, 0)); c.strokePath(PlazaPath(points: [CGPoint(x: 5, y: 10.5), CGPoint(x: 25, y: 10.5)]), lineWidth: 1, cap: .butt)
        assertPixel(try XCTUnwrap(c.makeImage()), 15, 19, 0, 0, 0, 255, note: "a half-pixel line is one full row")
        let e = try canvas(40, 40)
        e.setStrokeColor(rgb(0, 0, 0)); e.strokeEllipse(in: CGRect(x: 5, y: 5, width: 30, height: 30), lineWidth: 4)
        let ie = try XCTUnwrap(e.makeImage())
        assertPixel(ie, 20, 5, 0, 0, 0, 255, note: "ring bottom (device row 34..35 is user y 5..6 +-2)")
        assertPixel(ie, 20, 20, 0, 0, 0, 0, note: "ring centre empty")
    }

    func testCapsAndJoins() throws {
        let line = PlazaPath(points: [CGPoint(x: 10, y: 10), CGPoint(x: 25, y: 10)])
        for (cap, filled) in [(PlazaLineCap.butt, false), (.round, true)] {
            let c = try canvas(40, 20)
            c.setStrokeColor(rgb(0, 0, 0)); c.strokePath(line, lineWidth: 8, cap: cap)
            let image = try XCTUnwrap(c.makeImage())
            XCTAssertEqual(pixel(image, 7, 9).a > 128, filled, "cap \(cap)")
        }
        let corner = PlazaPath(points: [CGPoint(x: 5, y: 15), CGPoint(x: 20, y: 15), CGPoint(x: 20, y: 30)])   // outer corner up-right?
        var outer: [Int: UInt8] = [:]
        for (join, key) in [(PlazaLineJoin.miter, 0), (.round, 1)] {
            let c = try canvas(40, 40)
            c.setStrokeColor(rgb(0, 0, 0)); c.setLineJoin(join); c.strokePath(corner, lineWidth: 6, cap: .butt)
            let image = try XCTUnwrap(c.makeImage())
            outer[key] = pixel(image, 22, 27).a      // user (22.5, 12.5): the square corner of a miter, outside the round
        }
        XCTAssertEqual(outer[0], 255, "miter fills the square corner")
        XCTAssertEqual(outer[1], 0, "round join stays inside the circle")
    }

    // MARK: antialiasing, interpolation

    func testAliasedVersusAntialiased() throws {
        func alphas(_ aa: Bool) throws -> Set<UInt8> {
            let c = try canvas(40, 30)
            c.setShouldAntialias(aa)
            c.setFillColor(rgb(0, 0, 0)); c.fillEllipse(in: CGRect(x: 2.3, y: 2.6, width: 33.1, height: 24.2))
            let image = try XCTUnwrap(c.makeImage())
            return Set(image.pixels.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element))
        }
        XCTAssertTrue(try alphas(false).isSubset(of: [0, 255]), "aliased fills have only 0 and 255")
        XCTAssertGreaterThan(try alphas(true).count, 4, "antialiased has partial coverage")
        let c = try canvas(40, 30)
        c.setAllowsAntialiasing(false)   // CG: both flags must be on
        c.setFillColor(rgb(0, 0, 0)); c.fillEllipse(in: CGRect(x: 2.3, y: 2.6, width: 33.1, height: 24.2))
        XCTAssertTrue(Set(try XCTUnwrap(c.makeImage()).pixels.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element)).isSubset(of: [0, 255]))
    }

    func testNearestVersusDefaultInterpolation() throws {
        var checker = PlazaBitmap(width: 2, height: 2)
        checker[0, 0] = PlazaRGBA(r: 255, g: 255, b: 255, a: 255); checker[1, 1] = checker[0, 0]
        checker[1, 0] = PlazaRGBA(r: 0, g: 0, b: 0, a: 255); checker[0, 1] = checker[1, 0]
        let image = PlazaImage(bitmap: checker)
        let n = try canvas(8, 8)
        n.setInterpolationNone(); n.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = try XCTUnwrap(n.makeImage()).pixels
        for y in 0..<8 { for x in 0..<8 {
            let want: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 255 : 0
            XCTAssertEqual(out[x, y].r, want, "nearest (\(x), \(y))")
        } }
        let d = try canvas(8, 8)
        d.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let smooth = try XCTUnwrap(d.makeImage()).pixels
        XCTAssertTrue(smooth.bytes.enumerated().contains { $0.offset % 4 == 0 && $0.element != 0 && $0.element != 255 }, "default interpolation blends")
        // the state is restored with the stack
        let s = try canvas(8, 8)
        s.saveState(); s.setInterpolationNone(); s.restoreState()
        s.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(try XCTUnwrap(s.makeImage()).pixels, smooth)
    }

    func testImageUprightAndFromEverySource() throws {
        var b = PlazaBitmap(width: 2, height: 2)
        b[0, 0] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255)   // top-left red
        b[1, 0] = PlazaRGBA(r: 0, g: 255, b: 0, a: 255)
        b[0, 1] = PlazaRGBA(r: 0, g: 0, b: 255, a: 255)
        let image = PlazaImage(bitmap: b)
        let c = try canvas(4, 4)
        c.setInterpolationNone(); c.draw(image, in: CGRect(x: 1, y: 1, width: 2, height: 2))
        let out = try XCTUnwrap(c.makeImage())
        assertPixel(out, 1, 1, 255, 0, 0, 255, note: "upright: top-left stays top-left"); assertPixel(out, 2, 1, 0, 255, 0, 255)
        assertPixel(out, 1, 2, 0, 0, 255, 255); assertPixel(out, 2, 2, 0, 0, 0, 0)
        // from another canvas
        let other = try canvas(4, 4)
        other.setInterpolationNone(); other.draw(try XCTUnwrap(c.makeImage()), in: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(diff(try XCTUnwrap(other.makeImage()).pixels, out.pixels).over1, 0)
        // a cropped image, a patterned (partly transparent) one at 1:1
        let pattern = PlazaImage(bitmap: PlazaTestImages.patterned(width: 16, height: 12))
        let p = try canvas(16, 12)
        p.setInterpolationNone(); p.draw(pattern, in: CGRect(x: 0, y: 0, width: 16, height: 12))
        XCTAssertLessThanOrEqual(diff(try XCTUnwrap(p.makeImage()).pixels, pattern.pixels).maxDiff, 1, "1:1 copy of a translucent image")
        let crop = try XCTUnwrap(pattern.cropping(to: PlazaPixelRect(x: 4, y: 3, width: 6, height: 5)))
        let q = try canvas(6, 5)
        q.setInterpolationNone(); q.draw(crop, in: CGRect(x: 0, y: 0, width: 6, height: 5))
        XCTAssertLessThanOrEqual(diff(try XCTUnwrap(q.makeImage()).pixels, crop.pixels).maxDiff, 1)
    }

    func testDecodedBundledArtDrawsAsItself() throws {
        guard ProcessInfo.processInfo.environment[WinPlazaAssets.environmentKey] != nil || ProcessInfo.processInfo.environment["CI"] != nil else {
            throw XCTSkip("needs the bundled art")
        }
        for (name, ext) in [("plaza-ice-gloss", "png"), ("plaza-water-balloon", "png"), ("plaza-ice-cracks", "png")] {
            let url = try XCTUnwrap(graphics.assetURL(name, ext: ext), name)
            let art = try XCTUnwrap(graphics.decodeImage(at: url), name)
            let c = try canvas(art.width, art.height)
            c.setInterpolationNone(); c.draw(art, in: CGRect(x: 0, y: 0, width: art.width, height: art.height))
            let d = diff(try XCTUnwrap(c.makeImage()).pixels, art.pixels)
            print("CANVAS-DECODED \(name) \(d.line)")
            XCTAssertLessThanOrEqual(d.maxDiff, 1, "\(name) drawn 1:1 is the decoded pixels")
        }
    }

    // MARK: paths, corners

    func testPathFillIsWindingNotEvenOdd() throws {
        var star = PlazaPath()
        for i in 0..<5 {
            let a = Double(i) * 4 * Double.pi / 5 + Double.pi / 2
            let p = CGPoint(x: 20 + 16 * CGFloat(cos(a)), y: 20 + 16 * CGFloat(sin(a)))
            if i == 0 { star.move(to: p) } else { star.line(to: p) }
        }
        star.close()
        let c = try canvas(40, 40)
        c.setFillColor(rgb(0, 0, 0)); c.fillPath(star)
        assertPixel(try XCTUnwrap(c.makeImage()), 20, 19, 0, 0, 0, 255, note: "the pentagram's centre is inside by winding (even-odd would leave a hole)")
    }

    func testOpenPathFillsAsIfClosedAndZeroLengthSegmentsAreHarmless() throws {
        let c = try canvas(10, 10)
        c.setFillColor(rgb(0, 0, 0))
        c.fillPath(PlazaPath(points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 1), CGPoint(x: 9, y: 9)]))
        c.fillPath(PlazaPath(points: [CGPoint(x: 2, y: 2)]))
        XCTAssertEqual(c.failureCount, 0)
        assertPixel(try XCTUnwrap(c.makeImage()), 7, 8, 0, 0, 0, 255, note: "inside the triangle (user 7.5, 1.5)")
    }

    private func flatten(_ elements: [PlazaCurveElement]) -> [[CGPoint]] {
        var polygons: [[CGPoint]] = [], current: [CGPoint] = []
        for e in elements {
            switch e {
            case .move(let p): if current.count > 2 { polygons.append(current) }; current = [p]
            case .line(let p): current.append(p)
            case .curve(let p, let c1, let c2):
                let p0 = current.last ?? p
                for i in 1...32 {
                    let t = CGFloat(i) / 32, u = 1 - t
                    current.append(CGPoint(x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                                           y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y))
                }
            case .close: if current.count > 2 { polygons.append(current) }; current = []
            }
        }
        if current.count > 2 { polygons.append(current) }
        return polygons
    }

    private func winding(_ polygons: [[CGPoint]], _ x: CGFloat, _ y: CGFloat) -> Int {
        var w = 0
        for poly in polygons {
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if a.y <= y {
                    if b.y > y, (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) > 0 { w += 1 }
                } else if b.y <= y, (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) < 0 { w -= 1 }
            }
        }
        return w
    }

    /// Alpha plane (0...255 per device pixel, row 0 at the top) of a user-space outline, by 8x8 supersampling.
    private func referenceAlpha(_ polygons: [[CGPoint]], width: Int, height: Int) -> [Int] {
        var out = [Int](repeating: 0, count: width * height)
        let n = 8
        for py in 0..<height {
            for px in 0..<width {
                var inside = 0
                for sy in 0..<n { for sx in 0..<n {
                    let x = CGFloat(px) + (CGFloat(sx) + 0.5) / CGFloat(n)
                    let y = CGFloat(height - py - 1) + (CGFloat(sy) + 0.5) / CGFloat(n)
                    if winding(polygons, x, y) != 0 { inside += 1 }
                } }
                out[py * width + px] = inside * 255 / (n * n)
            }
        }
        return out
    }

    private func circularRoundedRect(_ rect: CGRect, radius r: CGFloat) -> [PlazaCurveElement] {
        var pts: [CGPoint] = []
        let corners: [(CGPoint, Double)] = [(CGPoint(x: rect.maxX - r, y: rect.minY + r), -90), (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0),
                                            (CGPoint(x: rect.minX + r, y: rect.maxY - r), 90), (CGPoint(x: rect.minX + r, y: rect.minY + r), 180)]
        for (center, start) in corners {
            for i in 0...16 {
                let a = (start + 90 * Double(i) / 16) * Double.pi / 180
                pts.append(CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a))))
            }
        }
        return [.move(pts[0])] + pts.dropFirst().map { .line($0) } + [.close]
    }

    private func alphaError(_ image: PlazaImage, _ reference: [Int]) -> (sum: Int, max: Int) {
        var sum = 0, worst = 0
        for i in 0..<reference.count {
            let d = abs(Int(image.pixels.bytes[i * 4 + 3]) - reference[i])
            sum += d; worst = max(worst, d)
        }
        return (sum, worst)
    }

    func testContinuousCornersFollowTheSharedCurveNotACircle() throws {
        let w = 70, h = 50
        let rect = CGRect(x: 3, y: 3, width: 60, height: 40)
        let c = try canvas(w, h)
        c.setFillColor(rgb(0, 0, 0)); c.fillRoundedRect(rect, radius: 16)
        let image = try XCTUnwrap(c.makeImage())
        let continuous = referenceAlpha(flatten(PlazaContinuousCorners.roundedRect(rect, radius: 16)), width: w, height: h)
        let circular = referenceAlpha(flatten(circularRoundedRect(rect, radius: 16)), width: w, height: h)
        let near = alphaError(image, continuous), far = alphaError(image, circular)
        print("CANVAS-CORNERS rounded r16: vs continuous sum=\(near.sum) max=\(near.max); vs circular sum=\(far.sum) max=\(far.max)")
        XCTAssertLessThanOrEqual(near.max, 40)
        XCTAssertLessThan(near.sum * 2, far.sum, "closer to the continuous curve than to a circle")
        // uneven radii, flipped into canvas coordinates by the shared code
        let radii = PlazaCornerRadii(topLeading: 18, bottomLeading: 0, bottomTrailing: 10, topTrailing: 24)
        let u = try canvas(w, h)
        u.setFillColor(rgb(0, 0, 0)); u.fillUnevenRoundedRect(rect, radii: radii)
        let ref = referenceAlpha(flatten(PlazaContinuousCorners.unevenRoundedRect(rect, radii: radii)), width: w, height: h)
        let e = alphaError(try XCTUnwrap(u.makeImage()), ref)
        print("CANVAS-CORNERS uneven: vs shared curve sum=\(e.sum) max=\(e.max)")
        XCTAssertLessThanOrEqual(e.max, 40)
        // "top" is the visual top: the 24 point corner is top-right, the square one bottom-left
        let img = try XCTUnwrap(u.makeImage())
        XCTAssertEqual(pixel(img, 62, 6).a, 0, "top-right corner is cut away")
        XCTAssertEqual(pixel(img, 4, 42).a, 255, "bottom-left corner is square")
    }

    func testSharedCornerPointsAreTheMacGolden() throws {
        let golden = try PlazaParityGoldens.load(PlazaCornersGolden.self, "corners.json")
        for c in golden.cases {
            let rect = CGRect(x: c.rect[0], y: c.rect[1], width: c.rect[2], height: c.rect[3])
            let ours: [PlazaCurveElement] = c.kind == "rounded"
                ? PlazaContinuousCorners.roundedRect(rect, radius: CGFloat(c.radii[0]))
                : PlazaContinuousCorners.unevenRoundedRect(rect, radii: PlazaCornerRadii(topLeading: CGFloat(c.radii[0]), bottomLeading: CGFloat(c.radii[1]),
                                                                                       bottomTrailing: CGFloat(c.radii[2]), topTrailing: CGFloat(c.radii[3])))
            let a = PlazaCornersGolden.flatten(ours), b = c.elements
            XCTAssertEqual(a.count, b.count, "\(c.kind) \(c.rect) \(c.radii)")
            for (x, y) in zip(a, b) where x.count == y.count {
                for (p, q) in zip(x, y) where abs(p - q) > 1e-3 { XCTFail("\(c.kind) \(c.rect) \(c.radii): \(x) vs \(y)"); return }
            }
        }
    }

    // MARK: shadow

    func testShadowOffsetBlurAndColour() throws {
        let c = try canvas(40, 40)   // device rect rows 10..20 / cols 10..20; shadow 4 right and 4 down
        c.setShadow(PlazaShadow(offset: CGSize(width: 4, height: -4), blur: 0, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        c.setFillColor(rgb(255, 0, 0)); c.fill(CGRect(x: 10, y: 20, width: 10, height: 10))
        let hard = try XCTUnwrap(c.makeImage())
        assertPixel(hard, 12, 12, 255, 0, 0, 255, note: "shape on top")
        assertPixel(hard, 22, 22, 0, 0, 0, 255, note: "shadow below and to the right")
        assertPixel(hard, 22, 12, 0, 0, 0, 0, note: "no shadow above the offset rows"); assertPixel(hard, 12, 22, 0, 0, 0, 0)
        let b = try canvas(60, 60)
        b.setShadow(PlazaShadow(offset: .zero, blur: 8, color: PlazaColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)))
        b.setFillColor(rgb(255, 255, 255)); b.fill(CGRect(x: 20, y: 20, width: 20, height: 20))
        let blurred = try XCTUnwrap(b.makeImage())
        var mass = 0
        for y in 0..<60 { for x in 0..<60 where !(x >= 20 && x < 40 && y >= 20 && y < 40) { mass += Int(pixel(blurred, x, y).a) } }
        let outside = mass
        XCTAssertGreaterThan(outside, 0, "the blur spreads outside the shape")
        let ring = pixel(blurred, 19, 30)
        XCTAssertTrue(ring.a > 0 && ring.a < 128 && ring.r == 0 && ring.b > 0, "edge of the halo is translucent blue: \(ring)")
        assertPixel(blurred, 30, 30, 255, 255, 255, 255, note: "shape stays opaque")
        // off again
        let d = try canvas(20, 20)
        d.setShadow(PlazaShadow(offset: CGSize(width: 3, height: -3), blur: 2, color: PlazaColor.black))
        d.setShadow(nil)
        d.setFillColor(rgb(255, 0, 0)); d.fill(CGRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(pixel(try XCTUnwrap(d.makeImage()), 12, 17).a, 0)
    }

    // MARK: parity with the Mac

    func testShapesLookLikeTheMac() throws {
        var lines: [String] = []
        for shape in PlazaCanvasShapes.cases {
            let mac = try golden("canvas-shapes/\(shape.name).png")
            let image = try XCTUnwrap(PlazaCanvasShapes.render(shape, graphics: graphics), shape.name)
            let d = diff(mac, image.pixels)
            let line = "CANVAS-PARITY \(shape.name) \(shape.exact ? "exact" : "aa"): \(d.line)\(d.firstBad.isEmpty ? "" : " first=\(d.firstBad)")"
            print(line); lines.append(line)
            save(image.pixels, as: "shapes-\(shape.name).png")
            save(sideBySide(mac: mac, windows: image.pixels), as: "shapes-\(shape.name)-compare.png")
            if shape.exact {
                XCTAssertEqual(d.over1, 0, line)
            } else {
                XCTAssertLessThanOrEqual(d.over64, 600, line)
                XCTAssertLessThanOrEqual(d.over8, 1200, line)
            }
        }
        if let dir = outputDirectory { try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("parity.txt"), atomically: true, encoding: .utf8) }
    }

    func testCanvasScriptRunsAndTheNonTextPartLooksLikeTheMac() throws {
        let c = try XCTUnwrap(graphics.makeCanvas(width: PlazaCanvasScript.width, height: PlazaCanvasScript.height, colorSpace: .sRGB) as? WinPlazaCanvas)
        PlazaCanvasScript.run(c, graphics.text)   // text draws nothing until Task 9
        XCTAssertEqual(c.failureCount, 0)
        let image = try XCTUnwrap(c.makeImage())
        let mac = try golden("canvas-script/script.png")
        let d = diff(mac, image.pixels)
        print("CANVAS-PARITY script.png (no text drawn on Windows yet): \(d.line)")
        save(image.pixels, as: "script.png")
        save(sideBySide(mac: mac, windows: image.pixels), as: "script-compare.png")
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 48)
        // the withPixels write at the end of the script: row 1, six pixels R = 200, A = 255
        for x in 0..<6 { XCTAssertEqual(pixel(image, x, 1).r, 200); XCTAssertEqual(pixel(image, x, 1).a, 255) }
    }

    func testEmoteArtMatchesTheMacExactly() throws {
        for scale in [1, 2] {
            let image = PlazaEmoteArt.image(.heart, scale: CGFloat(scale), graphics: graphics)
            let mac = try golden("canvas-script/emote@\(scale).png")
            let d = diff(mac, image.pixels)
            print("CANVAS-PARITY emote@\(scale): \(d.line)")
            save(image.pixels, as: "emote@\(scale).png")
            save(sideBySide(mac: mac, windows: image.pixels), as: "emote@\(scale)-compare.png")
            XCTAssertEqual(d.over1, 0, "an aliased grid of integer rectangles is pixel-exact")
        }
    }

    // MARK: threads, resources, cost

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var messages: [String] = []
        func add(_ message: String? = nil) { lock.lock(); n += 1; if let message { messages.append(message) }; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var failures: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    }

    func testCanvasesWorkOffTheMainThread() throws {
        let group = DispatchGroup()
        let done = Counter()
        let graphics = self.graphics
        for t in 0..<8 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for i in 0..<50 {
                    guard let c = graphics.makeCanvas(width: 24, height: 16, colorSpace: .sRGB) else { done.add("thread \(t): no canvas"); return }
                    c.setFillColor(PlazaColor(srgbRed: 1, green: 0, blue: 0))
                    c.saveState(); c.clip(to: CGRect(x: 0, y: 0, width: 12, height: 8)); c.setBlend(.multiply)
                    c.fill(CGRect(x: 0, y: 0, width: 24, height: 16)); c.restoreState()
                    c.setShadow(PlazaShadow(offset: CGSize(width: 1, height: -1), blur: 2, color: .black))
                    c.fillEllipse(in: CGRect(x: 2, y: 2, width: 8, height: 8))
                    guard let image = c.makeImage() else { done.add("thread \(t) #\(i): no image"); return }
                    if image.pixels[11, 15 - 7].a == 0 { done.add("thread \(t) #\(i): clipped multiply missing") }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(done.failures, [])
    }

    private struct ProcessCounters {
        typealias Memory = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
        typealias Handles = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
        typealias Gui = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UInt32
        struct Counters {
            var cb: UInt32 = 0, faults: UInt32 = 0
            var peakWS: UInt = 0, ws: UInt = 0, qpp: UInt = 0, qp: UInt = 0, qnpp: UInt = 0, qnp: UInt = 0, pagefile: UInt = 0, peakPagefile: UInt = 0, privateUsage: UInt = 0
        }
        static func snapshot() -> (privateBytes: Int, handles: Int, gdi: Int, user: Int)? {
            guard let memory = WinDynamic.symbol("kernel32.dll", "K32GetProcessMemoryInfo", as: Memory.self),
                  let handles = WinDynamic.symbol("kernel32.dll", "GetProcessHandleCount", as: Handles.self),
                  let gui = WinDynamic.symbol("user32.dll", "GetGuiResources", as: Gui.self) else { return nil }
            var counters = Counters()
            counters.cb = UInt32(MemoryLayout<Counters>.size)
            guard memory(GetCurrentProcess(), &counters, counters.cb) != 0 else { return nil }
            var count: UInt32 = 0
            guard handles(GetCurrentProcess(), &count) != 0 else { return nil }
            return (Int(counters.privateUsage), Int(count), Int(gui(GetCurrentProcess(), 0)), Int(gui(GetCurrentProcess(), 1)))
        }
    }

    private func busyOperations(_ c: any PlazaCanvas, image: PlazaImage, round i: Int) {
        c.saveState()
        c.translate(x: Double(i % 7), y: 1); c.scale(x: 1.1, y: 1)
        c.clip(to: CGRect(x: 0, y: 0, width: 90, height: 60))
        c.setFillColor(PlazaColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 0.7)); c.fill(CGRect(x: 3, y: 3, width: 20, height: 12))
        c.fillEllipse(in: CGRect(x: 10, y: 10, width: 30, height: 20))
        c.fillRoundedRect(CGRect(x: 5, y: 5, width: 40, height: 24), radius: 8)
        c.strokeUnevenRoundedRect(CGRect(x: 5, y: 5, width: 40, height: 24), radii: PlazaCornerRadii(topLeading: 3, bottomLeading: 8, bottomTrailing: 3, topTrailing: 9), lineWidth: 1.5)
        c.fillPath(PlazaPath(points: [CGPoint(x: 1, y: 1), CGPoint(x: 30, y: 4), CGPoint(x: 12, y: 30)], closed: true))
        c.strokePath(PlazaPath(points: [CGPoint(x: 1, y: 1), CGPoint(x: 30, y: 4), CGPoint(x: 12, y: 30)]), lineWidth: 2, cap: .round)
        c.draw(image, in: CGRect(x: 40, y: 10, width: 12, height: 10))
        if i % 10 == 0 {
            c.setShadow(PlazaShadow(offset: CGSize(width: 1, height: -1), blur: 2, color: .black)); c.fill(CGRect(x: 60, y: 10, width: 8, height: 8)); c.setShadow(nil)
            c.setBlend(.multiply); c.fill(CGRect(x: 0, y: 0, width: 20, height: 10)); c.setBlend(.normal)
        }
        c.restoreState()
    }

    func testTenThousandOperationsLeakNothing() throws {
        guard let before0 = ProcessCounters.snapshot() else { throw XCTSkip("process counters unavailable") }
        let image = PlazaImage(bitmap: PlazaTestImages.patterned(width: 6, height: 5))
        // One long-lived canvas: 1,250 rounds of 8-10 calls = more than 10,000 operations.
        let c = try canvas(96, 64)
        for i in 0..<100 { busyOperations(c, image: image, round: i) }   // warm-up: pools, caches
        guard let before = ProcessCounters.snapshot() else { return }
        for i in 0..<1250 { busyOperations(c, image: image, round: i) }
        XCTAssertEqual(c.failureCount, 0)
        guard let after = ProcessCounters.snapshot() else { return }
        print("CANVAS-LEAK long canvas: private \(before.privateBytes) -> \(after.privateBytes) (+\(after.privateBytes - before.privateBytes)), handles \(before.handles) -> \(after.handles), gdi \(before.gdi) -> \(after.gdi), user \(before.user) -> \(after.user)")
        XCTAssertLessThan(after.privateBytes - before.privateBytes, 3 << 20, "private bytes flat")
        XCTAssertLessThanOrEqual(after.handles, before.handles + 2); XCTAssertEqual(after.gdi, before.gdi); XCTAssertEqual(after.user, before.user)
        // Many short-lived canvases, each with the shadow / blend surfaces and an upload.
        for i in 0..<100 { let k = try canvas(64, 48); busyOperations(k, image: image, round: i * 10); _ = k.makeImage() }
        guard let mid = ProcessCounters.snapshot() else { return }
        for i in 0..<400 { let k = try canvas(64, 48); busyOperations(k, image: image, round: i * 10); _ = k.makeImage() }
        guard let end = ProcessCounters.snapshot() else { return }
        print("CANVAS-LEAK 400 canvases: private \(mid.privateBytes) -> \(end.privateBytes) (+\(end.privateBytes - mid.privateBytes)), handles \(mid.handles) -> \(end.handles), gdi \(mid.gdi) -> \(end.gdi), user \(mid.user) -> \(end.user), start private \(before0.privateBytes)")
        XCTAssertLessThan(end.privateBytes - mid.privateBytes, 6 << 20)
        XCTAssertLessThanOrEqual(end.handles, mid.handles + 2); XCTAssertEqual(end.gdi, mid.gdi); XCTAssertEqual(end.user, mid.user)
    }

    func testCostOfAPanelSizedCanvas() throws {
        let image = PlazaImage(bitmap: PlazaTestImages.patterned(width: 6, height: 5))
        var times: [Double] = []
        var held = 0
        for _ in 0..<12 {
            let start = DispatchTime.now().uptimeNanoseconds
            let c = try canvas(800, 600)   // 400 x 300 points at 2x
            c.scale(x: 2, y: 2)
            for i in 0..<5 { busyOperations(c, image: image, round: i * 10 + 1) }   // about 50 operations
            _ = try XCTUnwrap(c.makeImage())
            held = max(held, c.bytesHeld)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        print("CANVAS-COST 800x600, ~50 operations + makeImage: median \(times[times.count / 2]) ms, min \(times[0]) ms, max \(times[times.count - 1]) ms; bytes held \(held) (target \(800 * 600 * 4))")
        XCTAssertLessThan(times[times.count / 2], 1500)
    }
}
#endif
