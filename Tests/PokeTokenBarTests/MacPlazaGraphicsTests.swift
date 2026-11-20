import AppKit
import CoreText
import ImageIO
import XCTest
@testable import PokeTokenBar

/// The Mac graphics backend makes the same CoreGraphics / CoreText / ImageIO calls the art files made before.
final class MacPlazaGraphicsTests: XCTestCase {
    private let graphics = MacPlazaGraphics()

    /// Every bundled image as `PlazaResources` loads it today, with its file name.
    private func bundledImages() throws -> [(name: String, image: CGImage)] {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        var out: [(String, CGImage)] = [
            ("plaza-tiles.png", try XCTUnwrap(PlazaResources.tileSheet(in: bundle))),
            ("plaza-water-balloon.png", try XCTUnwrap(PlazaResources.waterBalloon(in: bundle))),
            ("plaza-tallgrass.png", try XCTUnwrap(PlazaResources.tallGrassSheet(in: bundle))),
            ("plaza-ice-cracks.png", try XCTUnwrap(PlazaResources.iceCrackSheet(in: bundle))),
            ("plaza-ice-gloss.png", try XCTUnwrap(PlazaResources.iceGlossSheet(in: bundle))),
        ]
        let frames = PlazaResources.iceShatterFrames(in: bundle)
        XCTAssertFalse(frames.isEmpty)
        out += frames.enumerated().map { ("plaza-ice-shatter.gif#\($0.offset)", $0.element) }
        return out
    }

    /// `SheetPixels` / `PlazaSnowSheet.recolored` read pixels exactly like this (verbatim).
    private func contextDraw(_ image: CGImage) -> [UInt8] {
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    func testNativeImagePixelsMatchAContextDraw() throws {
        for (name, image) in try bundledImages() {
            let plaza = PlazaImage(cgImage: image)
            XCTAssertTrue(plaza.cgImage === image, "\(name): a native image reaches SpriteKit unchanged")
            XCTAssertEqual([plaza.width, plaza.height], [image.width, image.height], name)
            let pixels = plaza.pixels
            XCTAssertEqual(pixels.alpha, .premultipliedLast)
            XCTAssertEqual(pixels.colorSpace, .sRGB)
            XCTAssertTrue(pixels.bytes == contextDraw(image), "\(name): pixels differ from the context draw")
            // a native crop is CGImage.cropping (top-left origin) and still native
            let rect = PlazaPixelRect(x: 1, y: 2, width: min(5, image.width - 1), height: min(4, image.height - 2))
            let crop = try XCTUnwrap(plaza.cropping(to: rect))
            XCTAssertNil(crop.bitmap)
            PlazaArtParity.assertIdentical(try XCTUnwrap(image.cropping(to: CGRect(x: 1, y: 2, width: rect.width, height: rect.height))),
                                           crop, "\(name) crop")
            XCTAssertEqual(crop.pixels, pixels.cropped(to: rect), "\(name): crop pixels")
        }
    }

    /// Experiment (plan R5): each bundled resource's colour space and pixel format, and whether drawing it into the
    /// premultiplied sRGB buffer shared code reads (`pixels`) changes its decoded bytes. Pinned so a changed asset or
    /// decoder shows up here.
    func testBundledImagesColourSpaces() throws {
        var report: [String] = []
        for (name, image) in try bundledImages() {
            let raw = Array((image.dataProvider?.data as Data?) ?? Data())
            let drawn = contextDraw(image)
            let packed = image.bitsPerPixel == 32 && image.bytesPerRow == image.width * 4
            let same = packed && raw == drawn
            var changed = 0
            if packed { changed = zip(raw, drawn).filter { $0 != $1 }.count }
            let line = "\(name) \(image.colorSpace?.name.map { $0 as String } ?? "nil") alpha \(image.alphaInfo.rawValue)"
                + " bpc \(image.bitsPerComponent) bpp \(image.bitsPerPixel) bpr \(image.bytesPerRow)"
                + " drawUnchanged \(same)" + (packed ? " changedBytes \(changed)" : "")
            report.append(line)
            print("PLAZA-COLOURSPACE: \(line)")
        }
        XCTAssertEqual(report, Self.expectedColourSpaces)
    }

    /// Observed 2026-11-14 (macOS 26): every resource decodes as 8-bit sRGB with straight alpha (`alphaInfo` 3, `.last`).
    /// Drawing into the premultiplied buffer changes the bytes of the sheets that have partly transparent pixels
    /// (tiles, water balloon, ice cracks) and none of the others. So shared code reads `pixels` (premultiplied, as
    /// `SheetPixels` did) and the Mac never rebuilds a native image from its pixels (plan D2/R5).
    static let expectedColourSpaces: [String] = [
        "plaza-tiles.png kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 2560 drawUnchanged false changedBytes 55638",
        "plaza-water-balloon.png kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 56 drawUnchanged false changedBytes 756",
        "plaza-tallgrass.png kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 832 drawUnchanged true changedBytes 0",
        "plaza-ice-cracks.png kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 1024 drawUnchanged false changedBytes 42",
        "plaza-ice-gloss.png kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 336 drawUnchanged true changedBytes 0",
        "plaza-ice-shatter.gif#0 kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 128 drawUnchanged true changedBytes 0",
        "plaza-ice-shatter.gif#1 kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 128 drawUnchanged true changedBytes 0",
        "plaza-ice-shatter.gif#2 kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 128 drawUnchanged true changedBytes 0",
        "plaza-ice-shatter.gif#3 kCGColorSpaceSRGB alpha 3 bpc 8 bpp 32 bpr 128 drawUnchanged true changedBytes 0",
    ]

    /// Bitmap images become a `CGImage` through the construction the art files use (premultiplied: tiles, shadow,
    /// pond, nest, ice, grass; skip-last: the campfire light texture), and the harness's byte-built characters.
    @MainActor   // PlazaRenderScenes is main-actor isolated
    func testBitmapCGImageMatchesTheArtFilesConstruction() {
        for (w, h) in [(1, 1), (3, 3), (12, 3), (37, 23), (64, 48)] {
            for layout in [PlazaAlphaLayout.premultipliedLast, .noneSkipLast] {
                let bitmap = PlazaTestImages.patterned(width: w, height: h, alpha: layout)
                let info = layout == .premultipliedLast ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
                let legacy = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                                     provider: CGDataProvider(data: Data(bitmap.bytes) as CFData)!, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent)!
                let image = PlazaImage(bitmap: bitmap)
                PlazaArtParity.assertIdentical(legacy, image, "\(w)x\(h) \(layout)")
                XCTAssertTrue(image.cgImage === image.cgImage, "built once, kept in backendCache")
                if layout == .premultipliedLast {
                    PlazaArtParity.assertIdentical(PlazaRenderScenes.image(bitmap.bytes, width: w, height: h), image, "harness fixture")
                }
            }
        }
        // (a native image that is not a CGImage no longer reaches cgImage: it is a preconditionFailure on the Mac)
        var device = PlazaTestImages.patterned(width: 4, height: 4)
        device.colorSpace = .deviceRGB
        XCTAssertEqual(PlazaImage(bitmap: device).cgImage.colorSpace?.model, .rgb)
        XCTAssertEqual(PlazaImage(bitmap: device).cgImage.colorSpace?.name, CGColorSpaceCreateDeviceRGB().name)
    }

    // MARK: Canvas

    /// Today's attributed strings (PlazaNamePlate, PlazaChatBubble, PlazaEmoteArt, PlazaPondArt.wetImage).
    private func ctLine(_ text: String, _ font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private func ctEmojiLine(_ text: String, size: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    }

    private func ctFramesetter(_ text: String) -> CTFramesetter {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: PlazaResources.font(.body),
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private let ink = PlazaColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255)
    private let pink = PlazaColor(hex: 0xFF9ECF)
    private let shadow = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)

    /// One scripted drawing through the canvas, covering every method.
    private func script(_ c: any PlazaCanvas, _ text: any PlazaTextEngine, bitmap: PlazaImage, native: PlazaImage) {
        c.setShouldAntialias(true)
        c.setAllowsAntialiasing(true)
        c.setShouldSmoothFonts(true)
        c.saveState()
        c.translate(x: 3, y: 2)
        c.scale(x: 1.5, y: 1.25)
        c.rotate(by: 0.1)
        c.setFillColor(pink)
        c.fill(CGRect(x: 1, y: 1, width: 9, height: 5))
        c.fillEllipse(in: CGRect(x: 12.5, y: 3, width: 11, height: 7.5))
        c.restoreState()
        c.setAlpha(0.6)
        c.setBlend(.multiply)
        c.setFillColor(PlazaColor(hex: 0x7FD4FF))
        c.fill(CGRect(x: 4, y: 4, width: 20, height: 12))
        c.setBlend(.normal)
        c.setAlpha(1)
        c.saveState()
        c.setInterpolationNone()
        c.draw(bitmap, in: CGRect(x: 30, y: 2, width: 12, height: 9))
        c.translate(x: 50, y: 30)
        c.scale(x: -1, y: 1)
        c.draw(native, in: CGRect(x: 0, y: 0, width: 10, height: 14))
        c.restoreState()
        c.saveState()
        c.clip(to: CGRect(x: 0, y: 20, width: 25, height: 10))
        c.setBlend(.sourceAtop)
        c.setFillColor(PlazaColor(srgbRed: 30 / 255, green: 124 / 255, blue: 184 / 255, alpha: 0.3))
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
        c.restoreState()
        // name plate: stroke behind with a shadow, then fill without
        let name = text.line("도토리 Ab", font: .system(size: 15, weight: .bold))
        c.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: shadow))
        c.setTextDrawingMode(.stroke)
        c.setLineWidth(3)
        c.setLineJoin(.round)
        c.setStrokeColor(ink)
        c.draw(name, at: CGPoint(x: 5, y: 22))
        c.setShadow(nil)
        c.setTextDrawingMode(.fill)
        c.setFillColor(pink)
        c.draw(name, at: CGPoint(x: 5, y: 22))
        c.setLineJoin(.miter)
        c.setTextDrawingMode(.stroke)
        c.draw(text.line("수줍은", font: .system(size: 12, weight: .semibold)), at: CGPoint(x: 6, y: 36))
        c.setTextDrawingMode(.fill)
        // emote text: antialiased, not smoothed (smoothing only shows with antialiasing on)
        c.setShouldSmoothFonts(false)
        c.draw(text.line("!?", font: .plaza(.body)), at: CGPoint(x: 30, y: 12))
        // bubble: no antialias for the shapes, Galmuri text
        c.setShouldAntialias(false)
        c.setFillColor(ink)
        c.draw(text.paragraph("안녕 hello 🔥 긴 줄은 접힌다", font: .plaza(.body), alignment: .center), in: CGRect(x: 2, y: 2, width: 44, height: 40))
        let small = text.line("Zz", font: .plaza(.small))
        let b = c.imageBounds(of: small)
        c.draw(small, at: CGPoint(x: (40 - b.midX).rounded(), y: (10 - b.midY).rounded()))
        c.setShouldAntialias(true)
        let drop = text.line("💧", font: .emoji(size: 12))
        let e = c.imageBounds(of: drop)
        c.draw(drop, at: CGPoint(x: 52 - e.midX, y: 40 - e.midY))
        c.setAllowsAntialiasing(false)
        c.fillEllipse(in: CGRect(x: 40, y: 2, width: 9, height: 9))
        c.withPixels { bytes, bytesPerRow in
            for x in 0..<6 { bytes[bytesPerRow * 1 + x * 4] = 200; bytes[bytesPerRow * 1 + x * 4 + 3] = 255 }
        }
    }

    /// The same calls, written the way the art files write them today.
    private func raw(_ c: CGContext, bitmap: CGImage, native: CGImage) {
        c.setShouldAntialias(true)
        c.setAllowsAntialiasing(true)
        c.setShouldSmoothFonts(true)
        c.saveGState()
        c.translateBy(x: 3, y: 2)
        c.scaleBy(x: 1.5, y: 1.25)
        c.rotate(by: 0.1)
        c.setFillColor(CGColor(srgbRed: 0xFF / 255, green: 0x9E / 255, blue: 0xCF / 255, alpha: 1))
        c.fill(CGRect(x: 1, y: 1, width: 9, height: 5))
        c.fillEllipse(in: CGRect(x: 12.5, y: 3, width: 11, height: 7.5))
        c.restoreGState()
        c.setAlpha(0.6)
        c.setBlendMode(.multiply)
        c.setFillColor(CGColor(srgbRed: 0x7F / 255, green: 0xD4 / 255, blue: 0xFF / 255, alpha: 1))
        c.fill(CGRect(x: 4, y: 4, width: 20, height: 12))
        c.setBlendMode(.normal)
        c.setAlpha(1)
        c.saveGState()
        c.interpolationQuality = .none
        c.draw(bitmap, in: CGRect(x: 30, y: 2, width: 12, height: 9))
        c.translateBy(x: 50, y: 30)
        c.scaleBy(x: -1, y: 1)
        c.draw(native, in: CGRect(x: 0, y: 0, width: 10, height: 14))
        c.restoreGState()
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 20, width: 25, height: 10))
        c.setBlendMode(.sourceAtop)
        let w = LegacyPlazaPondArt.waterColor
        c.setFillColor(CGColor(srgbRed: w.redComponent, green: w.greenComponent, blue: w.blueComponent, alpha: 0.3))
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
        c.restoreGState()
        let name = ctLine("도토리 Ab", NSFont.systemFont(ofSize: 15, weight: .bold))
        c.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        c.setTextDrawingMode(.stroke)
        c.setLineWidth(3)
        c.setLineJoin(.round)
        c.setStrokeColor(CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1))
        c.textPosition = CGPoint(x: 5, y: 22)
        CTLineDraw(name, c)
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setTextDrawingMode(.fill)
        c.setFillColor(CGColor(srgbRed: 0xFF / 255, green: 0x9E / 255, blue: 0xCF / 255, alpha: 1))
        c.textPosition = CGPoint(x: 5, y: 22)
        CTLineDraw(name, c)
        c.setLineJoin(.miter)
        c.setTextDrawingMode(.stroke)
        c.textPosition = CGPoint(x: 6, y: 36)
        CTLineDraw(ctLine("수줍은", NSFont.systemFont(ofSize: 12, weight: .semibold)), c)
        c.setTextDrawingMode(.fill)
        c.setShouldSmoothFonts(false)
        c.textPosition = CGPoint(x: 30, y: 12)
        CTLineDraw(ctLine("!?", PlazaResources.font(.body)), c)
        c.setShouldAntialias(false)
        c.setFillColor(CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1))
        CTFrameDraw(CTFramesetterCreateFrame(ctFramesetter("안녕 hello 🔥 긴 줄은 접힌다"), CFRange(),
                                             CGPath(rect: CGRect(x: 2, y: 2, width: 44, height: 40), transform: nil), nil), c)
        let small = ctLine("Zz", PlazaResources.font(.small))
        c.textPosition = .zero   // image bounds are relative to the origin (the canvas measures from .zero)
        let b = CTLineGetImageBounds(small, c)
        c.textPosition = CGPoint(x: (40 - b.midX).rounded(), y: (10 - b.midY).rounded())
        CTLineDraw(small, c)
        c.setShouldAntialias(true)
        let drop = ctEmojiLine("💧", size: 12)
        c.textPosition = .zero
        let e = CTLineGetImageBounds(drop, c)
        c.textPosition = CGPoint(x: 52 - e.midX, y: 40 - e.midY)
        CTLineDraw(drop, c)
        c.setAllowsAntialiasing(false)
        c.fillEllipse(in: CGRect(x: 40, y: 2, width: 9, height: 9))
        let bytes = c.data!.assumingMemoryBound(to: UInt8.self), bytesPerRow = c.bytesPerRow
        for x in 0..<6 { bytes[bytesPerRow * 1 + x * 4] = 200; bytes[bytesPerRow * 1 + x * 4 + 3] = 255 }
    }

    func testCanvasCallsMatchCGContextCalls() throws {
        let bitmap = PlazaImage(bitmap: PlazaTestImages.patterned(width: 6, height: 5))
        let sheet = try XCTUnwrap(PlazaResources.tallGrassSheet())
        let native = PlazaImage(cgImage: try XCTUnwrap(sheet.cropping(to: CGRect(x: 16, y: 0, width: 16, height: 16))))
        for space in [PlazaColorSpace.sRGB, .deviceRGB] {
            for (w, h) in [(64, 48), (61, 47)] {
                let canvas = try XCTUnwrap(graphics.makeCanvas(width: w, height: h, colorSpace: space))
                XCTAssertEqual([canvas.width, canvas.height], [w, h])
                script(canvas, graphics.text, bitmap: bitmap, native: native)
                let cgSpace = space == .sRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
                let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cgSpace,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                raw(ctx, bitmap: bitmap.cgImage, native: native.cgImage)
                let made = try XCTUnwrap(canvas.makeImage())
                XCTAssertNil(made.bitmap, "a canvas image is the context's own CGImage")
                PlazaArtParity.assertIdentical(try XCTUnwrap(ctx.makeImage()), made, "canvas \(space) \(w)x\(h)")
                let drawn = (made.cgImage.dataProvider?.data as Data?).map { Set(Array($0)).count } ?? 0
                XCTAssertGreaterThan(drawn, 20, "the script drew something")
            }
        }
        XCTAssertNil(graphics.makeCanvas(width: 0, height: 4, colorSpace: .sRGB))
    }

    // MARK: Text

    private let texts = ["", "나", "Name", "도토리도토리", "🔥🔥", "Hello 안녕 🔥 👍🏽", "Zz", "…",
                         String(repeating: "아주긴닉네임", count: 40)]

    private func bounds(_ line: CTLine) -> [CGFloat] {
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        return [w, a, d, l]
    }

    func testTextLineMatchesCoreTextMetrics() throws {
        let text = graphics.text
        let fonts: [(PlazaFont, (String) -> CTLine)] = [
            (.plaza(.body), { self.ctLine($0, PlazaResources.font(.body)) }),
            (.plaza(.small), { self.ctLine($0, PlazaResources.font(.small)) }),
            (.system(size: 15, weight: .bold), { self.ctLine($0, NSFont.systemFont(ofSize: 15, weight: .bold)) }),
            (.system(size: 12, weight: .semibold), { self.ctLine($0, NSFont.systemFont(ofSize: 12, weight: .semibold)) }),
            (.system(size: 13, weight: .regular), { self.ctLine($0, NSFont.systemFont(ofSize: 13, weight: .regular)) }),
            (.emoji(size: 12), { self.ctEmojiLine($0, size: 12) }),
        ]
        for (font, make) in fonts {
            for s in texts {
                let line = text.line(s, font: font)
                XCTAssertEqual([line.width, line.ascent, line.descent, line.leading], bounds(make(s)), "\(font) \(s.prefix(12))")
            }
            // the name plate's truncation
            let long = text.line(texts.last!, font: font), ellipsis = text.line("…", font: font)
            let cut = try XCTUnwrap(text.truncated(long, width: 200, ellipsis: ellipsis), "\(font)")
            let legacy = try XCTUnwrap(CTLineCreateTruncatedLine(make(texts.last!), 200, .end, make("…")))
            XCTAssertEqual([cut.width, cut.ascent, cut.descent, cut.leading], bounds(legacy), "\(font) truncated")
            for width in [0.0, 1, 3] {   // narrower than the ellipsis: CoreText gives up, and so does the engine
                XCTAssertEqual(text.truncated(long, width: width, ellipsis: ellipsis) == nil,
                               CTLineCreateTruncatedLine(make(texts.last!), width, .end, make("…")) == nil, "\(font) at \(width)")
            }
        }
        for size in PlazaTextSize.allCases {
            let f = PlazaResources.font(size)
            XCTAssertEqual(text.metrics(.plaza(size)), PlazaFontMetrics(ascender: f.ascender, descender: f.descender, leading: f.leading))
        }
        let bold = NSFont.systemFont(ofSize: 15, weight: .bold)
        XCTAssertEqual(text.metrics(.system(size: 15, weight: .bold)),
                       PlazaFontMetrics(ascender: bold.ascender, descender: bold.descender, leading: bold.leading))
        let emoji = CTFontCreateWithName("Apple Color Emoji" as CFString, 12, nil)
        XCTAssertEqual(text.metrics(.emoji(size: 12)),
                       PlazaFontMetrics(ascender: CTFontGetAscent(emoji), descender: -CTFontGetDescent(emoji), leading: CTFontGetLeading(emoji)))

        // the chat bubble's paragraph: suggested size and visible length
        let limit = CGSize(width: 216, height: 160)
        for s in texts + [String(repeating: "가나다 ", count: 30), "🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥"] {
            let p = text.paragraph(s, font: .plaza(.body), alignment: .center)
            let setter = ctFramesetter(s)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, limit, nil)
            XCTAssertEqual(p.suggestedSize(limit: limit), fit, "\(s.prefix(12))")
            for size in [fit, CGSize(width: 216, height: 20), CGSize(width: 40, height: 40)] {
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
                XCTAssertEqual(p.visibleLength(in: size), CTFrameGetVisibleStringRange(frame).length, "\(s.prefix(12)) in \(size)")
            }
        }
    }

    // MARK: Assets and codecs

    func testDecodeAndEncodeAreTodaysImageIO() throws {
        let bundle = try XCTUnwrap(PlazaResources.resourceBundle())
        let url = try XCTUnwrap(graphics.assetURL("plaza-tiles", ext: "png"))
        XCTAssertEqual(url, PlazaResources.resourceURL("plaza-tiles", "png", in: bundle))
        XCTAssertNil(graphics.assetURL("no-such-asset", ext: "png"))
        let sheet = try XCTUnwrap(PlazaResources.tileSheet(in: bundle))
        let decoded = try XCTUnwrap(graphics.decodeImage(at: url))
        XCTAssertNil(decoded.bitmap)
        PlazaArtParity.assertIdentical(sheet, decoded, "decodeImage(at:)")
        PlazaArtParity.assertIdentical(sheet, try XCTUnwrap(graphics.decodeImage(try Data(contentsOf: url))), "decodeImage(data)")
        XCTAssertNil(graphics.decodeImage(Data([1, 2, 3])))
        XCTAssertNil(graphics.decodeImage(at: URL(fileURLWithPath: "/nonexistent.png")))

        let gif = try XCTUnwrap(graphics.assetURL("plaza-ice-shatter", ext: "gif"))
        let legacyFrames = PlazaResources.iceShatterFrames(in: bundle)
        let frames = graphics.decodeImageFrames(at: gif)
        XCTAssertEqual(frames.count, legacyFrames.count)
        XCTAssertGreaterThan(frames.count, 1)
        for (legacy, new) in zip(legacyFrames, frames) { PlazaArtParity.assertIdentical(legacy, new, "gif frame") }
        XCTAssertEqual(graphics.decodeImageFrames(at: URL(fileURLWithPath: "/nonexistent.gif")).count, 0)

        for image in [decoded, PlazaGroundShadow.image(width: 40, height: 12)] {
            XCTAssertEqual(graphics.encodePNG(image), LegacyPlazaPhotoRenderer.png(image.cgImage))
        }
    }

    func testPlatformPlazaGraphicsIsTheMacBackend() {
        XCTAssertTrue(PlatformPlaza.graphics is MacPlazaGraphics)
        XCTAssertTrue(PlatformPlaza.graphics.text is CoreTextPlazaEngine)
    }
}
