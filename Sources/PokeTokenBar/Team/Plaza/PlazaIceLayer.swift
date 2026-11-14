import SpriteKit

/// 언 연못의 얼음, 금, 파편을 그리는 노드. 풀에서 꺼내 쓰는 스프라이트이고, 시간은 장면이 넘겨 주는 `elapsed` 로만 흐른다.
/// 타이머도 `SKAction` 도 없다. 노드는 연못 수 + 가장 큰 연못의 칸 수(금) + 6(파편)을 넘지 않는다.
@MainActor final class PlazaIceLayer: SKNode {
    static let iceZ: CGFloat = 0.02, crackZ: CGFloat = 0.025, shardZ: CGFloat = 0.045

    private let ponds: [PlazaIce.Pond]
    private let art: PlazaIceArt
    private let worldHeight: CGFloat
    private var iceImages: [PlazaImage] = []
    private var iceNodes: [SKSpriteNode] = []
    private var iceAlphas: [CGFloat?]
    private var crackNodes: [SKSpriteNode] = []
    private var shardNodes: [SKSpriteNode] = []
    private let crackTextures: [SKTexture]
    private let shardTextures: [SKTexture]
    private let crackCap: Int
    private var shownCracks: [(tile: TilePoint, cell: Int)] = []
    private var crackAlpha: CGFloat = 0
    private(set) var shownShardCount = 0
    private var isConcealed = false

    init(ponds: [PlazaIce.Pond], art: PlazaIceArt, mapImage: PlazaImage, worldHeight: CGFloat) {
        self.ponds = ponds
        self.art = art
        self.worldHeight = worldHeight
        self.iceAlphas = Array(repeating: nil, count: ponds.count)
        self.crackTextures = art.cracks.map(Self.texture)
        self.shardTextures = art.shards.map(Self.texture)
        self.crackCap = ponds.map(\.tiles.count).max() ?? 0
        super.init()
        for _ in ponds {
            let node = SKSpriteNode()
            node.anchorPoint = .zero
            node.zPosition = Self.iceZ
            node.isHidden = true
            addChild(node)
            iceNodes.append(node)
        }
        setMapImage(mapImage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var nodeCount: Int { children.count }
    var shownCrackCount: Int { shownCracks.count }

    func iceAlpha(pond: Int) -> CGFloat? { iceAlphas.indices.contains(pond) ? iceAlphas[pond] : nil }
    func iceTextureID(pond: Int) -> ObjectIdentifier? {
        iceNodes.indices.contains(pond) ? iceNodes[pond].texture.map(ObjectIdentifier.init) : nil
    }

    /// 지도 그림이 바뀌면(눈 오는 날) 연못마다 얼음 그림을 다시 만든다.
    func setMapImage(_ image: PlazaImage) {
        iceImages = ponds.map { PlazaIceArt.overlay(mapImage: image, pond: $0, gloss: art.gloss) }
        let tile = PlazaMap.tileSize
        for (i, pond) in ponds.enumerated() {
            let node = iceNodes[i]
            node.texture = Self.texture(iceImages[i])
            node.size = CGSize(width: iceImages[i].width, height: iceImages[i].height)
            node.position = CGPoint(x: CGFloat((pond.minX - 1) * tile),
                                    y: worldHeight - CGFloat((pond.minY - 1) * tile) - node.size.height)
        }
    }

    func show(frozen: Int?, alpha: CGFloat, breaking: (pond: Int, hit: TilePoint, elapsed: TimeInterval)?) {
        for i in ponds.indices { iceAlphas[i] = nil }
        if let frozen, ponds.indices.contains(frozen), alpha > 0 { iceAlphas[frozen] = alpha }
        shownCracks = []
        var shards: [(tile: TilePoint, frame: Int)] = []
        if let b = breaking, ponds.indices.contains(b.pond) {
            let fade = PlazaIce.iceAlpha(elapsed: b.elapsed)
            if fade > 0 { iceAlphas[b.pond] = fade }
            let pond = ponds[b.pond]
            if fade > 0, !crackTextures.isEmpty {
                let maxRing = pond.tiles.map { PlazaIce.ring(of: $0, hit: b.hit) }.max() ?? 0
                let reach = Int(b.elapsed / PlazaIce.crackStep(maxRing: maxRing))
                for t in pond.tiles where PlazaIce.ring(of: t, hit: b.hit) <= reach {
                    shownCracks.append((t, PlazaIce.crackCell(at: t)))
                }
                crackAlpha = fade
            }
            if !shardTextures.isEmpty {
                let tiles = PlazaIce.shardTiles(pond: pond, hit: b.hit)
                for k in 0..<PlazaIce.shardBursts {
                    if let f = PlazaIce.shardFrame(burst: k, elapsed: b.elapsed), f < shardTextures.count { shards.append((tiles[k], f)) }
                }
            }
        }
        for (i, node) in iceNodes.enumerated() {
            node.isHidden = iceAlphas[i] == nil
            node.alpha = iceAlphas[i] ?? 0
        }
        placeCracks()
        placeShards(shards)
    }

    func setConcealed(_ hidden: Bool) {
        isConcealed = hidden
        isHidden = hidden
    }

    /// 보이는 얼음과 금(알파 포함). 파편은 찍지 않는다. 가려져 있으면 없다.
    func photoParticles() -> [PlazaPhotoParticle] {
        guard !isConcealed else { return [] }
        let tile = CGFloat(PlazaMap.tileSize)
        var out: [PlazaPhotoParticle] = []
        for (i, pond) in ponds.enumerated() {
            guard let a = iceAlphas[i] else { continue }
            let image = iceImages[i]
            out.append(PlazaPhotoParticle(image: image, origin: CGPoint(x: CGFloat(pond.minX - 1) * tile, y: CGFloat(pond.minY - 1) * tile),
                                          size: CGSize(width: image.width, height: image.height), alpha: a))
        }
        for c in shownCracks {
            out.append(PlazaPhotoParticle(image: art.cracks[c.cell], origin: CGPoint(x: CGFloat(c.tile.x) * tile, y: CGFloat(c.tile.y) * tile),
                                          size: CGSize(width: tile, height: tile), alpha: crackAlpha))
        }
        return out
    }

    // MARK: - 내부

    private func placeCracks() {
        let tile = CGFloat(PlazaMap.tileSize)
        while crackNodes.count < min(shownCracks.count, crackCap) {
            let node = SKSpriteNode()
            node.anchorPoint = .zero
            node.size = CGSize(width: tile, height: tile)
            node.zPosition = Self.crackZ
            addChild(node)
            crackNodes.append(node)
        }
        for (i, node) in crackNodes.enumerated() {
            guard i < shownCracks.count else { node.isHidden = true; continue }
            let c = shownCracks[i]
            node.texture = crackTextures[c.cell]
            node.position = CGPoint(x: CGFloat(c.tile.x) * tile, y: worldHeight - CGFloat(c.tile.y + 1) * tile)
            node.alpha = crackAlpha
            node.isHidden = false
        }
    }

    private func placeShards(_ shards: [(tile: TilePoint, frame: Int)]) {
        let tile = CGFloat(PlazaMap.tileSize)
        while shardNodes.count < shards.count {
            let node = SKSpriteNode()
            node.size = CGSize(width: 64, height: 64)
            node.zPosition = Self.shardZ
            addChild(node)
            shardNodes.append(node)
        }
        for (i, node) in shardNodes.enumerated() {
            guard i < shards.count else { node.isHidden = true; continue }
            let s = shards[i]
            node.texture = shardTextures[s.frame]
            node.position = CGPoint(x: (CGFloat(s.tile.x) + 0.5) * tile, y: worldHeight - (CGFloat(s.tile.y) + 0.5) * tile)
            node.isHidden = false
        }
        shownShardCount = shards.count
    }

    private static func texture(_ image: PlazaImage) -> SKTexture {
        let t = SKTexture(cgImage: image.cgImage)
        t.filteringMode = .nearest
        return t
    }
}
