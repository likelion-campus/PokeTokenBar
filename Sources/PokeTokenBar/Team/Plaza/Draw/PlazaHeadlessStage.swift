import Foundation

/// A stage with nothing behind it: the tree is only state. It has no frame clock, so it never calls `stageUpdate`
/// (a hidden or headless plaza gets no frames); tests drive the scene's `update` themselves.
@MainActor final class PlazaHeadlessStage: PlazaStage {
    let root = PlazaNode()
    var camera: PlazaCameraNode?
    /// Tells the delegate when the value changes, as a scene's `didChangeSize` does.
    var size: CGSize {
        didSet { if size != oldValue { delegate?.stageDidChangeSize(from: oldValue) } }
    }
    var backingScale: CGFloat? { nil }
    var backgroundColor = PlazaColor.clear
    var isPaused = false
    weak var delegate: (any PlazaStageDelegate)?

    init(size: CGSize) { self.size = size }

    func currentModifiers() -> PlazaModifiers { [] }
}
