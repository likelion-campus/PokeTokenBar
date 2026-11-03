import SpriteKit

/// `PlazaActor.place`가 위치를 계산하는 데 필요한 장면 쪽 값.
struct PlazaActorContext {
    /// 월드 높이(월드 y를 장면 y로 바꿀 때 쓴다).
    let worldHeight: CGFloat
    /// 장면 좌표의 카메라 위치.
    let cameraPosition: CGPoint
    let zoom: Int
    /// 포인트당 기기 픽셀 수.
    let backing: CGFloat
    /// 뷰(카메라 공간) 크기.
    let viewport: CGSize
}

/// 광장에 서는 캐릭터 하나: 그림, 발밑 그림자, 머리 위 이름표, 프레임 순환, 텍스처 캐시.
/// 그림과 그림자는 월드에, 이름표는 카메라 자식이라 배율과 무관하게 또렷하다.
@MainActor final class PlazaActor {
    /// GIF는 지연 0 또는 0.01초가 흔하다.
    private static let minFrameDelay: TimeInterval = 0.02
    /// 캐릭터 그림을 월드 단위로 키우는 배율. 발 위치(아래 가운데)는 그대로이고 이름·그림자는 키운 크기에 맞춘다.
    static let characterScale: CGFloat = 1.5

    private let characterNode = SKSpriteNode()
    private let plateNode = SKSpriteNode()
    private let shadowNode = SKSpriteNode()
    /// 알일 때 알 앞에 얹는 둥지 앞 테두리. 알이 둥지 안에 앉아 보이게 한다.
    private let nestFrontNode = SKSpriteNode()
    private var nestFrontImage: CGImage?
    /// 말풍선은 이름표처럼 카메라 공간에 둔다.
    private let emoteNode = SKSpriteNode()
    /// 그림자 텍스처는 크기가 바뀔 때만 다시 만든다.
    private var shadowTextureSize: (width: Int, height: Int)?
    /// 발밑 그림: 그림자나 알의 둥지. 기념사진도 같은 그림을 쓴다.
    private var shadowImage: CGImage?
    private var shadowIsNest = false
    /// 이름판은 닉네임이나 배율이 바뀔 때만 다시 만든다.
    private var plateKey: (nickname: String, backing: CGFloat, color: CGColor)?
    /// 말풍선을 보여 주는 시간.
    static let emoteDuration: TimeInterval = 2.5
    private var emoteKey: (kind: TeamEmoteKind, backing: CGFloat, large: Bool)?
    private var emoteRemaining: TimeInterval = 0
    private(set) var emoteKind: TeamEmoteKind?
    /// 인사하기 말풍선이라 1.5배로 그린다.
    private(set) var emoteIsLarge = false
    /// 글 말풍선을 보여 주는 시간. 읽어야 하므로 이모트보다 길다. 이모트와 같은 자리를 쓰고 나중 것이 이긴다.
    static let chatDuration: TimeInterval = 6
    private var chatKey: (text: String, backing: CGFloat)?
    private(set) var chatText: String?
    private var name: String
    private var nameColor: CGColor

    /// 점프: 그림과 이름표가 위로 폴짝 뛰었다 내려온다. 그림자는 땅에 남는다.
    static let jumpDuration: TimeInterval = 0.36
    /// 가장 높이 떴을 때의 월드 픽셀.
    static let jumpHeight: CGFloat = 14
    private var jumpElapsed: TimeInterval?

    /// 몸통박치기: 상대 쪽으로 잠깐 뛰어들었다 돌아온다.
    static let lungeDuration: TimeInterval = 0.24
    /// 가장 멀리 나갔을 때의 월드 픽셀.
    static let lungeDistance: CGFloat = 8
    private var lunge: (direction: PlazaDirection, elapsed: TimeInterval)?

    private var frames: PlazaCharacterFrames?
    private var showingBack = false
    private var frameIndex = 0
    private var frameElapsed: TimeInterval = 0
    private var textureCache: [ObjectIdentifier: SKTexture] = [:]

    init(name: String, color: CGColor) {
        self.name = name
        self.nameColor = color
        shadowNode.anchorPoint = .zero
        shadowNode.zPosition = 0.5
        shadowNode.isHidden = true
        nestFrontNode.anchorPoint = .zero
        nestFrontNode.isHidden = true
        characterNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        characterNode.zPosition = 1
        characterNode.isHidden = true
        plateNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        plateNode.zPosition = 10
        emoteNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        emoteNode.zPosition = 11
        emoteNode.isHidden = true
    }

    func attach(world: SKNode, camera: SKCameraNode) {
        world.addChild(shadowNode)
        world.addChild(characterNode)
        world.addChild(nestFrontNode)
        camera.addChild(plateNode)
        camera.addChild(emoteNode)
    }

    func detach() {
        shadowNode.removeFromParent()
        characterNode.removeFromParent()
        nestFrontNode.removeFromParent()
        plateNode.removeFromParent()
        emoteNode.removeFromParent()
    }

    /// 새 말풍선이 옛것을 바꾸고 시간을 처음부터 다시 잰다. 그림은 `place`에서 그린다.
    func showEmote(_ kind: TeamEmoteKind, large: Bool = false) {
        chatText = nil
        chatKey = nil
        emoteKind = kind
        emoteIsLarge = large
        emoteRemaining = Self.emoteDuration
        emoteNode.isHidden = false
    }

    func showChat(_ text: String) {
        emoteKind = nil
        emoteKey = nil
        chatText = text
        emoteRemaining = Self.chatDuration
        emoteNode.isHidden = false
    }

    func setFrames(_ f: PlazaCharacterFrames) {
        frames = f
        textureCache.removeAll()
        frameIndex = 0
        frameElapsed = 0
        characterNode.isHidden = false
        shadowNode.isHidden = false
        refreshShadow()
        applyFrame()
    }

    func setName(_ name: String, color: CGColor) {
        self.name = name
        self.nameColor = color
    }

    func lunge(toward d: PlazaDirection) {
        lunge = (d, 0)
    }

    func jump() {
        jumpElapsed = 0
    }

    /// 지금 떠 있는 높이(월드 픽셀). 땅에 있으면 0.
    var jumpLift: CGFloat {
        guard let jumpElapsed else { return 0 }
        return (sin(.pi * min(jumpElapsed / Self.jumpDuration, 1)) * Self.jumpHeight).rounded()
    }

    /// 지금 뛰어든 만큼(월드 픽셀, y가 아래로). 뛰어들지 않았으면 0.
    var lungeOffset: CGPoint {
        guard let lunge else { return .zero }
        let amount = (sin(.pi * min(lunge.elapsed / Self.lungeDuration, 1)) * Self.lungeDistance).rounded()
        switch lunge.direction {
        case .right: return CGPoint(x: amount, y: 0)
        case .left: return CGPoint(x: -amount, y: 0)
        case .down: return CGPoint(x: 0, y: amount)
        case .up: return CGPoint(x: 0, y: -amount)
        }
    }

    func animate(by dt: TimeInterval, useBack: Bool) {
        if var l = lunge {
            l.elapsed += dt
            lunge = l.elapsed >= Self.lungeDuration ? nil : l
        }
        if let e = jumpElapsed {
            jumpElapsed = e + dt >= Self.jumpDuration ? nil : e + dt
        }
        if emoteKind != nil || chatText != nil {
            emoteRemaining -= dt
            if emoteRemaining <= 0 { hideEmote() }
        }
        if useBack != showingBack {
            showingBack = useBack
            frameIndex = 0
            frameElapsed = 0
        }
        guard let list = currentFrames, !list.isEmpty else { return }
        frameElapsed += dt
        var guardCount = 0
        while guardCount < list.count {
            let delay = max(list[frameIndex % list.count].delay, Self.minFrameDelay)
            guard frameElapsed >= delay else { break }
            frameElapsed -= delay
            frameIndex = (frameIndex + 1) % list.count
            guardCount += 1
        }
        applyFrame()
    }

    /// 그림, 그림자, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다. `foot`은 월드 좌표(y가 아래로)다.
    func place(foot: CGPoint, pose: PlazaSpriteChoice, in context: PlazaActorContext) {
        let lunge = lungeOffset
        let foot = CGPoint(x: foot.x + lunge.x, y: foot.y + lunge.y)
        let backing = context.backing
        let zoom = context.zoom
        func snap(_ v: CGFloat) -> CGFloat { PlazaPixelSnap.snap(v, backing: backing, zoom: zoom) }

        characterNode.xScale = pose.flipped ? -1 : 1
        characterNode.zPosition = 1 + foot.y / context.worldHeight   // 화면 아래쪽이 앞
        // 그림자는 발보다 조금 위(높이의 0.12)에 가운데를 두어 발 뒤에 깔리게 하고, 아래·왼쪽 모서리를 기기 픽셀에 맞춘다. 통통 튐은 받지 않는다.
        let shadowSize = shadowNode.size
        let shadowCenterY = context.worldHeight - (foot.y - (shadowSize.height * 0.12).rounded())
        shadowNode.position = CGPoint(x: snap(foot.x - shadowSize.width / 2), y: snap(shadowCenterY - shadowSize.height / 2))
        nestFrontNode.position = shadowNode.position
        // 내 알 바로 앞. 더 아래(앞)에 선 캐릭터보다는 뒤다(한 칸 차이가 이 값보다 훨씬 크다).
        nestFrontNode.zPosition = characterNode.zPosition + 0.0001
        let footScene = CGPoint(x: snap(foot.x), y: snap(context.worldHeight - foot.y + CGFloat(pose.bob) + jumpLift))
        characterNode.position = CGPoint(x: PlazaPixelSnap.centerX(footX: foot.x, width: characterNode.size.width, backing: backing, zoom: zoom),
                                         y: footScene.y)

        // 이름표는 카메라 공간(화면 포인트)에 둔다.
        let top = footScene.y + characterNode.size.height
        let labelBacking = max(backing, 1)
        refreshPlate(backing: labelBacking)
        plateNode.position = PlazaPixelSnap.platePosition(footSceneX: footScene.x, topY: top, cameraPos: context.cameraPosition,
                                                          plateWidth: plateNode.size.width, viewport: context.viewport,
                                                          backing: labelBacking, zoom: zoom)
        placeEmote(backing: labelBacking, viewport: context.viewport)
    }

    /// 기념사진에 찍을 값. 그림을 아직 못 받았으면 nil이다. 이름표와 말풍선은 화면 배율과 상관없이 배율 2로 새로 만든다.
    func photoActor(foot: CGPoint, pose: PlazaSpriteChoice) -> PlazaPhotoActor? {
        guard let list = currentFrames, !list.isEmpty else { return nil }
        let image = list[frameIndex % list.count].image
        var shadow: CGImage?
        var shadowRect = CGRect.zero
        if let size = shadowTextureSize {
            shadow = shadowImage
            shadowRect = CGRect(x: foot.x - CGFloat(size.width) / 2,
                                y: foot.y - (CGFloat(size.height) * 0.12).rounded() - CGFloat(size.height) / 2,
                                width: CGFloat(size.width), height: CGFloat(size.height))
        }
        return PlazaPhotoActor(image: image, flipped: pose.flipped, foot: foot, bob: CGFloat(pose.bob),
                               scale: Self.characterScale, shadow: shadow, shadowRect: shadowRect,
                               front: shadowIsNest ? nestFrontImage : nil,
                               plate: name.isEmpty ? nil : PlazaNamePlate.image(text: name, color: nameColor, scale: 2),
                               bubble: chatText.flatMap { PlazaChatBubble.image(text: $0, scale: 2) }
                                   ?? emoteKind.map { PlazaEmoteArt.image($0, scale: 2, large: emoteIsLarge) })
    }

    // MARK: - 값 읽기

    /// 배율을 적용한 앞모습 높이의 절반. 카메라가 큰 포켓몬의 머리를 자르지 않게 올려 보는 양이다(앞모습 기준).
    var cameraLift: CGFloat { frames?.front.first.map { Self.scaledSize(of: $0.image).height / 2 } ?? 0 }
    var groundShadowSize: (width: Int, height: Int) { shadowTextureSize ?? (0, 0) }
    var isOnNest: Bool { shadowIsNest }
    /// 둥지 앞 테두리가 보이고 내 그림보다 앞에 있는지(테스트용).
    var nestFrontIsInFront: Bool { !nestFrontNode.isHidden && nestFrontNode.zPosition > characterNode.zPosition }
    var groundShadowY: CGFloat { shadowNode.position.y }
    var characterX: CGFloat { characterNode.position.x }
    var characterY: CGFloat { characterNode.position.y }
    var characterZ: CGFloat { characterNode.zPosition }
    var characterSize: CGSize { characterNode.size }
    var namePlatePosition: CGPoint { plateNode.position }
    var namePlateWidth: CGFloat { plateNode.size.width }
    var namePlateTop: CGFloat { plateNode.position.y + plateNode.size.height }
    /// 보이는 말풍선의 카메라 공간 사각형(아래 가운데 기준). 없으면 nil.
    var emoteFrame: CGRect? {
        guard emoteKind != nil || chatText != nil, !emoteNode.isHidden else { return nil }
        return CGRect(x: emoteNode.position.x - emoteNode.size.width / 2, y: emoteNode.position.y,
                      width: emoteNode.size.width, height: emoteNode.size.height)
    }
    /// 닉네임이 비어 있으면 이름판을 숨긴다.
    var isNamePlateVisible: Bool { !plateNode.isHidden }

    // MARK: - 내부

    private func hideEmote() {
        emoteKind = nil
        chatText = nil
        emoteNode.isHidden = true
    }

    /// 이름표 바로 위에 놓는다. 왼쪽·아래 모서리를 기기 픽셀에 맞춘다(홀수 크기 뷰포트는 반 픽셀을 보정한다).
    private func placeEmote(backing: CGFloat, viewport: CGSize) {
        if let text = chatText {
            if chatKey?.text != text || chatKey?.backing != backing {
                chatKey = (text, backing)
                guard let image = PlazaChatBubble.image(text: text, scale: backing) else { return hideEmote() }
                setBubble(image, backing: backing)
            }
        } else if let kind = emoteKind {
            if emoteKey?.kind != kind || emoteKey?.backing != backing || emoteKey?.large != emoteIsLarge {
                emoteKey = (kind, backing, emoteIsLarge)
                setBubble(PlazaEmoteArt.image(kind, scale: backing, large: emoteIsLarge), backing: backing)
            }
        } else {
            return
        }
        func snapView(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }
        let halfW = viewport.width / 2, halfH = viewport.height / 2
        var origin = CGPoint(x: snapView(plateNode.position.x - emoteNode.size.width / 2 + halfW) - halfW,
                             y: snapView(namePlateTop + halfH) - halfH)
        if chatText != nil {
            origin = Self.chatBubbleOrigin(origin, size: emoteNode.size, plate: plateNode.position, viewport: viewport)
        }
        emoteNode.position = CGPoint(x: origin.x + emoteNode.size.width / 2, y: origin.y)
    }

    /// 글 말풍선은 넓어서 화면 가장자리에서 잘리지 않게 안쪽으로 민다. 이름표가 화면 밖이면 누구 말인지 알 수 없으므로 같이 밖에 둔다.
    /// 좌표는 카메라 공간(가운데가 원점)이고 `origin`은 왼쪽 아래 모서리다.
    static func chatBubbleOrigin(_ origin: CGPoint, size: CGSize, plate: CGPoint, viewport: CGSize) -> CGPoint {
        let halfW = viewport.width / 2, halfH = viewport.height / 2
        guard abs(plate.x) <= halfW, abs(plate.y) <= halfH else { return origin }
        let margin: CGFloat = 4
        return CGPoint(x: min(max(origin.x, -halfW + margin), halfW - size.width - margin),
                       y: min(origin.y, halfH - size.height - margin))
    }

    private func setBubble(_ image: CGImage, backing: CGFloat) {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        emoteNode.texture = texture
        emoteNode.size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
    }

    private var currentFrames: [PlazaFrame]? {
        guard let frames else { return nil }
        return showingBack ? frames.back : frames.front
    }

    /// 배율을 적용한 그림 크기. 정확한 배율을 쓰고(반올림하면 홀수 크기에서 도트가 일그러진다) 위치만 기기 픽셀에 맞춘다.
    private static func scaledSize(of image: CGImage) -> CGSize {
        CGSize(width: CGFloat(image.width) * characterScale, height: CGFloat(image.height) * characterScale)
    }

    private func applyFrame() {
        guard let list = currentFrames, !list.isEmpty else { return }
        let image = list[frameIndex % list.count].image
        let texture: SKTexture
        if let cached = textureCache[ObjectIdentifier(image)] {
            texture = cached
        } else {
            texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            textureCache[ObjectIdentifier(image)] = texture
        }
        characterNode.texture = texture
        characterNode.size = Self.scaledSize(of: image)
    }

    private func refreshShadow() {
        guard let frames, let first = frames.front.first else { return }
        let size = frames.isEgg ? PlazaNestArt.size
            : PlazaGroundShadow.size(forSpriteWidth: Int(Self.scaledSize(of: first.image).width.rounded()))
        if let old = shadowTextureSize, old == size, shadowIsNest == frames.isEgg { return }
        shadowTextureSize = size
        shadowIsNest = frames.isEgg
        let image = frames.isEgg ? PlazaNestArt.image() : PlazaGroundShadow.image(width: size.width, height: size.height)
        shadowImage = image
        nestFrontImage = frames.isEgg ? PlazaNestArt.frontImage() : nil
        nestFrontNode.isHidden = !frames.isEgg
        if let front = nestFrontImage {
            let texture = SKTexture(cgImage: front)
            texture.filteringMode = .nearest
            nestFrontNode.texture = texture
            nestFrontNode.size = CGSize(width: size.width, height: size.height)
        }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        shadowNode.texture = texture
        shadowNode.size = CGSize(width: size.width, height: size.height)
    }

    private func refreshPlate(backing: CGFloat) {
        plateNode.isHidden = name.isEmpty
        if name.isEmpty { return }
        if let key = plateKey, key.nickname == name, key.backing == backing, key.color == nameColor { return }
        plateKey = (name, backing, nameColor)
        guard let image = PlazaNamePlate.image(text: name, color: nameColor, scale: backing) else {
            // The next frame un-hides the node before the key check, so nothing of the old name may remain.
            plateNode.isHidden = true
            plateNode.texture = nil
            plateNode.size = .zero
            return
        }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        plateNode.texture = texture
        plateNode.size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
    }
}
