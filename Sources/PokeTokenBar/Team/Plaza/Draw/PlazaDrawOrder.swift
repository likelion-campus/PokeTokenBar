import Foundation

/// An affine transform of the shared tree (CoreGraphics' layout: x' = a·x + c·y + tx, y' = b·x + d·y + ty). Its own
/// type so shared code needs no `CGAffineTransform`.
struct PlazaTransform: Equatable {
    var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    static let identity = PlazaTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// This transform, then `outer` (`CGAffineTransform.concatenating`).
    func concatenating(_ outer: PlazaTransform) -> PlazaTransform {
        PlazaTransform(a: a * outer.a + b * outer.c, b: a * outer.b + b * outer.d,
                       c: c * outer.a + d * outer.c, d: c * outer.b + d * outer.d,
                       tx: tx * outer.a + ty * outer.c + outer.tx, ty: tx * outer.b + ty * outer.d + outer.ty)
    }

    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }
}

/// One sprite to draw. `transform` maps the unit square (0,0)–(1,1) of the sprite's texture (or colour) rect, origin
/// bottom-left, to the root's space, or to the camera's space (origin at the viewport centre) when `isScreenSpace`.
/// `clip` is in that same space (the bounding box of the crop masks above the sprite). `alpha` includes the ancestors'.
struct PlazaDrawItem {
    let sprite: PlazaSprite
    let globalZ: CGFloat
    let treeIndex: Int
    let isScreenSpace: Bool
    let clip: CGRect?
    let transform: PlazaTransform
    let alpha: CGFloat
}

/// The order SpriteKit draws the plaza in (with `ignoresSiblingOrder`, as the app's view sets it), for a renderer that
/// walks the shared tree itself (Windows, stage 6):
/// - global z (the sum of the ancestors' `zPosition`) decides, across the whole tree, camera children included;
/// - a crop node's subtree is one unit at the crop node's global z (sorted inside by the same rule);
/// - exact ties go in tree order (depth-first, parents before children, children in order). SpriteKit leaves ties
///   unspecified and they are not stable there (Task 1 probe); the render harness nudges them into this same order.
/// Hidden subtrees are skipped; sprites with alpha 0 are listed (they draw nothing).
enum PlazaDrawOrder {
    private struct Unit { let z: CGFloat; let index: Int; let items: [PlazaDrawItem] }

    @MainActor static func flatten(root: PlazaNode, camera: PlazaCameraNode?) -> [PlazaDrawItem] {
        var index = 0
        var units: [Unit] = []
        walk(root, parentZ: 0, parent: .identity, parentAlpha: 1, screen: false, clip: nil, camera: camera, index: &index, into: &units)
        return sorted(units)
    }

    private static func sorted(_ units: [Unit]) -> [PlazaDrawItem] {
        units.sorted { $0.z != $1.z ? $0.z < $1.z : $0.index < $1.index }.flatMap(\.items)
    }

    /// Scale, then rotate, then move: how SpriteKit places a node in its parent.
    @MainActor static func localTransform(of node: PlazaNode) -> PlazaTransform {
        let cosR = CGFloat(cos(Double(node.zRotation))), sinR = CGFloat(sin(Double(node.zRotation)))
        return PlazaTransform(a: cosR * node.xScale, b: sinR * node.xScale, c: -sinR * node.yScale, d: cosR * node.yScale,
                              tx: node.position.x, ty: node.position.y)
    }

    @MainActor private static func walk(_ node: PlazaNode, parentZ: CGFloat, parent: PlazaTransform, parentAlpha: CGFloat,
                                        screen: Bool, clip: CGRect?, camera: PlazaCameraNode?, index: inout Int, into units: inout [Unit]) {
        let myIndex = index
        index += 1
        guard !node.isHidden else { return }
        let z = parentZ + node.zPosition
        let isCamera = camera != nil && node === camera
        // The camera's children are placed relative to the camera: screen space.
        let transform = isCamera ? PlazaTransform.identity : localTransform(of: node).concatenating(parent)
        let alpha = parentAlpha * node.alpha
        let inScreen = screen || isCamera
        if let sprite = node as? PlazaSprite {
            let s = sprite.unscaledSize, anchor = sprite.anchorPoint
            let unit = PlazaTransform(a: s.width, b: 0, c: 0, d: s.height, tx: -anchor.x * s.width, ty: -anchor.y * s.height)
            let item = PlazaDrawItem(sprite: sprite, globalZ: z, treeIndex: myIndex, isScreenSpace: inScreen, clip: clip,
                                     transform: unit.concatenating(transform), alpha: alpha)
            units.append(Unit(z: z, index: myIndex, items: [item]))
        }
        if let crop = node as? PlazaCropNode {
            var inner: [Unit] = []
            var innerClip = clip
            if let mask = crop.maskRect {
                let box = bounds(of: mask, through: transform)
                innerClip = clip.map { $0.intersection(box) } ?? box
            }
            for child in node.children {
                walk(child, parentZ: z, parent: transform, parentAlpha: alpha, screen: inScreen, clip: innerClip, camera: camera, index: &index, into: &inner)
            }
            units.append(Unit(z: z, index: myIndex, items: sorted(inner)))
        } else {
            for child in node.children {
                walk(child, parentZ: z, parent: transform, parentAlpha: alpha, screen: inScreen, clip: clip, camera: camera, index: &index, into: &units)
            }
        }
    }

    private static func bounds(of rect: CGRect, through t: PlazaTransform) -> CGRect {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(t.apply)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
