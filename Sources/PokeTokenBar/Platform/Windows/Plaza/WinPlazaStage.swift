#if os(Windows)
import Foundation

/// The Windows plaza stage (D3, D4): the shared tree plus the frame clock's entry point. Nothing is mirrored into another
/// scene graph; the node mirrors only mark the frame dirty and `WinPlazaRenderer` draws the shared tree itself.
///
/// Main thread only. The stage never pauses itself (no window system changes `isPaused` behind its back), so it never
/// calls `stagePausedChanged`: the scene's own pause writes are never echoed back (the SpriteKit stage's no-echo rule).
@MainActor final class WinPlazaStage: PlazaStage {
    let root = PlazaNode()
    weak var delegate: (any PlazaStageDelegate)?
    let mirror: WinNodeMirror
    private let flag: WinDirtyFlag
    private var scale: CGFloat?

    init(size: CGSize) {
        self.size = size
        let flag = WinDirtyFlag()
        self.flag = flag
        mirror = WinNodeMirror(flag: flag)
        mirror.install(on: root)
    }

    /// Must be in the stage's tree, as on the Mac.
    var camera: PlazaCameraNode? {
        didSet { if camera !== oldValue { flag.isSet = true } }
    }

    /// Points (`SKScene.size` with `.resizeFill`: the view's size). Tells the delegate when it changes.
    var size: CGSize {
        didSet {
            guard size != oldValue else { return }
            flag.isSet = true
            delegate?.stageDidChangeSize(from: oldValue)
        }
    }

    /// Device pixels per point: `GetDpiForWindow / 96` exactly (1, 1.25, 1.5, 2...), set by the window or the harness.
    /// Nil until set (the scene then assumes 2, as on the Mac without a window).
    var backingScale: CGFloat? { scale }

    func setBackingScale(_ s: CGFloat) {
        guard s > 0, s != scale else { return }
        scale = s
        flag.isSet = true
    }

    var backgroundColor = PlazaColor.clear {
        didSet { if backgroundColor != oldValue { flag.isSet = true } }
    }

    var isPaused = false

    func currentModifiers() -> PlazaModifiers { PlatformPlaza.currentModifiers() }

    /// True when something in the tree or the stage changed since the last `didDraw` (D3). Starts true.
    var needsDraw: Bool { flag.isSet }

    /// The renderer drew everything up to now.
    func didDraw() { flag.isSet = false }

    /// For what changes the picture outside the tree (the window's resize, a device rebuild, the HUD host).
    func setNeedsDraw() { flag.isSet = true }

    /// One frame of the clock: the scene's update, unless paused. Drawing is the caller's (`WinPlazaRenderer.drawIfNeeded`).
    func tick(at seconds: TimeInterval) {
        guard !isPaused else { return }
        delegate?.stageUpdate(seconds)
    }

    func key(down e: PlazaKeyEvent) { delegate?.stageKeyDown(e) }
    func key(up keyCode: UInt16) { delegate?.stageKeyUp(keyCode: keyCode) }
}
#endif
