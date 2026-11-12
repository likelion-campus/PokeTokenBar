import SpriteKit

/// 눈 위의 발자국. 시간은 `advance`가 준 간격으로만 흐르고 타이머와 액션은 없다.
/// 노드는 풀에서 꺼내 쓰고, 상한을 넘으면 가장 오래된 것부터 지운다.
@MainActor final class PlazaFootprintLayer: SKNode {
    static let maxFootprints = 160

    private struct Mark {
        let node: SKSpriteNode
        var age: TimeInterval
    }

    private let worldHeight: CGFloat
    private var marks: [Mark] = []
    private var pool: [SKSpriteNode] = []

    /// 지도 위, 키 큰 풀 덮개(0.05)·그림자(0.5)·캐릭터 아래.
    init(worldHeight: CGFloat) {
        self.worldHeight = worldHeight
        super.init()
        zPosition = 0.04
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var count: Int { marks.count }
    var alphas: [CGFloat] { marks.map { $0.node.alpha } }

    func stamp(_ prints: [PlazaSnow.Footprint]) {
        for p in prints {
            if marks.count >= Self.maxFootprints { recycle(marks.removeFirst().node) }
            let node = pool.popLast() ?? SKSpriteNode()
            node.color = SKColor(red: CGFloat((PlazaSnow.footprintHex >> 16) & 0xFF) / 255,
                                 green: CGFloat((PlazaSnow.footprintHex >> 8) & 0xFF) / 255,
                                 blue: CGFloat(PlazaSnow.footprintHex & 0xFF) / 255, alpha: 1)
            node.size = p.alongX ? CGSize(width: PlazaSnow.footprintLength, height: PlazaSnow.footprintWidth)
                                 : CGSize(width: PlazaSnow.footprintWidth, height: PlazaSnow.footprintLength)
            // 시트 픽셀(월드 2픽셀)에 맞춘다.
            node.position = CGPoint(x: (p.center.x / 2).rounded() * 2, y: ((worldHeight - p.center.y) / 2).rounded() * 2)
            node.alpha = 1
            node.isHidden = false
            if node.parent == nil { addChild(node) }
            marks.append(Mark(node: node, age: 0))
        }
    }

    func advance(by dt: TimeInterval) {
        guard !marks.isEmpty else { return }
        var kept: [Mark] = []
        kept.reserveCapacity(marks.count)
        for var m in marks {
            m.age += dt
            if let alpha = PlazaSnow.footprintAlpha(age: m.age) {
                m.node.alpha = alpha
                kept.append(m)
            } else {
                recycle(m.node)
            }
        }
        marks = kept
    }

    func removeAll() {
        for m in marks { recycle(m.node) }
        marks = []
    }

    private func recycle(_ node: SKSpriteNode) {
        node.isHidden = true
        pool.append(node)
    }
}
