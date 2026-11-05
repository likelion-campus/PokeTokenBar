import Foundation
import CoreGraphics

/// 팀원 한 명의 화면 위치. 받은 칸을 한 칸씩 부드럽게 따라가며 대각선으로 가로지르지 않는다.
struct PlazaRemoteMotion: Sendable {
    /// 대기열이 이보다 길어지면 따라가기를 포기하고 바로 옮긴다.
    static let maxQueued = 3

    /// 서 있거나, 걷는 중이면 도착할 칸
    private(set) var tile: TilePoint
    var facing: PlazaDirection
    var senderIsWalking = false
    /// 그 팀원이 달리고 있다. 다음에 출발하는 칸부터 달리는 빠르기로 따라간다.
    var senderIsRunning = false

    private var queue: [TilePoint] = []
    /// 걷는 중이면 출발한 칸
    private var stepFrom: TilePoint?
    private var stepElapsed: TimeInterval = 0
    /// 지금 가는 칸에 걸리는 시간. 칸을 출발할 때 정한다.
    private var stepLength: TimeInterval = PlazaWalker.stepDuration

    var isWalking: Bool { stepFrom != nil || !queue.isEmpty || senderIsWalking }

    init(tile: TilePoint, facing: PlazaDirection) {
        self.tile = tile
        self.facing = facing
    }

    var footPoint: CGPoint {
        let t = stepFrom == nil ? 0 : min(1, stepElapsed / stepLength)
        return PlazaWalker.footPoint(from: stepFrom ?? tile, to: tile, progress: t)
    }

    /// 걷는 중이면 지금 걸음, 서 있으면 nil
    var currentStep: PlazaStep? {
        guard let from = stepFrom else { return nil }
        return PlazaStep(from: from, to: tile, progress: min(1, stepElapsed / stepLength))
    }

    mutating func moveTo(_ t: TilePoint) {
        let last = queue.last ?? tile
        if t == last { return }
        let distance = abs(t.x - last.x) + abs(t.y - last.y)
        guard distance == 1 else { return snap(to: t) }
        queue.append(t)
        if queue.count > Self.maxQueued { snap(to: t) }
    }

    mutating func snap(to t: TilePoint) {
        tile = t
        queue.removeAll()
        stepFrom = nil
        stepElapsed = 0
    }

    mutating func advance(by dt: TimeInterval, stepDuration: ((TilePoint, TilePoint, Bool) -> TimeInterval)? = nil) {
        var remaining = dt
        while true {
            if stepFrom != nil {
                let need = stepLength - stepElapsed
                if remaining < need {
                    stepElapsed += remaining
                    return
                }
                remaining -= need
                stepFrom = nil
                stepElapsed = 0
            }
            guard !queue.isEmpty else { return }
            let next = queue.removeFirst()
            facing = Self.direction(from: tile, to: next)
            stepLength = stepDuration?(tile, next, senderIsRunning)
                ?? (senderIsRunning ? PlazaWalker.runStepDuration : PlazaWalker.stepDuration)
            stepFrom = tile
            tile = next
        }
    }

    private static func direction(from a: TilePoint, to b: TilePoint) -> PlazaDirection {
        if b.x > a.x { return .right }
        if b.x < a.x { return .left }
        return b.y > a.y ? .down : .up
    }
}
