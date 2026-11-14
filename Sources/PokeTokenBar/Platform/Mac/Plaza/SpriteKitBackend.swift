import SpriteKit

/// The Mac backend of the shared plaza tree. Each shared node attached under a mounted root has one SpriteKit node in
/// the same place of a same-shaped tree (same classes, same child order, same values as the plaza built by hand), and
/// each changed value is written to it once. Nothing is read back from SpriteKit.
enum SpriteKitBackend {
    /// Builds the SpriteKit copy of `node` and of its subtree and installs the mirrors. Order of writes: scale 1 (a new
    /// node's) → unscaled size → texture, anchor, colour, blend factor, blend mode → position, z, alpha, hidden, name,
    /// rotation → scales → mask → children in order. Setting the size before the scales stores the shared unscaled size
    /// whatever the order of the writes that made it.
    @MainActor static func materialize(_ node: PlazaNode) -> SKNodeMirror {
        let mirror: SKNodeMirror
        switch node {
        case let sprite as PlazaSprite: mirror = SKSpriteMirror(sprite)
        case is PlazaCropNode: mirror = SKCropMirror()
        case is PlazaCameraNode: mirror = SKNodeMirror(node: SKCameraNode())
        default: mirror = SKNodeMirror(node: SKNode())
        }
        let sk = mirror.node
        sk.position = node.position
        sk.zPosition = node.zPosition
        sk.alpha = node.alpha
        sk.isHidden = node.isHidden
        sk.name = node.name
        sk.zRotation = node.zRotation
        sk.xScale = node.xScale
        sk.yScale = node.yScale
        if let crop = node as? PlazaCropNode, let rect = crop.maskRect { mirror.setMaskRect(rect) }
        node.installMirror(mirror)
        for child in node.children {
            sk.addChild((child.mirror as? SKNodeMirror ?? materialize(child)).node)
        }
        return mirror
    }

    /// The texture's `SKTexture`, made once: `SKTexture(cgImage:)` of the image's own `CGImage`, or
    /// `SKTexture(rect:in:)` of the parent's, always `.nearest`.
    @MainActor static func texture(_ t: PlazaTexture) -> SKTexture {
        if let cached = t.nativeCache as? SKTexture { return cached }
        let made = t.parent.map { SKTexture(rect: t.rect, in: texture($0)) } ?? SKTexture(cgImage: t.image.cgImage)
        made.filteringMode = .nearest
        t.nativeCache = made
        return made
    }

    static func blendMode(_ m: PlazaBlendMode) -> SKBlendMode {
        switch m {
        case .alpha: .alpha
        case .multiply: .multiply
        case .multiplyX2: .multiplyX2
        }
    }
}

/// A plain node's SpriteKit copy (`SKNode`, or `SKCameraNode` for the camera). Sprite and crop values do not apply.
@MainActor class SKNodeMirror: PlazaNodeMirror {
    let node: SKNode

    init(node: SKNode) {
        self.node = node
        super.init()
    }

    final override func insertChild(_ child: PlazaNode, at index: Int) {
        node.insertChild((child.mirror as? SKNodeMirror ?? SpriteKitBackend.materialize(child)).node, at: index)
    }

    final override func removeFromParent() { node.removeFromParent() }
    final override func setName(_ v: String?) { node.name = v }
    final override func setPosition(_ v: CGPoint) { node.position = v }
    final override func setZPosition(_ v: CGFloat) { node.zPosition = v }
    final override func setAlpha(_ v: CGFloat) { node.alpha = v }
    final override func setHidden(_ v: Bool) { node.isHidden = v }
    final override func setScale(x: CGFloat, y: CGFloat) { node.xScale = x; node.yScale = y }
    final override func setZRotation(_ v: CGFloat) { node.zRotation = v }
}

/// A sprite's copy: an `SKSpriteNode` built in the materialize order.
@MainActor final class SKSpriteMirror: SKNodeMirror {
    let sprite: SKSpriteNode

    init(_ source: PlazaSprite) {
        let s = SKSpriteNode()
        s.size = source.unscaledSize   // a new node's scale is 1, so this is the unscaled size SpriteKit keeps
        s.texture = source.texture.map(SpriteKitBackend.texture)
        s.anchorPoint = source.anchorPoint
        s.color = source.color.skColor
        s.colorBlendFactor = source.colorBlendFactor
        s.blendMode = SpriteKitBackend.blendMode(source.blendMode)
        sprite = s
        super.init(node: s)
    }

    override func setTexture(_ v: PlazaTexture?) { sprite.texture = v.map(SpriteKitBackend.texture) }
    override func setSize(_ v: CGSize) { sprite.size = v }
    override func setAnchorPoint(_ v: CGPoint) { sprite.anchorPoint = v }
    override func setColor(_ v: PlazaColor) { sprite.color = v.skColor }
    override func setColorBlendFactor(_ v: CGFloat) { sprite.colorBlendFactor = v }
    override func setBlendMode(_ v: PlazaBlendMode) { sprite.blendMode = SpriteKitBackend.blendMode(v) }
}

/// A crop node's copy: an `SKCropNode` whose mask is a white sprite with its anchor at the origin, placed at the rect
/// (what `PlazaActor` built by hand: position, size, then `maskNode`).
@MainActor final class SKCropMirror: SKNodeMirror {
    let crop = SKCropNode()
    private(set) var mask: SKSpriteNode?

    init() { super.init(node: crop) }

    override func setMaskRect(_ v: CGRect?) {
        guard let v else { crop.maskNode = nil; return }
        let m = mask ?? SKSpriteNode(color: .white, size: .zero)
        if mask == nil { m.anchorPoint = .zero; mask = m }
        m.position = v.origin
        m.size = v.size
        crop.maskNode = m
    }
}

extension PlazaNode {
    /// This node's SpriteKit copy, when it has one.
    var skNode: SKNode? { (mirror as? SKNodeMirror)?.node }

    /// Bridge while the scene is still an `SKScene` (Tasks 7–9; removed in Task 10): builds this shared subtree's
    /// SpriteKit copy and appends it to `parent`'s children, where `parent.addChild(layer)` put the layer before.
    func mountInSpriteKit(_ parent: SKNode) {
        parent.addChild((mirror as? SKNodeMirror ?? SpriteKitBackend.materialize(self)).node)
    }
}
