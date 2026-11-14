import SpriteKit

/// The `SKScene` the plaza window's `SKView` presents (Track A Task 10). It holds no plaza state: it is the SpriteKit
/// copy of the stage root (so the copies of the root's children are its children, exactly where `PlazaScene` added its
/// nodes when it was this scene), its `camera` is the copy of the stage camera, and it hands what SpriteKit tells a
/// scene to the stage's delegate (`PlazaScene`) unchanged: every frame's `update` with SpriteKit's own clock, size
/// changes, key events, and pause changes SpriteKit makes by itself (`presentScene` unpauses; `SKView` pausing).
@MainActor final class PlazaSKScene: SKScene {
    /// The stage this scene draws. Weak: the stage owns the scene.
    weak var stage: SpriteKitStage?

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// SpriteKit calls this only while neither the view nor the scene is paused; actions (none are used) run after it.
    override func update(_ currentTime: TimeInterval) {
        stage?.delegate?.stageUpdate(currentTime)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        stage?.delegate?.stageDidChangeSize(from: oldSize)
    }

    /// `super` would beep for the keys the scene does not use, so every key ends here (as it did in `PlazaScene`).
    override func keyDown(with event: NSEvent) {
        stage?.delegate?.stageKeyDown(PlazaKeyEvent(event))
    }

    override func keyUp(with event: NSEvent) {
        stage?.delegate?.stageKeyUp(keyCode: event.keyCode)
    }

    /// A change the stage did not make itself (SpriteKit's) reaches the delegate, so `PlazaScene`'s pause work runs
    /// exactly when its old `isPaused` `didSet` ran. The stage's own writes are not reported: the scene runs that work
    /// itself.
    override var isPaused: Bool {
        didSet {
            guard isPaused != oldValue, let stage, !stage.isWritingPause else { return }
            stage.delegate?.stagePausedChanged(isPaused)
        }
    }
}
