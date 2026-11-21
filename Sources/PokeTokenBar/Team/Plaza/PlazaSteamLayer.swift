import Foundation

/// 온천 위의 김을 그리는 노드. 스프라이트 여덟 장을 장면을 만들 때 한 번 만들고 다시는 만들지 않는다.
/// 시간은 `update(dt:)` 로만 흐르고(타이머 없음), 온천(과 한 칸 둘레)이 보이는 영역 밖이거나 배경을 숨기면
/// 아무것도 움직이지도, 어떤 노드 속성도 쓰지도 않는다.
@MainActor final class PlazaSteamLayer {
    let root = PlazaNode()
    private var field: PlazaSteamField
    private let frames: [PlazaImage]
    private let textures: [PlazaTexture]
    private let sprites: [PlazaSprite]
    private let worldHeight: CGFloat
    /// 온천 칸들의 바깥 상자에 `cullMargin` 을 두르고 위쪽에 `rise` 를 더한 영역(월드 픽셀, y 아래로).
    private let cullBounds: CGRect

    init(springTiles: [TilePoint], worldHeight: CGFloat, frames: [PlazaImage]) {
        field = PlazaSteamField(tiles: springTiles)
        self.frames = frames
        self.worldHeight = worldHeight
        textures = frames.map { PlazaTexture($0) }
        let size = CGFloat(PlazaMap.tileSize)
        let xs = springTiles.map { CGFloat($0.x) * size }, ys = springTiles.map { CGFloat($0.y) * size }
        if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
            cullBounds = CGRect(x: x0, y: y0, width: x1 + size - x0, height: y1 + size - y0)
                .insetBy(dx: -PlazaSteam.cullMargin, dy: -PlazaSteam.cullMargin)
                .adding(top: PlazaSteam.rise)   // 줄기는 수명 동안 `rise` 만큼 위로 올라가므로 끝이 그만큼 더 위까지 닿는다
        } else {
            cullBounds = .null
        }
        root.zPosition = PlazaSteam.z
        root.isHidden = true
        let side = CGFloat(frames.first.map { $0.width } ?? 0) * PlazaSteam.scale
        sprites = (0..<PlazaSteam.maxWisps).map { _ in
            let node = PlazaSprite(texture: nil, size: CGSize(width: side, height: side))
            node.isHidden = true
            return node
        }
        for node in sprites { root.addChild(node) }
    }

    /// `visible` 은 보이는 영역(월드 좌표, y 아래로), `step` 은 기기 픽셀 하나의 월드 크기.
    func update(dt: TimeInterval, visible: CGRect, isHidden: Bool, step: CGFloat) {
        guard !isHidden, !textures.isEmpty, Self.overlaps(visible, cullBounds) else {
            if !root.isHidden { root.isHidden = true }
            return
        }
        if root.isHidden { root.isHidden = false }
        field.advance(by: dt)
        let wisps = field.wisps
        for (i, node) in sprites.enumerated() {
            guard i < wisps.count else {
                if !node.isHidden { node.isHidden = true }
                continue
            }
            let w = wisps[i]
            let texture = textures[PlazaSteamField.frame(age: w.age)]
            if node.texture !== texture { node.texture = texture }
            node.alpha = PlazaSteamField.alpha(age: w.age)
            node.position = CGPoint(x: Self.snap(w.x, step), y: Self.snap(worldHeight - w.y + PlazaSteamField.lift(age: w.age), step))
            if node.isHidden { node.isHidden = false }
        }
    }

    /// 닿기만 하는 변은 겹침이 아니다(CGRect.intersects 의 플랫폼 차이를 피한다).
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        !b.isNull && a.maxX > b.minX && a.minX < b.maxX && a.maxY > b.minY && a.minY < b.maxY
    }

    private static func snap(_ v: CGFloat, _ step: CGFloat) -> CGFloat { (v / step).rounded() * step }

    /// 기념사진에 찍을 김: 지금 보이는 줄기를 월드 좌표(y 아래로)와 자기 투명도로. 숨었으면 비어 있다.
    func photoParticles(worldHeight: CGFloat) -> [PlazaPhotoParticle] {
        guard !root.isHidden else { return [] }
        return zip(sprites, field.wisps).map { node, wisp in
            PlazaPhotoParticle(image: frames[PlazaSteamField.frame(age: wisp.age)],
                               origin: CGPoint(x: node.position.x - node.size.width / 2,
                                               y: worldHeight - node.position.y - node.size.height / 2),
                               size: node.size, alpha: node.alpha)
        }
    }

    // MARK: 테스트용

    var isShown: Bool { !root.isHidden }
    var wisps: [PlazaSteamWisp] { field.wisps }
    /// 뿌리와 스프라이트. 만든 뒤 늘지 않아야 한다.
    var nodeCount: Int { 1 + root.children.count }
    var shownSpriteCount: Int { sprites.filter { !$0.isHidden }.count }
    var shownSpriteAlphas: [CGFloat] { sprites.filter { !$0.isHidden }.map(\.alpha) }
    struct SpriteState: Equatable { let x: CGFloat, y: CGFloat, alpha: CGFloat, hidden: Bool, texture: ObjectIdentifier? }
    var spriteStates: [SpriteState] {
        sprites.map { SpriteState(x: $0.position.x, y: $0.position.y, alpha: $0.alpha, hidden: $0.isHidden, texture: $0.texture.map(ObjectIdentifier.init)) }
    }
}

private extension CGRect {
    /// y 가 아래로 늘어나는 좌표에서 위쪽(작은 y)으로 `top` 만큼 늘린 사각형.
    func adding(top: CGFloat) -> CGRect { CGRect(x: minX, y: minY - top, width: width, height: height + top) }
}
