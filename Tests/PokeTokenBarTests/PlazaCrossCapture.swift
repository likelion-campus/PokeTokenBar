import Foundation
@testable import PokeTokenBar

// The cross-OS render compare (windows-port stage 6 Task 15): what one capture of the harness is, as either OS produces it,
// and the line format of its node tree. Shared code, so the Mac's SpriteKit harness and the Windows Direct2D harness fill the
// very same structure and one comparer (`PlazaCrossCompare`) judges the pair.

/// A device-pixel rectangle (right and bottom exclusive).
struct PlazaCrossRect: Equatable {
    var l: Int, t: Int, r: Int, b: Int
    var width: Int { max(0, r - l) }
    var height: Int { max(0, b - t) }
    func dilated(_ n: Int) -> PlazaCrossRect { PlazaCrossRect(l: l - n, t: t - n, r: r + n, b: b + n) }
    var text: String { "\(l),\(t),\(r),\(b)" }
    init(l: Int, t: Int, r: Int, b: Int) { self.l = l; self.t = t; self.r = r; self.b = b }
    init?(text: String) {
        let p = text.split(separator: ",", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        self.init(l: p[0], t: p[1], r: p[2], b: p[3])
    }
}

/// One node of the shared tree: the texture's origin (`-` no texture, `p` pixels, `c` canvas without text, `t` canvas with
/// text), the node's on-screen device rectangle (visible textured sprites only) and `PlazaTreeDump`'s own line.
struct PlazaCrossLine: Equatable {
    var origin: Character
    var rect: PlazaCrossRect?
    var text: String

    var encoded: String { "\(origin) \(rect?.text ?? "-") \(text)" }

    init(origin: Character, rect: PlazaCrossRect?, text: String) {
        self.origin = origin
        self.rect = rect
        self.text = text
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 1, let o = parts[0].first else { return nil }
        origin = o
        rect = parts[1] == "-" ? nil : PlazaCrossRect(text: String(parts[1]))
        text = String(parts[2])
    }
}

/// One capture of the cross set: a scene frame (with its node tree) or a photo (with the rectangles of its plates and bubbles).
/// `rgba` is premultiplied RGBA, row 0 at the top, `width * height * 4` bytes.
struct PlazaCrossCapture {
    enum Kind: String { case scene, photo }
    var stem: String
    var kind: Kind
    var width: Int
    var height: Int
    var rgba: [UInt8]
    var lines: [PlazaCrossLine] = []
    /// Photos: the plates' and bubbles' rectangles.
    var photoRects: [PlazaCrossRect] = []

    var tree: String { lines.map(\.text).joined(separator: "\n") + "\n" }
}

/// The node dump with texture origins and device rectangles, for both OSes from the shared tree.
@MainActor
enum PlazaCrossDump {
    static func originCharacter(_ origin: PlazaImageOrigin) -> Character {
        switch origin {
        case .pixels: "p"
        case .canvas: "c"
        case .canvasWithText: "t"
        }
    }

    /// `scene`'s tree, one entry per node in `PlazaTreeDump`'s order. `backing` is the device scale of the capture.
    static func lines(of scene: PlazaScene, backing: CGFloat) -> [PlazaCrossLine] {
        let stage = scene.stage
        let texts = PlazaTreeDump.lines(root: stage.root, camera: stage.camera, classNames: PlazaTreeDump.classNames(of: scene))
        var walker = Walker(camera: stage.camera, size: stage.size, scale: backing)
        walker.walk(stage.root, parent: .identity, screen: false, visible: true, alpha: 1)
        precondition(walker.entries.count == texts.count, "the cross walk and the tree dump disagree on the node count")
        return zip(walker.entries, texts).map { PlazaCrossLine(origin: $0.0.origin, rect: $0.0.rect, text: $0.1) }
    }

    /// The node's transform to the root's space (the root's own included, as `PlazaDrawOrder.flatten` does).
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

    @MainActor private struct Walker {
        let camera: PlazaCameraNode?
        let toWorld: PlazaTransform
        let toScreen: PlazaTransform
        var entries: [(origin: Character, rect: PlazaCrossRect?)] = []

        /// The renderer's mapping (`WinPlazaRenderer.build`): view points (origin bottom-left, y up) to device pixels (y down).
        init(camera: PlazaCameraNode?, size: CGSize, scale: CGFloat) {
            self.camera = camera
            let toDevice = PlazaTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: size.height * scale)
            let centre = PlazaTransform(a: 1, b: 0, c: 0, d: 1, tx: size.width / 2, ty: size.height / 2)
            toScreen = centre.concatenating(toDevice)
            toWorld = camera.map { PlazaCrossDump.inverse(PlazaCrossDump.worldTransform(of: $0)).concatenating(centre).concatenating(toDevice) } ?? toDevice
        }

        mutating func walk(_ node: PlazaNode, parent: PlazaTransform, screen: Bool, visible: Bool, alpha parentAlpha: CGFloat) {
            let isCamera = camera != nil && node === camera
            let transform = isCamera ? PlazaTransform.identity : PlazaDrawOrder.localTransform(of: node).concatenating(parent)
            let alpha = parentAlpha * node.alpha
            let shown = visible && !node.isHidden
            let inScreen = screen || isCamera
            var entry: (origin: Character, rect: PlazaCrossRect?) = ("-", nil)
            if let sprite = node as? PlazaSprite, let texture = sprite.texture {
                entry.origin = PlazaCrossDump.originCharacter(texture.image.origin)
                if shown, alpha > 0 {
                    let s = sprite.unscaledSize, anchor = sprite.anchorPoint
                    let unit = PlazaTransform(a: s.width, b: 0, c: 0, d: s.height, tx: -anchor.x * s.width, ty: -anchor.y * s.height)
                    let m = unit.concatenating(transform).concatenating(inScreen ? toScreen : toWorld)
                    let ps = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(m.apply)
                    let xs = ps.map(\.x), ys = ps.map(\.y)
                    if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite,
                       abs(x0) < 1e7, abs(x1) < 1e7, abs(y0) < 1e7, abs(y1) < 1e7 {
                        entry.rect = PlazaCrossRect(l: Int(x0.rounded(.down)), t: Int(y0.rounded(.down)), r: Int(x1.rounded(.up)), b: Int(y1.rounded(.up)))
                    }
                }
            }
            entries.append(entry)
            for child in node.children { walk(child, parent: transform, screen: inScreen, visible: shown, alpha: alpha) }
        }
    }
}

/// The photo's plate and bubble rectangles, laid out as `PlazaPhotoRenderer.render` does (its placement arithmetic, copied:
/// the Mac test `testPhotoRectsAreWhereThePlatesAreDrawn` proves the copy against the rendered pixels).
enum PlazaCrossPhoto {
    static func textRects(_ input: PlazaPhotoInput) -> [PlazaCrossRect] {
        let ppw = CGFloat(input.pixelsPerWorld)
        let rect = input.visibleRect
        let width = Int((rect.width * ppw).rounded())
        let height = Int((rect.height * ppw).rounded())
        func px(_ world: CGFloat, origin: CGFloat) -> Int { Int(((world - origin) * ppw).rounded()) }
        var out: [PlazaCrossRect] = []
        let ordered = input.actors.enumerated().sorted { ($0.element.foot.y, $0.offset) < ($1.element.foot.y, $1.offset) }.map(\.element)
        for a in ordered {
            let centerX = px(a.foot.x, origin: rect.minX)
            var top = px(a.foot.y - a.bob - a.lift, origin: rect.minY) - Int((CGFloat(a.image.height) * a.scale * ppw).rounded())
            if a.sink > 0 { top += Int((a.sink * ppw).rounded()) }
            if let base = a.plateBaseY { top = px(base, origin: rect.minY) }
            if let plate = a.plate {
                top -= 2 + plate.height
                let x = centerX - plate.width / 2
                out.append(PlazaCrossRect(l: x, t: top, r: x + plate.width, b: top + plate.height))
            }
            if let bubble = a.bubble {
                let isOnPhoto = (0..<width).contains(centerX) && (0..<height).contains(top)
                top -= bubble.height
                var x = centerX - bubble.width / 2
                if isOnPhoto {
                    x = min(max(x, 0), width - bubble.width)
                    top = max(top, 0)
                }
                out.append(PlazaCrossRect(l: x, t: top, r: x + bubble.width, b: top + bubble.height))
            }
        }
        return out
    }
}
