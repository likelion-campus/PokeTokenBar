import SpriteKit

/// 키 입력 처리 결과. 처리하지 않은 키도 조용히 삼킨다(시스템 경고음 방지).
enum PlazaKeyResult: Equatable { case swallowed, closeRequested }

/// 광장 장면. 월드는 y가 아래로 늘어나고 SpriteKit은 위로 늘어나므로 `sceneY = 월드 높이 - y`로 바꾼다.
/// 지도 한 장, 캐릭터 노드 하나, 카메라, 이름표(카메라 자식이라 배율과 무관하게 또렷하다)로 이루어진다.
@MainActor final class PlazaScene: SKScene {
    /// 한 프레임에 걸을 수 있는 최대 시간. 잠자기 뒤 같은 큰 간격을 막는다.
    private static let maxFrameDelta: TimeInterval = 0.1
    /// GIF는 지연 0 또는 0.01초가 흔하다.
    private static let minFrameDelay: TimeInterval = 0.02

    private let map: PlazaMap
    private let worldSize: CGSize
    private(set) var walker: PlazaWalker
    private(set) var nickname: String

    var zoom: Int {
        didSet {
            let clamped = PlazaCamera.clampedZoom(zoom)
            if clamped != zoom { zoom = clamped; return }
            guard zoom != oldValue else { return }
            layout()
            onZoomChange?(zoom)
        }
    }
    var onZoomChange: ((Int) -> Void)?
    /// Cmd+W, Esc. 앱에 메인 메뉴가 없어 창 닫기를 장면이 직접 요청한다.
    var onCloseRequest: (() -> Void)?
    /// 키 뗌 이벤트는 Command가 눌린 동안 오지 않으므로 update마다 수정 키를 확인한다. 테스트에서 바꿔 끼운다.
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    private let mapNode: SKSpriteNode
    private let characterNode = SKSpriteNode()
    private let cameraNode = SKCameraNode()
    private let plateNode = SKSpriteNode()
    private let shadowNode = SKSpriteNode()
    /// 그림자 텍스처는 크기가 바뀔 때만 다시 만든다.
    private var shadowTextureSize: (width: Int, height: Int)?
    /// 이름판은 닉네임이나 배율이 바뀔 때만 다시 만든다.
    private var plateKey: (nickname: String, backing: CGFloat)?

    private var frames: PlazaCharacterFrames?
    private var showingBack = false
    private var frameIndex = 0
    private var frameElapsed: TimeInterval = 0
    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0
    private var textureCache: [ObjectIdentifier: SKTexture] = [:]

    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String) {
        self.map = map
        self.worldSize = map.pixelSize
        self.walker = PlazaWalker(tile: start)
        self.nickname = nickname
        self.zoom = PlazaCamera.clampedZoom(zoom)
        let texture = SKTexture(cgImage: mapImage)
        texture.filteringMode = .nearest
        self.mapNode = SKSpriteNode(texture: texture, size: map.pixelSize)
        super.init(size: CGSize(width: 960, height: 640))
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .black

        mapNode.anchorPoint = .zero
        mapNode.position = .zero
        mapNode.zPosition = 0
        addChild(mapNode)

        shadowNode.anchorPoint = .zero
        shadowNode.zPosition = 0.5
        shadowNode.isHidden = true
        addChild(shadowNode)

        characterNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        characterNode.zPosition = 1
        characterNode.isHidden = true
        addChild(characterNode)

        plateNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        plateNode.zPosition = 10
        cameraNode.addChild(plateNode)
        addChild(cameraNode)
        camera = cameraNode
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 외부 조작

    func setCharacter(_ frames: PlazaCharacterFrames) {
        self.frames = frames
        textureCache.removeAll()
        frameIndex = 0
        frameElapsed = 0
        characterNode.isHidden = false
        shadowNode.isHidden = false
        refreshShadow()
        applyFrame()
        layout()
    }

    func setNickname(_ name: String) {
        nickname = name
        layout()
    }

    @discardableResult
    func handleKeyDown(keyCode: UInt16, characters: String?, isRepeat: Bool,
                       modifiers: NSEvent.ModifierFlags = []) -> PlazaKeyResult {
        if keyCode == Self.escapeKeyCode || (keyCode == Self.wKeyCode && modifiers.contains(.command)) {
            onCloseRequest?()
            return .closeRequested
        }
        if let d = Self.direction(keyCode) {
            // Command+방향키는 keyUp이 오지 않아 계속 걷게 되므로 무시한다.
            if !isRepeat && !modifiers.contains(.command) { walker.press(d) }
            return .swallowed
        }
        switch characters {
        case "-": zoom -= 1
        case "=", "+": zoom += 1
        default: break
        }
        return .swallowed
    }

    func handleKeyUp(keyCode: UInt16) {
        if let d = Self.direction(keyCode) { walker.release(d) }
    }

    func releaseAllKeys() { walker.releaseAll() }

    private static let escapeKeyCode: UInt16 = 53
    private static let wKeyCode: UInt16 = 13

    private static func direction(_ keyCode: UInt16) -> PlazaDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    // MARK: - 키 이벤트

    /// `super`를 부르면 처리하지 않은 키가 경고음을 내므로 모든 키를 여기서 삼킨다.
    override func keyDown(with event: NSEvent) {
        handleKeyDown(keyCode: event.keyCode, characters: event.characters, isRepeat: event.isARepeat,
                      modifiers: event.modifierFlags)
    }

    override func keyUp(with event: NSEvent) {
        handleKeyUp(keyCode: event.keyCode)
    }

    // MARK: - 그리기

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layout()
    }

    override func update(_ currentTime: TimeInterval) {
        let raw = currentTime - (lastTime ?? currentTime)
        lastTime = currentTime
        let dt = raw.isFinite ? min(max(raw, 0), Self.maxFrameDelta) : 0
        clock = currentTime
        if currentModifiers().contains(.command) { walker.releaseAll() }
        walker.advance(by: dt) { [map] in map.isWalkable($0) }
        advanceAnimation(by: dt)
        layout()
    }

    private func advanceAnimation(by dt: TimeInterval) {
        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        if pose.useBack != showingBack {
            showingBack = pose.useBack
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

    private var currentFrames: [PlazaFrame]? {
        guard let frames else { return nil }
        return showingBack ? frames.back : frames.front
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
        characterNode.size = CGSize(width: image.width, height: image.height)
    }

    /// 카메라, 캐릭터, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다.
    private func layout() {
        let z = CGFloat(zoom)
        let backing = view?.window?.backingScaleFactor ?? 2
        let step = 1 / (z * max(backing, 1))
        func snap(_ v: CGFloat) -> CGFloat { (v / step).rounded() * step }

        let foot = walker.footPoint
        let focus = PlazaCamera.focus(for: foot, rightInset: PlazaRosterMetrics.coveredWidth, zoom: zoom)
        let rect = PlazaCamera.visibleRect(focus: focus, viewport: size, zoom: zoom, backingScale: backing, world: worldSize,
                                        rightInset: PlazaRosterMetrics.coveredWidth)
        let cameraPos = CGPoint(x: snap(rect.midX), y: snap(worldSize.height - rect.midY))
        cameraNode.position = cameraPos
        cameraNode.setScale(1 / z)

        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        characterNode.xScale = pose.flipped ? -1 : 1
        // 그림자는 발보다 조금 아래(높이의 1/4)에 가운데를 두고, 아래·왼쪽 모서리를 기기 픽셀에 맞춘다. 통통 튐은 받지 않는다.
        let shadowSize = shadowNode.size
        let shadowCenterY = worldSize.height - (foot.y + (shadowSize.height * 0.25).rounded())
        shadowNode.position = CGPoint(x: snap(foot.x - shadowSize.width / 2), y: snap(shadowCenterY - shadowSize.height / 2))
        let footScene = CGPoint(x: snap(foot.x), y: snap(worldSize.height - foot.y + CGFloat(pose.bob)))
        characterNode.position = footScene

        // 이름표는 카메라 공간(화면 포인트)에 둔다.
        let top = footScene.y + characterNode.size.height
        let labelBacking = max(backing, 1)
        func snapView(_ v: CGFloat) -> CGFloat { (v * labelBacking).rounded() / labelBacking }
        refreshPlate(backing: labelBacking)
        plateNode.position = CGPoint(x: snapView((footScene.x - cameraPos.x) * z),
                                     y: snapView((top - cameraPos.y) * z + 1))
    }

    /// 테스트용: 그림자 노드의 크기와 아래 모서리 y, 캐릭터 노드의 y.
    var groundShadowSize: (width: Int, height: Int) { shadowTextureSize ?? (0, 0) }
    var groundShadowY: CGFloat { shadowNode.position.y }
    var characterY: CGFloat { characterNode.position.y }

    private func refreshShadow() {
        guard let first = frames?.front.first else { return }
        let size = PlazaGroundShadow.size(forSpriteWidth: first.image.width)
        if let old = shadowTextureSize, old == size { return }
        shadowTextureSize = size
        let texture = SKTexture(cgImage: PlazaGroundShadow.image(width: size.width, height: size.height))
        texture.filteringMode = .nearest
        shadowNode.texture = texture
        shadowNode.size = CGSize(width: size.width, height: size.height)
    }

    /// 닉네임이 비어 있으면 이름판을 숨긴다.
    var isNamePlateVisible: Bool { !plateNode.isHidden }

    private func refreshPlate(backing: CGFloat) {
        plateNode.isHidden = nickname.isEmpty
        if nickname.isEmpty { return }
        if let key = plateKey, key.nickname == nickname, key.backing == backing { return }
        plateKey = (nickname, backing)
        let image = PlazaNamePlate.image(text: nickname, scale: backing)
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        plateNode.texture = texture
        plateNode.size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
    }
}
