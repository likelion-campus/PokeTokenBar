import Foundation

/// 큰 나무의 노드: 뿌리 둘과 스프라이트 스무 장(띠 4, 잎 12, 먼지 2, 별 1, 떨어지는 아이템 1). 장면을 만들 때 모두 만들고 그 뒤로 노드를 더하지 않는다.
/// 시간은 `update(dt:visible:step:)` 로만 흐른다(타이머 없음). 가만히 있을 때는 아무 노드 속성도 쓰지 않고, 화면 밖에서는 시계만 가고 아무것도 쓰지 않는다.
///
/// `root` 는 줄기 밑(그림의 가운데 아래)에 놓인다. 띠와 낙엽·먼지 위치가 줄기 밑 기준이다. 띠는 위에서부터 `PlazaTree.bandRows` 의 네 장이다.
/// 세로 때림의 늘이기·눌림은 `root` 가 아니라 띠마다 줄기 밑을 축으로 건다(낙엽과 먼지가 같이 늘어나 튀지 않게).
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
    /// 띠마다 쉴 때의 왼쪽 x(`root` 기준)와 아래 변 높이.
    private let bandRest: [CGPoint]
    private(set) var season = PlazaSeason.summer

    // 풀: 잎 12, 먼지 2, 별, 떨어지는 아이템. 계절이 정하는 잎 그림은 날씨 격자(`PlazaTree.burstArt`)다.
    private let leafSprites: [PlazaSprite]
    private let dustSprites: [PlazaSprite]
    private let impactSprite: PlazaSprite
    private let itemSprite: PlazaSprite
    private let leafImages: [PlazaWeather.Kind: [PlazaImage]]
    private let leafTextures: [PlazaWeather.Kind: [PlazaTexture]]
    private let itemTextures: [ItemKind: PlazaTexture]
    private let dustTexture: PlazaTexture

    private var leafField: PlazaTreeLeaves
    /// 지금 진행 중인 때림 하나. 새 때림은 이것을 갈아 끼운다(쌓지 않는다).
    private struct Shake {
        var direction: PlazaDirection
        var level: Int
        var elapsed: TimeInterval = 0
        var foot: CGPoint
        var height: CGFloat
        var item: (kind: ItemKind, fall: PlazaTreeItemFall)?
        var burstDone = false
        var landed = false
        var end: TimeInterval {
            let hold = PlazaTree.contactAt + PlazaTree.hitStop[level - 1]
            var e = hold + PlazaTree.swingLength
            e = max(e, PlazaTree.contactAt + PlazaTree.impactGrow + PlazaTree.impactHold + PlazaTree.impactFade)
            e = max(e, hold + PlazaTree.dustLife)
            if item != nil { e = max(e, hold + PlazaTree.itemDelay + PlazaTree.itemFall + PlazaTree.itemBounceDuration) }
            return e
        }
    }
    private var shake: Shake?
    /// 마지막 쓰기가 쉬는 모습이었다(그리지 못한 채 끝난 때림은 다시 화면에 오면 쉬는 모습을 한 번 쓴다).
    private var restWritten = true

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
        let rests = rows.map { CGPoint(x: -rect.width / 2, y: CGFloat(PlazaResources.treeCrop.height - $0.upperBound) * scale) }
        bandRest = rests
        bands = zip(rows, rests).map { band, rest in
            let node = PlazaSprite(texture: nil, size: CGSize(width: rect.width, height: CGFloat(band.count) * scale))
            node.anchorPoint = .zero
            // 줄기 밑에서 이 띠의 아래 변까지의 높이: (그림 줄 수 − 띠의 끝 줄) 줄.
            node.position = rest
            return node
        }
        for node in bands { root.addChild(node) }

        let kinds: [PlazaWeather.Kind] = [.greenLeaves, .leaves, .snow]
        leafImages = Dictionary(uniqueKeysWithValues: kinds.map { ($0, PlazaWeatherArt.images($0)) })
        leafTextures = leafImages.mapValues { $0.map { PlazaTexture($0) } }
        let leafSide = CGFloat(leafImages[.greenLeaves]![0].width) * PlazaTree.leafScale
        leafSprites = (0..<PlazaTree.maxFallingLeaves).map { _ in
            let node = PlazaSprite(texture: nil, size: CGSize(width: leafSide, height: leafSide))
            node.zPosition = 0.0003
            node.isHidden = true
            return node
        }
        for node in leafSprites { root.addChild(node) }
        let dust = PlazaTexture(PlazaEmoteArt.dustImage(scale: 2))
        dustTexture = dust
        dustSprites = (0..<2).map { _ in
            let node = PlazaSprite(texture: dust, size: PlazaEmoteArt.dustSize)
            node.zPosition = 0.0002
            node.isHidden = true
            return node
        }
        for node in dustSprites { root.addChild(node) }
        impactSprite = PlazaSprite(texture: PlazaTexture(PlazaEmoteArt.impactImage(scale: 2)), size: PlazaEmoteArt.impactSize)
        impactSprite.isHidden = true
        itemTextures = Dictionary(uniqueKeysWithValues: ItemKind.allCases.map { ($0, PlazaTexture(PlazaEmoteArt.itemImage($0, scale: 8))) })
        itemSprite = PlazaSprite(texture: nil, size: PlazaEmoteArt.itemSize(.mint))
        itemSprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        itemSprite.isHidden = true
        fxRoot.addChild(impactSprite)
        fxRoot.addChild(itemSprite)
        leafField = PlazaTreeLeaves(spawnPoints: PlazaTree.canopySpawnPoints(images[.summer]!, artRect: rect), baseY: rect.maxY)
        apply(.summer)
    }

    /// 계절의 그림으로 바꾼다. 같은 계절이면 아무것도 쓰지 않는다. 떠 있는 잎은 다음 프레임부터 새 계절의 잎 그림으로 그려진다.
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

    // MARK: 타격

    /// 한 번 때린다. 진행 중이던 때림(흔들림·별·먼지·떨어지는 아이템)은 처음부터 다시 시작하고, 잎은 풀의 빈 자리를 먼저 쓴다.
    /// `tacklerFoot` 는 때린 쪽의 발 자리(월드 픽셀, y 아래로). `level` 은 1...3 으로 맞춘다.
    func hit(direction: PlazaDirection, level: Int, tacklerFoot: CGPoint, tacklerHeight: CGFloat, drop: ItemKind?) {
        let level = min(max(level, 1), PlazaTree.bend.count)
        let item = drop.map { ($0, PlazaTreeItemFall(from: PlazaTree.itemStart(artRect: artRect, tacklerFoot: tacklerFoot), to: tacklerFoot)) }
        shake = Shake(direction: direction, level: level, foot: tacklerFoot, height: tacklerHeight, item: item)
    }

    /// 지금 움직이는 것이 있다(때림 진행 중이거나 잎이 남아 있다).
    var isBusy: Bool { shake != nil || !leafField.leaves.isEmpty }

    /// 시간을 `dt` 흘린다. 움직이는 것도, 쉬는 모습으로 되돌릴 것도 없으면 노드를 하나도 건드리지 않고 돌아온다.
    /// 그림 사각형에서 `PlazaTree.cullMargin` 안에 `visible`(월드 좌표, y 아래로)이 닿지 않으면 시계와 잎만 가고 쓰지 않는다.
    /// 아이템이 땅에 닿는 프레임에 한 번 true.
    func update(dt: TimeInterval, visible: CGRect, step: CGFloat) -> Bool {
        guard isBusy || !restWritten else { return false }
        var landed = false
        let kind = PlazaTree.burstArt(season).kind
        if var sh = shake {
            let from = sh.elapsed
            sh.elapsed += dt
            let hold = PlazaTree.contactAt + PlazaTree.hitStop[sh.level - 1]
            if !sh.burstDone, sh.elapsed >= hold {
                // 잎은 멈춤이 끝나는 순간에 터진다: 그 전까지 옛 잎을 흘리고, 터뜨리고, 남은 만큼 모두 흘린다.
                leafField.advance(by: max(0, hold - from), kind: kind)
                leafField.burst(count: PlazaTree.leaves[sh.level - 1], direction: sh.direction, grids: PlazaTree.burstArt(season).grids)
                leafField.advance(by: sh.elapsed - max(hold, from), kind: kind)
                sh.burstDone = true
            } else {
                leafField.advance(by: dt, kind: kind)
            }
            if let item = sh.item, !sh.landed, sh.elapsed >= hold + PlazaTree.itemDelay + PlazaTree.itemFall {
                sh.landed = true
                landed = true
                _ = item
            }
            shake = sh.elapsed >= sh.end ? nil : sh
        } else {
            leafField.advance(by: dt, kind: kind)
        }
        let near = artRect.insetBy(dx: -PlazaTree.cullMargin, dy: -PlazaTree.cullMargin)
        if visible.maxX > near.minX && visible.minX < near.maxX && visible.maxY > near.minY && visible.minY < near.maxY {
            write(step: step)
            restWritten = !isBusy
        } else {
            restWritten = false
        }
        return landed
    }

    private func snap(_ v: CGFloat, _ step: CGFloat) -> CGFloat { step > 0 ? (v / step).rounded() * step : v }

    /// 지금 시계에 맞는 모습을 쓴다(때림이 없으면 쉬는 모습).
    private func write(step: CGFloat) {
        var bend: CGFloat = 0, direction = PlazaDirection.right
        if let sh = shake {
            bend = PlazaTree.bendAmount(at: sh.elapsed, level: sh.level)
            direction = sh.direction
        }
        // 맞은 쪽으로 +: 오른쪽·위로 때리면 +, 왼쪽·아래로 때리면 −. 가로는 띠를 옆으로 밀고, 세로는 늘이거나 누른다.
        let sign: CGFloat = (direction == .right || direction == .up) ? 1 : -1
        let horizontal = direction == .left || direction == .right
        let offsets = horizontal ? PlazaTree.bandOffsets(bend: sign * bend) : PlazaTree.bandWeights.map { _ in 0 }
        let stretch = horizontal ? 1 : PlazaTree.stretch(bend: sign * bend)
        for (i, node) in bands.enumerated() {
            node.position = CGPoint(x: bandRest[i].x + offsets[i], y: bandRest[i].y * stretch)
            node.yScale = stretch
        }

        let images = leafImages[PlazaTree.burstArt(season).kind]!, textures = leafTextures[PlazaTree.burstArt(season).kind]!
        for (i, node) in leafSprites.enumerated() {
            guard i < leafField.leaves.count else { if !node.isHidden { node.isHidden = true }; continue }
            let leaf = leafField.leaves[i]
            let grid = leaf.image % images.count
            node.texture = textures[grid]
            node.size = CGSize(width: CGFloat(images[grid].width) * PlazaTree.leafScale, height: CGFloat(images[grid].height) * PlazaTree.leafScale)
            node.alpha = PlazaTreeLeaves.alpha(leaf)
            node.position = CGPoint(x: snap(leaf.x, step) - root.position.x, y: artRect.maxY - snap(leaf.y, step))
            if node.isHidden { node.isHidden = false }
        }

        let sh = shake
        // 먼지: 멈춤이 끝나는 순간 뿌리 가장자리 둘에서 일어 퍼진다.
        let dustAge = sh.map { $0.elapsed - (PlazaTree.contactAt + PlazaTree.hitStop[$0.level - 1]) }
        for (i, node) in dustSprites.enumerated() {
            guard let sh, let age = dustAge, age >= 0, age < PlazaTree.dustLife else { if !node.isHidden { node.isHidden = true }; continue }
            let u = CGFloat(age / PlazaTree.dustLife), side: CGFloat = i == 0 ? -1 : 1
            node.xScale = side
            node.alpha = 1 - u
            node.position = CGPoint(x: snap(side * (PlazaTree.dustOffsetX + PlazaTree.dustSpread[sh.level - 1] * u), step),
                                    y: snap(PlazaTree.dustLift * (1 + u), step))
            if node.isHidden { node.isHidden = false }
        }

        // 충격 별: 닿는 순간 터지고 태클의 별처럼 자랐다가 흐려진다.
        if let sh, sh.elapsed >= PlazaTree.contactAt,
           case let age = sh.elapsed - PlazaTree.contactAt, age < PlazaTree.impactGrow + PlazaTree.impactHold + PlazaTree.impactFade {
            let target = PlazaTree.impactScale[sh.level - 1]
            let grow = CGFloat(min(1, age / PlazaTree.impactGrow))
            impactSprite.setScale(0.6 + (target - 0.6) * grow)
            let fade = age - PlazaTree.impactGrow - PlazaTree.impactHold
            impactSprite.alpha = fade <= 0 ? 1 : CGFloat(max(0, 1 - fade / PlazaTree.impactFade))
            let at = PlazaTree.impactPoint(tacklerFoot: sh.foot, direction: sh.direction, height: sh.height)
            impactSprite.position = CGPoint(x: at.x.rounded(), y: (worldHeight - at.y).rounded())
            if impactSprite.isHidden { impactSprite.isHidden = false }
        } else if !impactSprite.isHidden {
            impactSprite.isHidden = true
        }

        // 떨어지는 아이템: 잎 속에서 때린 쪽의 발까지.
        if let sh, let item = sh.item,
           let at = item.fall.position(at: sh.elapsed - (PlazaTree.contactAt + PlazaTree.hitStop[sh.level - 1] + PlazaTree.itemDelay)) {
            let texture = itemTextures[item.kind]!
            if itemSprite.texture !== texture {
                itemSprite.texture = texture
                itemSprite.size = PlazaEmoteArt.itemSize(item.kind)
            }
            itemSprite.position = CGPoint(x: snap(at.x, step), y: snap(worldHeight - at.y, step))
            if itemSprite.isHidden { itemSprite.isHidden = false }
        } else if !itemSprite.isHidden {
            itemSprite.isHidden = true
        }
    }

    /// 기념사진에 찍을 나무: 띠마다 하나(지금 옆으로 민 만큼, 늘이거나 누른 만큼)와 보이는 잎마다 하나. 월드 좌표(y 아래로), 바닥 변은 맨 아래 줄의 아래 끝.
    func photoProps() -> [PlazaPhotoProp] {
        guard !root.isHidden else { return [] }
        var props = zip(bandArt[season]!, bandRects()).map { image, rect in
            PlazaPhotoProp(particle: PlazaPhotoParticle(image: image, origin: rect.origin, size: rect.size), baseY: artRect.maxY)
        }
        let images = leafImages[PlazaTree.burstArt(season).kind]!
        for (node, leaf) in zip(leafSprites, leafField.leaves) where !node.isHidden {
            props.append(PlazaPhotoProp(particle: PlazaPhotoParticle(image: images[leaf.image % images.count],
                                                                    origin: CGPoint(x: node.position.x + root.position.x - node.size.width / 2,
                                                                                    y: artRect.maxY - node.position.y - node.size.height / 2),
                                                                    size: node.size, alpha: node.alpha),
                                        baseY: artRect.maxY))
        }
        return props
    }

    /// 띠마다 월드 사각형(y 아래로).
    private func bandRects() -> [CGRect] {
        bands.map { node in
            let left = root.position.x + node.position.x
            let bottom = worldHeight - (root.position.y + node.position.y)
            let height = node.size.height * node.yScale
            return CGRect(x: left, y: bottom - height, width: node.size.width, height: height)
        }
    }

    // MARK: 테스트용

    var isShown: Bool { !root.isHidden }
    /// 두 뿌리와 모든 자손. 만든 뒤 늘지 않아야 한다.
    var nodeCount: Int { 2 + root.children.count + fxRoot.children.count }
    var bandWorldRects: [CGRect] { bandRects() }
    var bandImages: [PlazaImage?] { bands.map { $0.texture?.image } }
    /// 띠마다 지금 옆으로 민 만큼(월드 픽셀).
    var bandOffsets: [CGFloat] { zip(bands, bandRest).map { $0.position.x - $1.x } }
    /// 지금 세로 배율(1이 쉬는 모습). 띠마다 같다.
    var stretch: CGFloat { bands[0].yScale }
    var shownLeafCount: Int { leafSprites.filter { !$0.isHidden }.count }
    var isImpactShown: Bool { !impactSprite.isHidden }
    /// 떨어지는 아이템의 지금 자리(월드 픽셀, y 아래로). 안 보이면 nil.
    var itemPosition: CGPoint? { itemSprite.isHidden ? nil : CGPoint(x: itemSprite.position.x, y: worldHeight - itemSprite.position.y) }
    struct SpriteState: Equatable { let x: CGFloat, y: CGFloat, alpha: CGFloat, hidden: Bool, texture: ObjectIdentifier?, xScale: CGFloat, yScale: CGFloat, w: CGFloat, h: CGFloat }
    /// 스무 장 전부의 모습. 가만히 있을 때 변하지 않아야 한다.
    var spriteStates: [SpriteState] {
        (bands + leafSprites + dustSprites + [impactSprite, itemSprite]).map {
            SpriteState(x: $0.position.x, y: $0.position.y, alpha: $0.alpha, hidden: $0.isHidden, texture: $0.texture.map(ObjectIdentifier.init),
                        xScale: $0.xScale, yScale: $0.yScale, w: $0.size.width, h: $0.size.height)
        }
    }
}
