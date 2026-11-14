import Foundation

/// One step of a frame-driven animation: the five `SKAction` scripts the plaza used, nothing more.
@MainActor indirect enum PlazaTweenStep {
    case moveBy(dx: CGFloat, dy: CGFloat, duration: TimeInterval)
    case fadeOut(duration: TimeInterval)
    case scaleTo(CGFloat, duration: TimeInterval)
    case wait(TimeInterval)
    case call(@MainActor () -> Void)
    case removeFromParent
    case group([PlazaTweenStep])
    case sequence([PlazaTweenStep])
}

/// Runs tweens one frame at a time with the scene's frame time. It copies `SKAction`'s arithmetic, measured against
/// SpriteKit under `SKRenderer` (`PlazaTweenOracleTests`), so a node goes through the same 32-bit values frame by frame:
/// - a tween's first step is at elapsed time 0 (progress 0), whatever `dt` is; later steps add `dt`;
/// - a step's clock is the elapsed time as a 32-bit float; a group or sequence hands its children
///   `clamp(time / duration, 0, 1) · duration` (a sequence minus the child's start), so a child shorter than its group
///   sees its parent's rounding (the tackle's scale inside a 0.34 s group); progress is `clamp(time / duration, 0, 1)`;
/// - a timed step is done once the elapsed time (a double) passes `Double(Float(duration))` (SpriteKit keeps durations
///   as 32-bit floats);
/// - `moveBy` adds `Float(dx) · (progress − last progress)` to the node's float position each step; `fadeOut` and
///   `scaleTo` blend from the value read at their first step with `fma(from, 1 − p, to · p)`;
/// - a sequence starts the next step in the same frame with the time left over; a group ends with its longest child;
/// - `call` and `removeFromParent` take no time;
/// - a tween started during `advance` (from a `call`) takes its first step in that same `advance`, as an action started
///   by a scene-level `SKAction.run` block does;
/// - a tween whose node has left the tree is dropped (SpriteKit stops running a removed node's actions).
/// Known differences, none visible in the plaza: SpriteKit's very last `moveBy` step can differ by one float step of
/// `dx` (every plaza script removes the node in that same frame); with a scene clock below 1 s, a fade inside a nested
/// sequence can differ by one float step (the app's clock is seconds since boot, the harness's 1000 + t); after a frame
/// hitch longer than `PlazaScene.maxFrameDelta`, tweens advance by the clamped time, SpriteKit by the real one.
@MainActor final class PlazaTweens {
    private final class Running {
        let node: PlazaNode?
        let state: TweenState
        var started = false
        var elapsed: TimeInterval = 0
        var done = false
        init(node: PlazaNode?, state: TweenState) { self.node = node; self.state = state }
    }

    private var running: [Running] = []

    init() {}

    /// Running tweens, scene-level ones included.
    var count: Int { running.count }

    /// Starts `step` on `node`; `nil` runs a scene-level script (only `wait` and `call` mean anything there).
    func run(_ step: PlazaTweenStep, on node: PlazaNode?) {
        running.append(Running(node: node, state: TweenState(step)))
    }

    func advance(by dt: TimeInterval) {
        var i = 0
        while i < running.count {   // `call` may start tweens; they run in this same pass
            let r = running[i]
            i += 1
            if let node = r.node, node.parent == nil { r.done = true; continue }
            if r.started { r.elapsed += dt } else { r.started = true }
            r.done = r.state.step(elapsed: r.elapsed, time: Float(r.elapsed), node: r.node)
        }
        running.removeAll { $0.done }
    }
}

@MainActor private final class TweenState {
    private enum Kind {
        case move(dx: Float, dy: Float), fade, scale(Float), wait, call(@MainActor () -> Void), remove
        case group([TweenState]), sequence([TweenState])
    }

    private let kind: Kind
    /// The duration as SpriteKit holds it (32-bit), and as a double for the "done" comparison.
    private let duration: Float
    let doneAfter: TimeInterval
    private var begun = false
    private var finished = false
    private var lastProgress: Float = 0
    private var from: (Float, Float) = (0, 0)
    private var index = 0
    private var offset: TimeInterval = 0
    private var offsetTime: Float = 0

    init(_ step: PlazaTweenStep) {
        switch step {
        case let .moveBy(dx, dy, d): kind = .move(dx: Float(dx), dy: Float(dy)); duration = Float(d)
        case let .fadeOut(d): kind = .fade; duration = Float(d)
        case let .scaleTo(s, d): kind = .scale(Float(s)); duration = Float(d)
        case let .wait(d): kind = .wait; duration = Float(d)
        case let .call(f): kind = .call(f); duration = 0
        case .removeFromParent: kind = .remove; duration = 0
        case let .group(steps):
            let children = steps.map { TweenState($0) }
            kind = .group(children); duration = Float(children.reduce(0) { max($0, $1.doneAfter) })
        case let .sequence(steps):
            let children = steps.map { TweenState($0) }
            kind = .sequence(children); duration = Float(children.reduce(0) { $0 + $1.doneAfter })
        }
        doneAfter = Double(duration)
    }

    /// SpriteKit's ratio: the step's clock over its 32-bit duration, clamped.
    private func progress(_ time: Float) -> Float { duration > 0 ? min(1, max(0, time / duration)) : 1 }

    private static func blend(_ from: Float, _ to: Float, _ p: Float) -> Float { (to * p).addingProduct(from, 1 - p) }

    /// One evaluation: `elapsed` seconds since this step began decide when it is done; `time`, the same clock as its
    /// parent hands it on in 32 bits, sets the values. True when the step is done.
    func step(elapsed: TimeInterval, time: Float, node: PlazaNode?) -> Bool {
        switch kind {
        case let .move(dx, dy):
            let p = progress(time)
            if let node {
                let x = Float(node.position.x) + dx * (p - lastProgress)
                let y = Float(node.position.y) + dy * (p - lastProgress)
                node.position = CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
            lastProgress = p
            return elapsed > doneAfter
        case .fade:
            if !begun { begun = true; from.0 = Float(node?.alpha ?? 0) }
            node?.alpha = CGFloat(Self.blend(from.0, 0, progress(time)))
            return elapsed > doneAfter
        case let .scale(target):
            if !begun { begun = true; from = (Float(node?.xScale ?? 1), Float(node?.yScale ?? 1)) }
            let p = progress(time)
            node?.xScale = CGFloat(Self.blend(from.0, target, p))
            node?.yScale = CGFloat(Self.blend(from.1, target, p))
            return elapsed > doneAfter
        case .wait:
            return elapsed > doneAfter
        case let .call(f):
            f()
            return true
        case .remove:
            node?.removeFromParent()
            return true
        case let .group(children):
            let inner = progress(time) * duration
            var all = true
            for child in children where !child.finished {
                if child.step(elapsed: elapsed, time: inner, node: node) { child.finished = true } else { all = false }
            }
            return all
        case let .sequence(children):
            let inner = progress(time) * duration
            while index < children.count {
                if !children[index].step(elapsed: elapsed - offset, time: inner - offsetTime, node: node) { return false }
                offset += children[index].doneAfter
                offsetTime += children[index].duration
                index += 1
            }
            return true
        }
    }
}
