import SpriteKit

/// 날아가는 눈덩이 하나. 지면 위 점(월드 px, y 아래로)과 높이로 그려진다.
struct PlazaSnowballFlight {
    enum Burst { case air, ground, none }   // none: the scene splashes instead
    var start: CGPoint, end: CGPoint
    var endHeight: CGFloat   // 0 on a miss
    var frames: Int
    var burst: Burst
}

/// 눈덩이·그림자·터짐 조각. 시간은 `advance`가 준 간격으로만 흐르고 타이머와 액션은 없다.
/// 노드는 모두 풀에서 꺼내 쓰고, 동시에 날 수 있는 수는 `maxFlights`로 막는다.
@MainActor final class PlazaSnowballLayer: SKNode {
    static let maxFlights = 24

    private struct Flight {
        let spec: PlazaSnowballFlight
        let onLand: @MainActor () -> Void
        var age: TimeInterval = 0
        var landed = false
        var ball: SKSpriteNode?
        var shadow: SKSpriteNode?
        var pieces: [SKSpriteNode] = []
    }

    private let worldHeight: CGFloat
    private var flights: [Flight] = []
    private var pool: [SKSpriteNode] = []
    private var created = 0
    private var textures: [SKTexture] = []
    /// 그림마다, 그림 한 픽셀의 월드 픽셀 수.
    private var scales: [CGFloat] = []
    private let shadowTexture: SKTexture

    private static func nearest(_ image: PlazaImage) -> SKTexture {
        let t = SKTexture(cgImage: image.cgImage)
        t.filteringMode = .nearest
        return t
    }

    /// 던지는 것과 터짐 그림을 바꾼다(계절이 바뀔 때). 이미 날고 있는 것은 다음 프레임부터 새 그림이다.
    func setArt(_ pieces: [PlazaSnowballArt.Piece]) {
        textures = pieces.map { Self.nearest($0.image) }
        scales = pieces.map(\.scale)
        for f in flights { f.ball.map { resize($0, glyph: 0) } }
    }

    private func resize(_ node: SKSpriteNode, glyph: Int) {
        node.texture = textures[glyph]
        node.size = CGSize(width: textures[glyph].size().width * scales[glyph], height: textures[glyph].size().height * scales[glyph])
    }

    init(worldHeight: CGFloat) {
        self.worldHeight = worldHeight
        let nearest = Self.nearest
        shadowTexture = nearest(PlazaGroundShadow.image(width: Int(PlazaSnowball.shadowSize.width), height: Int(PlazaSnowball.shadowSize.height)))
        super.init()
        setArt(PlazaSnowballArt.pieces())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var flightCount: Int { flights.count }
    /// 테스트용: 날고 있는 것들의 크기(월드 픽셀).
    var ballSizes: [CGSize] { flights.compactMap { $0.ball?.size } }
    var nodeCount: Int { created }
    var shownSpriteCount: Int { children.filter { !$0.isHidden }.count }

    /// false when `maxFlights` are already up (the caller lands it at once).
    func launch(_ flight: PlazaSnowballFlight, onLand: @escaping @MainActor () -> Void) -> Bool {
        guard flights.count < Self.maxFlights else { return false }
        var f = Flight(spec: flight, onLand: onLand)
        f.ball = take(texture: textures[0], anchor: CGPoint(x: 0, y: 0))
        f.ball.map { resize($0, glyph: 0) }
        f.shadow = take(texture: shadowTexture, anchor: CGPoint(x: 0, y: 0))
        f.shadow?.size = PlazaSnowball.shadowSize
        flights.append(f)
        place(&flights[flights.count - 1])
        return true
    }

    func advance(by dt: TimeInterval) {
        guard !flights.isEmpty else { return }
        // onLand may launch again, so work on a copy and keep what was added meanwhile.
        var current = flights
        flights = []
        var kept: [Flight] = []
        for var f in current {
            f.age += dt
            let frame = Int(f.age / PlazaSnowball.frameDuration + 1e-9)
            if frame >= f.spec.frames, !f.landed {
                f.landed = true
                release(&f.ball)
                release(&f.shadow)
                f.onLand()
            }
            if frame >= f.spec.frames + PlazaSnowball.burstFrames || (f.landed && f.spec.burst == .none) {
                recycleAll(of: &f)
                continue
            }
            place(&f)
            kept.append(f)
        }
        flights = kept + flights
    }

    /// Every flight lands now: its onLand runs, no burst is drawn, all nodes go back to the pools.
    func landAll() {
        let current = flights
        flights = []
        for var f in current {
            recycleAll(of: &f)
            if !f.landed { f.onLand() }
        }
    }

    // MARK: - Drawing

    private func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }

    private func place(_ f: inout Flight) {
        let spec = f.spec
        let frame = Int(f.age / PlazaSnowball.frameDuration + 1e-9)
        if !f.landed {
            let u = CGFloat(frame) / CGFloat(spec.frames)
            let g = CGPoint(x: spec.start.x + (spec.end.x - spec.start.x) * u, y: spec.start.y + (spec.end.y - spec.start.y) * u)
            f.ball?.position = CGPoint(x: even(g.x - (f.ball?.size.width ?? 0) / 2), y: even(worldHeight - g.y + PlazaSnowball.height(at: u, endHeight: spec.endHeight)))
            f.ball?.zPosition = 1 + g.y / worldHeight + 0.0003
            f.shadow?.position = CGPoint(x: even(g.x - PlazaSnowball.shadowSize.width / 2), y: even(worldHeight - g.y - PlazaSnowball.shadowSize.height / 2))
            f.shadow?.zPosition = 0.5
            return
        }
        let step = min(frame - spec.frames, PlazaSnowball.burstFrames - 1)
        let air = spec.burst == .air
        let center = CGPoint(x: spec.end.x, y: worldHeight - spec.end.y + (air ? spec.endHeight : 0))
        let z: CGFloat = air ? 21 : 1 + spec.end.y / worldHeight + 0.0003
        let pieces = PlazaSnowball.burstPieces(step: step, onGround: !air)
        while f.pieces.count < pieces.count {
            f.pieces.append(take(texture: textures[0], anchor: CGPoint(x: 0, y: 0)))
        }
        for (i, piece) in pieces.enumerated() {
            let node = f.pieces[i]
            resize(node, glyph: piece.glyph)
            // 왼쪽 아래 모서리를 월드 2픽셀(시트 한 픽셀)에 맞춘다. 가운데를 맞추면 6픽셀 조각이 홀수 픽셀에 앉는다.
            node.position = CGPoint(x: even(center.x + piece.offset.dx - node.size.width / 2),
                                    y: even(center.y + piece.offset.dy - node.size.height / 2))
            node.zPosition = z
        }
    }

    private func take(texture: SKTexture, anchor: CGPoint) -> SKSpriteNode {
        let node: SKSpriteNode
        if let n = pool.popLast() {
            node = n
        } else {
            node = SKSpriteNode()
            created += 1
            addChild(node)
        }
        node.texture = texture
        node.size = CGSize(width: texture.size().width * PlazaSnowball.cell, height: texture.size().height * PlazaSnowball.cell)
        node.anchorPoint = anchor
        node.isHidden = false
        return node
    }

    private func give(_ node: SKSpriteNode) {
        node.isHidden = true
        pool.append(node)
    }

    private func release(_ node: inout SKSpriteNode?) {
        if let n = node { give(n) }
        node = nil
    }

    private func recycleAll(of f: inout Flight) {
        release(&f.ball)
        release(&f.shadow)
        for n in f.pieces { give(n) }
        f.pieces = []
    }
}
