import CoreGraphics

// Throwaway (spec §9 experiment 4): the smallest drawing interface PlazaPondLayer needs.
@MainActor protocol DrawTexture: AnyObject { var pixelSize: CGSize { get } }
@MainActor protocol DrawNode: AnyObject {
    var position: CGPoint { get set }
    var zPosition: CGFloat { get set }
    var alpha: CGFloat { get set }
    var isHidden: Bool { get set }
    func addChild(_ child: DrawNode)
}
@MainActor protocol DrawSprite: DrawNode {
    var texture: DrawTexture? { get set }
    var size: CGSize { get set }
}
@MainActor protocol DrawFactory {
    func makeNode() -> DrawNode
    func makeSprite() -> DrawSprite
    func makeTexture(_ image: CGImage) -> DrawTexture
}
