import SpriteKit

final class SKDrawTexture: DrawTexture {
    let sk: SKTexture
    init(_ sk: SKTexture) { self.sk = sk }
    var pixelSize: CGSize { sk.size() }
}
class SKDrawNode: DrawNode {
    let sk: SKNode
    init(_ sk: SKNode) { self.sk = sk }
    var position: CGPoint { get { sk.position } set { sk.position = newValue } }
    var zPosition: CGFloat { get { sk.zPosition } set { sk.zPosition = newValue } }
    var alpha: CGFloat { get { sk.alpha } set { sk.alpha = newValue } }
    var isHidden: Bool { get { sk.isHidden } set { sk.isHidden = newValue } }
    func addChild(_ child: DrawNode) { sk.addChild((child as! SKDrawNode).sk) }
}
final class SKDrawSprite: SKDrawNode, DrawSprite {
    private let sprite = SKSpriteNode()
    private var held: DrawTexture?
    init() { super.init(sprite) }
    var texture: DrawTexture? {
        get { held }
        set { held = newValue; sprite.texture = (newValue as! SKDrawTexture?)?.sk }
    }
    var size: CGSize { get { sprite.size } set { sprite.size = newValue } }
}
struct SpriteKitDrawFactory: DrawFactory {
    func makeNode() -> DrawNode { SKDrawNode(SKNode()) }
    func makeSprite() -> DrawSprite { SKDrawSprite() }
    func makeTexture(_ image: CGImage) -> DrawTexture {
        let t = SKTexture(cgImage: image)
        t.filteringMode = .nearest
        return SKDrawTexture(t)
    }
}
extension PlazaPondLayer {
    /// Test access only: the SpriteKit nodes behind the layer.
    var children: [SKNode] { (root as! SKDrawNode).sk.children }
}
