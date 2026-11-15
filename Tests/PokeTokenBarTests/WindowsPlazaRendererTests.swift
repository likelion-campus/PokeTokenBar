#if os(Windows)
import CPlazaD2D
import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 4 on Windows: the shared plaza tree drawn by Direct2D, offscreen on WARP (no window, no swap chain), against
/// SpriteKit's measured pixels (`spritekit-swatches.json`) and against analytic expectations where the golden cannot
/// speak. Rotation: the golden's two 7° cases are drawn at one texel per pixel, where a 7° turn of an 8-pixel sprite moves
/// every pixel centre by less than half a texel, so SpriteKit's pixels equal the unrotated sprite's (probed on the Mac: a
/// plain `SKSpriteNode` gives the same, 30° turns visibly). They are matched like the other groups, and larger angles at
/// scale 3 and backing 1.5 are checked analytically (`rotationErrors`).
@MainActor
final class WindowsPlazaRendererTests: XCTestCase {
    // MARK: Rig

    @MainActor private struct Rig {
        let stage: WinPlazaStage
        let surface: WinGfxSurface
        let renderer: WinPlazaRenderer
        var device: WinGfxDevice { surface.device }
    }

    private func makeDevice(warp: Bool = true) throws -> WinGfxDevice {
        switch WinGfxDevice.make(forceWarp: warp) {
        case .success(let d): return d
        case .failure(let e):
            XCTFail("no Direct2D device: \(e)")
            throw e
        }
    }

    private func rig(_ device: WinGfxDevice, points: CGSize, backing: CGFloat) throws -> Rig {
        let stage = WinPlazaStage(size: points)
        stage.setBackingScale(backing)
        let w = Int((points.width * backing).rounded()), h = Int((points.height * backing).rounded())
        let surface = try WinGfxSurface.offscreen(device: device, width: w, height: h).get()
        return Rig(stage: stage, surface: surface, renderer: WinPlazaRenderer(surface: surface))
    }

    /// One frame cleared to transparent (as the Mac harness: SKRenderer draws no background), read back as RGBA.
    private func frame(_ r: Rig, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        r.stage.setNeedsDraw()
        let result = r.renderer.drawIfNeeded(stage: r.stage, transparent: true)
        XCTAssertEqual(result, .drawn, file: file, line: line)
        XCTAssertEqual(r.renderer.stats.failedFrames, 0, "a frame failed: \(WinPlazaCodecs.lastError())", file: file, line: line)
        return r.surface.readRGBA() ?? []
    }

    private func pixel(_ rgba: [UInt8], width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        guard i >= 0, i + 4 <= rgba.count else { return [] }
        return Array(rgba[i..<i + 4])
    }

    private func sprite(_ color: PlazaColor, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, z: CGFloat = 0) -> PlazaSprite {
        let s = PlazaSprite(color: color, size: CGSize(width: w, height: h))
        s.anchorPoint = .zero
        s.position = CGPoint(x: x, y: y)
        s.zPosition = z
        return s
    }

    // MARK: Checks (each returns what is wrong, so the fault test can run them too)

    /// The worst channel difference per golden group, and where it was.
    private func swatchErrors(_ device: WinGfxDevice, groups: Set<String>? = nil) throws -> (worst: [String: Int], at: [String: String]) {
        let file = try PlazaParityGoldens.load(PlazaSwatchFile.self, "spritekit-swatches.json")
        var worst: [String: Int] = [:], at: [String: String] = [:]
        for c in file.cases where groups?.contains(c.group) ?? true {
            let r = try rig(device, points: CGSize(width: c.width, height: c.height), backing: 1)
            r.stage.root.addChild(file.tree(of: c))
            let got = frame(r)
            let want = PlazaParityGoldens.bytes(fromHex: c.rgba)
            var e = got.count == want.count ? 0 : 255, pos = got.count == want.count ? "" : "size \(got.count) vs \(want.count)"
            for i in 0..<min(got.count, want.count) {
                let d = abs(Int(got[i]) - Int(want[i]))
                if d > e { e = d; pos = "pixel \(i / 4 % c.width),\(i / 4 / c.width) channel \(i % 4): \(got[i]) vs SpriteKit \(want[i])" }
            }
            if e > (worst[c.group] ?? -1) { worst[c.group] = e; at[c.group] = "\(c.name): \(pos)" }
        }
        return (worst, at)
    }

    /// How far (device pixels) from a rotated sprite's edge or texel edge a pixel centre may be and still land on the other
    /// side: measured on WARP up to 0.047 px (15 pixels of about 12,000 over 7°, 20°, -33° and 7° at 1.5; run 43685854815).
    /// Exact pixel-centre coverage is the reference; SpriteKit's own rotated edges were not measured at this precision (the
    /// golden's 7° case cannot show a turn).
    private static let rotatedEdgeTolerance = 1.0 / 16

    private static let swatchTolerance = ["colorBlend": 1, "multiply": 1, "daylight": 1, "nearest": 1, "rotation": 1, "multiplyX2": 2]

    private func swatchFailures(_ device: WinGfxDevice) throws -> [String] {
        let (worst, at) = try swatchErrors(device, groups: Set(Self.swatchTolerance.keys))
        return Self.swatchTolerance.keys.sorted().compactMap { g in
            (worst[g] ?? 255) > Self.swatchTolerance[g]! ? "swatch \(g): \(worst[g] ?? -1) (\(at[g] ?? "no case"))" : nil
        }
    }

    /// A cut from the middle of a sheet whose border is pure red, drawn at fractional offsets and scales (mirrored too), at
    /// 1 and 1.25 device pixels per point: no red may show (no bleeding from the neighbours with nearest sampling).
    private func bleedErrors(_ device: WinGfxDevice) throws -> [String] {
        var sheet = PlazaBitmap(width: 6, height: 6, fill: PlazaRGBA(r: 255, g: 0, b: 0, a: 255))
        for y in 1..<5 { for x in 1..<5 { sheet[x, y] = PlazaRGBA(r: 0, g: UInt8(40 * x + 60), b: UInt8(40 * y + 60), a: 255) } }
        let base = PlazaTexture(PlazaImage(bitmap: sheet))
        let inner = PlazaTexture(rect: CGRect(x: 1.0 / 6, y: 1.0 / 6, width: 4.0 / 6, height: 4.0 / 6), in: base)
        let cutOfCut = PlazaTexture(rect: CGRect(x: 2.0 / 6, y: 2.0 / 6, width: 2.0 / 6, height: 2.0 / 6), in: inner)
        var out: [String] = []
        for backing in [1.0, 1.25] as [CGFloat] {
            for (texture, texels) in [(inner, 4.0), (cutOfCut, 2.0)] as [(PlazaTexture, CGFloat)] {
                for scale in [1, 1.5, 2.5, 3, -2] as [CGFloat] {
                    for offset in [0, 0.25, 0.5, 0.75] as [CGFloat] {
                        let r = try rig(device, points: CGSize(width: 40, height: 40), backing: backing)
                        let s = PlazaSprite(texture: texture, size: CGSize(width: texels, height: texels))
                        s.position = CGPoint(x: 20 + offset, y: 20 + offset / 2)
                        s.xScale = scale
                        s.yScale = abs(scale)
                        r.stage.root.addChild(s)
                        let px = frame(r)
                        var red = 0, drawn = 0
                        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
                            drawn += 1
                            if px[i] > 0 { red += 1 }
                        }
                        let expected = Int((texels * abs(scale) * backing) * (texels * abs(scale) * backing))
                        if red > 0 || abs(drawn - expected) > Int(texels * abs(scale) * backing * 2 + 1) {
                            out.append("bleed: \(texels)-texel cut, scale \(scale), offset \(offset), backing \(backing): \(red) red of \(drawn) drawn (expected about \(expected))")
                        }
                    }
                }
            }
        }
        return out
    }

    /// An 8 × 8 texture of distinct opaque texels, rotated, at scale 3: every pixel shows the texel under its centre
    /// (nearest), and every pixel whose centre is outside stays empty. Derived from SpriteKit's placement rule (scale, rotate
    /// about the anchor, move), not from the renderer's code. A pixel that lands on the other side of an edge or a texel edge
    /// counts as a flip only when its centre is within `rotatedEdgeTolerance` of it; anything farther is wrong.
    private func rotationErrors(_ device: WinGfxDevice) throws -> [String] {
        var grid = PlazaBitmap(width: 8, height: 8)
        for y in 0..<8 { for x in 0..<8 { grid[x, y] = PlazaRGBA(r: UInt8(x * 30 + 10), g: UInt8(y * 30 + 10), b: 128, a: 255) } }
        let texture = PlazaTexture(PlazaImage(bitmap: grid))
        var out: [String] = []
        for (degrees, backing) in [(7.0, 1.0), (20.0, 1.0), (-33.0, 1.0), (7.0, 1.5)] as [(Double, CGFloat)] {
            let r = try rig(device, points: CGSize(width: 48, height: 48), backing: backing)
            let s = PlazaSprite(texture: texture, size: CGSize(width: 8, height: 8))
            s.position = CGPoint(x: 24, y: 24)
            s.setScale(3)
            s.zRotation = CGFloat(degrees * .pi / 180)
            r.stage.root.addChild(s)
            let px = frame(r)
            let w = r.surface.width, h = r.surface.height
            let theta = Double(s.zRotation), sc = 3.0, bk = Double(backing)
            var wrong = 0, judged = 0, flips = 0, flipDistance = 0.0, first = ""
            let pxPerTexel = sc * bk
            for py in 0..<h {
                for pxx in 0..<w {
                    let x = (Double(pxx) + 0.5) / bk, y = 48 - (Double(py) + 0.5) / bk
                    let dx = x - 24, dy = y - 24
                    let lx = (cos(-theta) * dx - sin(-theta) * dy) / sc, ly = (sin(-theta) * dx + cos(-theta) * dy) / sc
                    let u = lx / 8 + 0.5, v = 1 - (ly / 8 + 0.5)   // v from the top of the texture
                    let tu = u * 8, tv = v * 8
                    // device pixels from the centre to the nearest sprite edge or texel edge (edges are at 0...8 texels)
                    func gap(_ t: Double) -> Double { abs(t - min(8, max(0, t.rounded()))) * pxPerTexel }
                    let edge = min(gap(tu), gap(tv))
                    judged += 1
                    let got = pixel(px, width: w, pxx, py)
                    let want: [UInt8]
                    if tu > 0, tu < 8, tv > 0, tv < 8 {
                        let c = grid[Int(tu), Int(tv)]
                        want = [c.r, c.g, c.b, c.a]
                    } else {
                        want = [0, 0, 0, 0]
                    }
                    guard zip(got, want).contains(where: { abs(Int($0) - Int($1)) > 1 }) else { continue }
                    if edge < Self.rotatedEdgeTolerance {
                        flips += 1   // the rasterizer's own edge: WARP's coverage of a rotated quad is within this of exact
                        flipDistance = max(flipDistance, edge)
                    } else {
                        wrong += 1
                        if first.isEmpty { first = "(\(pxx),\(py)) \(got) vs \(want), \(edge) px from an edge" }
                    }
                }
            }
            print("ROTATION \(degrees)deg backing=\(backing) judged=\(judged) wrong=\(wrong) edgeFlips=\(flips) farthestFlip=\(String(format: "%.4f", flipDistance))px")
            if wrong > 0 { out.append("rotation \(degrees)° backing \(backing): \(wrong) of \(judged) pixels wrong, first \(first)") }
        }
        return out
    }

    /// Overlapping sprites with an equal-z tie, a crop unit whose child has a lower z than its neighbours, camera children
    /// sorting in the same z space, a hidden subtree, and a zoomed camera. Expected pixels are worked out by hand from the
    /// numbers below (device pixels, backing 2, origin top-left).
    private func orderErrors(_ device: WinGfxDevice) throws -> [String] {
        let red = PlazaColor(srgbRed: 1, green: 0, blue: 0), green = PlazaColor(srgbRed: 0, green: 1, blue: 0)
        let blue = PlazaColor(srgbRed: 0, green: 0, blue: 1), yellow = PlazaColor(srgbRed: 1, green: 1, blue: 0)
        let cyan = PlazaColor(srgbRed: 0, green: 1, blue: 1), magenta = PlazaColor(srgbRed: 1, green: 0, blue: 1)
        let none: [UInt8] = [0, 0, 0, 0]
        func bytes(_ c: PlazaColor) -> [UInt8] { [UInt8(c.red * 255), UInt8(c.green * 255), UInt8(c.blue * 255), 255] }
        var out: [String] = []

        // Stage 40 x 30 pt at backing 2 (80 x 60 px); the camera at world (50, 40), scale 1.
        let r = try rig(device, points: CGSize(width: 40, height: 30), backing: 2)
        let camera = PlazaCameraNode()
        camera.position = CGPoint(x: 50, y: 40)
        r.stage.root.addChild(camera)
        r.stage.camera = camera
        camera.addChild(sprite(yellow, -18, 9, 4, 4, z: 0))       // E: screen [4,12) x [4,12)
        camera.addChild(sprite(cyan, -12, -12, 6, 6, z: 0.5))     // G: screen [16,28) x [42,54)
        camera.addChild(sprite(magenta, -5, -5, 4, 4, z: 3))      // F: screen [30,38) x [32,40)
        r.stage.root.addChild(sprite(red, 40, 30, 10, 10, z: 1))  // A: [20,40) x [30,50)
        r.stage.root.addChild(sprite(green, 45, 35, 10, 10, z: 1))   // B: [30,50) x [20,40), ties with A, later in the tree
        let crop = PlazaCropNode()
        crop.zPosition = 2
        crop.maskRect = CGRect(x: 42, y: 32, width: 4, height: 4)   // [24,32) x [38,46)
        crop.addChild(sprite(blue, 40, 30, 10, 10, z: -5))          // D: global z -3, drawn with its crop unit at 2
        r.stage.root.addChild(crop)
        let hidden = PlazaNode()
        hidden.isHidden = true
        hidden.addChild(sprite(PlazaColor.white, 0, 0, 200, 200, z: 10))
        r.stage.root.addChild(hidden)
        let px = frame(r)
        let expect: [((Int, Int), [UInt8], String)] = [
            ((8, 8), bytes(yellow), "camera child E at the top left"),
            ((8, 50), none, "nothing where E would be without the y-flip"),
            ((17, 50), bytes(cyan), "camera child G alone"),
            ((22, 47), bytes(red), "world A (z 1) above camera child G (z 0.5)"),
            ((25, 35), bytes(red), "A alone"),
            ((26, 40), bytes(blue), "the crop unit (z 2) above A, its child clipped to the mask"),
            ((31, 44), bytes(blue), "crop unit inside its mask"),
            ((23, 40), bytes(red), "A just left of the mask"),
            ((26, 37), bytes(red), "A just above the mask (top edge exclusive of row 37)"),
            ((35, 35), bytes(magenta), "camera child F (z 3) above A and B"),
            ((39, 35), bytes(green), "the tie: B (later in the tree) above A"),
            ((45, 25), bytes(green), "B alone"),
            ((45, 45), none, "nothing"),
            ((70, 5), none, "the hidden subtree draws nothing"),
        ]
        for ((x, y), want, what) in expect where pixel(px, width: 80, x, y) != want {
            out.append("order: (\(x),\(y)) \(pixel(px, width: 80, x, y)) vs \(want): \(what)")
        }

        // Zoom: the camera at scale 0.5 (zoom 2) magnifies the world around its position.
        let z = try rig(device, points: CGSize(width: 40, height: 30), backing: 2)
        let zoomed = PlazaCameraNode()
        zoomed.position = CGPoint(x: 50, y: 40)
        zoomed.setScale(0.5)
        z.stage.root.addChild(zoomed)
        z.stage.camera = zoomed
        let h = PlazaSprite(color: red, size: CGSize(width: 4, height: 4))   // anchor 0.5: [32,48) x [22,38)
        h.position = CGPoint(x: 50, y: 40)
        z.stage.root.addChild(h)
        z.stage.root.addChild(sprite(green, 52, 40, 2, 2))   // J: [48,56) x [22,30)
        let zp = frame(z)
        let zoomExpect: [((Int, Int), [UInt8])] = [((40, 30), bytes(red)), ((47, 22), bytes(red)), ((47, 37), bytes(red)), ((48, 22), bytes(green)),
                                                   ((55, 29), bytes(green)), ((50, 33), none), ((31, 30), none), ((40, 38), none), ((56, 25), none)]
        for ((x, y), want) in zoomExpect where pixel(zp, width: 80, x, y) != want {
            out.append("zoom: (\(x),\(y)) \(pixel(zp, width: 80, x, y)) vs \(want)")
        }
        return out
    }

    /// Tiles of 16 pt with 8 x 8 textures, one device pixel in from the corner (on the device grid, not on whole points
    /// at fractional scales): no pixel inside the tiles is left empty or drawn twice over, and every covered pixel shows the
    /// texel under its centre. At 1.25 many pixel centres sit exactly on a texel edge (1 + 2.5 k device pixels): those take
    /// the texel to their right / below, SpriteKit's rule (the golden's `nearest x+0.5` cases), so the expectation is read
    /// 1/1024 pixel right of and below the centre (well inside the 32-bit storage error of the position, 2e-8 px).
    private func seamErrors(_ device: WinGfxDevice, backing s: CGFloat) throws -> [String] {
        let r = try rig(device, points: CGSize(width: 64, height: 48), backing: s)
        var tiles: [(bitmap: PlazaBitmap, origin: CGPoint)] = []   // index i * 3 + j
        for i in 0..<4 {
            for j in 0..<3 {
                var b = PlazaBitmap(width: 8, height: 8)
                for ty in 0..<8 { for tx in 0..<8 { b[tx, ty] = PlazaRGBA(r: UInt8(i * 60 + tx * 7), g: UInt8(j * 80 + ty * 9), b: 200, a: 255) } }
                let t = PlazaSprite(texture: PlazaTexture(PlazaImage(bitmap: b)), size: CGSize(width: 16, height: 16))
                t.anchorPoint = .zero
                t.position = CGPoint(x: 1 / s + CGFloat(16 * i), y: 1 / s + CGFloat(16 * j))
                r.stage.root.addChild(t)
                tiles.append((b, t.position))   // the stored (32-bit) position
            }
        }
        let px = frame(r)
        let w = r.surface.width, h = r.surface.height, sd = Double(s)
        var gaps = 0, wrong = 0, ties = 0, first = ""
        let lean = 1.0 / 1024
        for py in 0..<h {
            for x in 0..<w {
                let cx = Double(x) + 0.5, cy = Double(py) + 0.5
                let got = pixel(px, width: w, x, py)
                var want: [UInt8] = [0, 0, 0, 0]
                var inside = false
                for tile in tiles {
                    let x0 = Double(tile.origin.x) * sd, x1 = x0 + 16 * sd
                    let yb = Double(h) - Double(tile.origin.y) * sd, yt = yb - 16 * sd
                    guard cx >= x0, cx < x1, cy >= yt, cy < yb else { continue }
                    inside = true
                    let u0 = (cx - x0) / (2 * sd), v0 = (cy - yt) / (2 * sd)   // texels from the tile's top-left
                    if abs(u0 - u0.rounded()) < 1e-4 || abs(v0 - v0.rounded()) < 1e-4 { ties += 1 }
                    let u = u0 + lean / (2 * sd), v = v0 + lean / (2 * sd)
                    let c = tile.bitmap[min(7, Int(u.rounded(.down))), min(7, Int(v.rounded(.down)))]
                    want = [c.r, c.g, c.b, c.a]
                }
                if inside, got.count == 4, got[3] == 0 { gaps += 1 }
                if zip(got, want).contains(where: { abs(Int($0) - Int($1)) > 1 }) {
                    wrong += 1
                    if first.isEmpty { first = "(\(x),\(py)) \(got) vs \(want)" }
                }
            }
        }
        print("SEAMS backing=\(s) pixels=\(w)x\(h) gaps=\(gaps) wrongTexel=\(wrong) tiesJudged=\(ties)")
        return gaps + wrong == 0 ? [] : ["backing \(s): \(gaps) empty pixels inside the tiles, \(wrong) pixels not the texel under their centre, first \(first)"]
    }

    // MARK: Parity with SpriteKit

    func testSwatchesMatchSpriteKit() async throws {
        let device = try makeDevice()
        print("RENDERER device adapter=\"\(device.adapter)\" warp=\(device.isWarp)")
        let (worst, at) = try swatchErrors(device)
        for g in worst.keys.sorted() { print("SWATCH group=\(g) maxDelta=\(worst[g]!) worst=\(at[g] ?? "")") }
        XCTAssertEqual(try swatchFailures(device), [])
    }

    func testNearestSamplingAndEdges() async throws {
        let device = try makeDevice()
        let (worst, at) = try swatchErrors(device, groups: ["nearest", "rotation"])
        XCTAssertLessThanOrEqual(worst["nearest"] ?? 255, 1, at["nearest"] ?? "")
        XCTAssertLessThanOrEqual(worst["rotation"] ?? 255, 1, at["rotation"] ?? "")
        let bleed = try bleedErrors(device), rotation = try rotationErrors(device)
        XCTAssertEqual(bleed, [])
        XCTAssertEqual(rotation, [])
        print("NEAREST maxDelta=\(worst["nearest"] ?? -1) rotationGolden=\(worst["rotation"] ?? -1) bleedFailures=\(bleed.count) rotationFailures=\(rotation.count)")
    }

    func testDrawOrderIsFlattensOrder() async throws {
        let device = try makeDevice()
        XCTAssertEqual(try orderErrors(device), [])
    }

    func testFractionalBackingScale() async throws {
        let device = try makeDevice()
        for s in [1.0, 1.25, 1.5, 2.0] as [CGFloat] {
            let errors = try seamErrors(device, backing: s)
            print("SEAMS backing=\(s) errors=\(errors)")
            XCTAssertEqual(errors, [], "backing \(s)")
        }
    }

    // MARK: Cache, dirty frames, device loss

    func testCutTexturesDoNotUpload() async throws {
        let device = try makeDevice()
        let r = try rig(device, points: CGSize(width: 64, height: 64), backing: 1)
        let before = device.stats
        do {
            let sheet = PlazaTexture(PlazaImage(bitmap: PlazaBitmap(width: 16, height: 16, fill: PlazaRGBA(r: 10, g: 200, b: 30, a: 255))))
            var cuts: [PlazaTexture] = []
            for i in 0..<100 {
                let rect = CGRect(x: Double(i % 4) / 4, y: Double(i / 4 % 4) / 4, width: 0.25, height: 0.25)
                cuts.append(PlazaTexture(rect: rect, in: i % 10 == 9 ? cuts[i - 1] : sheet))   // every tenth a cut of a cut
                let s = PlazaSprite(texture: cuts[i], size: CGSize(width: 4, height: 4))
                s.position = CGPoint(x: 4 + CGFloat(i % 10) * 6, y: 4 + CGFloat(i / 10) * 6)
                r.stage.root.addChild(s)
            }
            _ = frame(r)
            XCTAssertEqual(device.stats.uploads - before.uploads, 1, "100 cuts of one image upload the image once")
            XCTAssertEqual(device.stats.liveBitmaps, before.liveBitmaps + 1)
            XCTAssertEqual(r.renderer.stats.bitmapDraws, 100)
            _ = frame(r)
            XCTAssertEqual(device.stats.uploads - before.uploads, 1, "a second frame uploads nothing")
            r.stage.root.removeAllChildren()
        }
        _ = frame(r)   // the image is gone: its bitmap is released at the next device call
        XCTAssertEqual(device.stats.liveBitmaps, before.liveBitmaps, "the bitmap lives exactly as long as its image")
    }

    func testCleanTicksDoNotDraw() async throws {
        let device = try makeDevice()
        let r = try rig(device, points: CGSize(width: 32, height: 32), backing: 2)
        let s = sprite(PlazaColor(srgbRed: 1, green: 0, blue: 0), 4, 4, 10, 10)
        r.stage.root.addChild(s)
        func draw(_ panels: [WinPanelDraw] = [], transparent: Bool = false) -> WinDrawResult {
            r.renderer.drawIfNeeded(stage: r.stage, panels: panels, transparent: transparent)
        }
        XCTAssertEqual(draw(), .drawn)
        let first = r.surface.readRGBA()
        XCTAssertEqual(draw(), .clean)
        XCTAssertEqual(draw(), .clean)
        s.alpha = 0.5
        XCTAssertEqual(draw(), .drawn, "one alpha write")
        s.alpha = 0.5
        XCTAssertEqual(draw(), .clean, "the same value again is no change")
        s.position = s.position
        XCTAssertEqual(draw(), .clean)
        let child = sprite(PlazaColor(srgbRed: 0, green: 0, blue: 1), 1, 1, 2, 2)
        s.addChild(child)
        XCTAssertEqual(draw(), .drawn, "a new child")
        child.zPosition = 3
        XCTAssertEqual(draw(), .drawn, "a write to the new child (its mirror was installed when it was added)")
        child.removeFromParent()
        XCTAssertEqual(draw(), .drawn)
        s.alpha = 1
        XCTAssertEqual(draw(), .drawn)
        XCTAssertEqual(r.surface.readRGBA(), first, "back to the first tree, the same bytes")
        r.stage.backgroundColor = PlazaColor(srgbRed: 0.1, green: 0.2, blue: 0.3)
        XCTAssertEqual(draw(), .drawn, "background")
        let panel = WinPanelDraw(layers: [.color(PlazaColor(srgbRed: 1, green: 1, blue: 1), frame: CGRect(x: 0, y: 0, width: 4, height: 4))],
                                 frame: CGRect(x: 2, y: 2, width: 4, height: 4))
        XCTAssertEqual(draw([panel]), .drawn, "a panel appears")
        XCTAssertEqual(draw([panel]), .clean)
        XCTAssertEqual(pixel(r.surface.readRGBA() ?? [], width: 64, 5, 5), [255, 255, 255, 255], "the panel is drawn on top at frame x backing")
        XCTAssertEqual(draw([panel], transparent: true), .drawn, "transparency toggled")
        r.stage.setBackingScale(1.5)
        XCTAssertEqual(draw([panel], transparent: true), .drawn, "backing scale")
        // An unchanged tree drawn again gives the same bytes.
        let before = r.surface.readRGBA()
        r.stage.setNeedsDraw()
        XCTAssertEqual(draw([panel], transparent: true), .drawn)
        XCTAssertEqual(r.surface.readRGBA(), before)
        XCTAssertEqual(r.renderer.stats.failedFrames, 0)
    }

    func testDeviceLossRebuildsAndRedraws() async throws {
        let device = try makeDevice()
        let r = try rig(device, points: CGSize(width: 32, height: 32), backing: 2)
        var grid = PlazaBitmap(width: 4, height: 4)
        for y in 0..<4 { for x in 0..<4 { grid[x, y] = PlazaRGBA(r: UInt8(x * 60), g: UInt8(y * 60), b: 90, a: 255) } }
        r.stage.root.addChild(sprite(PlazaColor(srgbRed: 0.8, green: 0.4, blue: 0.2), 0, 0, 32, 32))
        let textured = PlazaSprite(texture: PlazaTexture(PlazaImage(bitmap: grid)), size: CGSize(width: 8, height: 8))
        textured.position = CGPoint(x: 10, y: 10)
        r.stage.root.addChild(textured)
        let ghost = PlazaSprite(texture: PlazaTexture(PlazaImage(bitmap: grid)), size: CGSize(width: 8, height: 8))
        ghost.position = CGPoint(x: 22, y: 10)
        ghost.color = PlazaPondArt.waterColor
        ghost.colorBlendFactor = PlazaPondArt.submergedBlend
        ghost.alpha = 0.6
        ghost.xScale = -1
        r.stage.root.addChild(ghost)
        var light = PlazaBitmap(width: 4, height: 4, fill: PlazaRGBA(r: 160, g: 128, b: 100, a: 255))
        light.alpha = .noneSkipLast
        let lamp = PlazaSprite(texture: PlazaTexture(PlazaImage(bitmap: light)), size: CGSize(width: 12, height: 12))
        lamp.position = CGPoint(x: 16, y: 24)
        lamp.blendMode = .multiplyX2
        lamp.zPosition = 6
        r.stage.root.addChild(lamp)
        let daylight = sprite(PlazaColor(srgbRed: 0.5, green: 0.6, blue: 0.9), 0, 0, 32, 16, z: 5)
        daylight.blendMode = .multiply
        r.stage.root.addChild(daylight)
        let a = frame(r)
        let gen = device.generation, uploads = device.stats.uploads
        XCTAssertEqual(device.stats.liveBitmaps, 3)

        device.injectDeviceLoss()
        r.stage.setNeedsDraw()   // the loss shows on the next frame, and a frame runs only when something changed
        XCTAssertEqual(r.renderer.drawIfNeeded(stage: r.stage, transparent: true), .deviceLost)
        XCTAssertEqual(device.generation, gen + 1, "rebuilt with a new generation")
        XCTAssertTrue(r.stage.needsDraw, "the lost frame stays dirty")
        XCTAssertEqual(r.renderer.drawIfNeeded(stage: r.stage, transparent: true), .drawn)
        XCTAssertEqual(r.surface.readRGBA(), a, "the same pixels after the rebuild")
        XCTAssertEqual(device.stats.uploads, uploads + 3, "every texture uploaded again, lazily")
        XCTAssertEqual(device.stats.liveBitmaps, 3, "the old generation's bitmaps are gone")
        XCTAssertEqual(device.stats.losses, 1)
        XCTAssertEqual(r.renderer.stats.deviceLosses, 1)
        print("DEVICELOSS generation \(gen) -> \(device.generation) uploads \(uploads) -> \(device.stats.uploads) pixels equal \(r.surface.readRGBA() == a)")

        // Three losses within 10 s switch a hardware-first device to WARP for good.
        let hardware = try makeDevice(warp: false)
        let h = try rig(hardware, points: CGSize(width: 8, height: 8), backing: 1)
        h.stage.root.addChild(sprite(PlazaColor.white, 0, 0, 4, 4))
        XCTAssertFalse(hardware.wantsWarp)
        for _ in 0..<3 {
            _ = frame(h)
            hardware.injectDeviceLoss()
            h.stage.setNeedsDraw()
            XCTAssertEqual(h.renderer.drawIfNeeded(stage: h.stage, transparent: true), .deviceLost)
        }
        XCTAssertTrue(hardware.wantsWarp)
        XCTAssertTrue(hardware.isWarp)
        XCTAssertEqual(pixel(frame(h), width: 8, 1, 6), [255, 255, 255, 255], "it draws after the switch")
    }

    // MARK: Fault injection

    /// Each parity rule broken once on purpose: some check above must notice. The lines name the checks that caught it.
    func testEachInjectedFaultIsCaught() async throws {
        defer { WinRenderFaults.active = [] }
        let cleanDevice = try makeDevice()
        let duskClean = try await duskCapture(cleanDevice)
        for fault in WinRenderFaults.Fault.allCases {
            let device = try makeDevice()   // fresh: no upload made under an earlier fault is reused
            WinRenderFaults.active = [fault]
            var caught: [String] = []
            if try await duskCapture(device) != duskClean { caught.append("duskPreview") }
            let swatches = try swatchFailures(device)
            if !swatches.isEmpty { caught.append("swatches[" + swatches.map { String($0.prefix(while: { $0 != ":" })) }.joined(separator: ", ") + "]") }
            if !(try bleedErrors(device)).isEmpty { caught.append("bleed") }
            if !(try rotationErrors(device)).isEmpty { caught.append("rotation") }
            if !(try orderErrors(device)).isEmpty { caught.append("drawOrder") }
            if !(try seamErrors(device, backing: 1.25)).isEmpty { caught.append("seams@1.25") }
            WinRenderFaults.active = []
            print("FAULT \(fault): caught by \(caught.isEmpty ? "NOTHING" : caught.joined(separator: " "))")
            XCTAssertFalse(caught.isEmpty, "\(fault) went unnoticed")
        }
    }

    /// The `dusk` preview's one capture, drawn on `device`.
    private func duskCapture(_ device: WinGfxDevice) async throws -> [UInt8] {
        guard let scene = PlazaPreviewScenes.all.first(where: { $0.name == "dusk" }) else { return [] }
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.setBackingScale(scene.backing)
        let surface = try WinGfxSurface.offscreen(device: device, width: Int(640 * scene.backing), height: Int(480 * scene.backing)).get()
        let renderer = WinPlazaRenderer(surface: surface)
        var out: [UInt8] = []
        await PlazaPreviewScenes.run(scene, stage: stage) { _, _ in
            _ = renderer.drawIfNeeded(stage: stage, transparent: true)
            out = surface.readRGBA() ?? []
        }
        return out
    }

    // MARK: Real scenes

    private func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let image = PlazaImage(bitmap: PlazaBitmap(width: width, height: height, bytes: rgba))
        let png = try XCTUnwrap(WinPlazaGraphics.shared.encodePNG(image), "PNG encode: \(WinPlazaCodecs.lastError())")
        try png.write(to: url)
    }

    /// The preview scenes from the shared `PlazaScene` with fixture members and the bundled art, at their harness backing.
    /// With `PTB_PLAZA_PREVIEW_OUT` set, every capture is written as `<scene>@<frame>.png` (straight-alpha PNG of the
    /// transparent-cleared frame) and `<scene>@<frame>.render-tree.txt` (the tree that was drawn).
    func testPreviewScenesRenderOnWARP() async throws {
        let device = try makeDevice()
        let out = PlazaPreviewScenesTests.outputDirectory
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        XCTAssertNotNil(PlatformPlaza.tileSheet(), "the tile sheet must load (PTB_PLAZA_RESOURCES), or the map is plain grass")
        for scene in PlazaPreviewScenes.all {
            let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
            stage.setBackingScale(scene.backing)
            let w = Int(PlazaPreviewScenes.viewport.width * scene.backing), h = Int(PlazaPreviewScenes.viewport.height * scene.backing)
            let surface = try WinGfxSurface.offscreen(device: device, width: w, height: h).get()
            let renderer = WinPlazaRenderer(surface: surface)
            var previous: [UInt8]?
            try await PlazaPreviewScenes.run(scene, stage: stage) { frame, setup in
                XCTAssertEqual(renderer.drawIfNeeded(stage: stage, transparent: true), .drawn)
                device.finish()
                let rgba = try XCTUnwrap(surface.readRGBA())
                let opaque = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] == 255 }.count
                XCTAssertGreaterThan(Double(opaque) / Double(w * h), 0.9, "\(scene.name)@\(frame): the map should fill the view")
                XCTAssertNotEqual(rgba, previous, "\(scene.name)@\(frame): the same picture as the capture before")
                previous = rgba
                stage.setNeedsDraw()
                XCTAssertEqual(renderer.drawIfNeeded(stage: stage, transparent: true), .drawn)
                XCTAssertEqual(surface.readRGBA(), rgba, "\(scene.name)@\(frame): the unchanged tree drew different bytes")
                let st = renderer.stats, ds = device.stats
                print("PREVIEW \(scene.name)@\(frame) " + String(format: "commands=%d bitmaps=%d colors=%d effects=%d build=%.2fms submit=%.2fms liveBitmaps=%d liveBytes=%llu failed=%d",
                                                                    st.commands, st.bitmapDraws, st.colorDraws, st.effectDraws, st.buildSeconds * 1000,
                                                                    st.submitSeconds * 1000, Int(ds.liveBitmaps), ds.liveBitmapBytes, st.failedFrames))
                XCTAssertEqual(st.failedFrames, 0, WinPlazaCodecs.lastError())
                if let out {
                    try writePNG(rgba, width: w, height: h, to: out.appendingPathComponent("\(scene.name)@\(frame).png"))
                    try PlazaPreviewScenes.dump(setup).write(to: out.appendingPathComponent("\(scene.name)@\(frame).render-tree.txt"),
                                                             atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Answers every plain (not shiny) sprite ask with the same fixture GIF.
    private final class FixtureSpriteSource: PlazaSpriteSource, @unchecked Sendable {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let gif: Data
        init(gif: Data) { self.gif = gif }
        func data(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm?, back: Bool) async -> Data? { shiny ? nil : gif }
        func eggData() async -> Data? { nil }
    }

    /// A teammate whose picture comes through Task 3's shared path (`PlazaCharacterLoader` over `PlazaStoreSpriteFetcher`)
    /// from FIXTURE GIF bytes (built by `PlazaGIFFixtures`: no Pokémon art is committed), decoded by the shared GIF decoder
    /// on Windows, standing in `base-noon` and drawn: its palette colour fills where the teammate stands.
    func testFetchedSpritesDrawInTheScene() async throws {
        let w = 20, h = 24
        func gifFrame(_ step: Int) -> PlazaGIFFixtures.Frame {
            var indices = [UInt8](repeating: 0, count: w * h)
            for y in 2..<22 { for x in 3..<17 { indices[y * w + x] = 1 } }
            indices[8 * w + 7] = 2; indices[8 * w + 12] = 2; indices[(19 + step) * w + 5] = 2
            var f = PlazaGIFFixtures.Frame(width: w, height: h, indices: indices)
            f.transparent = 0
            f.delay = 20
            return f
        }
        let gif = Data(PlazaGIFFixtures.gif(width: w, height: h, global: [[0, 0, 0], [250, 40, 200], [20, 20, 30], [255, 255, 255]],
                                            frames: [gifFrame(0), gifFrame(1)]))
        let loader = PlazaCharacterLoader(fetcher: PlazaStoreSpriteFetcher(source: FixtureSpriteSource(gif: gif), graphics: WinPlazaGraphics.shared))
        let fetched = await loader.frames(for: CompanionStore.RepresentativeSubject(speciesID: 25, isShiny: false))
        XCTAssertFalse(fetched.isPlaceholder, "the fixture GIF did not come through the fetcher")
        XCTAssertEqual(fetched.front.count, 2)
        let device = try makeDevice()
        let scene = try XCTUnwrap(PlazaPreviewScenes.all.first { $0.name == "base-noon" })
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.setBackingScale(scene.backing)
        let surface = try WinGfxSurface.offscreen(device: device, width: 640, height: 480).get()
        let renderer = WinPlazaRenderer(surface: surface)
        var magenta = 0
        try await PlazaPreviewScenes.run(scene, stage: stage, prepare: { $0.scene.setMemberFrames("ash", fetched) }) { frame, _ in
            guard frame == 10 else { return }
            XCTAssertEqual(renderer.drawIfNeeded(stage: stage, transparent: true), .drawn)
            let rgba = try XCTUnwrap(surface.readRGBA())
            magenta = stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0] == 250 && rgba[$0 + 1] == 40 && rgba[$0 + 2] == 200 }.count
            if let out = PlazaPreviewScenesTests.outputDirectory {
                try writePNG(rgba, width: 640, height: 480, to: out.appendingPathComponent("fetched-sprites@10.png"))
            }
        }
        // 14 x 20 opaque texels, 1.5 world pixels each at zoom 2 and backing 1: 3 x 3 device pixels a texel
        print("FETCHED magentaPixels=\(magenta) frames=\(fetched.front.count) placeholder=\(fetched.isPlaceholder)")
        XCTAssertGreaterThan(magenta, 14 * 20 * 9 / 2, "the fetched teammate is not on screen")
    }

    /// D19's busy case on WARP: per frame the scene's update, then flatten + command building, recording + EndDraw, and the
    /// raster time (`finish`). Report-only numbers (debug build; the release numbers come from the selftest), plus the
    /// private-bytes growth over the steady frames.
    func testFrameCostOnWARP() async throws {
        let device = try makeDevice()
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.setBackingScale(2)
        let surface = try WinGfxSurface.offscreen(device: device, width: 1280, height: 960).get()
        let renderer = WinPlazaRenderer(surface: surface)
        let setup = PlazaPreviewScenes.rushHour.build(stage)
        setup.step(0)
        for _ in 0..<PlazaPreviewScenes.warmUpUpdates { stage.tick(at: PlazaPreviewScenes.clockBase) }
        var update: [Double] = [], build: [Double] = [], submit: [Double] = [], raster: [Double] = []
        var clean = 0, privateBefore: UInt64 = 0
        let warm = 60, measured = 240
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        for f in 1...(warm + measured) {
            setup.step(f)
            let t0 = now()
            stage.tick(at: PlazaPreviewScenes.clockBase + Double(f) / 60)
            let t1 = now()
            let result = renderer.drawIfNeeded(stage: stage)
            let t2 = now()
            device.finish()
            let t3 = now()
            if f == warm { privateBefore = ptb_gfx_process_private_bytes() }
            guard f > warm else { continue }
            if result == .clean { clean += 1; continue }
            update.append(t1 - t0)
            build.append(renderer.stats.buildSeconds)
            submit.append(renderer.stats.submitSeconds)
            raster.append(t3 - t2)
        }
        let privateAfter = ptb_gfx_process_private_bytes()
        func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] * 1000 }
        let both = zip(update, build).map { $0 + $1 }
        let st = renderer.stats
        print(String(format: "FRAMECOST rush-hour debug drawn=%d clean=%d update p50=%.2f p95=%.2f | update+flatten+build p50=%.2f p95=%.2f | submit p50=%.2f | WARP raster p50=%.2f p95=%.2f ms | commands=%d bitmaps=%d colors=%d effects=%d | private %+lld KB over %d frames",
                     update.count, clean, pct(update, 0.5), pct(update, 0.95), pct(both, 0.5), pct(both, 0.95), pct(submit, 0.5),
                     pct(raster, 0.5), pct(raster, 0.95), st.commands, st.bitmapDraws, st.colorDraws, st.effectDraws,
                     (Int64(privateAfter) - Int64(privateBefore)) / 1024, measured))
        XCTAssertGreaterThan(update.count, measured / 2, "a busy plaza draws most frames")
        XCTAssertLessThan(Int64(privateAfter) - Int64(privateBefore), 32 << 20, "steady frames must not keep growing memory")
        XCTAssertEqual(st.failedFrames, 0)
    }
}
#endif
