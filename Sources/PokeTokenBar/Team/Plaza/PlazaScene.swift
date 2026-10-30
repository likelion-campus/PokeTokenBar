import SpriteKit

/// 키 입력 처리 결과. 처리하지 않은 키도 조용히 삼킨다(시스템 경고음 방지).
enum PlazaKeyResult: Equatable { case swallowed, closeRequested }

/// 광장 장면. 월드는 y가 아래로 늘어나고 SpriteKit은 위로 늘어나므로 `sceneY = 월드 높이 - y`로 바꾼다.
/// 지도 한 장, 캐릭터 노드 하나, 카메라, 이름표(카메라 자식이라 배율과 무관하게 또렷하다)로 이루어진다.
@MainActor final class PlazaScene: SKScene {
    /// 한 프레임에 걸을 수 있는 최대 시간. 잠자기 뒤 같은 큰 간격을 막는다.
    private static let maxFrameDelta: TimeInterval = 0.1

    static let characterScale = PlazaActor.characterScale

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
    /// 창 없는 테스트에서 화면 배율을 정한다. 창이 없으면 기본값은 2라 1배 화면 경로를 밟지 못한다.
    var backingOverride: CGFloat?

    private let mapNode: SKSpriteNode
    private let cameraNode = SKCameraNode()
    /// 내 캐릭터.
    private let me: PlazaActor
    private(set) var nameColor = PlazaNameColor.palette[0]
    /// false(알)면 방향키를 삼키고 입력을 지운다. 걷던 칸은 마저 간다.
    var canWalk = true {
        didSet { if !canWalk { walker.clearInput() } }
    }

    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0

    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String) {
        self.map = map
        self.worldSize = map.pixelSize
        self.walker = PlazaWalker(tile: start)
        self.nickname = nickname
        self.me = PlazaActor(name: nickname, color: PlazaNameColor.palette[0])
        self.zoom = PlazaCamera.clampedZoom(zoom)
        let texture = SKTexture(cgImage: mapImage)
        texture.filteringMode = .nearest
        self.mapNode = SKSpriteNode(texture: texture, size: map.pixelSize)
        super.init(size: CGSize(width: 960, height: 640))
        scaleMode = .resizeFill
        anchorPoint = .zero
        // 지도 밖은 타일셋 나무 그림자 톤의 짙은 초록(숲이 이어진 느낌).
        backgroundColor = SKColor(red: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1)

        mapNode.anchorPoint = .zero
        mapNode.position = .zero
        mapNode.zPosition = 0
        addChild(mapNode)

        addChild(cameraNode)
        me.attach(world: self, camera: cameraNode)
        camera = cameraNode
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 외부 조작

    func setCharacter(_ frames: PlazaCharacterFrames) {
        me.setFrames(frames)
        layout()
    }

    func setNickname(_ name: String) {
        nickname = name
        me.setName(name, color: nameColor)
        layout()
    }

    func setNameColor(_ color: CGColor) {
        guard color != nameColor else { return }
        nameColor = color
        me.setName(nickname, color: color)
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
            if canWalk && !isRepeat && !modifiers.contains(.command) { walker.press(d) }
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
        me.animate(by: dt, useBack: pose.useBack)
    }

    /// 카메라, 캐릭터, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다.
    private func layout() {
        let z = CGFloat(zoom)
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2
        func snap(_ v: CGFloat) -> CGFloat { PlazaPixelSnap.snap(v, backing: backing, zoom: zoom) }

        let foot = walker.footPoint
        // 큰 포켓몬의 머리가 잘리지 않게 앞모습 높이의 절반만큼 위를 본다(앞모습 기준이라 돌아봐도 카메라가 흔들리지 않는다).
        let lift = me.cameraLift
        let focus = PlazaCamera.focus(for: foot, rightInset: PlazaRosterMetrics.coveredWidth, zoom: zoom, lift: lift)
        let rect = PlazaCamera.visibleRect(focus: focus, viewport: size, zoom: zoom, backingScale: backing, world: worldSize,
                                        rightInset: PlazaRosterMetrics.coveredWidth)
        let cameraPos = CGPoint(x: rect.midX, y: worldSize.height - rect.midY)   // 원점은 visibleRect가 이미 기기 격자에 맞췄다
        cameraNode.position = cameraPos
        cameraNode.setScale(1 / z)

        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        me.place(foot: foot, pose: pose, in: PlazaActorContext(worldHeight: worldSize.height, cameraPosition: cameraPos,
                                                              zoom: zoom, backing: backing, viewport: size))
    }

    /// 테스트용: 내 캐릭터 값을 그대로 넘긴다.
    var groundShadowSize: (width: Int, height: Int) { me.groundShadowSize }
    var groundShadowY: CGFloat { me.groundShadowY }
    var characterX: CGFloat { me.characterX }
    var characterY: CGFloat { me.characterY }
    var cameraPosition: CGPoint { cameraNode.position }
    var namePlatePosition: CGPoint { me.namePlatePosition }
    var namePlateWidth: CGFloat { me.namePlateWidth }
    var characterSize: CGSize { me.characterSize }
    /// 닉네임이 비어 있으면 이름판을 숨긴다.
    var isNamePlateVisible: Bool { me.isNamePlateVisible }
}
