import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import PokeTokenBar

/// What the Mac measured once and the Windows plaza renderer must match (stage 6, Task 1). The files live in
/// `Tests/PlazaParityGoldens/`, outside the test target (so the Windows build, which excludes non-Swift files from the
/// target, never sees them) and are read through `#filePath`. They are written by one command on a Mac and checked by
/// `PlazaParityGoldensMacTests.testParityGoldensStillHoldOnThisMac` on every Mac run:
///
///     PTB_PLAZA_GOLDENS_WRITE=1 swift test --filter PlazaParityGoldensMacTests/testWriteParityGoldens
///
/// Shared code: the Windows tests decode the same types.
enum PlazaParityGoldens {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlazaParityGoldens", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url(name)))
    }

    /// Compact JSON with sorted keys and a final newline: the same value always writes the same bytes.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(fromHex text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count / 2)
        var high: UInt8?
        for c in text.utf8 {
            let v: UInt8 = c >= 97 ? c - 87 : c - 48
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return out
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

// MARK: premultiply.json

/// `PlazaImage.pixels` of every bundled PNG and ice GIF frame (SHA-256), and the straight → premultiplied table
/// CoreGraphics makes: all 65,536 `(colour, alpha)` pairs, row = alpha, column = colour, as one SHA-256 over the 65,536
/// bytes and every 17th row spelled out (so a failing hash can be located without the whole table).
struct PlazaPremultiplyGolden: Codable {
    var images: [String: String]
    var tableSHA256: String
    var rows: [String: String]
}

// MARK: fill-gray.json

/// `setFillGray(g)` on a device-RGB canvas: the bytes (R, G, B, A) of the filled pixel for g = 0, 0.05 … 1.
struct PlazaFillGrayGolden: Codable {
    var steps: [Double]
    var deviceRGB: [[Int]]
    var sRGB: [[Int]]
}

// MARK: font-metrics.json

struct PlazaFontMetricsGolden: Codable {
    struct Entry: Codable {
        var size: Double
        var nsAscender: Double, nsDescender: Double, nsLeading: Double
        var ctAscent: Double, ctDescent: Double, ctLeading: Double
        var unitsPerEm: Int
        var hheaAscender: Int, hheaDescender: Int, hheaLineGap: Int
    }
    var fonts: [String: Entry]
}

// MARK: corners.json

/// SwiftUI's `.continuous` rounded rectangles as elements: `[0, x, y]` move, `[1, x, y]` line,
/// `[2, x, y, c1x, c1y, c2x, c2y]` curve, `[3]` close; coordinates rounded to 1e-10.
struct PlazaCornersGolden: Codable {
    struct Case: Codable {
        /// "rounded": `Path(roundedRect:cornerRadius:style: .continuous)` in the rect's own coordinates;
        /// "uneven": `UnevenRoundedRectangle` in canvas coordinates (`CGPlazaCanvas.unevenRoundedRect`).
        var kind: String
        var rect: [Double]       // x, y, width, height
        var radii: [Double]      // rounded: [r]; uneven: topLeading, bottomLeading, bottomTrailing, topTrailing
        var elements: [[Double]]
    }
    var cases: [Case]

    static func flatten(_ elements: [PlazaCurveElement]) -> [[Double]] {
        func r(_ v: CGFloat) -> Double { (Double(v) * 1e10).rounded() / 1e10 + 0 }   // + 0 turns -0 into 0
        return elements.map {
            switch $0 {
            case .move(let p): [0, r(p.x), r(p.y)]
            case .line(let p): [1, r(p.x), r(p.y)]
            case .curve(let p, let c1, let c2): [2, r(p.x), r(p.y), r(c1.x), r(c1.y), r(c2.x), r(c2.y)]
            case .close: [3]
            }
        }
    }

    static func unflatten(_ rows: [[Double]]) -> [PlazaCurveElement] {
        rows.map {
            switch Int($0[0]) {
            case 0: .move(CGPoint(x: $0[1], y: $0[2]))
            case 1: .line(CGPoint(x: $0[1], y: $0[2]))
            case 2: .curve(to: CGPoint(x: $0[1], y: $0[2]), c1: CGPoint(x: $0[3], y: $0[4]), c2: CGPoint(x: $0[5], y: $0[6]))
            default: .close
            }
        }
    }

    /// The rectangles and radii the golden covers: sides 4 … 400, radii 0 … 30 (and a radius above half a side).
    static let roundedRects: [CGRect] = [
        CGRect(x: 0, y: 0, width: 4, height: 4), CGRect(x: 0, y: 0, width: 400, height: 4), CGRect(x: 5, y: 7, width: 30, height: 30),
        CGRect(x: 0, y: 0, width: 37, height: 30), CGRect(x: 3, y: 2, width: 100, height: 60), CGRect(x: 0, y: 0, width: 123.5, height: 40.5),
        CGRect(x: 0, y: 0, width: 211, height: 100), CGRect(x: 0, y: 0, width: 400, height: 400),
    ]
    static let roundedRadii: [CGFloat] = [0, 1, 3, 8, 12, 20, 30]
    static let unevenRects: [CGRect] = [
        CGRect(x: 0, y: 0, width: 100, height: 60), CGRect(x: 5, y: 7, width: 36, height: 46), CGRect(x: 0, y: 0, width: 211, height: 30),
        CGRect(x: 0, y: 0, width: 400, height: 400),
    ]
    /// topLeading, bottomLeading, bottomTrailing, topTrailing.
    static let unevenRadii: [[CGFloat]] = [
        [10, 0, 20, 5], [30, 0, 0, 0], [0, 0, 0, 30], [30, 20, 0, 0], [0, 0, 0, 0], [30, 30, 30, 30], [47, 9, 50, 59], [20, 0, 0, 20],
    ]
}

// MARK: breaks.json

/// TextKit's `.standard` line ranges and CTFramesetter's line ranges for the corpus (`PlazaBreakCorpus`) at the widths
/// of `PlazaBreakCorpus.widths`, in both Galmuri sizes, with the clusters `PlazaLineBreaker` is fed. A cluster is
/// `[utf16End, width, flags]` (the start is the previous end); flags: 1 white space, 2 newline, 4 can break after,
/// 8 Hangul, 16 word character.
struct PlazaBreaksGolden: Codable {
    struct Case: Codable {
        var font: Int            // 0 small (Galmuri11 12 pt), 1 body (Galmuri14 15 pt)
        var text: Int
        var width: Int
        var kit: [Int]           // TextKit `.standard` (as `CoreTextPlazaEngine.breaks`): lo, hi, lo, hi …
        var frame: [Int]         // CTFramesetter in a frame `width` wide
        var suggested: [Double]  // `suggestedSize` for the chat bubble's limit (width, 8 lines): w, h
        var visible: Int         // `visibleLength` in that suggested size
    }
    var texts: [String]
    var widths: [Double]
    var fonts: [String]
    var clusters: [[[[Double]]]]   // [font][text][cluster] = [end, width, flags]
    var cases: [Case]

    static func flags(_ c: PlazaBreakCluster) -> Double {
        Double((c.isWhitespace ? 1 : 0) | (c.isNewline ? 2 : 0) | (c.canBreakAfter ? 4 : 0) | (c.isHangul ? 8 : 0) | (c.isWordCharacter ? 16 : 0))
    }

    func breakClusters(font: Int, text: Int) -> [PlazaBreakCluster] {
        var start = 0
        return clusters[font][text].map { row in
            let end = Int(row[0]), f = Int(row[2])
            defer { start = end }
            return PlazaBreakCluster(utf16: start..<end, width: CGFloat(row[1]), isWhitespace: f & 1 != 0, isNewline: f & 2 != 0,
                                     canBreakAfter: f & 4 != 0, isHangul: f & 8 != 0, isWordCharacter: f & 16 != 0)
        }
    }

    static func ranges(_ flat: [Int]) -> [Range<Int>] { stride(from: 0, to: flat.count, by: 2).map { flat[$0]..<flat[$0 + 1] } }
    static func flat(_ ranges: [Range<Int>]) -> [Int] { ranges.flatMap { [$0.lowerBound, $0.upperBound] } }
}

// MARK: spritekit-swatches.json

/// SpriteKit's own pixels for small synthetic scenes: what a renderer that draws `PlazaSprite`s must reproduce. Scenes
/// are `width × height` points at one pixel per point, origin bottom-left, no camera, cleared to transparent black;
/// pixels are premultiplied RGBA, row 0 at the top.
struct PlazaSwatchFile: Codable {
    struct Texture: Codable {
        var width: Int, height: Int
        var rgba: String           // premultiplied RGBA hex, row 0 at the top
    }
    struct Sprite: Codable {
        var texture: String?       // a key of `textures`; nil = a plain colour rectangle
        var color: [Double]        // sRGB r, g, b, a
        var size: [Double]         // the sprite's size as assigned, before its own scale
        var position: [Double]
        var anchor: [Double]
        var scale: [Double]
        var rotationDegrees: Double
        var alpha: Double
        var z: Double
        var blend: String          // "alpha", "multiply", "multiplyX2"
        var colorBlendFactor: Double
    }
    struct Case: Codable {
        var name: String
        var group: String
        var width: Int, height: Int
        var sprites: [Sprite]      // drawn in this order (z ascending, ties in order)
        var rgba: String           // the pixels SpriteKit drew
    }
    var textures: [String: Texture]
    var cases: [Case]

    /// The shared tree of a case: one root, the sprites in order.
    @MainActor func tree(of c: Case) -> PlazaNode {
        let root = PlazaNode()
        for s in c.sprites {
            let sprite: PlazaSprite
            if let key = s.texture, let t = textures[key] {
                let bitmap = PlazaBitmap(width: t.width, height: t.height, bytes: PlazaParityGoldens.bytes(fromHex: t.rgba))
                sprite = PlazaSprite(texture: PlazaTexture(PlazaImage(bitmap: bitmap)), size: CGSize(width: s.size[0], height: s.size[1]))
                sprite.color = PlazaColor(srgbRed: s.color[0], green: s.color[1], blue: s.color[2], alpha: s.color[3])
            } else {
                sprite = PlazaSprite(color: PlazaColor(srgbRed: s.color[0], green: s.color[1], blue: s.color[2], alpha: s.color[3]),
                                     size: CGSize(width: s.size[0], height: s.size[1]))
            }
            sprite.anchorPoint = CGPoint(x: s.anchor[0], y: s.anchor[1])
            sprite.position = CGPoint(x: s.position[0], y: s.position[1])
            sprite.xScale = CGFloat(s.scale[0])
            sprite.yScale = CGFloat(s.scale[1])
            sprite.zRotation = CGFloat(s.rotationDegrees * Double.pi / 180)
            sprite.alpha = CGFloat(s.alpha)
            sprite.zPosition = CGFloat(s.z)
            sprite.colorBlendFactor = CGFloat(s.colorBlendFactor)
            sprite.blendMode = s.blend == "multiply" ? .multiply : (s.blend == "multiplyX2" ? .multiplyX2 : .alpha)
            root.addChild(sprite)
        }
        return root
    }
}

extension PlazaBitmap {
    /// Packed premultiplied RGBA bytes as a bitmap.
    init(width: Int, height: Int, bytes: [UInt8]) {
        self.init(width: width, height: height)
        precondition(bytes.count == width * height * 4)
        self.bytes = bytes
    }
}

// MARK: canvas-script

/// One scripted drawing through the canvas that uses every method (the sequence of Track A Task 3's
/// `MacPlazaGraphicsTests`, with byte-built images only). The Mac's pixels of it are
/// `Tests/PlazaParityGoldens/canvas-script/script.png` (64 × 48, sRGB): Windows' canvas must look like them.
enum PlazaCanvasScript {
    static let width = 64, height = 48
    static let small = PlazaImage(bitmap: PlazaTestImages.patterned(width: 6, height: 5))
    static let large = PlazaImage(bitmap: PlazaTestImages.patterned(width: 16, height: 16))
    private static let ink = PlazaColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255)
    private static let pink = PlazaColor(hex: 0xFF9ECF)
    private static let shadow = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)

    static func run(_ c: any PlazaCanvas, _ text: any PlazaTextEngine) {
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
        c.draw(small, in: CGRect(x: 30, y: 2, width: 12, height: 9))
        c.translate(x: 50, y: 30)
        c.scale(x: -1, y: 1)
        c.draw(large, in: CGRect(x: 0, y: 0, width: 10, height: 14))
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
        let tiny = text.line("Zz", font: .plaza(.small))
        let b = c.imageBounds(of: tiny)
        c.draw(tiny, at: CGPoint(x: (40 - b.midX).rounded(), y: (10 - b.midY).rounded()))
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
}
