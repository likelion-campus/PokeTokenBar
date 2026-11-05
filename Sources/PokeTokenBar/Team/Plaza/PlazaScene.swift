import SpriteKit

/// 키 입력 처리 결과. 처리하지 않은 키도 조용히 삼킨다(시스템 경고음 방지).
enum PlazaKeyResult: Equatable { case swallowed, closeRequested }

/// 장면이 그리는 팀원 한 명의 값. 접속 중이면 받은 칸, 자리 비움이면 쉼터에서 쉰다.
struct PlazaSceneMember: Equatable, Sendable {
    let memberID: String
    let nickname: String
    let isAway: Bool
    let tile: TilePoint?
    let facing: PlazaDirection
    let isWalking: Bool
    /// 한동안 입력이 없다(자리비움). 이름에 zZ를 붙인다. 광장 안이면 자리는 그대로 둔다.
    var isIdle = false
    /// 그 팀원이 고른 이름 색. 없거나 팔레트에 없으면 멤버 ID의 색.
    var nameColor: UInt32?
    /// 달리고 있다. 이 화면에서도 달리는 빠르기로 따라간다.
    var isRunning = false
}

/// 광장 장면. 월드는 y가 아래로 늘어나고 SpriteKit은 위로 늘어나므로 `sceneY = 월드 높이 - y`로 바꾼다.
/// 지도 한 장, 캐릭터 노드 하나, 카메라, 이름표(카메라 자식이라 배율과 무관하게 또렷하다)로 이루어진다.
@MainActor final class PlazaScene: SKScene {
    /// 한 프레임에 걸을 수 있는 최대 시간. 잠자기 뒤 같은 큰 간격을 막는다.
    /// 가장 짧은 칸(달리기)보다 짧아야 한 프레임에 칸이 하나만 바뀐다. 두 칸을 한 번에 가면 그 사이 칸을 팀원에게
    /// 보내지 못해, 팀원 화면에서는 두 칸 떨어진 칸으로 순간 이동한다.
    static let maxFrameDelta: TimeInterval = 0.07

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
    /// 키 1–5. 한글 입력기에서는 문자가 달라지므로 keyCode로만 판정한다.
    var onEmoteKey: ((TeamEmoteKind) -> Void)?
    /// 스페이스. 판이 닫혀 있을 때만 온다.
    var onInteractKey: (() -> Void)?
    /// 키 P(기념사진). keyCode로만 판정한다.
    var onPhotoKey: (() -> Void)?
    /// Z(점프). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onJumpKey: (() -> Void)?
    /// X(인사하기). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onGreetKey: (() -> Void)?
    /// C(몸통박치기). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onTackleKey: (() -> Void)?
    /// G(단체 사진). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onGroupPhotoKey: (() -> Void)?
    /// F(불꽃놀이). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onFireworkKey: (() -> Void)?
    /// Return과 숫자패드 Enter. 판이 닫혀 있을 때만 온다.
    var onChatKey: (() -> Void)?
    /// 판이 열린 동안 판이 쓰는 키(위, 아래, 스페이스, Enter, Esc). 눌러 둔 자동 반복은 넘기지 않는다.
    var onOverlayKey: ((PlazaOverlayKey) -> Void)?
    /// 판이 열리면 방향키와 말풍선 키를 무시하고 눌린 키를 놓는다. Cmd+W는 그대로 창을 닫는다.
    var isOverlayOpen = false {
        didSet { if isOverlayOpen && !oldValue { clearInput() } }
    }
    /// 목록에서 골라 걸어가거나 따라가는 중인 팀원.
    private var autoWalk: String?
    /// 따라가기: 옆에 닿아도 멈추지 않고 계속 붙어 다닌다.
    private var isFollowing = false
    /// 따라가기를 시작하거나 멈췄다. 따라가는 팀원(멈췄으면 nil)을 넘긴다.
    var onFollowChange: ((String?) -> Void)?
    /// 키 뗌 이벤트는 Command가 눌린 동안 오지 않으므로 update마다 수정 키를 확인한다. 테스트에서 바꿔 끼운다.
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// 창 없는 테스트에서 화면 배율을 정한다. 창이 없으면 기본값은 2라 1배 화면 경로를 밟지 못한다.
    var backingOverride: CGFloat?

    private let mapImage: CGImage
    /// 마지막 `layout`이 정한 보이는 월드 영역. 기념사진이 이 영역을 찍는다.
    private var visibleRect: CGRect
    private let mapNode: SKSpriteNode
    private var shutterNode: SKSpriteNode?
    private let cameraNode = SKCameraNode()
    /// 계절 날씨 입자. 캐릭터(z 1~2) 위, 낮밤 곱하기(5)와 이름표(10) 아래.
    private let weatherLayer = PlazaWeatherLayer()
    /// 불꽃. 빛이라 낮밤 곱하기(5)와 모닥불빛(6) 위, 이름표(10) 아래.
    private let fireworkLayer = PlazaFireworkLayer()
    /// 지금 지도에서 아이템이 놓일 수 있는 칸. 지도가 바뀌지 않으니 한 번만 센다.
    private lazy var itemOpenTiles: Set<TilePoint> = PlazaItems.openTiles(in: map)
    /// 누군가 주운 아이템 칸. 창 컨트롤러가 채운다.
    var pickedItemSlots: Set<Int> = []
    /// 지금 광장에 있는 아이템.
    private(set) var shownItem: PlazaItems.Spawn?
    private var itemNode: SKSpriteNode?
    /// 내가 아이템 칸에 섰다. 서 있는 동안 화면마다 다시 부르고, 주운 것으로 칠지는 창 컨트롤러가 정한다.
    var onItemPickup: ((PlazaItems.Spawn) -> Void)?
    /// 아이템이 떨어지거나 사라졌다(작은 지도 갱신용).
    var onItemChange: ((PlazaItems.Spawn?) -> Void)?
    /// 내 캐릭터.
    private let me: PlazaActor
    private(set) var nameColor = PlazaNameColor.palette[0]
    /// false(알)면 방향키를 삼키고 입력을 지운다. 걷던 칸은 마저 간다.
    var canWalk = true {
        didSet { if !canWalk { walker.clearInput() } }
    }

    /// 팀원 한 명의 장면 쪽 상태. 그림은 내 캐릭터와 같은 `PlazaActor`를 쓴다.
    private struct Remote {
        let actor: PlazaActor
        var color: CGColor
        var nickname: String
        var isAway: Bool
        var isIdle = false
        var motion: PlazaRemoteMotion
        var wanderer: PlazaShelterWanderer?
        var grassWatch = GrassWatch()

        /// zZ는 자리비움(입력 없음)일 때만. 광장을 닫고 일하는 팀원은 쉼터에 서 있어도 zZ가 없다.
        var displayName: String { Self.displayName(nickname, isIdle: isIdle) }

        static func displayName(_ nickname: String, isIdle: Bool) -> String {
            isIdle ? nickname + " " + L(.ko).plazaAwaySuffix : nickname
        }

        mutating func advance(by dt: TimeInterval, blocked: Set<TilePoint>) {
            if let moved = wanderer?.advance(by: dt, blocked: blocked) { motion.moveTo(moved) }
            motion.advance(by: dt)
        }
    }

    private var remotes: [String: Remote] = [:]

    /// 풀숲 흔들기 상태 하나(나 또는 팀원 한 명): 지난 걸음과 가만히 가려져 있는 시간.
    @MainActor private struct GrassWatch {
        var lastStep: (from: TilePoint, to: TilePoint)?
        var still: TimeInterval = 0
        var flip = false
        var lastLift: CGFloat = 0

        mutating func advance(tile: TilePoint, step: PlazaStep?, lift: CGFloat, dt: TimeInterval, layer: PlazaTallGrassLayer) {
            if let step {
                if lastStep?.from != step.from || lastStep?.to != step.to {
                    lastStep = (step.from, step.to)
                    for cue in PlazaTallGrass.cues(from: step.from, to: step.to, isGrass: layer.isGrass) { layer.rustle(cue) }
                }
            } else {
                lastStep = nil
            }
            // 점프에서 내려앉은 프레임: 풀숲 칸이면 약하게 들썩인다. 장면 시간(dt)으로만 잰다.
            if lastLift > 0, lift == 0, layer.isGrass(tile) {
                layer.rustle(PlazaRustleCue(tile: tile, kind: .bounce, strong: false, delay: 0))
            }
            lastLift = lift
            let hidden = PlazaTallGrass.concealment(tile: tile, step: step, jumpLift: lift, isGrass: layer.isGrass) == 1
            guard hidden, step == nil, lift == 0 else { still = 0; return }
            still += dt
            if still >= PlazaTallGrass.twitchInterval {
                still = 0
                layer.rustle(PlazaRustleCue(tile: tile, kind: .sway(flip ? -1 : 1), strong: false, delay: 0))
                flip.toggle()
            }
        }
    }
    private var myGrassWatch = GrassWatch()
    private(set) var tallGrassLayer: PlazaTallGrassLayer?

    /// 큰 소식 반짝임 조각 하나. 시간 흐름은 `update`가 준 간격으로만 재서 창이 멈추면 같이 멈춘다.
    private struct Sparkle {
        let node: SKSpriteNode
        let origin: CGPoint
        let velocity: CGVector
        var elapsed: TimeInterval = 0
    }
    static let sparkleDuration: TimeInterval = 1.0
    private static let sparkleVelocities: [CGVector] = (0..<7).map { i in
        let angle = Double(i) / 7 * 2 * .pi
        let speed = i.isMultiple(of: 2) ? 44.0 : 28.0
        return CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed + 18)
    }
    private var sparkles: [Sparkle] = []
    private var boardMarker: SKSpriteNode?
    private var lastReported: (tile: TilePoint, facing: PlazaDirection, isWalking: Bool)
    /// 칸, 방향, 걷는 중 여부가 바뀔 때만 부른다.
    var onLocalPositionChange: ((TilePoint, PlazaDirection, Bool) -> Void)?
    /// 스페이스로 말을 걸 대상. 내가 움직이거나 팀원이 움직여 바뀔 때만 `onInteractionTargetChange`를 부른다.
    private(set) var interactionTarget: PlazaInteractionHit?
    var onInteractionTargetChange: ((PlazaInteractionHit?) -> Void)?

    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0

    /// 방향키를 누를 때(자동 반복 제외, 판이 닫혀 있을 때). `canWalk`와 무관하게 알도 부른다. 모닥불에서 일어서는 데 쓴다.
    var onWalkKey: (() -> Void)?

    // MARK: 모닥불 상태
    /// 창 컨트롤러가 정한다. 켜진 채 `true → false`가 되면 연기가 `smokeDuration` 동안 피어오른다.
    var campfireLit = false {
        didSet {
            guard campfireLit != oldValue else { return }
            campfireClock = 0
            campfirePhase = 0
            smokeRemaining = (campfireLit || isPaused) ? 0 : PlazaCampfire.smokeDuration
        }
    }
    private(set) var campfirePhase = 0
    private var campfireClock: TimeInterval = 0
    private var smokeRemaining: TimeInterval = 0
    private let campfireNode: SKSpriteNode?
    private var campfireTextures: [PlazaCampfireArt.State: [SKTexture]] = [:]
    private var campfireDrawn: (state: PlazaCampfireArt.State, index: Int)?
    private let campfireLightNode = SKSpriteNode()
    /// 밤빛 텍스처. 현재 밤 색(1/256로 반올림) 하나에 대해서만 위상별로 쌓는다. 색이 바뀌면 비운다.
    private struct LightKey: Hashable { let r: Int, g: Int, b: Int }
    private var lightTextures: (key: LightKey, byPhase: [Int: SKTexture])?
    private var lightDrawn: (key: LightKey, phase: Int)?
    private var campfireTimerNode: SKSpriteNode?
    private(set) var campfireTimerText: String?
    private var campfireTimerDrawn: (text: String, backing: CGFloat)?

    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String, tallGrass: PlazaTallGrassArt? = nil) {
        self.map = map
        self.worldSize = map.pixelSize
        self.walker = PlazaWalker(tile: start)
        self.lastReported = (start, .down, false)
        self.nickname = nickname
        self.me = PlazaActor(name: nickname, color: PlazaNameColor.palette[0])
        self.mapImage = mapImage
        self.visibleRect = CGRect(origin: .zero, size: map.pixelSize)
        self.zoom = PlazaCamera.clampedZoom(zoom)
        let texture = SKTexture(cgImage: mapImage)
        texture.filteringMode = .nearest
        self.mapNode = SKSpriteNode(texture: texture, size: map.pixelSize)
        self.campfireNode = Self.makeCampfireNode(map: map)
        super.init(size: CGSize(width: 960, height: 640))
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = Self.forestColor

        mapNode.anchorPoint = .zero
        mapNode.position = .zero
        mapNode.zPosition = 0
        addChild(mapNode)
        if let tallGrass {
            let layer = PlazaTallGrassLayer(map: map, art: tallGrass)
            addChild(layer)
            tallGrassLayer = layer
        }

        if let campfireNode { addChild(campfireNode) }
        // 낮밤 곱하기(5) 위, 이름표(10) 아래. 곱하고 둘로 늘려 흰색에 가까운 값(0.5)이 아무것도 바꾸지 않는다.
        campfireLightNode.blendMode = .multiplyX2
        campfireLightNode.zPosition = 6
        campfireLightNode.isHidden = true
        if campfireNode != nil { addChild(campfireLightNode) }
        weatherLayer.zPosition = 3
        addChild(weatherLayer)
        fireworkLayer.zPosition = 7
        addChild(fireworkLayer)
        addChild(cameraNode)
        me.attach(world: self, camera: cameraNode)
        camera = cameraNode
        // 지도와 캐릭터 위, 이름표와 말풍선(10, 11) 아래에 곱해 글자는 밤에도 그대로 읽힌다.
        daylightNode.zPosition = 5
        daylightNode.blendMode = .multiply
        daylightNode.colorBlendFactor = 1
        daylightNode.isHidden = true
        cameraNode.addChild(daylightNode)
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 외부 조작

    func setCharacter(_ frames: PlazaCharacterFrames) {
        me.setFrames(frames)
        layout()
    }

    /// 낮과 밤의 색을 화면 전체에 곱한다. 카메라에 붙어 있어 화면 크기다.
    private let daylightNode = SKSpriteNode(color: .clear, size: .zero)
    /// 지금 시각. 테스트에서 바꿔 끼운다.
    var now: () -> Date = Date.init

    /// 지금 곱하는 색. 배경을 숨겼으면 뒤의 작업 화면이 어두워지지 않게 곱하지 않는다.
    var daylightTint: PlazaDaylight.Tint {
        guard !isBackgroundHidden else { return .none }
        return PlazaDaylight.dimmed(PlazaDaylight.tint(minute: PlazaDaylight.minute(of: now())), by: fireworkLayer.dimLevel)
    }

    /// 마지막 `applyDaylight`가 정한 색. 모닥불빛이 프레임마다 시각 계산을 되풀이하지 않게 한 번만 구해 둔다.
    private var appliedTint = PlazaDaylight.Tint.none

    private func applyDaylight() {
        let t = daylightTint
        appliedTint = t
        daylightNode.isHidden = t == .none
        daylightNode.color = SKColor(srgbRed: t.red, green: t.green, blue: t.blue, alpha: 1)
        daylightNode.size = size
    }

    /// 화면에 곱하고 있는 색. 곱하지 않으면 nil(테스트용).
    var shownDaylight: PlazaDaylight.Tint? {
        guard !daylightNode.isHidden else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        daylightNode.color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return PlazaDaylight.Tint(red: Double(r), green: Double(g), blue: Double(b))
    }

    /// 지도 밖은 타일셋 나무 그림자 톤의 짙은 초록(숲이 이어진 느낌).
    private static let forestColor = SKColor(red: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1)

    /// 지도와 바탕을 숨긴다. 걸을 수 있는 칸은 그대로라 보이지 않는 나무와 덤불에 막힌다.
    func setBackgroundHidden(_ hidden: Bool) {
        mapNode.isHidden = hidden
        tallGrassLayer?.setHidden(hidden)
        layout()   // 풀숲 가림을 바로 풀어 곧바로 찍는 사진도 숨은 팀원을 그리게 한다
        backgroundColor = hidden ? .clear : Self.forestColor
        applyDaylight()
        advanceWeather(by: 0)
        applyCampfire()
    }

    var isBackgroundHidden: Bool { mapNode.isHidden }

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

    /// 없는 팀원의 캐릭터를 지우고 새 팀원의 캐릭터를 만든다. 값만 받고 그리지 않는다(창이 가려진 동안에도 안전하다).
    func applyMembers(_ members: [PlazaSceneMember]) {
        let ids = Set(members.map(\.memberID))
        for (id, remote) in remotes where !ids.contains(id) {
            remote.actor.detach()
            remotes[id] = nil
        }
        for m in members {
            let target = resolvedTile(m)
            if var r = remotes[m.memberID] {
                if r.isAway != m.isAway {
                    r.isAway = m.isAway
                    r.wanderer = m.isAway ? shelterWanderer(m.memberID) : nil
                    r.motion.snap(to: r.wanderer?.tile ?? target)
                } else if !m.isAway {
                    r.motion.moveTo(target)
                }
                r.motion.senderIsWalking = !m.isAway && m.isWalking
                r.motion.senderIsRunning = !m.isAway && m.isRunning
                if !m.isAway { r.motion.facing = m.facing }
                r.nickname = m.nickname
                r.isIdle = m.isIdle
                r.color = PlazaNameColor.color(forMemberID: m.memberID, chosen: m.nameColor)
                r.actor.setName(r.displayName, color: r.color)
                remotes[m.memberID] = r
            } else {
                let color = PlazaNameColor.color(forMemberID: m.memberID, chosen: m.nameColor)
                let wanderer = m.isAway ? shelterWanderer(m.memberID) : nil
                var motion = PlazaRemoteMotion(tile: wanderer?.tile ?? target, facing: m.facing)
                motion.senderIsWalking = !m.isAway && m.isWalking
                motion.senderIsRunning = !m.isAway && m.isRunning
                let r = Remote(actor: PlazaActor(name: Remote.displayName(m.nickname, isIdle: m.isIdle), color: color),
                               color: color, nickname: m.nickname, isAway: m.isAway, isIdle: m.isIdle, motion: motion,
                               wanderer: wanderer)
                r.actor.attach(world: self, camera: cameraNode)
                remotes[m.memberID] = r
            }
        }
        refreshInteractionTarget()
    }

    func setMemberFrames(_ memberID: String, _ frames: PlazaCharacterFrames) {
        guard let r = remotes[memberID] else { return }
        r.actor.setFrames(frames)
        layout()
    }

    private func shelterWanderer(_ memberID: String) -> PlazaShelterWanderer {
        PlazaShelterWanderer(memberID: memberID, shelter: map.shelterTiles)
    }

    /// 받은 칸이 지도 밖이거나 걸을 수 없으면 쉼터 칸. 다른 버전의 지도나 잘못된 값에도 나무 위에 서지 않는다.
    private func resolvedTile(_ m: PlazaSceneMember) -> TilePoint {
        if let t = m.tile, map.isWalkable(t) { return t }
        return shelterWanderer(m.memberID).tile
    }

    @discardableResult
    func handleKeyDown(keyCode: UInt16, characters: String?, isRepeat: Bool,
                       modifiers: NSEvent.ModifierFlags = []) -> PlazaKeyResult {
        if keyCode == Self.wKeyCode && modifiers.contains(.command) {
            onCloseRequest?()
            return .closeRequested
        }
        if isOverlayOpen {
            // 판이 열린 동안에는 판의 키만 넘긴다. 이후 키 분기(사진 등)도 이 아래에 둔다.
            if !isRepeat, let key = Self.overlayKey(keyCode) { onOverlayKey?(key) }
            return .swallowed
        }
        if keyCode == Self.escapeKeyCode {
            // 누르고 있는 Esc가 방금 닫은 판 다음에 창까지 닫지 않게 반복은 무시한다.
            if isRepeat { return .swallowed }
            onCloseRequest?()
            return .closeRequested
        }
        if keyCode == Self.spaceKeyCode {
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) { onInteractKey?() }
            return .swallowed
        }
        if keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode {
            // 보내려고 누르고 있는 Enter가 입력창을 다시 열지 않게 반복은 무시한다.
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) { onChatKey?() }
            return .swallowed
        }
        if let d = Self.direction(keyCode) {
            if !isRepeat && !modifiers.contains(.command) { onWalkKey?() }
            // Command+방향키는 keyUp이 오지 않아 계속 걷게 되므로 무시한다.
            if canWalk && !isRepeat && !modifiers.contains(.command) {
                stopWalkingToMember()
                walker.press(d)
            }
            return .swallowed
        }
        // 사진 키도 말풍선 키와 같은 규칙: 수정 키가 눌렸거나 자동 반복이면 보내지 않는다(P를 누르고 있어도 한 번만 찍는다).
        // Z(점프), X(인사하기), C(몸통박치기), G(단체 사진), F(불꽃놀이)도 말풍선 키와 같은 규칙: 수정 키가 눌렸거나 자동 반복이면 하지 않는다.
        if let action = [Self.zKeyCode: onJumpKey, Self.xKeyCode: onGreetKey, Self.cKeyCode: onTackleKey,
                         Self.gKeyCode: onGroupPhotoKey, Self.fKeyCode: onFireworkKey][keyCode] {
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) { action?() }
            return .swallowed
        }
        if keyCode == Self.pKeyCode {
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) { onPhotoKey?() }
            return .swallowed
        }
        // Cmd/Ctrl/Opt 조합은 말풍선이 아니다(아래로 내려가 처리하지 않은 키처럼 삼킨다). 눌러 둔 자동 반복도 보내지 않는다.
        if let kind = Self.emoteKind(keyCode), modifiers.isDisjoint(with: Self.emoteBlockingModifiers) {
            if !isRepeat { onEmoteKey?(kind) }
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

    /// 입력창이 키를 가져가면 키 뗌이 장면에 오지 않으므로 눌린 키와 탭을 지운다. 걷던 칸은 마저 간다.
    func clearInput() {
        // 따라가기는 한마디를 쓰는 동안에도 이어 간다.
        if !isFollowing { stopWalkingToMember() }
        walker.clearInput()
    }

    // MARK: - 팀원에게 걸어가기

    /// 목록에서 고른 팀원 바로 옆까지 걸어가 그쪽을 바라본다. 팀원이 움직이면 길을 다시 찾는다.
    /// 방향키를 누르거나 판·입력창을 열면 멈춘다. 알이거나 모르는 팀원이면 false.
    @discardableResult
    func walk(toMember id: String) -> Bool {
        guard canWalk, remotes[id] != nil else { return false }
        setAutoWalk(id, following: false)
        return true
    }

    /// 그 팀원 옆에 붙어 계속 따라다닌다. 그 팀원이 움직이면 그 옆으로(대개 방금 떠난 칸으로) 걸어가 기차처럼 이어진다.
    /// 방향키를 누르거나 그 팀원이 광장을 떠나면 멈춘다. 판이 열린 동안은 쉬었다가 닫으면 이어 간다. 알이거나 모르는 팀원이면 false.
    @discardableResult
    func follow(member id: String) -> Bool {
        guard canWalk, remotes[id] != nil else { return false }
        setAutoWalk(id, following: true)
        return true
    }

    func stopWalkingToMember() { setAutoWalk(nil, following: false) }

    var followingMember: String? { isFollowing ? autoWalk : nil }

    private func setAutoWalk(_ id: String?, following: Bool) {
        let was = followingMember
        autoWalk = id
        isFollowing = id != nil && following
        if followingMember != was { onFollowChange?(followingMember) }
    }

    /// 모닥불 자리에 앉는다. 그 칸과 방향으로 바로 옮기고, 걸어가기와 따라가기를 멈추고, 바뀐 자리를 알린다.
    func sit(at seat: PlazaCampfire.Seat) {
        stopWalkingToMember()
        walker = PlazaWalker(tile: seat.tile, facing: seat.facing)
        layout()
        reportLocalPosition()
        refreshInteractionTarget()
    }

    /// 말을 걸 대상 쪽으로 돌아선다. 걷는 중이면 돌지 않는다.
    func face(_ d: PlazaDirection) {
        walker.face(d)
        refreshInteractionTarget()
    }

    func refreshInteractionTarget() {
        let hit = PlazaInteraction.target(from: walker.tile, facing: walker.facing, map: map, members: memberTiles)
        guard hit != interactionTarget else { return }
        interactionTarget = hit
        onInteractionTargetChange?(hit)
    }

    var walkingToMember: String? { autoWalk }

    /// 다른 팀원이 서 있는(걷는 중이면 도착할) 칸. 나는 이 칸에 들어가지 못한다. 이미 겹쳐 서 있으면 빠져나갈 수는 있다.
    /// 팀원 쪽 Mac도 같은 규칙으로 나를 피하므로 서로 겹치지 않는다(동시에 같은 칸에 들어가면 잠깐 겹칠 수 있다).
    func occupiedTiles(except id: String? = nil) -> Set<TilePoint> {
        Set(remotes.filter { $0.key != id }.map(\.value.motion.tile))
    }

    /// 길은 한 칸 갈 때마다 다시 찾는다. 팀원이 움직이거나 길을 막으면 바로 돌아간다(지도가 작아 금방 찾는다).
    private func advanceWalkToMember() {
        guard let id = autoWalk else { return }
        guard canWalk, let target = remotes[id]?.motion.tile else { return stopWalkingToMember() }
        if isOverlayOpen {
            if !isFollowing { stopWalkingToMember() }
            return
        }
        guard !walker.isWalking else { return }
        if PlazaPathfinder.isAdjacent(walker.tile, target) {
            walker.face(PlazaPathfinder.direction(from: walker.tile, to: target))
            if !isFollowing { stopWalkingToMember() }
            return
        }
        guard let first = PlazaPathfinder.path(from: walker.tile, toNextTo: target, map: map,
                                               blocked: occupiedTiles())?.first else {
            // 따라가는 중이면 길이 트일 때까지 기다린다.
            if !isFollowing { stopWalkingToMember() }
            return
        }
        walker.step(first)
    }

    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func showEmote(memberID: String?, kind: TeamEmoteKind) {
        guard let actor = actor(memberID) else { return }
        actor.showEmote(kind)
        layout()
    }

    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func showChat(memberID: String?, text: String) {
        guard let actor = actor(memberID) else { return }
        actor.showChat(text)
        layout()
    }

    /// 지금 화면에 보이는 영역을 기념사진 입력으로 모은다. 그림을 아직 못 받은 캐릭터는 뺀다(알과 자리 비움은 다른 팀원처럼 찍힌다).
    func photoInput() -> PlazaPhotoInput? {
        guard visibleRect.width > 0, visibleRect.height > 0 else { return nil }
        func pose(_ facing: PlazaDirection, _ isWalking: Bool) -> PlazaSpriteChoice {
            PlazaPose.choice(facing: facing, isWalking: isWalking, clock: clock)
        }
        var actors = [me.photoActor(foot: walker.footPoint, pose: pose(walker.facing, walker.isWalking))]
        for id in remotes.keys.sorted() {
            guard let r = remotes[id] else { continue }
            actors.append(r.actor.photoActor(foot: r.motion.footPoint, pose: pose(r.motion.facing, r.motion.isWalking)))
        }
        let tint = daylightTint
        return PlazaPhotoInput(mapImage: mapImage, visibleRect: visibleRect, pixelsPerWorld: zoom * 2, actors: actors.compactMap { $0 },
                               tint: tint, weather: weatherLayer.photoParticles(worldHeight: worldSize.height),
                               items: itemPhotoParticles,
                               bands: tallGrassLayer?.photoBands(in: visibleRect) ?? [],
                               props: campfirePhotoProps, light: campfirePhotoLight(tint: tint),
                               fireworks: fireworkLayer.photoParticles(worldHeight: worldSize.height),
                               fireworkLight: fireworkLayer.photoLight(tint: tint, worldHeight: worldSize.height))
    }

    /// 사진을 찍은 뒤 화면이 잠깐 하얗게 번쩍인다. 카메라 자식이라 배율과 상관없이 화면을 덮는다.
    func playShutterFlash() {
        // 창이 가려져 멈춘 장면에서는 사라지는 동작이 돌지 않아 흰 막이 남는다. 보이지 않으니 번쩍이지 않는다.
        guard !isPaused else { return }
        shutterNode?.removeFromParent()
        let node = SKSpriteNode(color: .white, size: size)
        node.alpha = 0.7
        node.zPosition = 100
        cameraNode.addChild(node)
        node.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
        shutterNode = node
    }

    var isShutterFlashing: Bool { shutterNode?.parent != nil }

    /// 소식판 위의 `!` 말풍선. 안 읽은 소식이 있을 때 켠다.
    func setBoardMarker(visible: Bool) {
        if boardMarker == nil {
            guard visible else { return }
            let image = PlazaEmoteArt.image(.exclaim, scale: 2)
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.size)
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            let tile = CGFloat(PlazaMap.tileSize)
            node.position = CGPoint(x: (CGFloat(map.boardTile.x) + 1) * tile,   // 두 칸 너비 팻말의 가운데
                                    y: worldSize.height - CGFloat(map.boardTile.y) * tile)
            node.zPosition = 5
            addChild(node)
            boardMarker = node
        }
        boardMarker?.isHidden = !visible
    }

    var isBoardMarkerVisible: Bool { boardMarker.map { !$0.isHidden } ?? false }

    /// 그 캐릭터(nil이면 나) 위에서 별 조각 몇 개가 1초쯤 퍼진다. 모르는 팀원이면 아무것도 안 한다.
    func playSparkle(memberID: String?) {
        guard let actor = actor(memberID) else { return }
        let foot = memberID.flatMap { remotes[$0]?.motion.footPoint } ?? walker.footPoint
        // 풀숲에 숨은 캐릭터는 몸이 없으니 이름표가 앉은 자리에서 터진다.
        let originY = memberID != nil && actor.concealment > 0.5 ? worldSize.height - foot.y + PlazaTallGrass.hiddenPlateLift
            : worldSize.height - foot.y + max(actor.characterSize.height, 24) * 0.6
        let origin = CGPoint(x: foot.x.rounded(), y: originY.rounded())
        let image = PlazaEmoteArt.sparkImage(scale: 2)
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        for velocity in Self.sparkleVelocities {
            let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.sparkSize)
            node.position = origin
            node.zPosition = 20
            addChild(node)
            sparkles.append(Sparkle(node: node, origin: origin, velocity: velocity))
        }
    }

    var sparkleCount: Int { sparkles.count }

    /// 그 캐릭터(nil이면 나) 머리 위로 한 발이 올라가 터진다. 내 불꽃은 앞의 불꽃이 끝나야 쏠 수 있어 난사할 수 없다.
    /// 시간을 재지 않아 창이 멈추면 기다림도 멈춘다. 팀원의 불꽃은 그 팀원의 Mac이 막았으니 여기서는 막지 않는다.
    /// 터뜨리지 못했으면 false. 창이 가려져 멈춘 장면은 볼 수 없으니 터뜨리지 않는다.
    @discardableResult
    func playFirework(memberID: String?, style: String?) -> Bool {
        guard !isPaused, let actor = actor(memberID) else { return false }
        if memberID == nil, fireworkLayer.isFiring(owner: nil) { return false }
        let foot = memberID.flatMap { remotes[$0]?.motion.footPoint } ?? walker.footPoint
        let head = CGPoint(x: foot.x, y: worldSize.height - foot.y + actor.characterSize.height)
        // 오른쪽 목록이 덮는 폭은 카메라처럼 빼고 본다. 멀리 있는 팀원의 불꽃이 목록 뒤에서 터지면 보이지 않는다.
        let v = visibleRect, covered = PlazaRosterMetrics.coveredWidth / CGFloat(zoom)
        let burst = PlazaFireworks.burstPoint(head: head, visible: CGRect(x: v.minX, y: worldSize.height - v.maxY,
                                                                          width: v.width - covered, height: v.height))
        return fireworkLayer.launch(PlazaFireworks.style(id: style), at: burst, rise: PlazaFireworks.rise(head: head, burst: burst),
                                    owner: memberID)
    }

    /// 그 자리(장면 좌표)에 지금 닿은 모닥불빛(0~1). 꺼져 있으면 0이다.
    private func firelight(at point: CGPoint) -> Double {
        guard isCampfireLightShown, let center = PlazaCampfireLight.center(campfireTiles: map.campfireTiles) else { return 0 }
        let radii = PlazaCampfireLight.radii
        let dx = (point.x - center.x) / radii.width, dy = (worldSize.height - point.y - center.y) / radii.height
        return PlazaCampfireLight.mix(normalizedDistance: hypot(dx, dy)) * PlazaCampfireLight.strength(appliedTint)
    }

    /// 테스트용
    var fireworkZ: CGFloat { fireworkLayer.zPosition }
    var fireworkPieceCount: Int { fireworkLayer.shownCount }
    var fireworkLightCount: Int { fireworkLayer.shownLightCount }
    var fireworkPositions: [CGPoint] { fireworkLayer.shownPositions }
    var fireworkStyleIDs: [String] { fireworkLayer.styleIDs }

    /// 몸통박치기: 민 쪽이 상대 쪽으로 뛰어들고, 맞은 쪽 몸 가운데에서 민 쪽으로 조금 나온 곳에 충격 그림이 터졌다 사라진다.
    /// `pusher`나 `target`이 nil이면 나. 움직이는 것은 맞은 쪽 Mac이 정한다(`pushMe`).
    func playTackle(by pusher: String?, on target: String?, direction: PlazaDirection) {
        actor(pusher)?.lunge(toward: direction)
        guard let hit = actor(target) else { return }
        let foot = target.flatMap { remotes[$0]?.motion.footPoint } ?? walker.footPoint
        let toward = CGFloat(PlazaMap.tileSize) * 0.5
        let back: CGPoint = switch direction {
        case .right: CGPoint(x: -toward, y: 0)
        case .left: CGPoint(x: toward, y: 0)
        case .down: CGPoint(x: 0, y: toward)
        case .up: CGPoint(x: 0, y: -toward)
        }
        let center = CGPoint(x: (foot.x + back.x).rounded(),
                             y: (worldSize.height - foot.y + back.y + max(hit.characterSize.height, 24) * 0.55).rounded())
        let texture = SKTexture(cgImage: PlazaEmoteArt.impactImage(scale: 2))
        texture.filteringMode = .nearest
        let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.impactSize)
        node.position = center
        node.zPosition = 20
        node.setScale(0.6)
        node.name = Self.impactName
        addChild(node)
        node.run(.sequence([
            .group([.scale(to: 1.4, duration: 0.14), .sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.22)])]),
            .removeFromParent(),
        ]))
    }

    private static let impactName = "tackle-impact"
    private static let dustName = "jump-dust"

    /// 점프: 그 캐릭터가 위로 폴짝 뛰고, 뛸 때와 내려올 때 발밑에서 먼지가 양옆으로 퍼진다. `memberID`가 nil이면 나.
    func playJump(memberID: String?) {
        guard let actor = actor(memberID) else { return }
        actor.jump()
        puffDust(under: memberID)
        run(.sequence([.wait(forDuration: PlazaActor.jumpDuration), .run { [weak self] in self?.puffDust(under: memberID) }]))
    }

    private func puffDust(under memberID: String?) {
        guard actor(memberID) != nil else { return }
        let foot = memberID.flatMap { remotes[$0]?.motion.footPoint } ?? walker.footPoint
        let texture = SKTexture(cgImage: PlazaEmoteArt.dustImage(scale: 2))
        texture.filteringMode = .nearest
        for side in [-1.0, 1.0] {
            let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.dustSize)
            node.position = CGPoint(x: (foot.x + side * 6).rounded(), y: (worldSize.height - foot.y + 3).rounded())
            node.xScale = side
            node.zPosition = 1 + foot.y / worldSize.height + 0.0002   // 그 캐릭터 발 바로 앞
            node.name = Self.dustName
            addChild(node)
            node.run(.sequence([
                .group([.moveBy(x: side * 10, y: 3, duration: 0.35), .fadeOut(withDuration: 0.35)]),
                .removeFromParent(),
            ]))
        }
    }

    /// 테스트용: 떠 있는 먼지 수와 그 캐릭터가 떠 있는 높이.
    var dustCount: Int { children.filter { $0.name == Self.dustName }.count }
    func jumpLift(memberID: String?) -> CGFloat? { actor(memberID)?.jumpLift }
    /// 테스트용: 떠 있는 충격 그림 수와 내가 뛰어든 만큼.
    var impactCount: Int { children.filter { $0.name == Self.impactName }.count }
    func lungeOffset(memberID: String?) -> CGPoint? { actor(memberID)?.lungeOffset }

    /// 몸통박치기에 맞아 `tiles`칸 밀린다. 막힌 칸을 만나면 그 앞에 선다. 알도 밀린다.
    /// 창이 가려져 장면이 멈춰 있으면(`isPaused`) 다음 화면이 오지 않으므로 그 자리에서 다 밀리고 팀원에게 바로 알린다.
    func pushMe(_ d: PlazaDirection, tiles: Int = 1) {
        walker.push(d, tiles: tiles)
        guard isPaused else { return }
        let occupied = occupiedTiles()
        walker.advance(by: PlazaWalker.stepDuration * Double(tiles)) { [map] in map.isWalkable($0) && !occupied.contains($0) }
        reportLocalPosition()
    }
    /// 테스트용: 그 팀원을 달리는 빠르기로 따라가는지. 없으면 nil.
    func memberIsRunning(_ id: String) -> Bool? { remotes[id]?.motion.senderIsRunning }
    /// 테스트용: 조각들의 가운데(장면 좌표). 없으면 nil.
    var sparkleCenter: CGPoint? {
        guard !sparkles.isEmpty else { return nil }
        let n = CGFloat(sparkles.count)
        return CGPoint(x: sparkles.reduce(0) { $0 + $1.node.position.x } / n, y: sparkles.reduce(0) { $0 + $1.node.position.y } / n)
    }
    var walkerFootX: CGFloat { walker.footPoint.x }
    var walkerFootY: CGFloat { walker.footPoint.y }

    private func advanceSparkles(by dt: TimeInterval) {
        guard !sparkles.isEmpty else { return }
        sparkles = sparkles.compactMap { s in
            var s = s
            s.elapsed += dt
            guard s.elapsed < Self.sparkleDuration else { s.node.removeFromParent(); return nil }
            s.node.position = CGPoint(x: (s.origin.x + s.velocity.dx * s.elapsed).rounded(),
                                      y: (s.origin.y + s.velocity.dy * s.elapsed).rounded())
            s.node.alpha = CGFloat(1 - s.elapsed / Self.sparkleDuration)
            return s
        }
    }

    private func actor(_ memberID: String?) -> PlazaActor? {
        guard let memberID else { return me }
        return remotes[memberID]?.actor
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let wKeyCode: UInt16 = 13
    private static let spaceKeyCode: UInt16 = 49
    private static let pKeyCode: UInt16 = 35
    private static let zKeyCode: UInt16 = 6
    private static let xKeyCode: UInt16 = 7
    private static let cKeyCode: UInt16 = 8
    private static let gKeyCode: UInt16 = 5
    private static let fKeyCode: UInt16 = 3
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    private static let emoteBlockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option]

    private static func emoteKind(_ keyCode: UInt16) -> TeamEmoteKind? {
        switch keyCode {
        case 18: .heart
        case 19: .lol
        case 20: .party
        case 21: .exclaim
        case 23: .question
        default: nil
        }
    }

    private static func overlayKey(_ keyCode: UInt16) -> PlazaOverlayKey? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case spaceKeyCode: .space
        case returnKeyCode, keypadEnterKeyCode: .enter
        case escapeKeyCode: .escape
        default: nil
        }
    }

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

    private func noteFrameClock(advanced: Bool) {
        if advanced {
            if stalledFrames >= Self.stalledFramesForLog { onFrameClockStall?(false) }
            stalledFrames = 0
        } else {
            stalledFrames += 1
            if stalledFrames == Self.stalledFramesForLog { onFrameClockStall?(true) }
        }
    }

    // MARK: - 그리기

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layout()
    }

    /// 장면이 돈 횟수. 광장 멈춤 진단 로그에 쓴다.
    private(set) var updateCount = 0
    /// 마지막으로 받은 프레임 시계. 광장 멈춤 진단 로그에 쓴다.
    var lastFrameTime: TimeInterval? { lastTime }
    /// 장면은 도는데 프레임 시계가 멈췄으면 true, 그 뒤 다시 흐르면 false로 부른다. 움직임과 말풍선 시간은 모두 이
    /// 시계의 차이로만 흘러, 시계가 멈추면 `update`가 돌아도 아무도 움직이지 않는다. 광장 멈춤 진단 로그에 쓴다.
    var onFrameClockStall: ((Bool) -> Void)?
    /// 프레임 시계가 이만큼 연달아 흐르지 않으면 멈춘 것으로 본다(60fps로 2초).
    static let stalledFramesForLog = 120
    private var stalledFrames = 0

    override func update(_ currentTime: TimeInterval) {
        updateCount &+= 1
        let raw = currentTime - (lastTime ?? currentTime)
        lastTime = currentTime
        noteFrameClock(advanced: raw > 0)
        let dt = raw.isFinite ? min(max(raw, 0), Self.maxFrameDelta) : 0
        clock = currentTime
        let modifiers = currentModifiers()
        if modifiers.contains(.command) { walker.releaseAll() }
        // 방향키와 Shift를 함께 누르고 있거나, 따라가는 팀원이 달리면 달린다. Shift만으로는 달리지 않아,
        // 따라가며 한마디에 대문자를 쳐도 달리지 않는다.
        walker.wantsToRun = (modifiers.contains(.shift) && walker.isHoldingKey)
            || (followingMember.flatMap { remotes[$0]?.motion.senderIsRunning } ?? false)
        advanceWalkToMember()
        let occupied = occupiedTiles()
        walker.advance(by: dt) { [map] in map.isWalkable($0) && !occupied.contains($0) }
        advanceAnimation(by: dt)
        advanceTallGrass(by: dt)
        advanceSparkles(by: dt)
        fireworkLayer.advance(by: dt, tint: appliedTint, firelight: firelight(at:))
        applyDaylight()
        advanceCampfire(by: dt)
        layout()
        advanceWeather(by: dt)
        advanceItem()
        reportLocalPosition()
        refreshInteractionTarget()
    }

    /// 지금 칸의 아이템을 띄우거나 걷고, 내가 그 칸에 서 있으면 알린다. 배경을 숨기면 땅이 없으니 아이템도 없다.
    private func advanceItem() {
        let spawn = isBackgroundHidden ? nil : currentItem()
        if spawn != shownItem { showItem(spawn) }
        placeItem()
        // 칸에 들어서는 순간(걸음을 시작할 때)이 아니라, 캐릭터가 반 칸 넘게 올라섰을 때 줍는다.
        if let spawn, walker.tile == spawn.tile {
            let foot = PlazaWalker.footPoint(from: spawn.tile, to: spawn.tile, progress: 0), now = walker.footPoint
            if abs(now.x - foot.x) + abs(now.y - foot.y) <= CGFloat(PlazaMap.tileSize) / 2 { onItemPickup?(spawn) }
        }
    }

    /// 칸의 아이템은 3시간 동안 같으니 칸이 바뀔 때만 다시 센다.
    private var itemSpawnCache: (slot: Int, spawn: PlazaItems.Spawn?)?

    private func currentItem() -> PlazaItems.Spawn? {
        let date = now(), slot = PlazaItems.slot(at: date)
        if itemSpawnCache?.slot != slot { itemSpawnCache = (slot, PlazaItems.spawn(slot: slot, candidates: PlazaItems.spawnCandidates)) }
        if let spawn = itemSpawnCache?.spawn, !PlazaItems.isShown(spawn, openTiles: itemOpenTiles) { return nil }
        return PlazaItems.visible(itemSpawnCache?.spawn, at: date, picked: pickedItemSlots)
    }

    private func showItem(_ spawn: PlazaItems.Spawn?) {
        shownItem = spawn
        itemNode?.removeFromParent()
        itemNode = nil
        defer { onItemChange?(spawn) }
        guard let spawn else { return }
        // 가장 큰 배율(배율 4 × 화면 2)로 그려 두면 어느 배율에서도 정수배로 줄어든다.
        let texture = SKTexture(cgImage: PlazaEmoteArt.itemImage(spawn.kind, scale: 8))
        texture.filteringMode = .nearest
        let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.itemSize(spawn.kind))
        node.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.zPosition = 0.6   // 그림자(0.5) 위, 캐릭터(1 이상) 아래라 밟고 선 캐릭터가 앞에 온다.
        addChild(node)
        itemNode = node
    }

    /// 칸 가운데 발 높이에 두고 위아래로 살짝 떠다니게 한다. 기기 픽셀에 맞춘다.
    private func placeItem() {
        guard let spawn = shownItem, let node = itemNode else { return }
        let foot = PlazaWalker.footPoint(from: spawn.tile, to: spawn.tile, progress: 0)
        let bob = (sin(clock * 3) + 1) * 1.5
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2
        node.position = CGPoint(x: PlazaPixelSnap.snap(foot.x, backing: backing, zoom: zoom),
                                y: PlazaPixelSnap.snap(worldSize.height - foot.y + bob, backing: backing, zoom: zoom))
    }

    /// 기념사진에 담을 아이템. 좌표는 월드 픽셀(y 아래로, 그림 왼쪽 위).
    private var itemPhotoParticles: [PlazaPhotoParticle] {
        guard let spawn = shownItem, let node = itemNode else { return [] }
        let size = PlazaEmoteArt.itemSize(spawn.kind)
        return [PlazaPhotoParticle(image: PlazaEmoteArt.itemImage(spawn.kind, scale: 8),
                                   origin: CGPoint(x: node.position.x - size.width / 2, y: worldSize.height - node.position.y - size.height),
                                   size: size)]
    }

    /// 테스트용: 떠 있는 아이템의 칸.
    var itemTile: TilePoint? { itemNode == nil ? nil : shownItem?.tile }

    /// 날씨 입자를 움직인다. 보이는 영역은 `layout`이 정한 값을 장면 좌표(y 위로)로 바꿔 넘긴다.
    private func advanceWeather(by dt: TimeInterval) {
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2
        let v = visibleRect
        weatherLayer.update(date: now(), isHidden: isBackgroundHidden, dt: dt,
                            visible: CGRect(x: v.minX, y: worldSize.height - v.maxY, width: v.width, height: v.height),
                            step: PlazaPixelSnap.step(backing: backing, zoom: zoom))
    }

    /// 테스트용: 지금 내리는 날씨와 입자.
    var weatherKind: PlazaWeather.Kind { weatherLayer.kind }
    var weatherParticleCount: Int { weatherLayer.particleCount }
    var weatherParticlePositions: [CGPoint] { weatherLayer.particlePositions }

    private func reportLocalPosition() {
        // 달리기는 칸을 출발할 때나 멈출 때만 바뀌므로 칸·걷기 변화와 함께 보내진다.
        let now = (tile: walker.tile, facing: walker.facing, isWalking: walker.isWalking)
        guard now != lastReported else { return }
        lastReported = now
        onLocalPositionChange?(now.tile, now.facing, now.isWalking)
    }

    /// `dt`는 `update`에서 이미 유한하고 `maxFrameDelta` 이하다. 깨어난 장면이 팀원 이동을 몰아서 돌지 않는다.
    private func advanceAnimation(by dt: TimeInterval) {
        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        me.animate(by: dt, useBack: pose.useBack)
        for id in Array(remotes.keys) {
            // 쉼터에서 어슬렁거리는 팀원도 나와 다른 팀원이 선 칸으로는 옮기지 않는다.
            // `remotes`를 읽는 값은 먼저 구한다. 같은 식 안에서 고치는 원소와 함께 읽으면 접근 충돌로 멈춘다.
            let blocked = occupiedTiles(except: id).union([walker.tile])
            remotes[id]?.advance(by: dt, blocked: blocked)
            guard let r = remotes[id] else { continue }
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.animate(by: dt, useBack: p.useBack)
        }
    }

    /// 나와 팀원의 새 걸음이 지나는 풀을 흔들고, 가만히 가려진 채 있으면 가끔 움찔하게 한 뒤 레이어 시간을 흘린다.
    private func advanceTallGrass(by dt: TimeInterval) {
        guard let layer = tallGrassLayer else { return }
        myGrassWatch.advance(tile: walker.tile, step: walker.currentStep, lift: me.jumpLift, dt: dt, layer: layer)
        for id in Array(remotes.keys) {
            guard let r = remotes[id] else { continue }
            var watch = r.grassWatch
            watch.advance(tile: r.motion.tile, step: r.motion.currentStep, lift: r.actor.jumpLift, dt: dt, layer: layer)
            remotes[id]?.grassWatch = watch
        }
        layer.update(dt: dt)
    }

    /// 풀숲에 가려진 정도(0–1). 그림이 없거나 배경이 숨으면 늘 0이다.
    private func concealment(tile: TilePoint, step: PlazaStep?, actor: PlazaActor) -> CGFloat {
        PlazaTallGrass.concealment(tile: tile, step: step, jumpLift: actor.jumpLift) { [tallGrassLayer] in tallGrassLayer?.isGrass($0) ?? false }
    }

    /// 카메라, 캐릭터, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다.
    private func layout() {
        let z = CGFloat(zoom)
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2

        let foot = walker.footPoint
        // 큰 포켓몬의 머리가 잘리지 않게 앞모습 높이의 절반만큼 위를 본다(앞모습 기준이라 돌아봐도 카메라가 흔들리지 않는다).
        let lift = me.cameraLift
        let focus = PlazaCamera.focus(for: foot, viewportWidth: size.width, rightInset: PlazaRosterMetrics.coveredWidth,
                                      characterHalfWidth: me.characterSize.width * z / 2, zoom: zoom, lift: lift)
        let rect = PlazaCamera.visibleRect(focus: focus, viewport: size, zoom: zoom, backingScale: backing, world: worldSize,
                                        rightInset: PlazaRosterMetrics.coveredWidth)
        visibleRect = rect
        let cameraPos = CGPoint(x: rect.midX, y: worldSize.height - rect.midY)   // 원점은 visibleRect가 이미 기기 격자에 맞췄다
        cameraNode.position = cameraPos
        cameraNode.setScale(1 / z)

        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        let context = PlazaActorContext(worldHeight: worldSize.height, cameraPosition: cameraPos,
                                        zoom: zoom, backing: backing, viewport: size)
        me.place(foot: foot, pose: pose, in: context,
                 concealment: concealment(tile: walker.tile, step: walker.currentStep, actor: me), isMe: true)
        for r in remotes.values {
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.place(foot: r.motion.footPoint, pose: p, in: context,
                          concealment: concealment(tile: r.motion.tile, step: r.motion.currentStep, actor: r.actor))
        }
    }

    /// 내 화면에 보이는 팀원 자리(걷는 중이면 도착할 칸, 자리 비움은 쉼터 칸). 표적 찾기에 쓴다.
    var memberTiles: [String: TilePoint] { remotes.mapValues { $0.motion.tile } }
    /// 테스트용
    func memberFoot(_ id: String) -> CGPoint? { remotes[id]?.motion.footPoint }
    func memberName(_ id: String) -> String? { remotes[id]?.displayName }
    func memberNameColor(_ id: String) -> CGColor? { remotes[id]?.color }
    func shownChat(memberID: String?) -> String? { actor(memberID)?.chatText }
    func shownEmote(memberID: String?) -> TeamEmoteKind? { actor(memberID)?.emoteKind }
    func emoteFrame(memberID: String?) -> CGRect? { actor(memberID)?.emoteFrame }
    func memberNamePlateTop(_ id: String) -> CGFloat? { remotes[id]?.actor.namePlateTop }
    func memberZ(_ id: String) -> CGFloat? { remotes[id]?.actor.characterZ }
    var myOpacity: CGFloat { me.characterOpacity }
    var myShadowOpacity: CGFloat { me.shadowOpacity }
    var myNamePlateTop: CGFloat { me.namePlateTop }
    var myFootPoint: CGPoint { walker.footPoint }
    func memberShadowOpacity(_ id: String) -> CGFloat? { remotes[id]?.actor.shadowOpacity }
    func memberNamePlateVisible(_ id: String) -> Bool? { remotes[id]?.actor.isNamePlateVisible }
    func memberOpacity(_ id: String) -> CGFloat? { remotes[id]?.actor.characterOpacity }
    func memberNestFrontOpacity(_ id: String) -> CGFloat? { remotes[id]?.actor.nestFrontOpacity }

    /// 테스트용: 내 캐릭터 값을 그대로 넘긴다.
    var groundShadowSize: (width: Int, height: Int) { me.groundShadowSize }
    var groundShadowY: CGFloat { me.groundShadowY }
    var characterX: CGFloat { me.characterX }
    var characterY: CGFloat { me.characterY }
    var cameraPosition: CGPoint { cameraNode.position }
    var visibleWorldRect: CGRect { visibleRect }
    var isMeOnNest: Bool { me.isOnNest }
    func memberIsOnNest(_ id: String) -> Bool? { remotes[id]?.actor.isOnNest }
    var namePlatePosition: CGPoint { me.namePlatePosition }
    var namePlateWidth: CGFloat { me.namePlateWidth }
    var characterSize: CGSize { me.characterSize }
    /// 닉네임이 비어 있으면 이름판을 숨긴다.
    var isNamePlateVisible: Bool { me.isNamePlateVisible }

    // MARK: - 모닥불

    var campfireState: PlazaCampfireArt.State { campfireLit ? .lit : (smokeRemaining > 0 ? .ended : .ready) }

    /// 모닥불 발자국 바닥 변에서 4px 아래, 가로 가운데(월드, y 아래로). 지도에 모닥불이 없으면 nil.
    private static func campfireBase(_ map: PlazaMap) -> CGPoint? {
        let t = map.campfireTiles
        guard let minX = t.map(\.x).min(), let maxX = t.map(\.x).max(), let maxY = t.map(\.y).max() else { return nil }
        let tile = CGFloat(PlazaMap.tileSize)
        return CGPoint(x: CGFloat(minX + maxX + 1) / 2 * tile, y: CGFloat(maxY + 1) * tile + 4)
    }

    private static func makeCampfireNode(map: PlazaMap) -> SKSpriteNode? {
        guard let base = campfireBase(map), let maxY = map.campfireTiles.map(\.y).max() else { return nil }
        let node = SKSpriteNode(color: .clear, size: PlazaCampfireArt.worldSize)
        node.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.position = CGPoint(x: base.x, y: map.pixelSize.height - base.y)
        // 캐릭터와 같은 식: 바닥 변(칸 경계)의 y로 앞뒤를 정한다.
        node.zPosition = 1 + CGFloat(maxY + 1) * CGFloat(PlazaMap.tileSize) / map.pixelSize.height
        return node
    }

    private func campfireTexture(_ state: PlazaCampfireArt.State, _ index: Int) -> SKTexture {
        if campfireTextures[state] == nil {
            campfireTextures[state] = PlazaCampfireArt.frames(state).map {
                let texture = SKTexture(cgImage: $0)
                texture.filteringMode = .nearest
                return texture
            }
        }
        return campfireTextures[state]![index]
    }

    /// 프레임 시계는 `update`가 준 간격으로만 흐른다. 연기는 꺼진 뒤 `smokeDuration` 동안.
    private func advanceCampfire(by dt: TimeInterval) {
        if smokeRemaining > 0 { smokeRemaining = max(0, smokeRemaining - dt) }
        if campfireState != .ready {
            let period = PlazaCampfire.frameDuration * Double(PlazaCampfire.frameCount)
            campfireClock += dt
            if campfireClock >= period { campfireClock -= period }
            campfirePhase = min(Int(campfireClock / PlazaCampfire.frameDuration), PlazaCampfire.frameCount - 1)
        } else {
            campfirePhase = 0
        }
        applyCampfire()
    }

    private func applyCampfire() {
        if let node = campfireNode {
            node.isHidden = isBackgroundHidden
            let state = campfireState
            let index = state == .ready ? 0 : campfirePhase
            if campfireDrawn?.state != state || campfireDrawn?.index != index {
                node.texture = campfireTexture(state, index)
                campfireDrawn = (state, index)
            }
        }
        applyCampfireLight()
        applyCampfireTimer()
    }

    var isCampfirePitShown: Bool { campfireNode.map { !$0.isHidden } ?? false }
    var campfireZ: CGFloat? { campfireNode?.zPosition }

    /// 밤빛은 불이 켜져 있고, 배경이 보이고, 해 질 녘이나 밤일 때만.
    var isCampfireLightShown: Bool { lightShown(tint: appliedTint) }

    private func lightShown(tint: PlazaDaylight.Tint) -> Bool {
        campfireNode != nil && campfireLit && !isBackgroundHidden && PlazaCampfireLight.strength(tint) > 0
    }

    private func applyCampfireLight() {
        let shown = isCampfireLightShown
        campfireLightNode.isHidden = !shown
        guard shown, let center = PlazaCampfireLight.center(campfireTiles: map.campfireTiles) else { return }
        let tint = appliedTint
        let key = LightKey(r: Int((tint.red * 256).rounded()), g: Int((tint.green * 256).rounded()), b: Int((tint.blue * 256).rounded()))
        if lightDrawn?.key != key || lightDrawn?.phase != campfirePhase {
            if lightTextures?.key != key { lightTextures = (key, [:]) }
            let radii = PlazaCampfireLight.radii(phase: campfirePhase)
            let counts = PlazaCampfireLight.blockCounts(radii: radii)
            if lightTextures?.byPhase[campfirePhase] == nil {
                let rounded = PlazaDaylight.Tint(red: Double(key.r) / 256, green: Double(key.g) / 256, blue: Double(key.b) / 256)
                lightTextures?.byPhase[campfirePhase] = Self.lightTexture(tint: rounded, radii: radii)
            }
            campfireLightNode.texture = lightTextures?.byPhase[campfirePhase]
            campfireLightNode.size = CGSize(width: counts.w * 2, height: counts.h * 2)
            lightDrawn = (key, campfirePhase)
        }
        campfireLightNode.position = CGPoint(x: center.x, y: worldSize.height - center.y)
    }

    /// 2 세계 px당 텍셀 하나. 값은 `multiplier / 2`(곱하기X2가 두 배로 되돌린다). 타원 밖은 (0.5, 0.5, 0.5)라 그대로다.
    /// `color`와 `level`은 빛의 색과 세기로, 불꽃이 제 값을 넘긴다.
    static func lightTexture(tint: PlazaDaylight.Tint, radii: CGSize, color: (r: Double, g: Double, b: Double) = PlazaCampfireLight.warm,
                             level: Double = 1) -> SKTexture {
        let n = PlazaCampfireLight.blockCounts(radii: radii)
        var rings: [Double: [UInt8]] = [:]
        var data = [UInt8](repeating: 255, count: n.w * n.h * 4)
        for j in 0..<n.h {
            for i in 0..<n.w {
                let k = PlazaCampfireLight.blockMix(i: i, j: j, radii: radii)
                if rings[k] == nil {
                    let m = PlazaCampfireLight.multiplier(tint: tint, mix: k * level, color: color)
                    rings[k] = [m.r, m.g, m.b].map { UInt8(min(255, max(0, ($0 / 2 * 255).rounded()))) }
                }
                let o = (j * n.w + i) * 4
                data[o] = rings[k]![0]; data[o + 1] = rings[k]![1]; data[o + 2] = rings[k]![2]
            }
        }
        let image = CGImage(width: n.w, height: n.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n.w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    /// 모닥불 밑에 띄우는 남은 시간 글자. nil이면 숨긴다. 글자가 바뀔 때만 다시 그린다.
    func setCampfireTimer(_ text: String?) {
        campfireTimerText = text
        applyCampfireTimer()
    }

    private func applyCampfireTimer() {
        guard let text = campfireTimerText, campfireNode != nil, !isBackgroundHidden,
              let base = Self.campfireBase(map) else { campfireTimerNode?.isHidden = true; return }
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2
        if campfireTimerDrawn?.text != text || campfireTimerDrawn?.backing != backing {
            guard let image = PlazaNamePlate.image(text: text, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), scale: backing) else {
                campfireTimerNode?.isHidden = true
                return
            }
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            let node = campfireTimerNode ?? SKSpriteNode()
            node.texture = texture
            node.size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.zPosition = 10
            if node.parent == nil { cameraNode.addChild(node) }
            campfireTimerNode = node
            campfireTimerDrawn = (text, backing)
        }
        guard let node = campfireTimerNode else { return }
        node.isHidden = false
        let z = CGFloat(zoom)
        let bottomY = worldSize.height - base.y - node.size.height / z
        node.position = PlazaPixelSnap.platePosition(footSceneX: base.x, topY: bottomY, cameraPos: cameraNode.position,
                                                     plateWidth: node.size.width, viewport: size, backing: backing, zoom: zoom)
    }

    var isCampfireTimerShown: Bool { campfireTimerNode.map { !$0.isHidden } ?? false }
    /// 테스트용: 글자 그림과 밤빛 그림이 새로 만들어졌는지 보려는 신원.
    var campfireTimerTextureID: ObjectIdentifier? { campfireTimerNode?.texture.map(ObjectIdentifier.init) }
    /// 테스트용: 밤빛 텍스처의 픽셀과 노드의 월드 사각형(장면 좌표, y 위로).
    var campfireLightImage: CGImage? { campfireLightNode.texture?.cgImage() }
    var campfireLightFrame: CGRect { campfireLightNode.frame }
    var campfireLightTextureID: ObjectIdentifier? { campfireLightNode.texture.map(ObjectIdentifier.init) }

    /// 모닥불은 캐릭터와 같은 앞뒤 순서에 끼어든다(바닥 변 y = 칸 경계).
    private var campfirePhotoProps: [PlazaPhotoProp] {
        guard let node = campfireNode, !node.isHidden, let base = Self.campfireBase(map) else { return [] }
        let state = campfireState
        let frames = PlazaCampfireArt.frames(state)
        let size = PlazaCampfireArt.worldSize
        let particle = PlazaPhotoParticle(image: frames[state == .ready ? 0 : campfirePhase],
                                          origin: CGPoint(x: base.x - size.width / 2, y: base.y - size.height), size: size)
        return [PlazaPhotoProp(particle: particle, baseY: base.y - 4)]
    }

    private func campfirePhotoLight(tint: PlazaDaylight.Tint) -> PlazaPhotoLight? {
        guard lightShown(tint: tint), let center = PlazaCampfireLight.center(campfireTiles: map.campfireTiles) else { return nil }
        return PlazaPhotoLight(center: center, radii: PlazaCampfireLight.radii(phase: campfirePhase), tint: tint)
    }
}
