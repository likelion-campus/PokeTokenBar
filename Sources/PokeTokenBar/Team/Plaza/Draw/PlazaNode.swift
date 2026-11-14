import Foundation

/// How a sprite's colour meets what is under it: the three SpriteKit blend modes the plaza uses.
enum PlazaBlendMode: Sendable { case alpha, multiply, multiplyX2 }

/// SpriteKit keeps node geometry, alpha, scales, rotation and colour components as 32-bit floats and hands back the
/// rounded value. A shared node stores exactly what SpriteKit would hand back, so code that reads a value it wrote
/// (`characterNode.zPosition + 0.0001`) computes what it computed against SpriteKit. Change detection compares bit
/// patterns, so a write that SpriteKit would store as the same float never reaches the mirror.
enum PlazaFloat {
    @inline(__always) static func stored(_ v: CGFloat) -> CGFloat { CGFloat(Float(v)) }
    @inline(__always) static func stored(_ p: CGPoint) -> CGPoint { CGPoint(x: stored(p.x), y: stored(p.y)) }
    static func stored(_ r: CGRect) -> CGRect {
        CGRect(x: stored(r.origin.x), y: stored(r.origin.y), width: stored(r.size.width), height: stored(r.size.height))
    }
    static func stored(_ c: PlazaColor) -> PlazaColor {
        PlazaColor(srgbRed: Double(Float(c.red)), green: Double(Float(c.green)), blue: Double(Float(c.blue)), alpha: Double(Float(c.alpha)))
    }

    @inline(__always) static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { Double(a).bitPattern == Double(b).bitPattern }
    @inline(__always) static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { same(a.x, b.x) && same(a.y, b.y) }
    static func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return same(a.origin, b.origin) && same(a.size.width, b.size.width) && same(a.size.height, b.size.height)
    }
    static func same(_ a: PlazaColor, _ b: PlazaColor) -> Bool {
        a.red.bitPattern == b.red.bitPattern && a.green.bitPattern == b.green.bitPattern
            && a.blue.bitPattern == b.blue.bitPattern && a.alpha.bitPattern == b.alpha.bitPattern
    }
}

/// A node of the shared plaza tree. Every drawing value is a plain stored property, so shared code and tests read
/// it on any OS; nothing is ever read back from a backend. A node attached under a mounted root gets a backend
/// *mirror* (on the Mac a SpriteKit node in the same place of a same-shaped tree), and each changed value is written
/// through to it once. Values follow SpriteKit's read-back rules (32-bit storage, `PlazaFloat`).
///
/// Tree rules, as SpriteKit's: `addChild` appends; a node has at most one parent (adding a parented node is a
/// programmer error, as it raises in SpriteKit); `children` is a value, so removing nodes while looping over it is
/// safe. Draw order (`PlazaDrawOrder`): global z is the sum of the ancestors' `zPosition`; `isHidden` hides the
/// subtree; `alpha` multiplies down the tree.
@MainActor class PlazaNode {
    // Unchecked storage: these are read and written only by plain loads and stores in this file's get/set accessors,
    // on the main actor; never passed inout, no observers, no modify accessors. Overlapping access cannot happen, so
    // the dynamic exclusivity checks (about 2 ns a write, Task 7) are left out. SharedSourcesScanTests checks it.
    @exclusivity(unchecked) private var _name: String?
    @exclusivity(unchecked) private var _position = CGPoint.zero
    @exclusivity(unchecked) private var _zPosition: CGFloat = 0
    @exclusivity(unchecked) private var _alpha: CGFloat = 1
    @exclusivity(unchecked) private var _isHidden = false
    @exclusivity(unchecked) private var _xScale: CGFloat = 1
    @exclusivity(unchecked) private var _yScale: CGFloat = 1
    @exclusivity(unchecked) private var _zRotation: CGFloat = 0

    final private(set) weak var parent: PlazaNode?
    final private(set) var children: [PlazaNode] = []
    /// The backend's copy of this node. Set once, by a backend (`installMirror`); kept when the node leaves the tree,
    /// so a node that comes back is not built again. Unchecked storage, as above.
    @exclusivity(unchecked) final private(set) var mirror: PlazaNodeMirror?

    init() {}

    final var name: String? {
        get { _name }
        set {
            guard newValue != _name else { return }
            _name = newValue
            mirror?.setName(newValue)
        }
    }

    final var position: CGPoint {
        get { _position }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _position) else { return }
            _position = v
            mirror?.setPosition(v)
        }
    }

    final var zPosition: CGFloat {
        get { _zPosition }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _zPosition) else { return }
            _zPosition = v
            mirror?.setZPosition(v)
        }
    }

    /// Not clamped, as in SpriteKit.
    final var alpha: CGFloat {
        get { _alpha }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _alpha) else { return }
            _alpha = v
            mirror?.setAlpha(v)
        }
    }

    final var isHidden: Bool {
        get { _isHidden }
        set {
            guard newValue != _isHidden else { return }
            _isHidden = newValue
            mirror?.setHidden(newValue)
        }
    }

    final var xScale: CGFloat {
        get { _xScale }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _xScale) else { return }
            _xScale = v
            mirror?.setScale(x: v, y: _yScale)
        }
    }

    final var yScale: CGFloat {
        get { _yScale }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _yScale) else { return }
            _yScale = v
            mirror?.setScale(x: _xScale, y: v)
        }
    }

    final func setScale(_ s: CGFloat) {
        let v = PlazaFloat.stored(s)
        guard !(PlazaFloat.same(v, _xScale) && PlazaFloat.same(v, _yScale)) else { return }
        _xScale = v
        _yScale = v
        mirror?.setScale(x: v, y: v)
    }

    /// Radians, counter-clockwise. Not normalised, as in SpriteKit.
    final var zRotation: CGFloat {
        get { _zRotation }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _zRotation) else { return }
            _zRotation = v
            mirror?.setZRotation(v)
        }
    }

    // MARK: Tree

    final func addChild(_ node: PlazaNode) {
        precondition(node.parent == nil, "PlazaNode.addChild: the node already has a parent (SpriteKit raises here too)")
        node.parent = self
        children.append(node)
        mirror?.insertChild(node, at: children.count - 1)
    }

    /// Leaves the parent. A root mounted straight into a backend tree (the SpriteKit bridge, Tasks 7–9) has no shared
    /// parent; removing it takes its copy out of that tree.
    final func removeFromParent() {
        guard let p = parent else {
            mirror?.removeFromParent()
            return
        }
        if let i = p.children.firstIndex(where: { $0 === self }) { p.children.remove(at: i) }
        parent = nil
        mirror?.removeFromParent()
    }

    final func removeAllChildren() {
        let old = children
        children = []
        for child in old {
            child.parent = nil
            child.mirror?.removeFromParent()
        }
    }

    /// Every node below this one (children, their children, ...).
    final var descendantCount: Int { children.reduce(children.count) { $0 + $1.descendantCount } }

    /// For backends only: attach the backend's copy of this node. A backend calls it once, when it first builds the copy.
    final func installMirror(_ m: PlazaNodeMirror) {
        precondition(mirror == nil, "PlazaNode.installMirror: the node already has a mirror")
        mirror = m
    }
}

/// A textured or plain-coloured rectangle (`SKSpriteNode`'s model).
///
/// `size` follows SpriteKit exactly (`SpriteKitSemanticsTests`, `PlazaNodeTests`): the node keeps an unscaled size;
/// reading `size` gives it times |scale|; assigning divides by the scales only while both are positive (with either
/// scale zero or negative, SpriteKit stores the assigned size as is, on both axes). Assigning a texture keeps the size.
@MainActor final class PlazaSprite: PlazaNode {
    /// SpriteKit's default sprite colour: white with alpha 0 (not black, not clear black).
    static let defaultColor = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)

    // Unchecked storage: these are read and written only by plain loads and stores in this file's get/set accessors,
    // on the main actor; never passed inout, no observers, no modify accessors. Overlapping access cannot happen, so
    // the dynamic exclusivity checks (about 2 ns a write, Task 7) are left out. SharedSourcesScanTests checks it.
    @exclusivity(unchecked) private var _texture: PlazaTexture?
    @exclusivity(unchecked) private var _unscaledWidth: CGFloat = 0
    @exclusivity(unchecked) private var _unscaledHeight: CGFloat = 0
    @exclusivity(unchecked) private var _anchorPoint = CGPoint(x: 0.5, y: 0.5)
    @exclusivity(unchecked) private var _color = PlazaSprite.defaultColor
    @exclusivity(unchecked) private var _colorBlendFactor: CGFloat = 0
    @exclusivity(unchecked) private var _blendMode = PlazaBlendMode.alpha

    override init() { super.init() }

    /// `SKSpriteNode(texture:size:)`: the default colour, the given size.
    init(texture: PlazaTexture?, size: CGSize) {
        super.init()
        _texture = texture
        _unscaledWidth = PlazaFloat.stored(size.width)
        _unscaledHeight = PlazaFloat.stored(size.height)
    }

    /// `SKSpriteNode(color:size:)`: no texture, the given colour and size.
    init(color: PlazaColor, size: CGSize) {
        super.init()
        _color = PlazaFloat.stored(color)
        _unscaledWidth = PlazaFloat.stored(size.width)
        _unscaledHeight = PlazaFloat.stored(size.height)
    }

    var texture: PlazaTexture? {
        get { _texture }
        set {
            guard newValue !== _texture else { return }
            _texture = newValue
            mirror?.setTexture(newValue)
        }
    }

    /// The size including `xScale` / `yScale` (their magnitudes), as `SKSpriteNode.size` reads.
    var size: CGSize {
        get {
            CGSize(width: CGFloat(Float(_unscaledWidth) * abs(Float(xScale))),
                   height: CGFloat(Float(_unscaledHeight) * abs(Float(yScale))))
        }
        set {
            let sx = Float(xScale), sy = Float(yScale)
            let w = Float(newValue.width), h = Float(newValue.height)
            let divide = sx > 0 && sy > 0
            let uw = CGFloat(divide ? w / sx : w), uh = CGFloat(divide ? h / sy : h)
            guard !(PlazaFloat.same(uw, _unscaledWidth) && PlazaFloat.same(uh, _unscaledHeight)) else { return }
            _unscaledWidth = uw
            _unscaledHeight = uh
            mirror?.setSize(newValue)   // SpriteKit divides by the same scale it holds
        }
    }

    /// The size before the node's own scale: what a backend builds a new copy with, and what a renderer stretches the
    /// texture to before applying the node's transform.
    var unscaledSize: CGSize { CGSize(width: _unscaledWidth, height: _unscaledHeight) }

    /// Default (0.5, 0.5).
    var anchorPoint: CGPoint {
        get { _anchorPoint }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _anchorPoint) else { return }
            _anchorPoint = v
            mirror?.setAnchorPoint(v)
        }
    }

    var color: PlazaColor {
        get { _color }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _color) else { return }
            _color = v
            mirror?.setColor(v)
        }
    }

    var colorBlendFactor: CGFloat {
        get { _colorBlendFactor }
        set {
            let v = PlazaFloat.stored(newValue)
            guard !PlazaFloat.same(v, _colorBlendFactor) else { return }
            _colorBlendFactor = v
            mirror?.setColorBlendFactor(v)
        }
    }

    var blendMode: PlazaBlendMode {
        get { _blendMode }
        set {
            guard newValue != _blendMode else { return }
            _blendMode = newValue
            mirror?.setBlendMode(newValue)
        }
    }

    /// `SKSpriteNode.frame` without rotation (no plaza code reads the frame of a rotated sprite): the scaled size placed
    /// by the anchor (a negative scale mirrors the anchor, so the width stays positive), each value rounded to 1/1000 as
    /// SpriteKit does. Equal to SpriteKit's bit for bit except at some exact half-thousandths, where SpriteKit's own
    /// rounding goes the other way (within 0.001; probe: 2,962 of 3,000 random frames bit-equal). Nothing draws from it.
    var frame: CGRect {
        let w = Double(Float(_unscaledWidth) * abs(Float(xScale))), h = Double(Float(_unscaledHeight) * abs(Float(yScale)))
        let ax = Double(_anchorPoint.x), ay = Double(_anchorPoint.y)
        let x = xScale < 0 ? Double(position.x) - (1 - ax) * w : Double(position.x) - ax * w
        let y = yScale < 0 ? Double(position.y) - (1 - ay) * h : Double(position.y) - ay * h
        func thousandths(_ v: Double) -> CGFloat { CGFloat(Float((v * 1000).rounded() / 1000)) }
        return CGRect(x: thousandths(x), y: thousandths(y), width: thousandths(w), height: thousandths(h))
    }
}

/// Draws its subtree clipped to `maskRect` (in its own coordinates), as one unit at its own z: what the plaza did with
/// an `SKCropNode` and a white mask sprite (anchor at the origin) placed at the rect. `nil`: no mask.
@MainActor final class PlazaCropNode: PlazaNode {
    // Unchecked storage: these are read and written only by plain loads and stores in this file's get/set accessors,
    // on the main actor; never passed inout, no observers, no modify accessors. Overlapping access cannot happen, so
    // the dynamic exclusivity checks (about 2 ns a write, Task 7) are left out. SharedSourcesScanTests checks it.
    @exclusivity(unchecked) private var _maskRect: CGRect?

    var maskRect: CGRect? {
        get { _maskRect }
        set {
            let v = newValue.map { PlazaFloat.stored($0) }
            guard !PlazaFloat.same(v, _maskRect) else { return }
            _maskRect = v
            mirror?.setMaskRect(v)
        }
    }
}

/// The stage's camera. Its children are drawn in screen space (origin at the viewport centre) but sort in the same
/// global z space as the world.
@MainActor final class PlazaCameraNode: PlazaNode {}

/// A backend's copy of one node: the backend subclasses this and overrides what its node kind needs; the defaults do
/// nothing. Each call carries a value that changed, already in stored form. A class rather than a protocol because
/// every changed write goes through it: a class method call measured about 2 ns cheaper per write than a call through
/// a protocol existential (Task 7, risk R1), on a write that costs SpriteKit itself about 4 ns.
@MainActor class PlazaNodeMirror {
    init() {}
    /// `child` was added to this node's children at `index`; builds the child's copy (and its subtree's) when it has none.
    func insertChild(_ child: PlazaNode, at index: Int) {}
    func removeFromParent() {}
    func setName(_ v: String?) {}
    func setPosition(_ v: CGPoint) {}
    func setZPosition(_ v: CGFloat) {}
    func setAlpha(_ v: CGFloat) {}
    func setHidden(_ v: Bool) {}
    func setScale(x: CGFloat, y: CGFloat) {}
    func setZRotation(_ v: CGFloat) {}
    func setTexture(_ v: PlazaTexture?) {}
    /// The value assigned to `size` (scaled, as assigned); the backend applies its own scale rule, which is the shared one.
    func setSize(_ v: CGSize) {}
    func setAnchorPoint(_ v: CGPoint) {}
    func setColor(_ v: PlazaColor) {}
    func setColorBlendFactor(_ v: CGFloat) {}
    func setBlendMode(_ v: PlazaBlendMode) {}
    func setMaskRect(_ v: CGRect?) {}
}
