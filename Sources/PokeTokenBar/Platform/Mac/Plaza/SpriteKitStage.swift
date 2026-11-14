import SpriteKit

/// The Mac's plaza stage (Track A Task 10): the shared tree drawn by SpriteKit. The stage root's mirror is the
/// `PlazaSKScene` itself, so the root's children become the scene's children in the same order (the tree the plaza
/// built when `PlazaScene` was an `SKScene`; the render harness compares it node for node). Values are read from the
/// scene (`size`, `isPaused`), since SpriteKit changes them itself (`.resizeFill`, `presentScene`).
@MainActor final class SpriteKitStage: PlazaStage {
    let root = PlazaNode()
    /// What the window's `SKView` presents (`PlazaMacWindow.open`) and the render harness renders.
    let skScene: PlazaSKScene
    weak var delegate: (any PlazaStageDelegate)?
    /// True while the stage itself writes `skScene.isPaused`, so the scene does not report the change back.
    private(set) var isWritingPause = false

    init(size: CGSize) {
        skScene = PlazaSKScene(size: size)
        root.installMirror(SKNodeMirror(node: skScene))
        skScene.backgroundColor = backgroundColor.skColor
        skScene.stage = self
    }

    /// Must already be in the stage's tree: SpriteKit's camera is the node's SpriteKit copy, made when it was added.
    var camera: PlazaCameraNode? {
        didSet {
            let copy = (camera?.mirror as? SKNodeMirror)?.node as? SKCameraNode
            precondition(camera == nil || copy != nil, "SpriteKitStage.camera: add the camera to the stage's tree first")
            skScene.camera = copy
        }
    }

    var size: CGSize {
        get { skScene.size }
        set { skScene.size = newValue }
    }

    var backingScale: CGFloat? { skScene.view?.window?.backingScaleFactor }

    var backgroundColor = PlazaColor.clear {
        didSet { skScene.backgroundColor = backgroundColor.skColor }
    }

    var isPaused: Bool {
        get { skScene.isPaused }
        set {
            isWritingPause = true
            skScene.isPaused = newValue
            isWritingPause = false
        }
    }

    func currentModifiers() -> PlazaModifiers { MacPlazaInput.currentModifiers() }
}
