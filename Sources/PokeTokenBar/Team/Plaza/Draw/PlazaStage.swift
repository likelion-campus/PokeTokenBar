import Foundation

/// What a stage tells the scene that draws on it (Task 10 makes `PlazaScene` this delegate).
@MainActor protocol PlazaStageDelegate: AnyObject {
    /// One frame. Not called while the stage is paused or hidden.
    func stageUpdate(_ currentTime: TimeInterval)
    func stageDidChangeSize(from old: CGSize)
    func stageKeyDown(_ e: PlazaKeyEvent)
    func stageKeyUp(keyCode: UInt16)
    /// Only when the platform itself changed `isPaused` (SpriteKit unpauses a scene it presents).
    func stagePausedChanged(_ paused: Bool)
}

/// Where the shared tree is drawn: SpriteKit on the Mac (Task 10), nothing in headless tests and on Windows until stage 6.
@MainActor protocol PlazaStage: AnyObject {
    var root: PlazaNode { get }
    var camera: PlazaCameraNode? { get set }
    var size: CGSize { get set }
    /// nil without a window.
    var backingScale: CGFloat? { get }
    var backgroundColor: PlazaColor { get set }
    var isPaused: Bool { get set }
    var delegate: (any PlazaStageDelegate)? { get set }
    func currentModifiers() -> PlazaModifiers
}
