import SpriteKit

/// 연못의 물보라 방울, 물결 고리, 거품을 그리는 노드. 모두 풀에서 꺼내 쓰는 스프라이트이고,
/// 시간은 `update(dt:)` 로만 흐른다. 타이머는 없다.
@MainActor final class PlazaPondLayer: SKNode {
    static let maxDroplets = 64, maxRings = 12, maxBubbles = 24, maxPending = 32
    static let secondRingDelay: TimeInterval = 0.12
    private static let dropletLife: TimeInterval = 0.6, ringLife: TimeInterval = 0.6, bubbleLife: TimeInterval = 0.6
    private static let dropletZ: CGFloat = 2.5, ringZ: CGFloat = 0.06, bubbleZ: CGFloat = 2.4
    /// 방울마다 (옆으로 가는 거리, 가장 높이 오르는 높이). 월드 px, 물가선 기준. 부채꼴로 퍼진다.
    private static let bigShapes: [(reach: CGFloat, height: CGFloat)] = [
        (-64, 26), (-52, 46), (-42, 62), (-32, 78), (-23, 90), (-14, 100), (-7, 108), (-2, 114),
        (4, 110), (10, 104), (18, 94), (27, 82), (36, 68), (46, 50), (56, 34), (66, 22)]
    private static let smallShapes: [(reach: CGFloat, height: CGFloat)] = [
        (-26, 16), (-17, 30), (-6, 40), (7, 38), (18, 28), (27, 14)]
    static let bigDroplets = bigShapes.count, smallDroplets = smallShapes.count
    private static let ringFromRadius = 2, bigRingToRadius = 20, smallRingToRadius = 10   // 시트 픽셀 (월드 ×2)
    private static let bubbleRise: CGFloat = 14
    private static let bubbleOffsets: [CGFloat] = [-6, 5, -2, 7, -8, 3]
    private static let grid: CGFloat = 2
    private static let scale: CGFloat = 2   // 시트 픽셀 → 월드 px

    private struct Particle {
        let start: CGPoint   // 월드 좌표(SpriteKit, y 위로)
        var reach: CGFloat = 0   // 방울: 옆으로 가는 거리
        var height: CGFloat = 0   // 방울: 가장 높이 오르는 높이
        var toRadius = 0   // 고리: 끝 반지름(시트 픽셀)
        var age: TimeInterval
        let node: SKSpriteNode
    }
    /// 대기열에는 큰 물보라의 두 번째 고리만 들어간다.
    private struct Pending {
        let at: CGPoint
        let toRadius: Int
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
    private let bigDropletTexture = PlazaPondLayer.texture(PlazaPondArt.bigDroplet())
    private let bubbleTexture = PlazaPondLayer.texture(PlazaPondArt.bubble())
    private var isConcealed = false
    private var bubbleSerial = 0

    init(map: PlazaMap = PlazaMapData.map) {
        worldHeight = CGFloat(map.height * PlazaMap.tileSize)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var dropletCount: Int { droplets.count }
    var ringCount: Int { rings.count }
    var bubbleCount: Int { bubbles.count }
    var pendingCount: Int { pending.count }

    /// 물보라는 `tile`의 물가선(칸 아래쪽, 발이 닿는 높이)에서 시작한다.
    func splash(at tile: TilePoint, big: Bool) {
        guard !isConcealed else { return }
        let foot = PlazaWalker.footPoint(from: tile, to: tile, progress: 0)
        let p = CGPoint(x: foot.x, y: worldHeight - foot.y)
        // 대기열은 물보라 통째로 넣거나 통째로 버린다(고리만 잃고 방울만 남지 않게).
        if big {
            guard pending.count < Self.maxPending else { return }
            pending.append(Pending(at: p, toRadius: Self.bigRingToRadius, wait: Self.secondRingDelay))
        }
        startDroplets(big ? Self.bigShapes : Self.smallShapes, at: p)
        startRing(at: p, toRadius: big ? Self.bigRingToRadius : Self.smallRingToRadius, elapsed: 0)
    }

    func bubble(at tile: TilePoint) {
        guard !isConcealed, bubbles.count < Self.maxBubbles else { return }
        let node = bubblePool.popLast() ?? makeNode(z: Self.bubbleZ, size: 3)
        node.texture = bubbleTexture
        var c = center(of: tile)
        c.x += Self.bubbleOffsets[bubbleSerial % Self.bubbleOffsets.count]
        bubbleSerial += 1
        let b = Particle(start: c, age: 0, node: node)
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
            if p.wait <= 0 { startRing(at: p.at, toRadius: p.toRadius, elapsed: -p.wait) } else { waiting.append(p) }
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

    private func startDroplets(_ shapes: [(reach: CGFloat, height: CGFloat)], at p: CGPoint) {
        for (i, shape) in shapes.enumerated() where droplets.count < Self.maxDroplets {
            let node = dropletPool.popLast() ?? makeNode(z: Self.dropletZ, size: 2)
            // 세 번째마다 큰 방울. 풀에서 되살린 노드는 크기가 다를 수 있어 매번 그림과 크기를 함께 정한다.
            let big = i % 3 == 0
            node.texture = big ? bigDropletTexture : dropletTexture
            node.size = CGSize(width: (big ? 3 : 2) * Self.scale, height: (big ? 3 : 2) * Self.scale)
            let d = Particle(start: p, reach: shape.reach, height: shape.height, age: 0, node: node)
            node.isHidden = false
            droplets.append(d)
            placeDroplet(d)
        }
    }

    private func startRing(at p: CGPoint, toRadius: Int, elapsed: TimeInterval) {
        guard rings.count < Self.maxRings else { return }
        let node = ringPool.popLast() ?? makeNode(z: Self.ringZ, size: 0)
        let r = Particle(start: p, toRadius: toRadius, age: elapsed, node: node)
        node.isHidden = false
        rings.append(r)
        placeRing(r)
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
        let u = CGFloat(d.age / Self.dropletLife)
        // 옆으로는 같은 빠르기로, 위로는 포물선: u=0.5 에서 `height` 만큼 오르고 다시 물가선으로 내려온다.
        d.node.position = snap(CGPoint(x: d.start.x + d.reach * u, y: d.start.y + 4 * d.height * u * (1 - u)))
    }

    private func placeRing(_ r: Particle) {
        let k = CGFloat(r.age / Self.ringLife)
        let span = r.toRadius - Self.ringFromRadius
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
