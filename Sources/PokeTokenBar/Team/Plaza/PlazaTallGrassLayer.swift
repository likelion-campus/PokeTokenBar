import Foundation

/// 풀숲의 앞 띠, 흔들리는 겹침 그림, 흩날리는 잎을 그리는 노드. 겹침 그림과 잎은 풀에서 꺼내 쓰는 스프라이트이고,
/// 시간은 `update(dt:)` 로만 흐른다. 타이머는 없다. 노드는 공유 트리(`root`)에 있고, 장면이 그 트리를 그린다.
@MainActor final class PlazaTallGrassLayer {
    static let maxRustles = 24, maxLeaves = 36
    private static let overlayZ: CGFloat = 0.05
    private static let leafZ: CGFloat = 2.5
    private static let leafSize: CGFloat = 8
    private static let leafGrid: CGFloat = 2
    private static let leafVX: [CGFloat] = [-10, 9, 1]
    private static let leafVY: [CGFloat] = [-30, -34, -42]
    private static let leafGravity: CGFloat = 40
    private static let scale: CGFloat = 2   // 시트 픽셀 → 월드 px

    private struct Running {
        let tile: TilePoint
        let kind: PlazaRustleKind
        let strong: Bool
        var elapsed: TimeInterval
        let node: PlazaSprite
    }
    private struct Leaf {
        let start: CGPoint   // 월드 좌표(y 아래로)
        let vx: CGFloat, vy: CGFloat
        var age: TimeInterval
        let node: PlazaSprite
    }

    let root = PlazaNode()
    private let map: PlazaMap
    private var art: PlazaTallGrassArt
    private let worldHeight: CGFloat
    private var bands: [TilePoint: PlazaSprite] = [:]
    private var slices: [TilePoint: PlazaTallGrassSlice] = [:]
    private var running: [Running] = []   // 시작 순서(앞이 가장 오래됨)
    private var pending: [(cue: PlazaRustleCue, wait: TimeInterval)] = []
    private var leaves: [Leaf] = []
    private var overlayPool: [PlazaSprite] = []
    private var leafPool: [PlazaSprite] = []
    private var textureCache: [String: PlazaTexture] = [:]
    private var leafTextures: [PlazaTexture]
    private var isConcealed = false
    private var leafSpawned = 0

    init(map: PlazaMap, art: PlazaTallGrassArt) {
        self.map = map
        self.art = art
        self.worldHeight = CGFloat(map.height * PlazaMap.tileSize)
        self.leafTextures = art.leaves.map(Self.texture)
        let tile = CGFloat(PlazaMap.tileSize)
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                guard map.tile(at: p) == .tallGrass else { continue }
                let slice = PlazaTallGrass.slice(at: p) { map.tile(at: $0) == .tallGrass }
                slices[p] = slice
                let node = PlazaSprite(texture: cachedTexture("front", slice) { art.front($0) }, size: CGSize(width: tile, height: tile))
                node.anchorPoint = .zero
                node.position = basePosition(p)
                node.zPosition = 1 + (CGFloat(y) * tile + 31) / worldHeight
                root.addChild(node)
                bands[p] = node
            }
        }
    }

    var bandCount: Int { bands.count }
    var leafCount: Int { leaves.count }
    /// 테스트용: 띠들이 쓰는 서로 다른 텍스처 수(조각 종류마다 하나만 만든다).
    var distinctBandTextureCount: Int { Set(bands.values.compactMap { $0.texture.map(ObjectIdentifier.init) }).count }
    var activeRustles: [(tile: TilePoint, kind: PlazaRustleKind, strong: Bool)] {
        running.map { ($0.tile, $0.kind, $0.strong) }
    }

    /// 테스트용: 띠가 지금 쓰는 텍스처.
    func bandTexture(at p: TilePoint) -> PlazaTexture? { bands[p]?.texture }

    /// 그림을 바꿔 끼운다(눈 오는 날). 도는 흔들림은 끝내고, 텍스처 캐시를 비우고, 모든 띠를 새 그림으로 다시 입힌다.
    func setArt(_ art: PlazaTallGrassArt) {
        for r in running { finish(r) }
        running = []
        self.art = art
        textureCache = [:]
        leafTextures = art.leaves.map(Self.texture)
        for (p, band) in bands {
            band.texture = cachedTexture("front", slices[p]!) { art.front($0) }
        }
    }

    func isGrass(_ p: TilePoint) -> Bool { !isConcealed && map.tile(at: p) == .tallGrass }

    func bandZ(at p: TilePoint) -> CGFloat? { bands[p]?.zPosition }

    func bandOffset(at p: TilePoint) -> CGPoint? {
        guard let band = bands[p] else { return nil }
        let base = basePosition(p)
        return CGPoint(x: band.position.x - base.x, y: band.position.y - base.y)
    }

    func overlayOffset(at p: TilePoint) -> CGPoint? {
        guard let r = running.first(where: { $0.tile == p }),
              let o = PlazaTallGrass.offset(r.kind, strong: r.strong, elapsed: r.elapsed) else { return nil }
        return CGPoint(x: CGFloat(o.dx) * Self.scale, y: -CGFloat(o.dy) * Self.scale)
    }

    /// 기념사진에 찍을 띠. `visible`은 월드(y 아래로)이고, 겹치는 칸의 지금 띠를 변위까지 담아 돌려준다. 가려져 있으면 비어 있다.
    func photoBands(in visible: CGRect) -> [PlazaPhotoBand] {
        guard !isConcealed else { return [] }
        let tile = CGFloat(PlazaMap.tileSize)
        var result: [PlazaPhotoBand] = []
        for (p, node) in bands {
            let origin = CGPoint(x: node.position.x, y: worldHeight - node.position.y - tile)
            guard CGRect(origin: origin, size: CGSize(width: tile, height: tile)).intersects(visible) else { continue }
            result.append(PlazaPhotoBand(image: art.front(slices[p]!), origin: origin, size: CGSize(width: tile, height: tile),
                                         sortY: CGFloat(p.y) * tile + 31))
        }
        return result
    }

    func rustle(_ cue: PlazaRustleCue) {
        guard isGrass(cue.tile) else { return }
        if cue.delay > 0 { pending.append((cue, cue.delay)) } else { start(cue, elapsed: 0) }
    }

    func update(dt: TimeInterval) {
        guard !isConcealed else { return }
        var alive: [Running] = []
        for var r in running {
            r.elapsed += dt
            if apply(r) { alive.append(r) } else { finish(r) }
        }
        running = alive
        // 대기 신호는 시간이 차면 시작하고, 넘친 만큼은 이미 흐른 것으로 본다.
        var waiting: [(cue: PlazaRustleCue, wait: TimeInterval)] = []
        for var p in pending {
            p.wait -= dt
            if p.wait <= 0 { start(p.cue, elapsed: -p.wait) } else { waiting.append(p) }
        }
        pending = waiting
        var flying: [Leaf] = []
        for var l in leaves {
            l.age += dt
            if l.age < PlazaTallGrass.leafLife { place(l); flying.append(l) } else { recycleLeaf(l.node) }
        }
        leaves = flying
    }

    func setHidden(_ hidden: Bool) {
        isConcealed = hidden
        if hidden {
            for r in running { finish(r) }
            running = []
            pending = []
            for l in leaves { recycleLeaf(l.node) }
            leaves = []
        }
        for band in bands.values { band.isHidden = hidden }
    }

    // MARK: - 내부

    private func basePosition(_ p: TilePoint) -> CGPoint {
        let tile = CGFloat(PlazaMap.tileSize)
        return CGPoint(x: CGFloat(p.x) * tile, y: worldHeight - CGFloat(p.y + 1) * tile)
    }

    /// 같은 칸에서 돌던 것은 바꾸고, 상한을 넘으면 가장 오래된 것을 끝낸다.
    private func start(_ cue: PlazaRustleCue, elapsed: TimeInterval) {
        if let i = running.firstIndex(where: { $0.tile == cue.tile }) {
            finish(running[i])
            running.remove(at: i)
        }
        while running.count >= Self.maxRustles {
            finish(running[0])
            running.remove(at: 0)
        }
        let node = overlayPool.popLast() ?? {
            let n = PlazaSprite()
            n.anchorPoint = .zero
            n.size = CGSize(width: PlazaMap.tileSize, height: PlazaMap.tileSize)
            n.zPosition = Self.overlayZ
            root.addChild(n)
            return n
        }()
        let slice = slices[cue.tile]!
        switch cue.kind {
        case .sway: node.texture = cachedTexture("top", slice) { art.top($0) }
        case .bounce: node.texture = cachedTexture("tile", slice) { art.tile($0) }
        }
        let r = Running(tile: cue.tile, kind: cue.kind, strong: cue.strong, elapsed: elapsed, node: node)
        if apply(r) { running.append(r) } else { finish(r) }
        if cue.strong { spawnLeaves(cue) }
    }

    /// 겹침 그림과 (들썩일 때) 띠를 현재 변위에 둔다. 끝났으면 false.
    private func apply(_ r: Running) -> Bool {
        guard let o = PlazaTallGrass.offset(r.kind, strong: r.strong, elapsed: r.elapsed) else { return false }
        let base = basePosition(r.tile)
        let moved = CGPoint(x: base.x + CGFloat(o.dx) * Self.scale, y: base.y - CGFloat(o.dy) * Self.scale)
        r.node.position = moved
        r.node.isHidden = false
        if r.kind == .bounce { bands[r.tile]?.position = moved }
        return true
    }

    private func finish(_ r: Running) {
        r.node.isHidden = true
        overlayPool.append(r.node)
        bands[r.tile]?.position = basePosition(r.tile)
    }

    private func cachedTexture(_ kind: String, _ s: PlazaTallGrassSlice, _ make: (PlazaTallGrassSlice) -> PlazaImage) -> PlazaTexture {
        let key = "\(kind)-\(s.col)-\(s.row)"
        if let t = textureCache[key] { return t }
        let t = Self.texture(make(s))
        textureCache[key] = t
        return t
    }

    private func spawnLeaves(_ cue: PlazaRustleCue) {
        let tile = CGFloat(PlazaMap.tileSize)
        let start = CGPoint(x: (CGFloat(cue.tile.x) + 0.5) * tile, y: (CGFloat(cue.tile.y) + 0.3) * tile)
        var bias: CGFloat = 0
        if case .sway(let dir) = cue.kind { bias = 12 * CGFloat(dir) }
        for i in 0..<PlazaTallGrass.leavesPerRustle where leaves.count < Self.maxLeaves {
            let node = leafPool.popLast() ?? {
                let n = PlazaSprite()
                n.size = CGSize(width: Self.leafSize, height: Self.leafSize)
                n.zPosition = Self.leafZ
                root.addChild(n)
                return n
            }()
            node.texture = leafTextures[(leafSpawned + i) % leafTextures.count]
            let leaf = Leaf(start: start, vx: Self.leafVX[i % Self.leafVX.count] + bias,
                            vy: Self.leafVY[i % Self.leafVY.count], age: 0, node: node)
            place(leaf)
            node.isHidden = false
            leaves.append(leaf)
        }
        leafSpawned += PlazaTallGrass.leavesPerRustle
    }

    private func place(_ l: Leaf) {
        let k = CGFloat(l.age / PlazaTallGrass.leafLife)
        let x = l.start.x + l.vx * k
        let y = l.start.y + l.vy * k + Self.leafGravity * k * k   // 월드 y(아래로)
        let g = Self.leafGrid
        l.node.position = CGPoint(x: (x / g).rounded() * g, y: ((worldHeight - y) / g).rounded() * g)
    }

    private func recycleLeaf(_ node: PlazaSprite) {
        node.isHidden = true
        leafPool.append(node)
    }

    private static func texture(_ image: PlazaImage) -> PlazaTexture {
        PlazaTexture(image)
    }
}
