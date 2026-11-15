#if os(Windows)
import Foundation

/// The stage's "something changed" flag, shared by the stage and its mirror (a box, so the mirror holds no reference to
/// the stage and a node that outlives its stage stays harmless). Unchecked storage: plain stores and loads on the main
/// actor only, never inout.
@MainActor final class WinDirtyFlag {
    @exclusivity(unchecked) var isSet = true
}

/// The Windows backend of the shared tree (D3): nothing is copied, the renderer reads the shared tree itself
/// (`PlazaDrawOrder.flatten`). Every write that reaches a mirror is a change (the shared node already dropped writes of the
/// same value), so each one is one store to the stage's dirty flag. One mirror object serves every node of a stage: the
/// mirror keeps no per-node state, so attaching a node costs no allocation.
@MainActor final class WinNodeMirror: PlazaNodeMirror {
    let flag: WinDirtyFlag

    init(flag: WinDirtyFlag) {
        self.flag = flag
        super.init()
    }

    /// Gives `node` and every node below it without a mirror this one. A node that already has a mirror has one on every
    /// node below it too (children added later were mirrored as they came), so its subtree is skipped.
    func install(on node: PlazaNode) {
        guard node.mirror == nil else { return }
        node.installMirror(self)
        for child in node.children { install(on: child) }
    }

    override func insertChild(_ child: PlazaNode, at index: Int) {
        install(on: child)
        flag.isSet = true
    }

    override func removeFromParent() { flag.isSet = true }
    override func setName(_ v: String?) {}   // names draw nothing
    override func setPosition(_ v: CGPoint) { flag.isSet = true }
    override func setZPosition(_ v: CGFloat) { flag.isSet = true }
    override func setAlpha(_ v: CGFloat) { flag.isSet = true }
    override func setHidden(_ v: Bool) { flag.isSet = true }
    override func setScale(x: CGFloat, y: CGFloat) { flag.isSet = true }
    override func setZRotation(_ v: CGFloat) { flag.isSet = true }
    override func setTexture(_ v: PlazaTexture?) { flag.isSet = true }
    override func setSize(_ v: CGSize) { flag.isSet = true }
    override func setAnchorPoint(_ v: CGPoint) { flag.isSet = true }
    override func setColor(_ v: PlazaColor) { flag.isSet = true }
    override func setColorBlendFactor(_ v: CGFloat) { flag.isSet = true }
    override func setBlendMode(_ v: PlazaBlendMode) { flag.isSet = true }
    override func setMaskRect(_ v: CGRect?) { flag.isSet = true }
}
#endif
