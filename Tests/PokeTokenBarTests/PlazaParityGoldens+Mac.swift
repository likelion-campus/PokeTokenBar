import AppKit
import CoreText
import CryptoKit
import ImageIO
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// The Mac's side of the parity goldens (stage 6, Task 1): measures everything in `Tests/PlazaParityGoldens/` from
/// CoreGraphics, CoreText, TextKit, SwiftUI and SpriteKit (`SKRenderer`, offscreen: no window, no activation), writes it
/// (`testWriteParityGoldens`, env `PTB_PLAZA_GOLDENS_WRITE=1`) and re-measures it on every run
/// (`testParityGoldensStillHoldOnThisMac`): a merge that changes what SpriteKit draws, the fonts or SwiftUI's corners
/// fails here first, before a Windows number is compared with a stale Mac number.
///
///     PTB_PLAZA_GOLDENS_WRITE=1 swift test --filter PlazaParityGoldensMacTests/testWriteParityGoldens
@MainActor
final class PlazaParityGoldensMacTests: XCTestCase {
    private let graphics = PlatformPlaza.graphics

    // MARK: premultiply.json

    private func bundledImages() throws -> [(name: String, image: PlazaImage)] {
        var out: [(String, PlazaImage)] = []
        for (name, ext) in [("plaza-tiles", "png"), ("plaza-water-balloon", "png"), ("plaza-tallgrass", "png"), ("plaza-ice-cracks", "png"),
                            ("plaza-ice-gloss", "png")] {
            let url = try XCTUnwrap(graphics.assetURL(name, ext: ext), name)
            out.append(("\(name).\(ext)", try XCTUnwrap(graphics.decodeImage(at: url), name)))
        }
        let gif = try XCTUnwrap(graphics.assetURL(PlazaResources.iceShatterName, ext: "gif"))
        for (i, frame) in graphics.decodeImageFrames(at: gif).enumerated() { out.append(("plaza-ice-shatter.gif#\(i)", frame)) }
        return out
    }

    /// What a premultiplied sRGB RGBA context makes of every straight (colour, alpha) pair: row = alpha, column = colour.
    fileprivate func coreGraphicsPremultiplyTable() throws -> [UInt8] {
        let n = 256
        var straight = [UInt8](repeating: 0, count: n * n * 4)
        for a in 0..<n { for c in 0..<n { let i = (a * n + c) * 4; straight[i] = UInt8(c); straight[i + 1] = UInt8(c); straight[i + 2] = UInt8(c); straight[i + 3] = UInt8(a) } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = try XCTUnwrap(CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(straight) as CFData)!,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var out = [UInt8](repeating: 0, count: n * n * 4)
        out.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return (0..<n * n).map { out[$0 * 4] }   // the red channel: all three colour channels are the same value
    }

    private func makePremultiply() throws -> PlazaPremultiplyGolden {
        var images: [String: String] = [:]
        for (name, image) in try bundledImages() { images[name] = "\(image.width)x\(image.height) " + PlazaParityGoldens.sha256Hex(image.pixels.bytes) }
        let table = try coreGraphicsPremultiplyTable()
        var rows: [String: String] = [:]
        for a in stride(from: 0, to: 256, by: 17) { rows[String(a)] = PlazaParityGoldens.hex(Array(table[a * 256..<(a + 1) * 256])) }
        return PlazaPremultiplyGolden(images: images, tableSHA256: PlazaParityGoldens.sha256Hex(table), rows: rows)
    }

    // MARK: fill-gray.json

    private func makeFillGray() throws -> PlazaFillGrayGolden {
        let steps = (0...20).map { Double($0) / 20 }
        func fills(_ space: PlazaColorSpace) throws -> [[Int]] {
            try steps.map { g in
                let canvas = try XCTUnwrap(graphics.makeCanvas(width: 1, height: 1, colorSpace: space))
                canvas.setFillGray(CGFloat(g))
                canvas.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                var px: [Int] = []
                canvas.withPixels { bytes, _ in px = (0..<4).map { Int(bytes[$0]) } }
                return px
            }
        }
        return PlazaFillGrayGolden(steps: steps, deviceRGB: try fills(.deviceRGB), sRGB: try fills(.sRGB))
    }

    // MARK: font-metrics.json

    private func table(_ d: Data, _ tag: String) -> Data? {
        func u16(_ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        for i in 0..<u16(4) {
            let o = 12 + i * 16
            if String(decoding: d[o..<o + 4], as: UTF8.self) == tag { return d.subdata(in: u32(o + 8)..<u32(o + 8) + u32(o + 12)) }
        }
        return nil
    }

    private func makeFontMetrics() throws -> PlazaFontMetricsGolden {
        var fonts: [String: PlazaFontMetricsGolden.Entry] = [:]
        for size in PlazaTextSize.allCases {
            let url = try XCTUnwrap(graphics.assetURL(size.fileName, ext: "ttf"))
            let file = try Data(contentsOf: url)
            let hhea = try XCTUnwrap(table(file, "hhea")), head = try XCTUnwrap(table(file, "head"))
            func s16(_ t: Data, _ o: Int) -> Int { let v = Int(t[o]) << 8 | Int(t[o + 1]); return v >= 0x8000 ? v - 0x10000 : v }
            let ns = PlazaResources.font(size)
            let ct = CTFontCreateWithName(size.fontName as CFString, size.points, nil)
            fonts[size.fontName] = .init(size: Double(size.points), nsAscender: Double(ns.ascender), nsDescender: Double(ns.descender), nsLeading: Double(ns.leading),
                                         ctAscent: CTFontGetAscent(ct), ctDescent: CTFontGetDescent(ct), ctLeading: CTFontGetLeading(ct),
                                         unitsPerEm: s16(head, 18), hheaAscender: s16(hhea, 4), hheaDescender: s16(hhea, 6), hheaLineGap: s16(hhea, 8))
        }
        return PlazaFontMetricsGolden(fonts: fonts)
    }

    // MARK: corners.json

    private func swiftUIElements(_ path: Path) -> [PlazaCurveElement] {
        var out: [PlazaCurveElement] = []
        path.forEach { e in
            switch e {
            case .move(let p): out.append(.move(p))
            case .line(let p): out.append(.line(p))
            case .curve(let p, let c1, let c2): out.append(.curve(to: p, c1: c1, c2: c2))
            case .quadCurve: XCTFail("a quad curve")
            case .closeSubpath: out.append(.close)
            }
        }
        return out
    }

    fileprivate func swiftUIRounded(_ rect: CGRect, _ r: CGFloat) -> [PlazaCurveElement] {
        swiftUIElements(Path(roundedRect: rect, cornerRadius: r, style: .continuous))
    }

    fileprivate func swiftUIUneven(_ rect: CGRect, _ r: [CGFloat]) -> [PlazaCurveElement] {
        swiftUIElements(CGPlazaCanvas.unevenRoundedRect(rect, radii: PlazaCornerRadii(topLeading: r[0], bottomLeading: r[1], bottomTrailing: r[2], topTrailing: r[3])).swiftUIPath)
    }

    /// The largest coordinate difference between two element lists (infinity when their shapes differ).
    fileprivate func distance(_ a: [PlazaCurveElement], _ b: [PlazaCurveElement]) -> Double {
        guard a.count == b.count else { return .infinity }
        func pts(_ e: PlazaCurveElement) -> [CGPoint] {
            switch e {
            case .move(let p), .line(let p): [p]
            case .curve(let p, let c1, let c2): [p, c1, c2]
            case .close: []
            }
        }
        var worst = 0.0
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.move, .move), (.line, .line), (.curve, .curve), (.close, .close):
                for (p, q) in zip(pts(x), pts(y)) { worst = max(worst, Double(abs(p.x - q.x)), Double(abs(p.y - q.y))) }
            default: return .infinity
            }
        }
        return worst
    }

    private func makeCorners() throws -> PlazaCornersGolden {
        var cases: [PlazaCornersGolden.Case] = []
        for rect in PlazaCornersGolden.roundedRects {
            for r in PlazaCornersGolden.roundedRadii {
                cases.append(.init(kind: "rounded", rect: [rect.minX, rect.minY, rect.width, rect.height].map(Double.init), radii: [Double(r)],
                                   elements: PlazaCornersGolden.flatten(swiftUIRounded(rect, r))))
            }
        }
        for rect in PlazaCornersGolden.unevenRects {
            for r in PlazaCornersGolden.unevenRadii {
                cases.append(.init(kind: "uneven", rect: [rect.minX, rect.minY, rect.width, rect.height].map(Double.init), radii: r.map(Double.init),
                                   elements: PlazaCornersGolden.flatten(swiftUIUneven(rect, r))))
            }
        }
        return PlazaCornersGolden(cases: cases)
    }

    // MARK: breaks.json

    private static func isHangul(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xA960...0xA97F).contains(v)
            || (0xD7B0...0xD7FF).contains(v)
    }

    private static func isWordCharacter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark,
             .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// The clusters `PlazaLineBreaker` is fed, measured the way a text engine can: grapheme clusters, glyph advances of
    /// one `CTLine` (each glyph's advance goes to the cluster its string index is in, kerning included), break
    /// opportunities from `CFStringTokenizer` line-break units, a no-break space is not white space.
    func clusters(of text: String, font: NSFont) -> [PlazaBreakCluster] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let length = (text as NSString).length
        var unitEnds = Set<Int>()
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: length), kCFStringTokenizerUnitLineBreak, nil)
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            unitEnds.insert(r.location + r.length)
        }
        var owner = [Int](repeating: 0, count: length)
        var advances: [CGFloat] = []
        var u = 0
        for ch in text {
            let len = String(ch).utf16.count
            for k in u..<(u + len) { owner[k] = advances.count }
            advances.append(0)
            u += len
        }
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var adv = [CGSize](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
            CTRunGetAdvances(run, CFRange(), &adv)
            CTRunGetStringIndices(run, CFRange(), &idx)
            for g in 0..<n { advances[owner[idx[g]]] += adv[g].width }
        }
        var out: [PlazaBreakCluster] = []
        u = 0
        for (i, ch) in text.enumerated() {
            let len = String(ch).utf16.count
            let scalars = ch.unicodeScalars
            out.append(PlazaBreakCluster(
                utf16: u..<(u + len), width: advances[i],
                isWhitespace: scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) && ![0xA0, 0x2007, 0x202F].contains($0.value) },
                isNewline: scalars.contains { "\n\r\u{2028}\u{2029}\u{85}".unicodeScalars.contains($0) },
                canBreakAfter: unitEnds.contains(u + len), isHangul: scalars.first.map(Self.isHangul) ?? false,
                isWordCharacter: scalars.first.map(Self.isWordCharacter) ?? false))
            u += len
        }
        return out
    }

    fileprivate func trimmedRanges(_ ranges: [NSRange], in ns: NSString) -> [Range<Int>] {
        var out = ranges.map { r -> Range<Int> in
            var r = r
            while r.length > 0, let last = Unicode.Scalar(ns.character(at: r.location + r.length - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(last) { r.length -= 1 }
            return r.location..<(r.location + r.length)
        }
        if out.isEmpty { out = [0..<0] }
        return out
    }

    /// CTFramesetter's line ranges in a frame `width` wide (trailing white space dropped, an empty text is one empty line).
    func frameLines(_ attributed: NSAttributedString, width: CGFloat) -> [Range<Int>] {
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        return trimmedRanges(lines.map { let r = CTLineGetStringRange($0); return NSRange(location: r.location, length: r.length) }, in: attributed.string as NSString)
    }

    func textKitLines(_ attributed: NSAttributedString, width: CGFloat) -> [Range<Int>] {
        trimmedRanges(CoreTextPlazaEngine.breaks(attributed, width: width), in: attributed.string as NSString)
    }

    private func makeBreaks() throws -> PlazaBreaksGolden {
        let sizes: [PlazaTextSize] = [.small, .body]
        var clusterTable: [[[[Double]]]] = []
        var cases: [PlazaBreaksGolden.Case] = []
        for (fi, size) in sizes.enumerated() {
            let font = PlazaResources.font(size)
            let metrics = graphics.text.metrics(.plaza(size))
            let maxHeight = ((metrics.ascender - metrics.descender + metrics.leading) * 8).rounded(.up)   // the chat bubble's eight lines
            clusterTable.append(PlazaBreakCorpus.texts.map { text in
                var end = 0
                return clusters(of: text, font: font).map { c in end = c.utf16.upperBound; return [Double(end), Double(c.width), PlazaBreaksGolden.flags(c)] }
            })
            for (ti, text) in PlazaBreakCorpus.texts.enumerated() {
                let attributed = NSAttributedString(string: text, attributes: CoreTextPlazaEngine.attributes(.plaza(size)))
                let paragraph = graphics.text.paragraph(text, font: .plaza(size), alignment: .center)
                for (wi, width) in PlazaBreakCorpus.widths.enumerated() {
                    let fit = paragraph.suggestedSize(limit: CGSize(width: width, height: maxHeight))
                    let frameSize = CGSize(width: min(max(fit.width, 1).rounded(.up), width), height: min(max(fit.height, 1).rounded(.up), maxHeight))
                    cases.append(.init(font: fi, text: ti, width: wi,
                                       kit: PlazaBreaksGolden.flat(textKitLines(attributed, width: width)),
                                       frame: PlazaBreaksGolden.flat(frameLines(attributed, width: width)),
                                       suggested: [Double(fit.width), Double(fit.height)], visible: paragraph.visibleLength(in: frameSize)))
                }
            }
        }
        return PlazaBreaksGolden(texts: PlazaBreakCorpus.texts, widths: PlazaBreakCorpus.widths.map(Double.init), fonts: ["small", "body"],
                                 clusters: clusterTable, cases: cases)
    }

    // MARK: spritekit-swatches.json

    /// Known premultiplied pixels (`PlazaPremultiply` of straight colours): 8 × 8 with alpha 0 … 255, and a 2 × 2 of
    /// opaque primaries and white, and an opaque 8 × 8 "light" around the neutral 0.5 of the campfire's light bitmap.
    private func swatchTextures() -> [String: PlazaSwatchFile.Texture] {
        var straight = [UInt8]()
        let alphas: [UInt8] = [255, 255, 192, 128, 128, 64, 32, 0]
        for y in 0..<8 { for x in 0..<8 { straight += [UInt8(x * 32 + 10), UInt8(y * 32 + 10), UInt8(((x + y) * 18 + 30) & 255), alphas[(x + 2 * y) % 8]] } }
        let grid = PlazaPremultiply.bitmap(straight: straight, width: 8, height: 8)
        var light = [UInt8]()
        for y in 0..<8 { for x in 0..<8 { light += [UInt8(96 + x * 8), UInt8(160 - y * 8), UInt8(128 + ((x + y) % 2) * 32), 255] } }
        let px2: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        return ["grid8": .init(width: 8, height: 8, rgba: PlazaParityGoldens.hex(grid.bytes)),
                "light8": .init(width: 8, height: 8, rgba: PlazaParityGoldens.hex(light)),
                "px2x2": .init(width: 2, height: 2, rgba: PlazaParityGoldens.hex(px2))]
    }

    private func sprite(_ texture: String?, color: [Double] = [1, 1, 1, 1], size: [Double], position: [Double], anchor: [Double] = [0.5, 0.5],
                        scale: [Double] = [1, 1], rotation: Double = 0, alpha: Double = 1, z: Double = 0, blend: String = "alpha",
                        factor: Double = 0) -> PlazaSwatchFile.Sprite {
        .init(texture: texture, color: color, size: size, position: position, anchor: anchor, scale: scale, rotationDegrees: rotation, alpha: alpha, z: z,
              blend: blend, colorBlendFactor: factor)
    }

    private func swatchCases() -> [(name: String, group: String, width: Int, height: Int, sprites: [PlazaSwatchFile.Sprite])] {
        var cases: [(String, String, Int, Int, [PlazaSwatchFile.Sprite])] = []
        // colour blend: a textured sprite over nothing
        let colours: [[Double]] = [[1, 0, 0, 1], [0.2, 0.6, 1, 1], [0.5, 0.5, 0.5, 1]]
        for (ci, color) in colours.enumerated() {
            for f in [0.0, 0.3, 0.5, 1.0] {
                for a in [1.0, 0.5] {
                    cases.append(("colorBlend c\(ci) f\(f) a\(a)", "colorBlend", 8, 8,
                                  [sprite("grid8", color: color, size: [8, 8], position: [4, 4], alpha: a, z: 1, factor: f)]))
                }
            }
        }
        // multiply and multiplyX2 of a plain colour over four backgrounds, source alpha 1, 0.5, 0
        let backgrounds: [(String, [Double]?)] = [("opaqueGray", [0.5, 0.5, 0.5, 1]), ("opaqueOrange", [0.8, 0.4, 0.2, 1]),
                                                  ("halfOrange", [0.8, 0.4, 0.2, 0.5]), ("nothing", nil)]
        for blend in ["multiply", "multiplyX2"] {
            for (bn, bg) in backgrounds {
                for a in [1.0, 0.5, 0.0] {
                    var sprites: [PlazaSwatchFile.Sprite] = []
                    if let bg { sprites.append(sprite(nil, color: bg, size: [4, 4], position: [2, 2], z: 1)) }
                    sprites.append(sprite(nil, color: [0.6, 0.8, 1, a], size: [4, 4], position: [2, 2], z: 2, blend: blend))
                    cases.append(("\(blend) over \(bn) alpha \(a)", blend, 4, 4, sprites))
                }
            }
        }
        // a textured light (opaque bitmap, neutral 0.5) through both modes
        for blend in ["multiply", "multiplyX2"] {
            for (bn, bg) in backgrounds.prefix(3) {
                cases.append(("\(blend) light8 over \(bn)", blend, 8, 8,
                              [sprite(nil, color: bg!, size: [8, 8], position: [4, 4], z: 1), sprite("light8", size: [8, 8], position: [4, 4], z: 2, blend: blend)]))
            }
        }
        // the daylight: an untextured colour with .multiply at colorBlendFactor 1
        for a in [1.0, 0.5] {
            cases.append(("daylight multiply factor 1 alpha \(a)", "daylight", 4, 4,
                          [sprite(nil, color: [0.8, 0.4, 0.2, 1], size: [4, 4], position: [2, 2], z: 1),
                           sprite(nil, color: [0.25, 0.35, 0.7, a], size: [4, 4], position: [2, 2], z: 2, blend: "multiply", factor: 1)]))
        }
        // nearest sampling of a 2 x 2 texture at scale 3, and shifted by fractions of a device pixel
        for off in [0.0, 0.25, 0.5, 0.75] {
            cases.append(("nearest 2x2 scale 3 x+\(off)", "nearest", 10, 10,
                          [sprite("px2x2", size: [2, 2], position: [5 + off, 5], scale: [3, 3], z: 1)]))
        }
        cases.append(("nearest 2x2 scale 3 mirrored x+0.5", "nearest", 10, 10,
                      [sprite("px2x2", size: [2, 2], position: [5.5, 5], scale: [-3, 3], z: 1)]))
        // rotated 7 degrees: edge pixels
        cases.append(("rotated 7 degrees grid8", "rotation", 16, 16, [sprite("grid8", size: [8, 8], position: [8, 8], rotation: 7, z: 1)]))
        cases.append(("rotated 7 degrees plain", "rotation", 16, 16, [sprite(nil, color: [1, 0.5, 0, 1], size: [8, 8], position: [8, 8], rotation: 7, z: 1)]))
        return cases
    }

    /// SKRenderer, offscreen, one fresh renderer per case, 15 settling passes (the harness's warm-up), then the pixels.
    private func renderSwatch(_ renderer: PlazaOffscreenRenderer, _ swatches: PlazaSwatchFile, _ c: PlazaSwatchFile.Case) -> [UInt8] {
        renderer.startFresh()
        let stage = SpriteKitStage(size: CGSize(width: c.width, height: c.height))
        stage.root.addChild(swatches.tree(of: c))
        for _ in 0..<PlazaRenderRun.warmUpPasses {
            renderer.pass(stage.skScene, points: CGSize(width: c.width, height: c.height), pixels: (c.width, c.height), time: 0)
        }
        let bgra = renderer.bytes()
        var rgba = [UInt8](repeating: 0, count: bgra.count)
        for i in stride(from: 0, to: bgra.count, by: 4) { rgba[i] = bgra[i + 2]; rgba[i + 1] = bgra[i + 1]; rgba[i + 2] = bgra[i]; rgba[i + 3] = bgra[i + 3] }
        return rgba
    }

    private func makeSwatches() throws -> PlazaSwatchFile {
        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        var file = PlazaSwatchFile(textures: swatchTextures(), cases: [])
        for d in swatchCases() {
            var c = PlazaSwatchFile.Case(name: d.name, group: d.group, width: d.width, height: d.height, sprites: d.sprites, rgba: "")
            c.rgba = PlazaParityGoldens.hex(renderSwatch(renderer, file, c))
            file.cases.append(c)
        }
        return file
    }

    // MARK: canvas-script

    private let scriptPlate = PlazaColor(hex: 0xFF9ECF)

    /// `script.png` and the plate, bubble and emote at scale 1 and 2.
    private func makeCanvasImages() throws -> [String: PlazaImage] {
        var out: [String: PlazaImage] = [:]
        let canvas = try XCTUnwrap(graphics.makeCanvas(width: PlazaCanvasScript.width, height: PlazaCanvasScript.height, colorSpace: .sRGB))
        PlazaCanvasScript.run(canvas, graphics.text)
        out["script.png"] = try XCTUnwrap(canvas.makeImage())
        for scale in [1, 2] {
            out["plate@\(scale).png"] = try XCTUnwrap(PlazaNamePlate.image(text: "도토리 Ab", color: scriptPlate, scale: CGFloat(scale)))
            out["bubble@\(scale).png"] = try XCTUnwrap(PlazaChatBubble.image(text: "안녕 hello 🔥 긴 줄은 접힌다", scale: CGFloat(scale)))
            out["emote@\(scale).png"] = PlazaEmoteArt.image(.heart, scale: CGFloat(scale))
        }
        return out
    }

    // MARK: writer and checker

    private var writing: Bool { ProcessInfo.processInfo.environment["PTB_PLAZA_GOLDENS_WRITE"] == "1" }

    func testWriteParityGoldens() throws {
        guard writing else { throw XCTSkip("PTB_PLAZA_GOLDENS_WRITE=1 writes Tests/PlazaParityGoldens") }
        let fm = FileManager.default
        try fm.createDirectory(at: PlazaParityGoldens.url("canvas-script"), withIntermediateDirectories: true)
        try PlazaParityGoldens.encode(makePremultiply()).write(to: PlazaParityGoldens.url("premultiply.json"))
        try PlazaParityGoldens.encode(makeFillGray()).write(to: PlazaParityGoldens.url("fill-gray.json"))
        try PlazaParityGoldens.encode(makeFontMetrics()).write(to: PlazaParityGoldens.url("font-metrics.json"))
        try PlazaParityGoldens.encode(makeBreaks()).write(to: PlazaParityGoldens.url("breaks.json"))
        try PlazaParityGoldens.encode(makeCorners()).write(to: PlazaParityGoldens.url("corners.json"))
        try PlazaParityGoldens.encode(makeSwatches()).write(to: PlazaParityGoldens.url("spritekit-swatches.json"))
        for (name, image) in try makeCanvasImages() {
            try XCTUnwrap(graphics.encodePNG(image)).write(to: PlazaParityGoldens.url("canvas-script/" + name))
        }
    }

    private func decodedPixels(_ data: Data) throws -> PlazaBitmap {
        try XCTUnwrap(graphics.decodeImage(data), "a PNG").pixels
    }

    /// Re-measures every golden on this Mac and compares: JSON files must be identical (swatches: within one level a
    /// channel, the GPU's rounding), PNGs equal pixel for pixel.
    func testParityGoldensStillHoldOnThisMac() throws {
        func same<T: Codable>(_ name: String, _ fresh: @autoclosure () throws -> T) throws {
            let stored = try Data(contentsOf: PlazaParityGoldens.url(name))
            XCTAssertTrue(try PlazaParityGoldens.encode(fresh()) == stored,
                          "\(name) no longer matches what this Mac measures: a SpriteKit, CoreGraphics, CoreText or SwiftUI behaviour moved. Regenerate with PTB_PLAZA_GOLDENS_WRITE=1 and review the diff.")
        }
        try same("premultiply.json", makePremultiply())
        try same("fill-gray.json", makeFillGray())
        try same("font-metrics.json", makeFontMetrics())
        try same("corners.json", makeCorners())
        try same("breaks.json", makeBreaks())

        let stored = try PlazaParityGoldens.load(PlazaSwatchFile.self, "spritekit-swatches.json")
        let fresh = try makeSwatches()
        XCTAssertEqual(stored.cases.map(\.name), fresh.cases.map(\.name))
        XCTAssertEqual(try PlazaParityGoldens.encode(stored.textures.mapValues { $0.rgba }), try PlazaParityGoldens.encode(fresh.textures.mapValues { $0.rgba }))
        for (a, b) in zip(stored.cases, fresh.cases) {
            XCTAssertEqual(a.sprites.count, b.sprites.count, a.name)
            let x = PlazaParityGoldens.bytes(fromHex: a.rgba), y = PlazaParityGoldens.bytes(fromHex: b.rgba)
            XCTAssertEqual(x.count, y.count, a.name)
            let worst = zip(x, y).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "swatch '\(a.name)': SpriteKit now draws pixels up to \(worst) levels away from the golden")
        }

        for (name, image) in try makeCanvasImages() {
            let golden = try decodedPixels(Data(contentsOf: PlazaParityGoldens.url("canvas-script/" + name)))
            XCTAssertEqual(image.pixels, golden, "canvas-script/\(name) changed")
        }
    }
}


// MARK: Mac tests of the shared code against the platform it copies

extension PlazaParityGoldensMacTests {
    /// The shared formula equals CoreGraphics for all 65,536 pairs, and every bundled PNG, decoded as straight alpha and
    /// premultiplied by the shared code, gives `PlazaImage.pixels` (what a context draw makes) byte for byte.
    func testPremultiplyReproducesCoreGraphics() throws {
        let table = try coreGraphicsPremultiplyTableForTests()
        for a in 0..<256 {
            for c in 0..<256 where PlazaPremultiply.premultiplied(UInt8(c), alpha: UInt8(a)) != table[a * 256 + c] {
                XCTFail("colour \(c) alpha \(a): CoreGraphics \(table[a * 256 + c]), PlazaPremultiply \(PlazaPremultiply.premultiplied(UInt8(c), alpha: UInt8(a)))")
                return
            }
        }
        var checked = 0
        for (name, ext) in [("plaza-tiles", "png"), ("plaza-water-balloon", "png"), ("plaza-tallgrass", "png"), ("plaza-ice-cracks", "png"), ("plaza-ice-gloss", "png")] {
            let url = try XCTUnwrap(PlatformPlaza.graphics.assetURL(name, ext: ext))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.alphaInfo, .last, "\(name): ImageIO hands the PNG over as straight alpha")
            XCTAssertEqual(image.bitsPerPixel, 32, name)
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            var straight = [UInt8]()
            straight.reserveCapacity(image.width * image.height * 4)
            for y in 0..<image.height { straight += data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * 4)] }
            let made = PlazaPremultiply.bitmap(straight: straight, width: image.width, height: image.height)
            XCTAssertEqual(made.bytes, PlazaImage(cgImage: image).pixels.bytes, "\(name): PlazaPremultiply equals the context draw")
            checked += 1
        }
        XCTAssertEqual(checked, 5)
    }

    /// `PlazaPremultiply.straight` is what ImageIO writes: every premultiplied (colour <= alpha, alpha) pair through a
    /// PNG encode and decode.
    func testStraightReproducesImageIOsPNGWriter() throws {
        let n = 256
        var premultiplied = [UInt8](repeating: 0, count: n * n * 4)
        for a in 0..<n { for c in 0..<n { let i = (a * n + c) * 4, v = UInt8(min(c, a)); premultiplied[i] = v; premultiplied[i + 1] = v; premultiplied[i + 2] = v; premultiplied[i + 3] = UInt8(a) } }
        var bitmap = PlazaBitmap(width: n, height: n)
        bitmap.bytes = premultiplied
        let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(PlazaImage(bitmap: bitmap)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.alphaInfo, .last)
        let data = try XCTUnwrap(decoded.dataProvider?.data as Data?)
        let mine = PlazaPremultiply.straight(bitmap)
        for a in 0..<n {
            for c in 0..<n {
                let at = a * decoded.bytesPerRow + c * 4
                if a == 0 { continue }   // alpha 0 carries no colour; ImageIO writes whatever it likes
                XCTAssertEqual(mine[(a * n + c) * 4], data[at], "premultiplied \(min(c, a)) alpha \(a)")
                if mine[(a * n + c) * 4] != data[at] { return }
            }
        }
    }

    /// `PlazaContinuousCorners` against SwiftUI itself over a seeded random matrix (the golden pins a fixed one): within
    /// SwiftUI's single-precision step everywhere, bit-exact (1e-9) on uniform rectangles where the arithmetic is the same.
    func testContinuousCornersEqualSwiftUI() throws {
        var rng = SplitMix(seed: 20_261_115)
        var exact = 0, band = 0
        var unevenGaps: [String] = []
        for _ in 0..<1500 {
            let rect = CGRect(x: Double(rng.int(0, 20)), y: Double(rng.int(0, 20)), width: Double(rng.int(4, 400)), height: Double(rng.int(4, 400)))
            let r = CGFloat([0, Double(rng.int(1, 30)), Double(rng.int(1, 120))][rng.int(0, 2)])
            let theirs = swiftUIRounded(rect, r)
            let mine = PlazaContinuousCorners.roundedRect(rect, radius: r)
            let d = distance(mine, theirs)
            if PlazaContinuousCornersTests.exactRegime(rect, [Double(r)]) { exact += 1; XCTAssertLessThanOrEqual(d, 1e-9, "uniform \(rect) r \(r)") }
            else { band += 1; XCTAssertLessThanOrEqual(d, 3e-5, "uniform \(rect) r \(r)") }
            let radii = (0..<4).map { _ in CGFloat([0, Double(rng.int(1, 30)), Double(rng.int(1, 30))][rng.int(0, 2)]) }
            let uneven = PlazaContinuousCorners.unevenRoundedRect(rect, radii: PlazaCornerRadii(topLeading: radii[0], bottomLeading: radii[1], bottomTrailing: radii[2], topTrailing: radii[3]))
            if distance(uneven, swiftUIUneven(rect, radii)) > 3e-5 { unevenGaps.append("\(rect) \(radii)") }
        }
        XCTAssertGreaterThan(exact, 500)
        XCTAssertGreaterThan(band, 100)
        // Known gap: four radii that together overfill a small rectangle (sides about the radii) are shared out by SwiftUI in
        // a way the cap rule does not always reproduce (8 of 20,000 in an offline run); the golden's cases all match.
        XCTAssertLessThanOrEqual(unevenGaps.count, 5, "uneven shapes beyond the single-precision step: \(unevenGaps.prefix(5))")
    }

    /// The breaker, run on live CoreText clusters (not the golden) for a text the golden does not hold.
    func testLineBreakerOnLiveClusters() throws {
        let text = "토큰을 오늘 많이 썼어요 정말로요 그래서 조금 쉬어갈게요"
        for size in PlazaTextSize.allCases {
            let font = PlazaResources.font(size)
            let attributed = NSAttributedString(string: text, attributes: CoreTextPlazaEngine.attributes(.plaza(size)))
            let cl = clusters(of: text, font: font)
            for width in [60.0, 90, 130, 180, 260] {
                XCTAssertEqual(PlazaLineBreaker.lines(cl, width: CGFloat(width), rule: .swiftUIText), textKitLines(attributed, width: CGFloat(width)), "TextKit \(size) \(width)")
                XCTAssertEqual(PlazaLineBreaker.lines(cl, width: CGFloat(width), rule: .coreTextFrame), frameLines(attributed, width: CGFloat(width)), "CTFramesetter \(size) \(width)")
            }
        }
    }

    /// `CGPlazaCanvas.makeImage` tags what it made: no text, text, and a crop keeps the tag.
    func testCanvasImagesCarryTheirOrigin() throws {
        let plain = try XCTUnwrap(PlatformPlaza.graphics.makeCanvas(width: 8, height: 8, colorSpace: .sRGB))
        plain.setFillColor(PlazaColor(hex: 0xFF0000))
        plain.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        _ = plain.imageBounds(of: PlatformPlaza.graphics.text.line("Ab", font: .plaza(.small)))   // measuring draws nothing
        let image = try XCTUnwrap(plain.makeImage())
        XCTAssertEqual(image.origin, .canvas)
        XCTAssertEqual(image.cropping(to: PlazaPixelRect(x: 0, y: 0, width: 4, height: 4))?.origin, .canvas)
        let texty = try XCTUnwrap(PlatformPlaza.graphics.makeCanvas(width: 24, height: 16, colorSpace: .sRGB))
        texty.draw(PlatformPlaza.graphics.text.line("Ab", font: .plaza(.small)), at: CGPoint(x: 1, y: 3))
        XCTAssertEqual(try XCTUnwrap(texty.makeImage()).origin, .canvasWithText)
        let paragraphs = try XCTUnwrap(PlatformPlaza.graphics.makeCanvas(width: 24, height: 16, colorSpace: .sRGB))
        paragraphs.draw(PlatformPlaza.graphics.text.paragraph("Ab", font: .plaza(.small), alignment: .natural), in: CGRect(x: 0, y: 0, width: 24, height: 16))
        XCTAssertEqual(try XCTUnwrap(paragraphs.makeImage()).origin, .canvasWithText)
        XCTAssertEqual(PlazaImage(bitmap: PlazaTestImages.solid(width: 1, height: 1, PlazaRGBA(r: 0, g: 0, b: 0, a: 0))).origin, .pixels)
        XCTAssertEqual(try XCTUnwrap(PlatformPlaza.graphics.decodeImage(try XCTUnwrap(PlatformPlaza.graphics.encodePNG(image)))).origin, .pixels)
        // real art: the plate and the bubble carry text, the emote does not
        XCTAssertEqual(PlazaNamePlate.image(text: "Ab", color: PlazaColor(hex: 0xFFFFFF), scale: 1)?.origin, .canvasWithText)
        XCTAssertEqual(PlazaChatBubble.image(text: "Ab", scale: 1)?.origin, .canvasWithText)
        XCTAssertEqual(PlazaEmoteArt.image(.heart, scale: 1).origin, .canvas)
    }
}

extension PlazaParityGoldensMacTests {
    fileprivate func coreGraphicsPremultiplyTableForTests() throws -> [UInt8] { try coreGraphicsPremultiplyTable() }
}

/// A seeded generator, so the random matrix is the same on every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
}

private extension CGPath {
    /// A SwiftUI `Path` of this `CGPath`, to read its elements the same way as SwiftUI's own.
    var swiftUIPath: Path { Path(self) }
}
