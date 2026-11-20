import SpriteKit
@testable import PokeTokenBar

// Test-only bridges (the app's were removed in Track A Task 10: the scene attaches everything to its stage root). They
// mount shared nodes straight into hand-built SpriteKit trees, so the mirror and actor parity tests can compare a
// shared subtree's SpriteKit copy with a legacy tree of exactly the same shape.

extension PlazaNode {
    /// Builds this shared subtree's SpriteKit copy and appends it to `parent`'s children. Only a root mounts;
    /// `removeFromParent()` takes it out again (and then it can mount again or join a shared parent).
    func mountInSpriteKit(_ parent: SKNode) {
        precondition(self.parent == nil, "mountInSpriteKit: the node has a shared parent; only a root mounts")
        let copy = (mirror as? SKNodeMirror ?? SpriteKitBackend.materialize(self)).node
        precondition(copy.parent == nil, "mountInSpriteKit: the node is already mounted; removeFromParent() it first")
        parent.addChild(copy)
    }
}

extension PlazaActor {
    /// The actor's nodes mounted where the SpriteKit actor added its own (world nodes, then camera nodes, in order).
    func attach(world: SKNode, camera: SKCameraNode) {
        for node in worldNodes { node.mountInSpriteKit(world) }
        for node in cameraNodes { node.mountInSpriteKit(camera) }
    }
}
