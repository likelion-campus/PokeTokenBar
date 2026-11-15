#if os(Windows)
import CPlazaD2D
import Foundation

/// What one `drawIfNeeded` did.
enum WinDrawResult: Equatable, Sendable {
    /// A frame was drawn into the surface.
    case drawn
    /// Nothing changed since the last frame: nothing was drawn (D3).
    case clean
    /// The GPU is behind (window surfaces, Task 5): the tick skipped its draw and the frame stays dirty.
    case gpuBusy
    /// The device was lost (or could not draw): it was rebuilt, the frame stays dirty and the next tick draws it again.
    case deviceLost
}

/// One HUD panel's drawing at its frame (window points, origin top-left), drawn above the scene in list order (D8).
/// Image layers draw 1:1 at `frame × backing` with nearest sampling; colour layers are filled rectangles.
struct WinPanelDraw: Equatable {
    var layers: [PlazaPanelLayer]
    var frame: CGRect
}

/// The renderer's counters. The per-frame values describe the last frame that was drawn.
struct WinRenderStats: Equatable, Sendable {
    var draws = 0, cleans = 0, deviceLosses = 0
    /// Frames whose drawing reported an error other than a device loss (the first one is logged).
    var failedFrames = 0
    var commands = 0, bitmapDraws = 0, colorDraws = 0, effectDraws = 0
    /// Main thread, last drawn frame: `flatten` + command building + any uploads.
    var buildSeconds: Double = 0
    /// Main thread, last drawn frame: recording the commands and `EndDraw` (`ptb_gfx_frame`). On WARP the rasterizing
    /// itself may finish later on WARP's threads; `WinGfxDevice.finish()` waits for it.
    var submitSeconds: Double = 0
}

/// Draws the shared plaza tree with Direct2D (D2): one loop over `PlazaDrawOrder.flatten`, one command per sprite, one call
/// into the shim per frame. Main thread only.
///
/// Mapping (every property the scene writes; see the Task 4 report for the full table):
/// - order, equal-z ties (tree order), crop units, hidden subtrees, accumulated alpha: `flatten`'s.
/// - position, scales (negative = flips), zRotation, anchor, unscaled size: `flatten`'s unit-square transform, then the
///   camera's inverse (world items) or the viewport centre (camera children), then the y-flip and `backingScale`.
/// - texture: the root image's bitmap, uploaded once per `PlazaImage`; a cut texture is a source rect into it (edges
///   within 1/1000 of a texel snap to it), sampled nearest-neighbour with SpriteKit's tie rule (a pixel centre on a
///   texel edge takes the texel to its right / below on screen); untextured sprites are coloured rectangles.
/// - colour blend (textured sprites): each colour channel × (1 − f + f · colour), alpha kept, then × alpha (measured).
/// - `.multiply` / `.multiplyX2` (measured): rgb = k · src · dst (clamped), alpha = src alpha, inside the sprite's pixels.
/// - crop masks: an axis-aligned clip of the mask's box, snapped by pixel centres (left/top inclusive).
@MainActor final class WinPlazaRenderer {
    let surface: WinGfxSurface
    private(set) var stats = WinRenderStats()

    private var commands: [PTBDrawCmd] = []
    private var clear: [Float] = [0, 0, 0, 0]
    private var lastPanels: [WinPanelDraw] = []
    private var lastTransparent: Bool?
    private var lastPixels: (width: Int, height: Int)?
    private var loggedFailure = false

    static let recreateTarget = Int32(bitPattern: 0x8899_000C)

    init(surface: WinGfxSurface) {
        self.surface = surface
        commands.reserveCapacity(1024)
    }

    var device: WinGfxDevice { surface.device }

    /// Draws a frame when the tree, the stage, the panels or the surface changed since the last one; otherwise `.clean`.
    func drawIfNeeded(stage: WinPlazaStage, panels: [WinPanelDraw] = [], transparent: Bool = false) -> WinDrawResult {
        let pixels = (width: surface.width, height: surface.height)
        if !stage.needsDraw, panels == lastPanels, transparent == lastTransparent,
           let last = lastPixels, last.width == pixels.width, last.height == pixels.height {
            stats.cleans += 1
            return .clean
        }
        let start = DispatchTime.now().uptimeNanoseconds
        build(stage: stage, panels: panels)
        let built = DispatchTime.now().uptimeNanoseconds
        let background = transparent ? PlazaColor.clear : stage.backgroundColor
        clear[0] = Float(background.red)
        clear[1] = Float(background.green)
        clear[2] = Float(background.blue)
        clear[3] = Float(background.alpha)
        device.setOptions(WinRenderFaults.has(.bilinear) ? 1 : 0)
        let code = clear.withUnsafeBufferPointer { c in
            commands.withUnsafeBufferPointer { ptb_gfx_frame(surface.handle.raw, c.baseAddress, $0.baseAddress, UInt32($0.count)) }
        }
        let submitted = DispatchTime.now().uptimeNanoseconds
        if code == Self.recreateTarget {
            stats.deviceLosses += 1
            _ = device.recreateAfterLoss(at: Double(submitted) / 1e9)
            stage.setNeedsDraw()
            lastPixels = nil
            return .deviceLost
        }
        if code < 0 {
            stats.failedFrames += 1
            if !loggedFailure {
                loggedFailure = true
                AppLog.write("plaza renderer: a frame reported \(WinPlazaCodecs.lastError())")
            }
        }
        stats.draws += 1
        stats.buildSeconds = Double(built - start) / 1e9
        stats.submitSeconds = Double(submitted - built) / 1e9
        stage.didDraw()
        lastPanels = panels
        lastTransparent = transparent
        lastPixels = pixels
        return .drawn
    }

    // MARK: Commands

    /// The unit square with (0,0) top-left, y down, onto `flatten`'s unit square (origin bottom-left, y up).
    private static let unitYDown = PlazaTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)

    private func build(stage: WinPlazaStage, panels: [WinPanelDraw]) {
        commands.removeAll(keepingCapacity: true)
        stats.bitmapDraws = 0
        stats.colorDraws = 0
        stats.effectDraws = 0
        let scale = stage.backingScale ?? 1
        let size = stage.size
        // View points (origin bottom-left, y up; what `.resizeFill` with anchor .zero gives) to device pixels (y down).
        let toDevice = PlazaTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: size.height * scale)
        let centre = PlazaTransform(a: 1, b: 0, c: 0, d: 1, tx: size.width / 2, ty: size.height / 2)
        let screen = WinRenderFaults.has(.noScreenFlip)
            ? PlazaTransform(a: scale, b: 0, c: 0, d: scale, tx: size.width / 2 * scale, ty: size.height / 2 * scale)
            : centre.concatenating(toDevice)
        let world = stage.camera.map { Self.inverse(Self.worldTransform(of: $0)).concatenating(centre).concatenating(toDevice) } ?? toDevice
        var items = PlazaDrawOrder.flatten(root: stage.root, camera: stage.camera)
        if WinRenderFaults.has(.reverseTies) { Self.reverseTies(&items) }
        for item in items { append(item, world: world, screen: screen) }
        for panel in panels { append(panel, scale: scale) }
        stats.commands = commands.count
    }

    private func append(_ item: PlazaDrawItem, world: PlazaTransform, screen: PlazaTransform) {
        let sprite = item.sprite
        let alpha = min(item.alpha, 1)
        guard alpha > 0 else { return }   // draws nothing (SpriteKit's alpha-0 sprites; no multiply sprite of the plaza fades)
        let toTarget = item.isScreenSpace ? screen : world
        let m = Self.unitYDown.concatenating(item.transform).concatenating(toTarget)
        var cmd = PTBDrawCmd()
        cmd.m = (Float(m.a), Float(m.b), Float(m.c), Float(m.d), Float(m.tx), Float(m.ty))
        cmd.opacity = Float(alpha)
        var blend = sprite.blendMode
        if WinRenderFaults.has(.swapMultiplyModes) { blend = blend == .multiply ? .multiplyX2 : (blend == .multiplyX2 ? .multiply : blend) }
        cmd.blend = blend == .alpha ? 0 : (blend == .multiply ? 1 : 2)
        if let texture = sprite.texture {
            guard let ref = device.bitmap(for: texture.image) else { return }
            cmd.kind = 0
            cmd.bitmap = ref.handle
            let w = CGFloat(texture.image.width), h = CGFloat(texture.image.height), r = texture.rect
            func snap(_ v: CGFloat, _ limit: CGFloat) -> CGFloat {
                let n = v.rounded()
                return min(max(abs(v - n) < 1e-3 ? n : v, 0), limit)
            }
            let x0 = snap(r.minX * w, w), x1 = snap(r.maxX * w, w), y0 = snap((1 - r.maxY) * h, h), y1 = snap((1 - r.minY) * h, h)
            guard x1 > x0, y1 > y0 else { return }
            cmd.src = (Float(x0), Float(y0), Float(x1 - x0), Float(y1 - y0))
            let f = min(max(sprite.colorBlendFactor, 0), 1)
            if f > 0 {
                let c = sprite.color
                let k = (Float(1 - f + f * CGFloat(c.red)), Float(1 - f + f * CGFloat(c.green)), Float(1 - f + f * CGFloat(c.blue)))
                if k != (1, 1, 1) {
                    cmd.useTint = 1
                    cmd.tint = k
                }
            }
            stats.bitmapDraws += 1
        } else {
            let c = sprite.color
            guard c.alpha > 0 || blend != .alpha else { return }   // SpriteKit's default colour is white with alpha 0
            cmd.kind = 1
            cmd.color = (Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
            stats.colorDraws += 1
        }
        if let clip = item.clip {
            let box = Self.pixelCover(Self.bounds(clip, through: toTarget))
            cmd.hasClip = 1
            cmd.clip = (box.l, box.t, box.r, box.b)
        }
        if cmd.blend != 0 || cmd.useTint != 0 {
            let quad = Self.bounds(CGRect(x: 0, y: 0, width: 1, height: 1), through: m)
            let region: (l: Int32, t: Int32, r: Int32, b: Int32)
            if cmd.blend != 0 {
                // The multiply paths write every pixel of the region, so it must be the sprite's own pixels: every plaza
                // multiply sprite (daylight, campfire light, firework light) is axis-aligned.
                let axisAligned = abs(m.b) < 1e-9 && abs(m.c) < 1e-9
                assert(axisAligned, "a rotated or skewed .multiply sprite: the plaza has none, and its region would be its bounding box")
                region = Self.pixelCover(quad)
            } else {
                region = (Self.int32(quad.minX.rounded(.down)), Self.int32(quad.minY.rounded(.down)),
                          Self.int32(quad.maxX.rounded(.up)), Self.int32(quad.maxY.rounded(.up)))
            }
            cmd.region = (region.l, region.t, region.r, region.b)
            stats.effectDraws += 1
        }
        commands.append(cmd)
    }

    private func append(_ panel: WinPanelDraw, scale: CGFloat) {
        for layer in panel.layers {
            var cmd = PTBDrawCmd()
            cmd.opacity = 1
            let frame: CGRect
            switch layer {
            case .image(let image, let f):
                guard let ref = device.bitmap(for: image) else { continue }
                cmd.kind = 0
                cmd.bitmap = ref.handle
                cmd.src = (0, 0, Float(image.width), Float(image.height))
                frame = f
                stats.bitmapDraws += 1
            case .color(let c, let f):
                cmd.kind = 1
                cmd.color = (Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
                frame = f
                stats.colorDraws += 1
            }
            let x = (panel.frame.minX + frame.minX) * scale, y = (panel.frame.minY + frame.minY) * scale
            cmd.m = (Float(frame.width * scale), 0, 0, Float(frame.height * scale), Float(x), Float(y))
            commands.append(cmd)
        }
    }

    // MARK: Geometry

    /// The node's transform to the root's space (the root's own included, as `flatten` does).
    static func worldTransform(of node: PlazaNode) -> PlazaTransform {
        var t = PlazaDrawOrder.localTransform(of: node)
        var parent = node.parent
        while let p = parent {
            t = t.concatenating(PlazaDrawOrder.localTransform(of: p))
            parent = p.parent
        }
        return t
    }

    static func inverse(_ t: PlazaTransform) -> PlazaTransform {
        let det = t.a * t.d - t.b * t.c
        guard det != 0 else { return .identity }
        let a = t.d / det, b = -t.b / det, c = -t.c / det, d = t.a / det
        return PlazaTransform(a: a, b: b, c: c, d: d, tx: -(a * t.tx + c * t.ty), ty: -(b * t.tx + d * t.ty))
    }

    static func bounds(_ rect: CGRect, through t: PlazaTransform) -> CGRect {
        let ps = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                  CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(t.apply)
        let xs = ps.map(\.x), ys = ps.map(\.y)
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CGRect(x: x0, y: y0, width: (xs.max() ?? 0) - x0, height: (ys.max() ?? 0) - y0)
    }

    /// The pixels whose centres a device-space rect covers, left and top edges inclusive (the rasterizer's rule).
    static func pixelCover(_ r: CGRect) -> (l: Int32, t: Int32, r: Int32, b: Int32) {
        (int32((r.minX - 0.5).rounded(.up)), int32((r.minY - 0.5).rounded(.up)),
         int32((r.maxX - 0.5).rounded(.up)), int32((r.maxY - 0.5).rounded(.up)))
    }

    static func int32(_ v: CGFloat) -> Int32 {
        let limit = CGFloat(1 << 24)
        return Int32(max(min(v, limit), -limit))
    }

    /// Fault injection only: every run of equal global z drawn in reverse.
    private static func reverseTies(_ items: inout [PlazaDrawItem]) {
        var i = 0
        while i < items.count {
            var j = i + 1
            while j < items.count, items[j].globalZ == items[i].globalZ { j += 1 }
            items[i..<j].reverse()
            i = j
        }
    }
}
#endif
