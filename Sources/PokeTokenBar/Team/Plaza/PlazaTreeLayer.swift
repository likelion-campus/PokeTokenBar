import Foundation

/// 큰 나무의 노드. 이 작업(Task 4)은 가만히 서 있는 나무: 뿌리 둘과 네 띠. 타격 풀은 Task 6이 더한다.
/// 시간은 `update(dt:)` 로만 흐른다(타이머 없음). 장면을 만들 때 모든 노드를 만들고 그 뒤로 노드를 더하지 않는다.
///
/// `root` 는 줄기 밑(그림의 가운데 아래)에 놓인다. 위 세로 늘이기가 줄기 밑을 축으로 하고, 띠와 낙엽·먼지 위치가
/// 줄기 밑 기준이 되게 하려는 것이다. 띠는 위에서부터 `PlazaTree.bandRows` 의 네 장이다.
@MainActor final class PlazaTreeLayer {
    /// 나무 본체(띠·낙엽·먼지). 깊이는 모닥불과 같은 식(`PlazaTree.z`). 배경을 숨기면 같이 숨는다.
    let root = PlazaNode()
    /// 타격 효과(별, 떨어지는 아이템). 배경을 숨겨도 그린다. 이름표(10) 아래, 낮밤 곱하기(5) 위.
    let fxRoot = PlazaNode()

    private let artRect: CGRect
    private let worldHeight: CGFloat
    /// 계절마다 네 띠의 그림과 그 텍스처. 장면을 만들 때 한 번에 만든다(나중에 만드는 것이 없다).
    private let bandArt: [PlazaSeason: [PlazaImage]]
    private let textures: [PlazaSeason: [PlazaTexture]]
    private let bands: [PlazaSprite]
    private(set) var season = PlazaSeason.summer

    /// `images` 는 네 계절 모두의 소나무 한 장씩(장면이 네 장이 모두 있을 때만 이 층을 만든다).
    init(map: PlazaMap, images: [PlazaSeason: PlazaImage], worldHeight: CGFloat) {
        precondition(PlazaSeason.allCases.allSatisfy { images[$0] != nil }, "the tree layer needs the pine of every season")
        precondition(!PlazaTree.tiles(in: map).isEmpty, "the tree layer needs a map with a tree")
        let rect = PlazaTree.artRect(in: map)!
        artRect = rect
        bandArt = images.mapValues { PlazaTree.bands($0) }
        textures = bandArt.mapValues { $0.map { PlazaTexture($0) } }
        self.worldHeight = worldHeight
        root.zPosition = PlazaTree.z(in: map)!
        // 줄기 밑: 그림의 가운데 아래(장면 좌표, y 위로).
        root.position = CGPoint(x: rect.midX, y: worldHeight - rect.maxY)
        fxRoot.zPosition = 20
        let scale = PlazaTree.scale
        let rows = PlazaTree.bandRows
        bands = rows.map { band in
            let node = PlazaSprite(texture: nil, size: CGSize(width: rect.width, height: CGFloat(band.count) * scale))
            node.anchorPoint = .zero
            // 줄기 밑에서 이 띠의 아래 변까지의 높이: (그림 줄 수 − 띠의 끝 줄) 줄.
            node.position = CGPoint(x: -rect.width / 2, y: CGFloat(PlazaResources.treeCrop.height - band.upperBound) * scale)
            return node
        }
        for node in bands { root.addChild(node) }
        apply(.summer)
    }

    /// 계절의 그림으로 바꾼다. 같은 계절이면 아무것도 쓰지 않는다.
    func setSeason(_ s: PlazaSeason) {
        guard s != season else { return }
        season = s
        apply(s)
    }

    func setHidden(_ hidden: Bool) {
        if root.isHidden != hidden { root.isHidden = hidden }
    }

    private func apply(_ s: PlazaSeason) {
        for (node, texture) in zip(bands, textures[s]!) where node.texture !== texture { node.texture = texture }
    }

    /// 기념사진에 찍을 나무: 띠마다 하나. 월드 좌표(y 아래로), 바닥 변은 맨 아래 줄의 아래 끝(모닥불과 같은 규칙).
    func photoProps() -> [PlazaPhotoProp] {
        guard !root.isHidden else { return [] }
        return zip(bandArt[season]!, bandRects()).map { image, rect in
            PlazaPhotoProp(particle: PlazaPhotoParticle(image: image, origin: rect.origin, size: rect.size), baseY: artRect.maxY)
        }
    }

    /// 띠마다 월드 사각형(y 아래로).
    private func bandRects() -> [CGRect] {
        bands.map { node in
            let left = root.position.x + node.position.x
            let bottom = worldHeight - (root.position.y + node.position.y)
            return CGRect(x: left, y: bottom - node.size.height, width: node.size.width, height: node.size.height)
        }
    }

    // MARK: 테스트용

    var isShown: Bool { !root.isHidden }
    /// 두 뿌리와 모든 자손. 만든 뒤 늘지 않아야 한다.
    var nodeCount: Int { 2 + root.children.count + fxRoot.children.count }
    var bandWorldRects: [CGRect] { bandRects() }
    var bandImages: [PlazaImage?] { bands.map { $0.texture?.image } }
}
