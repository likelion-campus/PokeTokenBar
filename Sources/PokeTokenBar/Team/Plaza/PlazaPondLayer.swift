import SpriteKit

/// 연못의 물보라 방울, 물결 고리, 거품을 그리는 노드. 모두 풀에서 꺼내 쓰는 스프라이트이고,
/// 시간은 `update(dt:)` 로만 흐른다. 타이머는 없다.
@MainActor final class PlazaPondLayer: SKNode {
    static let maxDroplets = 48, maxRings = 12, maxBubbles = 24, maxPending = 32
    static let smallDroplets = 4, bigDroplets = 10
    static let secondRingDelay: TimeInterval = 0.12
    private static let dropletLife: TimeInterval = 0.5, ringLife: TimeInterval = 0.6, bubbleLife: TimeInterval = 0.6
    private static let dropletZ: CGFloat = 2.5, ringZ: CGFloat = 0.06, bubbleZ: CGFloat = 0.07
    private static let dropletVX: [CGFloat] = [-22, 18, -8, 10, -30, 28, -14, 24, -3, 4]
    private static let dropletVY: CGFloat = 70, dropletGravity: CGFloat = 260
    private static let ringFromRadius = 2, ringToRadius = 7   // 시트 픽셀 (월드 4 → 14px)
    private static let bubbleRise: CGFloat = 10
    private static let grid: CGFloat = 2
    private static let scale: CGFloat = 2   // 시트 픽셀 → 월드 px

    private struct Particle {
        let start: CGPoint   // 월드 좌표(SpriteKit, y 위로)
        let vx: CGFloat
        var age: TimeInterval
        let node: SKSpriteNode
    }
    private enum Kind { case droplets(Int), ring }
    private struct Pending {
        let at: CGPoint
        let kind: Kind
        var wait: TimeInterval
    }

    private let worldHeight: CGFloat
    private var droplets: [Particle] = []
    private var rings: [Particle] = []
    private var bubbles: [Particle] = []
    private var pending: [Pending] = []
    private var dropletPool: [SKSpriteNode] = []
    private var ringPool: [SKSpriteNode] = []
    private var bubblePool: [SKSpriteNode] = []
    private var ringTextures: [Int: SKTexture] = [:]   // 반지름(시트 픽셀)마다 하나
    private let dropletTexture = PlazaPondLayer.texture(PlazaPondArt.droplet())
    private let bubbleTexture = PlazaPondLayer.texture(PlazaPondArt.bubble())
    private var isConcealed = false

    init(map: PlazaMap = PlazaMapData.map) {
        worldHeight = CGFloat(map.height * PlazaMap.tileSize)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var dropletCount: Int { droplets.count }
    var ringCount: Int { rings.count }
    var bubbleCount: Int { bubbles.count }

    func splash(at tile: TilePoint, big: Bool, delay: TimeInterval = 0) {
        guard !isConcealed else { return }
        let p = center(of: tile)
        let kinds: [(Kind, TimeInterval)] = big
            ? [(.droplets(Self.bigDroplets), 0), (.ring, 0), (.ring, Self.secondRingDelay)]
            : [(.droplets(Self.smallDroplets), 0), (.ring, 0)]
        for (kind, extra) in kinds {
            let wait = delay + extra
            if wait <= 0 {
                start(Pending(at: p, kind: kind, wait: 0), elapsed: 0)
            } else if pending.count < Self.maxPending {
                pending.append(Pending(at: p, kind: kind, wait: wait))
            }
        }
    }

    func bubble(at tile: TilePoint) {
        guard !isConcealed, bubbles.count < Self.maxBubbles else { return }
        let node = bubblePool.popLast() ?? makeNode(z: Self.bubbleZ, size: 3)
        node.texture = bubbleTexture
        let b = Particle(start: center(of: tile), vx: 0, age: 0, node: node)
        node.isHidden = false
        bubbles.append(b)
        placeBubble(b)
    }

    func update(dt: TimeInterval) {
        guard !isConcealed else { return }
        droplets = advance(droplets, life: Self.dropletLife, dt: dt, place: placeDroplet) { dropletPool.append($0) }
        rings = advance(rings, life: Self.ringLife, dt: dt, place: placeRing) { ringPool.append($0) }
        bubbles = advance(bubbles, life: Self.bubbleLife, dt: dt, place: placeBubble) { bubblePool.append($0) }
        // 대기 중인 것은 시간이 차면 시작하고, 넘친 만큼은 이미 흐른 것으로 본다.
        var waiting: [Pending] = []
        for var p in pending {
            p.wait -= dt
            if p.wait <= 0 { start(p, elapsed: -p.wait) } else { waiting.append(p) }
        }
        pending = waiting
    }

    func setHidden(_ hidden: Bool) {
        isConcealed = hidden
        guard hidden else { return }
        for p in droplets { recycle(p.node, into: &dropletPool) }
        for p in rings { recycle(p.node, into: &ringPool) }
        for p in bubbles { recycle(p.node, into: &bubblePool) }
        droplets = []; rings = []; bubbles = []; pending = []
    }

    // MARK: - 내부

    private func center(of tile: TilePoint) -> CGPoint {
        let t = CGFloat(PlazaMap.tileSize)
        return CGPoint(x: (CGFloat(tile.x) + 0.5) * t, y: worldHeight - (CGFloat(tile.y) + 0.5) * t)
    }

    private func snap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x / Self.grid).rounded() * Self.grid, y: (p.y / Self.grid).rounded() * Self.grid)
    }

    private func start(_ p: Pending, elapsed: TimeInterval) {
        switch p.kind {
        case .droplets(let n):
            for i in 0..<n where droplets.count < Self.maxDroplets {
                let node = dropletPool.popLast() ?? makeNode(z: Self.dropletZ, size: 2)
                node.texture = dropletTexture
                var d = Particle(start: p.at, vx: Self.dropletVX[i % Self.dropletVX.count], age: elapsed, node: node)
                d.age = min(d.age, Self.dropletLife)
                node.isHidden = false
                droplets.append(d)
                placeDroplet(d)
            }
        case .ring:
            guard rings.count < Self.maxRings else { return }
            let node = ringPool.popLast() ?? makeNode(z: Self.ringZ, size: 0)
            let r = Particle(start: p.at, vx: 0, age: elapsed, node: node)
            node.isHidden = false
            rings.append(r)
            placeRing(r)
        }
    }

    private func makeNode(z: CGFloat, size: CGFloat) -> SKSpriteNode {
        let n = SKSpriteNode()
        n.size = CGSize(width: size * Self.scale, height: size * Self.scale)
        n.zPosition = z
        addChild(n)
        return n
    }

    private func advance(_ list: [Particle], life: TimeInterval, dt: TimeInterval, place: (Particle) -> Void,
                         recycle done: (SKSpriteNode) -> Void) -> [Particle] {
        var alive: [Particle] = []
        for var p in list {
            p.age += dt
            if p.age < life { place(p); alive.append(p) } else { p.node.isHidden = true; done(p.node) }
        }
        return alive
    }

    private func recycle(_ node: SKSpriteNode, into pool: inout [SKSpriteNode]) {
        node.isHidden = true
        pool.append(node)
    }

    private func placeDroplet(_ d: Particle) {
        let t = CGFloat(d.age)
        let y = Self.dropletVY * t - 0.5 * Self.dropletGravity * t * t   // 위로 튀고 떨어진다
        d.node.position = snap(CGPoint(x: d.start.x + d.vx * t, y: d.start.y + y))
    }

    private func placeRing(_ r: Particle) {
        let k = CGFloat(r.age / Self.ringLife)
        let span = Self.ringToRadius - Self.ringFromRadius
        let radius = Self.ringFromRadius + Int((CGFloat(span) * k).rounded())
        let texture = ringTextures[radius] ?? {
            let t = Self.texture(PlazaPondArt.ring(radius: radius))
            ringTextures[radius] = t
            return t
        }()
        r.node.texture = texture
        r.node.size = CGSize(width: texture.size().width * Self.scale, height: texture.size().height * Self.scale)
        r.node.alpha = 1 - k
        r.node.position = snap(r.start)
    }

    private func placeBubble(_ b: Particle) {
        let k = CGFloat(b.age / Self.bubbleLife)
        b.node.alpha = 1 - k
        b.node.position = snap(CGPoint(x: b.start.x, y: b.start.y + Self.bubbleRise * k))
    }

    private static func texture(_ image: CGImage) -> SKTexture {
        let t = SKTexture(cgImage: image)
        t.filteringMode = .nearest
        return t
    }
}
