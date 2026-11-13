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
    /// 연못에서 잠수 중이다.
    var isDiving = false
    /// 진화 단계 1...3.
    var evolutionStage = 1
    /// 이름 위에 쓰는 성격. 모르면 이름만 쓴다.
    var nature: PokemonNature?
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
            // 사진 모드 안의 확대는 저장하지 않는다. 나갈 때 들어올 때의 확대로 돌아간다.
            if !isPhotoMode { onZoomChange?(zoom) }
        }
    }

    /// 사진 모드의 프레임 중심(세계 좌표, y 아래로). nil이면 평소처럼 내 캐릭터를 따라간다.
    private(set) var photoCenter: CGPoint?
    var isPhotoMode: Bool { photoCenter != nil }
    /// 사진 모드에서 화면에 비친 사진 틀(세계 좌표, y 아래로). `layout()`이 정한다.
    private(set) var photoFrame: CGRect?
    /// 마지막 `layout()`에서 지도 안으로 잘린 틀 중심. `photoCenter`는 확대·크기 변경에 건드리지 않고, 밀 때만 이 값에서 시작해 잘라 저장한다.
    private var photoShownCenter: CGPoint?
    var onPhotoModeChange: ((Bool) -> Void)?
    private var zoomBeforePhotoMode = PlazaCamera.defaultZoom
    private var panKeys: Set<PlazaDirection> = []
    var onZoomChange: ((Int) -> Void)?
    /// Cmd+W, Esc. 앱에 메인 메뉴가 없어 창 닫기를 장면이 직접 요청한다.
    var onCloseRequest: (() -> Void)?
    /// 키 1–5. 한글 입력기에서는 문자가 달라지므로 keyCode로만 판정한다.
    var onEmoteKey: ((TeamEmoteKind) -> Void)?
    /// 스페이스. 판이 닫혀 있을 때만 온다.
    var onInteractKey: (() -> Void)?
    /// 키 P(사진 모드 진입, 사진 모드에서는 촬영). keyCode로만 판정한다.
    var onPhotoKey: (() -> Void)?
    /// Z(점프). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onJumpKey: (() -> Void)?
    /// X(인사하기). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onGreetKey: (() -> Void)?
    /// C(몸통박치기). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onTackleKey: (() -> Void)?
    /// V(눈덩이). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onSnowballKey: (() -> Void)?
    /// G(단체 사진). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onGroupPhotoKey: (() -> Void)?
    /// F(불꽃놀이). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다.
    var onFireworkKey: (() -> Void)?
    /// A(기도). 판이 닫혀 있을 때만 온다. keyCode로만 판정한다. 알인지는 컨트롤러가 가른다.
    var onPrayKey: (() -> Void)?
    /// 내 춤 한 판이 시작됐다(D를 눌렀을 때와 판이 끝나 저절로 이어질 때). 춤의 `PlazaDance.Style.id`를 넘긴다. 컨트롤러가 팀원에게 보낸다.
    var onDanceRound: ((String) -> Void)?
    /// 내가 모닥불에서 집중 중이다. 컨트롤러가 알려 준다. 집중 중에는 춤추지 않는다.
    var isFocusing: () -> Bool = { false }
    /// 다음 춤을 고른다(직전 춤은 피한다). 테스트에서 바꿔 끼운다.
    var pickDanceStyle: (PlazaDance.Style?) -> PlazaDance.Style = { last in
        var rng = SystemRandomNumberGenerator()
        return PlazaDance.Style.next(after: last, using: &rng)
    }
    /// 내가 따라 출 팀원이 지금 추는 춤. 따라 출 팀원이 없으면 nil. 컨트롤러가 알려 준다.
    var danceLeaderStyle: () -> PlazaDance.Style? = { nil }
    /// 내가 직전에 춘 춤. 연달아 같은 춤이 나오지 않게 기억한다.
    private var lastDanceStyle: PlazaDance.Style?
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

    private(set) var mapImage: CGImage
    /// 처음 받은 지도 그림과 풀숲 그림(눈 오는 날이 아닌 모습).
    private let normalMapImage: CGImage
    private let normalTallGrass: PlazaTallGrassArt?
    /// 멈추면 모든 춤을 끝낸다. 멈춘 동안 시계만 흘러 되살아난 춤이 박자 격자에서 어긋나기 때문이다.
    /// 그리기 감시가 멈춘 그림을 깨우려고 뷰를 껐다 켜도(`checkRendering`) 장면이 멈췄다 풀리므로 춤이 끝난다. 의도한 동작이다.
    override var isPaused: Bool {
        didSet {
            if isPaused && !oldValue {
                finishIceNow()
                stopAllDances()
                climbOutNowIfPaused()   // 알이 물에 든 채 멈추기 시작하면 `update`가 더는 올라오게 해 주지 않는다
                snowballLayer.landAll()   // 멈춘 장면은 프레임이 오지 않으니 날던 눈덩이를 모두 그 자리에서 착지시킨다
            }
        }
    }

    /// 마지막 `layout`이 정한 보이는 월드 영역. 평소 기념사진이 이 영역을 찍는다(사진 모드에서는 `photoFrame`).
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
    /// My plate while I copy a teammate; nil for my own.
    private var disguise: PlazaMimicLook?
    /// My own nature title, kept apart from what the actor shows.
    private var ownTitle: String?
    /// false(알)면 방향키를 삼키고 입력을 지운다. 걷던 칸은 마저 간다.
    var canWalk = true {
        didSet {
            if !canWalk {
                walker.clearInput()
                climbOutNowIfPaused()
            }
        }
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
        var printWatch = PrintWatch()
        /// 광장 메타몽 전용: 몸통박치기에 튕겨 나가는 중(걸음이 아니라 밀림이라 발자국을 남기지 않는다).
        var isBouncing = false
        /// 그 팀원이 알린 잠수와, 그림에 반영한 흐려짐.
        var diving = false
        var dive = DiveFade()
        var stage = 1
        var pond = PondWatch()
        /// 광장 메타몽 전용: 팀원을 따라 한 모습인지.
        var isDecoy = false

        /// zZ는 자리비움(입력 없음)일 때만. 광장을 닫고 일하는 팀원은 쉼터에 서 있어도 zZ가 없다.
        var displayName: String { Self.displayName(nickname, isIdle: isIdle) }

        static func displayName(_ nickname: String, isIdle: Bool) -> String {
            isIdle ? nickname + " " + L(.ko).plazaAwaySuffix : nickname
        }

        mutating func advance(by dt: TimeInterval, blocked: Set<TilePoint>,
                              stepDuration: ((TilePoint, TilePoint, Bool) -> TimeInterval)? = nil) {
            if let moved = wanderer?.advance(by: dt, blocked: blocked) { motion.moveTo(moved) }
            motion.advance(by: dt, stepDuration: stepDuration)
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

    /// 발자국 기록 하나(나 또는 팀원 한 명): 가고 있는 걸음과 미끄러지는 걸음인지. 끝난 걸음을 돌려준다(미끄러진 걸음은 빼고).
    private struct PrintWatch {
        var lastStep: (from: TilePoint, to: TilePoint)?
        var slides = false

        mutating func advance(step: PlazaStep?, sliding: Bool) -> (from: TilePoint, to: TilePoint)? {
            var ended: (from: TilePoint, to: TilePoint)?
            if let last = lastStep, step?.from != last.from || step?.to != last.to {
                if !slides { ended = last }
                lastStep = nil
                slides = false
            }
            if let step {
                if lastStep == nil { lastStep = (step.from, step.to) }
                slides = slides || sliding
            }
            return ended
        }
    }
    private var myPrintWatch = PrintWatch()
    private let footprintLayer: PlazaFootprintLayer
    private let snowballLayer: PlazaSnowballLayer
    var snowballFlightCount: Int { snowballLayer.flightCount }
    var snowballBallSizes: [CGSize] { snowballLayer.ballSizes }
    var snowballNodeCount: Int { snowballLayer.nodeCount }
    var snowballSpriteCount: Int { snowballLayer.shownSpriteCount }
    var footprintCount: Int { footprintLayer.count }
    var footprintAlphas: [CGFloat] { footprintLayer.alphas }

    /// 연못 기록 하나(나 또는 팀원 한 명): 땅에서 물로 뛰는 걸음, 지난 점프 높이, 잠수 거품 시계.
    /// 도착·착지·거품을 `advance`가 세어 돌려주고, 물보라와 젖음은 장면이 낸다.
    private struct PondWatch {
        var plungeTo: TilePoint?
        var lastStep: (from: TilePoint, to: TilePoint)?
        var lastLift: CGFloat = 0
        var bubbleClock: TimeInterval = PlazaPond.bubbleInterval

        struct Events { var landedInWater: TilePoint?; var shoreSplash: TilePoint?; var bubble = false }

        /// 땅→물 걸음이 끝난 프레임에 도착 칸을, 점프에서 내려앉은 프레임에 땅의 물가 물보라 칸을, 잠수 중 0.4초마다 거품을 알린다.
        mutating func advance(tile: TilePoint, step: PlazaStep?, lift: CGFloat, facing: PlazaDirection, diving: Bool,
                              dt: TimeInterval, isWater: (TilePoint) -> Bool) -> Events {
            var events = Events()
            let sameStep = step != nil && step?.from == lastStep?.from && step?.to == lastStep?.to
            if let landed = plungeTo, !sameStep {
                // 뛰어든 걸음이 사라졌어도 아직 물에 있을 때만 착지다. 자리 비움 같은 순간이동이면 물보라를 내지 않는다.
                // (방향키를 누르고 있으면 같은 프레임에 다음 헤엄 걸음이 시작되니 `tile == landed`로 비교하지 않는다.)
                if isWater(tile) { events.landedInWater = landed }
                plungeTo = nil
            }
            if let step {
                if !sameStep {
                    lastStep = (step.from, step.to)
                    if !isWater(step.from), isWater(step.to) { plungeTo = step.to }
                }
            } else {
                lastStep = nil
            }
            if lastLift > 0, lift == 0, !isWater(tile) {
                events.shoreSplash = PlazaPond.shoreSplashTile(tile: tile, facing: facing, isWater: isWater)
            }
            lastLift = lift
            if diving {
                bubbleClock += dt
                if bubbleClock >= PlazaPond.bubbleInterval { bubbleClock = 0; events.bubble = true }
            } else {
                bubbleClock = PlazaPond.bubbleInterval
            }
            return events
        }
    }
    private var myPond = PondWatch()
    /// 내 진화 단계(1...3). 큰 물보라가 젖게 하는 반경이다. 창 컨트롤러가 내 종이 바뀔 때마다 맞춘다.
    var myEvolutionStage = 1

    /// 잠수로 흐려지는 정도(0–1). `PlazaPond.diveFade`초에 걸쳐 오가며 장면 시간(dt)으로만 잰다.
    private struct DiveFade {
        var level: CGFloat = 0
        mutating func advance(toward on: Bool, dt: TimeInterval) {
            let step = CGFloat(dt / PlazaPond.diveFade)
            level = on ? min(1, level + step) : max(0, level - step)
        }
    }
    private var myDive = DiveFade()
    private let pondVisuals: Bool
    private(set) var pondLayer: PlazaPondLayer?
    private var iceLayer: PlazaIceLayer?
    /// 내가 잠수 중이다. 물속에서만 켜진다.
    private(set) var isDiving = false
    private var diveElapsed: TimeInterval = 0
    /// 잠수 제한 시간. 창 컨트롤러가 포켓몬 타입으로 바꾼다.
    var diveLimit: TimeInterval = PlazaPond.diveLimit
    /// 시간이 다했거나 물 밖으로 나가 장면이 잠수를 끝냈을 때. `setDiving`으로 끈 때는 부르지 않는다.
    var onDivingChange: ((Bool) -> Void)?
    private(set) var tallGrassLayer: PlazaTallGrassLayer?
    /// 풀숲이 그려진 칸. 배경을 숨기면 풀숲도 없다.
    func isGrass(_ t: TilePoint) -> Bool { tallGrassLayer?.isGrass(t) ?? false }

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

    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String, tallGrass: PlazaTallGrassArt? = nil,
         pondVisuals: Bool = false, iceArt: PlazaIceArt? = nil) {
        self.map = map
        self.icePonds = iceArt == nil ? [] : PlazaIce.ponds(in: map)
        var index: [TilePoint: Int] = [:]
        for (i, pond) in icePonds.enumerated() { for t in pond.tiles { index[t] = i } }
        self.icePondIndex = index
        self.frozenIndex = icePonds.isEmpty ? nil : 0
        self.worldSize = map.pixelSize
        self.footprintLayer = PlazaFootprintLayer(worldHeight: map.pixelSize.height)
        self.snowballLayer = PlazaSnowballLayer(worldHeight: map.pixelSize.height)
        // 처음 보이는 계절(`shownSeason`)의 그림으로 시작한다. `refreshSnowDay`는 계절이 바뀔 때만 그림을 바꾼다.
        snowballLayer.setArt(PlazaSnowballArt.pieces(.summer, balloon: PlazaScene.waterBalloon))
        self.walker = PlazaWalker(tile: start)
        self.lastReported = (start, .down, false)
        self.nickname = nickname
        self.pondVisuals = pondVisuals
        self.me = PlazaActor(name: nickname, color: PlazaNameColor.palette[0])
        self.mapImage = mapImage
        self.normalMapImage = mapImage
        self.normalTallGrass = tallGrass
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

        if pondVisuals {
            let layer = PlazaPondLayer(map: map)
            addChild(layer)
            pondLayer = layer
        }
        if let iceArt {
            let layer = PlazaIceLayer(ponds: icePonds, art: iceArt, mapImage: mapImage, worldHeight: map.pixelSize.height)
            addChild(layer)
            iceLayer = layer
            drawIce()
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
        addChild(footprintLayer)
        addChild(snowballLayer)
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

    /// 팀이 정한 밝은 시간대와 날씨 주기. `PlazaWindowController.applySchedule`이 넣는다.
    /// 바뀌면 `setBackgroundHidden`처럼 바로 다시 그린다(멈춘 장면에서도 낮밤·날씨·모닥불빛이 맞게).
    var coreTime = PlazaCoreTime.standard {
        didSet { if coreTime != oldValue { applyDaylight(); applyCampfire() } }
    }
    /// 팀이 고른 계절. 정한 적이 없으면 겨울이다.
    var seasonChoice = PlazaSeasonChoice.winter {
        didSet { if seasonChoice != oldValue { advanceWeather(by: 0); refreshSnowDay(); refreshIce(hit: nil) } }
    }
    /// 지금의 계절. `auto`면 내 달력의 오늘이다.
    var season: PlazaSeason { seasonChoice.season(on: now()) }

    /// 지금 곱하는 색. 배경을 숨겼으면 뒤의 작업 화면이 어두워지지 않게 곱하지 않는다.
    var daylightTint: PlazaDaylight.Tint {
        guard !isBackgroundHidden else { return .none }
        return PlazaDaylight.dimmed(PlazaDaylight.tint(minute: PlazaDaylight.minute(of: now()), core: coreTime), by: fireworkLayer.dimLevel)
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
        pondLayer?.setHidden(hidden)
        iceLayer?.setConcealed(hidden)
        footprintLayer.isHidden = hidden
        if hidden { footprintLayer.removeAll() }
        layout()   // 풀숲 가림을 바로 풀어 곧바로 찍는 사진도 숨은 팀원을 그리게 한다
        backgroundColor = hidden ? .clear : Self.forestColor
        applyDaylight()
        advanceWeather(by: 0)
        applyCampfire()
    }

    var isBackgroundHidden: Bool { mapNode.isHidden }

    func setNickname(_ name: String) {
        nickname = name
        applyMyPlate()
    }

    func setNameColor(_ color: CGColor) {
        guard color != nameColor else { return }
        nameColor = color
        applyMyPlate()
    }

    /// 내 이름 위의 성격.
    func setNature(_ nature: PokemonNature?) {
        let title = nature.map(L(.ko).plazaNatureTitle)
        guard title != ownTitle else { return }
        ownTitle = title
        applyMyPlate()
    }

    /// My plate while I copy a teammate (§5.2); nil for my own. `nickname`, `nameColor` and my nature title stay mine:
    /// `setNickname`, `setNameColor` and `setNature` keep storing them and show them only while no disguise is set.
    func setMyDisguise(_ look: PlazaMimicLook?) {
        disguise = look
        applyMyPlate()
    }

    var myShownName: String { me.name }
    var myShownNameColor: CGColor { me.nameColor }

    private func applyMyPlate() {
        if let d = disguise {
            me.setName(d.name, color: PlazaNameColor.color(forMemberID: d.memberID, chosen: d.nameHex))
            me.setTitle(d.nature.map(L(.ko).plazaNatureTitle))
        } else {
            me.setName(nickname, color: nameColor)
            me.setTitle(ownTitle)
        }
        layout()
    }

    /// Test-only: how many times the member list was redrawn, so a test can see an idle tick leave the scene alone.
    private(set) var applyMembersCount = 0

    /// 없는 팀원의 캐릭터를 지우고 새 팀원의 캐릭터를 만든다. 값만 받고 그리지 않는다(창이 가려진 동안에도 안전하다).
    func applyMembers(_ members: [PlazaSceneMember]) {
        applyMembersCount &+= 1
        let ids = Set(members.map(\.memberID))
        for (id, remote) in remotes where !ids.contains(id) && id != PlazaDitto.sceneKey {
            remote.actor.detach()
            remotes[id] = nil
        }
        for m in members {
            let target = resolvedTile(m)
            if var r = remotes[m.memberID] {
                let tileBefore = r.motion.tile
                defer { if let now = remotes[m.memberID], now.motion.tile != tileBefore { now.actor.stopDance() } }
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
                if r.diving, !m.isDiving, isWaterNow(target) {
                    splash(at: target, big: true, stage: m.evolutionStage, splasher: m.memberID)
                }
                r.diving = m.isDiving
                r.stage = m.evolutionStage
                r.color = PlazaNameColor.color(forMemberID: m.memberID, chosen: m.nameColor)
                r.actor.setName(r.displayName, color: r.color)
                r.actor.setTitle(m.nature.map(L(.ko).plazaNatureTitle))
                remotes[m.memberID] = r
            } else {
                let color = PlazaNameColor.color(forMemberID: m.memberID, chosen: m.nameColor)
                let wanderer = m.isAway ? shelterWanderer(m.memberID) : nil
                var motion = PlazaRemoteMotion(tile: wanderer?.tile ?? target, facing: m.facing)
                motion.senderIsWalking = !m.isAway && m.isWalking
                motion.senderIsRunning = !m.isAway && m.isRunning
                let r = Remote(actor: PlazaActor(name: Remote.displayName(m.nickname, isIdle: m.isIdle), color: color),
                               color: color, nickname: m.nickname, isAway: m.isAway, isIdle: m.isIdle, motion: motion,
                               wanderer: wanderer, diving: m.isDiving, stage: m.evolutionStage)
                r.actor.setTitle(m.nature.map(L(.ko).plazaNatureTitle))
                r.actor.attach(world: self, camera: cameraNode)
                remotes[m.memberID] = r
            }
        }
        refreshInteractionTarget()
    }

    /// 광장 메타몽 한 마리. nil이면 지운다. 팀원이 아니라서 `applyMembers`가 건드리지 않고 `memberTiles`에도 없다.
    func applyDitto(_ shown: PlazaDittoShown?) {
        let key = PlazaDitto.sceneKey
        guard let shown else {
            remotes[key]?.actor.detach()
            remotes[key] = nil
            refreshInteractionTarget()
            return
        }
        if var r = remotes[key] {
            // 팀원처럼 칸이 바뀌면(걸음이든 순간이동이든) 춤을 멈춘다. 옛 칸에서 정한, 걸음이 끝나길 기다리던 춤도 버린다.
            if r.motion.tile != shown.tile {
                stopDance(memberID: key)
                // 몸통박치기에 튕겨 나가는 메타몽은 가는 동안 통통 뛴다. 떠 있는 동안에는 다시 뛰지 않는다.
                if shown.isBouncing, r.actor.jumpLift == 0 { playJump(memberID: key) }
            }
            r.motion.moveTo(shown.tile)   // 한 칸이 아니면 moveTo가 알아서 바로 옮긴다
            r.motion.senderIsWalking = shown.isWalking
            r.motion.senderIsRunning = shown.isRunning
            r.motion.facing = shown.facing
            r.nickname = shown.name
            r.color = shown.nameColor
            r.isDecoy = shown.isDecoy
            r.isBouncing = shown.isBouncing
            r.actor.setName(r.displayName, color: r.color)
            r.actor.setTitle(shown.title)
            remotes[key] = r
        } else {
            var motion = PlazaRemoteMotion(tile: shown.tile, facing: shown.facing)
            motion.senderIsWalking = shown.isWalking
            motion.senderIsRunning = shown.isRunning
            var r = Remote(actor: PlazaActor(name: shown.name, color: shown.nameColor), color: shown.nameColor,
                           nickname: shown.name, isAway: false, motion: motion)
            r.isDecoy = shown.isDecoy
            r.isBouncing = shown.isBouncing
            r.actor.setTitle(shown.title)
            r.actor.attach(world: self, camera: cameraNode)
            remotes[key] = r
        }
        refreshInteractionTarget()
    }

    var dittoTile: TilePoint? { remotes[PlazaDitto.sceneKey]?.motion.tile }
    var decoyTile: TilePoint? {
        guard let r = remotes[PlazaDitto.sceneKey], r.isDecoy else { return nil }
        return r.motion.tile
    }

    /// 변신·원래대로 돌아올 때 발밑에서 일어나는 먼지 고리.
    func playDittoPoof() {
        guard !isPaused, let r = remotes[PlazaDitto.sceneKey] else { return }
        let foot = r.motion.footPoint
        let texture = SKTexture(cgImage: PlazaEmoteArt.dustImage(scale: 2))
        texture.filteringMode = .nearest
        let count = 5
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi
            let dx = cos(angle), dy = sin(angle)
            let node = SKSpriteNode(texture: texture, size: PlazaEmoteArt.dustSize)
            node.position = CGPoint(x: (foot.x + dx * 6).rounded(), y: (worldSize.height - foot.y + 3 + dy * 4).rounded())
            node.xScale = dx < 0 ? -1 : 1
            node.zPosition = 1 + foot.y / worldSize.height + 0.0002
            node.name = Self.dustName
            addChild(node)
            node.run(.sequence([
                .group([.moveBy(x: dx * 12, y: dy * 8 + 3, duration: 0.45), .fadeOut(withDuration: 0.45)]),
                .removeFromParent(),
            ]))
        }
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
        if let t = m.tile, map.isWalkable(t) || map.isWater(t) { return t }
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
        if isPhotoMode { return handlePhotoModeKeyDown(keyCode: keyCode, characters: characters, isRepeat: isRepeat, modifiers: modifiers) }
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
            // 알은 물속에서도 방향키로 움직이지 않는다. 물가로는 `update`가 저절로 올려 보낸다.
            if canWalk && !isRepeat && !modifiers.contains(.command) {
                stopWalkingToMember()
                walker.press(d)
                stopDance(memberID: nil)
            }
            return .swallowed
        }
        // C(몸통박치기)와 V(눈덩이), P(사진)도 말풍선 키와 같은 규칙: 수정 키가 눌렸거나 자동 반복이면 하지 않는다(P를 누르고 있어도 한 번만 찍는다).
        if keyCode == Self.cKeyCode || keyCode == Self.vKeyCode || keyCode == Self.pKeyCode {
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) {
                if keyCode == Self.cKeyCode { onTackleKey?() } else if keyCode == Self.vKeyCode { onSnowballKey?() } else { onPhotoKey?() }
            }
            return .swallowed
        }
        return handleSharedKeyDown(keyCode: keyCode, characters: characters, isRepeat: isRepeat, modifiers: modifiers)
    }

    /// 평소와 사진 모드가 함께 쓰는 키: Z/X/G/F(불꽃놀이)/A(기도)/D(춤), 말풍선, 확대. 수정 키가 눌렸거나 자동 반복이면 보내지 않는다.
    /// 사진 모드에서만 다른 키(방향키, Space/P, C, Enter, Esc)는 호출하기 전에 각자 처리한다.
    private func handleSharedKeyDown(keyCode: UInt16, characters: String?, isRepeat: Bool,
                                     modifiers: NSEvent.ModifierFlags) -> PlazaKeyResult {
        let plain = !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers)
        if keyCode == Self.dKeyCode {
            if plain { pressDance() }
            return .swallowed
        }
        if let action = [Self.zKeyCode: onJumpKey, Self.xKeyCode: onGreetKey, Self.gKeyCode: onGroupPhotoKey,
                         Self.fKeyCode: onFireworkKey, Self.aKeyCode: onPrayKey][keyCode] {
            if plain { action?() }
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

    /// 사진 모드의 키. 전부 삼킨다. 방향키는 걷기가 아니라 틀을 민다.
    private func handlePhotoModeKeyDown(keyCode: UInt16, characters: String?, isRepeat: Bool,
                                        modifiers: NSEvent.ModifierFlags) -> PlazaKeyResult {
        if keyCode == Self.escapeKeyCode {
            if !isRepeat { exitPhotoMode() }
            return .swallowed
        }
        if let d = Self.direction(keyCode) {
            // Command+방향키는 keyUp이 오지 않아 계속 밀리게 되므로 무시한다.
            if !isRepeat && !modifiers.contains(.command) { panKeys.insert(d) }
            return .swallowed
        }
        if keyCode == Self.spaceKeyCode || keyCode == Self.pKeyCode {
            if !isRepeat && modifiers.isDisjoint(with: Self.emoteBlockingModifiers) { onPhotoKey?() }
            return .swallowed
        }
        // 사진 모드에서는 C(몸통박치기), V(눈덩이), Enter(채팅)를 쓰지 않는다.
        if keyCode == Self.cKeyCode || keyCode == Self.vKeyCode || keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode { return .swallowed }
        return handleSharedKeyDown(keyCode: keyCode, characters: characters, isRepeat: isRepeat, modifiers: modifiers)
    }

    /// 카메라를 내 캐릭터에서 떼어 지금 보이는 화면 한가운데에 둔다. 걷던 것도 멈춘다.
    func enterPhotoMode() {
        guard !isPhotoMode else { return }
        zoomBeforePhotoMode = zoom
        // 화면이 튀지 않게 틀 가운데를 지금 보이는 영역이 그대로 남는 곳에 둔다(위 여백과 아래 여백이 다르다).
        photoCenter = CGPoint(x: visibleRect.midX,
                              y: visibleRect.midY + (PlazaPhotoFrame.topInset - PlazaPhotoFrame.bottomInset) / (2 * CGFloat(zoom)))
        walker.clearInput()   // 아직 쓰지 않은 탭이 남아 한 걸음 더 가지 않게 탭까지 지운다
        stopWalkingToMember()
        panKeys.removeAll()
        layout()
        onPhotoModeChange?(true)
    }

    func exitPhotoMode() {
        guard isPhotoMode else { return }
        photoCenter = nil
        photoFrame = nil
        panKeys.removeAll()
        zoom = zoomBeforePhotoMode
        layout()
        onPhotoModeChange?(false)
    }

    func handleKeyUp(keyCode: UInt16) {
        if let d = Self.direction(keyCode) { walker.release(d); panKeys.remove(d) }
    }

    func releaseAllKeys() { walker.releaseAll(); panKeys.removeAll() }

    /// 입력창이 키를 가져가면 키 뗌이 장면에 오지 않으므로 눌린 키와 탭을 지운다. 걷던 칸은 마저 간다.
    func clearInput() {
        // 따라가기는 한마디를 쓰는 동안에도 이어 간다.
        if !isFollowing { stopWalkingToMember() }
        walker.clearInput()
        panKeys.removeAll()
    }

    // MARK: - 팀원에게 걸어가기

    /// 목록에서 고른 팀원 바로 옆까지 걸어가 그쪽을 바라본다. 팀원이 움직이면 길을 다시 찾는다.
    /// 방향키를 누르거나 판·입력창을 열면 멈춘다. 알이거나 모르는 팀원이면 false.
    @discardableResult
    func walk(toMember id: String) -> Bool {
        guard canWalk, !isMeInWater, remotes[id] != nil else { return false }
        setAutoWalk(id, following: false)
        return true
    }

    /// 그 팀원 옆에 붙어 계속 따라다닌다. 그 팀원이 움직이면 그 옆으로(대개 방금 떠난 칸으로) 걸어가 기차처럼 이어진다.
    /// 방향키를 누르거나 그 팀원이 광장을 떠나면 멈춘다. 판이 열린 동안은 쉬었다가 닫으면 이어 간다. 알이거나 모르는 팀원이면 false.
    @discardableResult
    func follow(member id: String) -> Bool {
        guard canWalk, !isMeInWater, remotes[id] != nil else { return false }
        setAutoWalk(id, following: true)
        return true
    }

    func stopWalkingToMember() { setAutoWalk(nil, following: false) }

    var followingMember: String? { isFollowing ? autoWalk : nil }

    private func setAutoWalk(_ id: String?, following: Bool) {
        let was = followingMember
        if id != nil { stopDance(memberID: nil) }
        autoWalk = id
        isFollowing = id != nil && following
        if followingMember != was { onFollowChange?(followingMember) }
    }

    /// 모닥불 자리에 앉는다. 그 칸과 방향으로 바로 옮기고, 걸어가기와 따라가기를 멈추고, 바뀐 자리를 알린다.
    func sit(at seat: PlazaCampfire.Seat) {
        stopWalkingToMember()
        stopDance(memberID: nil)
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
        let hit = PlazaInteraction.target(from: walker.tile, facing: walker.facing, map: map, members: interactionTiles)
        guard hit != interactionTarget else { return }
        interactionTarget = hit
        onInteractionTargetChange?(hit)
    }

    var walkingToMember: String? { autoWalk }

    /// 내가 물속에 있다(걷는 중이면 도착할 칸 기준).
    var isMeInWater: Bool { isWaterNow(walker.tile) }
    /// 그 팀원이 물속에 있다. 모르는 팀원이면 nil.
    func memberIsInWater(_ id: String) -> Bool? { remotes[id].map { isWaterNow($0.motion.tile) } }

    /// 잠수를 켠다(물속에서만) 또는 끈다. 컨트롤러가 부르므로 `onDivingChange`는 부르지 않는다.
    func setDiving(_ on: Bool) {
        guard on != isDiving, !on || isMeInWater else { return }
        isDiving = on
        diveElapsed = 0
        if !on { splashSurfacing() }
    }

    /// Z를 눌렀을 때 할 일: 땅에서는 점프(물가면 첨벙 점프)나 첨벙 뛰어들기, 물속에서는 잠수와 떠오름.
    /// 바라보는 물 칸에 팀원이 있으면 뛰어들지 않는다.
    func pondAction(canMove: Bool) -> PlazaPondAction {
        let taken = occupiedTiles()
        return PlazaPond.action(tile: walker.tile, facing: walker.facing, isDiving: isDiving, canMove: canMove,
                                isWater: { isWaterNow($0) }, isFree: { !taken.contains($0) },
                                isIce: { isFrozen($0) })
    }

    /// 물속에서 잠수를 끝내며 떠오르는 큰 물보라. 물 밖이면 아무것도 하지 않는다.
    private func splashSurfacing() {
        if isMeInWater { splash(at: walker.tile, big: true, stage: myEvolutionStage, splasher: nil) }
    }

    /// 물 칸 `d` 쪽으로 첨벙 뛰어든다. `pondAction`이 `.plunge`일 때만 부른다(땅에 서 있고 바라보는 칸이 빈 물 칸).
    /// 큰 물보라는 걸음이 물에 내려앉을 때 `advancePond`가 낸다.
    func plunge(_ d: PlazaDirection) {
        stopDance(memberID: nil)
        walker.plunge(d)
        plungeJumpOwed = PlazaWalker.offset(walker.tile, d)
    }

    /// 얼음 칸 `d` 쪽으로 뛰어오른다: 뛰어들기와 같은 걸음이지만 점프 한 번 길이(0.36초)다. `pondAction`이 `.leapOntoIce`일 때만 부른다.
    func leapOntoIce(_ d: PlazaDirection) {
        stopDance(memberID: nil)
        walker.plunge(d, duration: PlazaPond.plungeStepDuration)
        plungeJumpOwed = PlazaWalker.offset(walker.tile, d)
    }

    // MARK: - 언 연못

    /// 한 번에 줄 서는 얼음 착지 수의 상한. 넘치면 바로 착지시킨다(받은 값이 노드를 늘리지 못하게).
    static let maxIceLandings = 8
    private let icePonds: [PlazaIce.Pond]
    private let icePondIndex: [TilePoint: Int]
    /// 깨진 뒤 아직 아무 연못도 안 얼었을 때, 다음 연못이 얼기 시작할 벽시계(유닉스 초). 얼어 있거나 모르면 nil.
    private var freezeDue: Double?
    private var frozenIndex: Int?
    /// 마지막으로 깨진 연못. 어느 연못이 언 채인지는 이것과 내 시계(`at + 60초`)로 정해진다.
    private(set) var iceBreak: PlazaIceBreak?
    private var breaking: (pond: Int, hit: TilePoint, elapsed: TimeInterval)?
    private var landings: [(break: PlazaIceBreak, jumper: String?, remaining: TimeInterval)] = []
    /// 깬 점프가 땅에 닿았다. 깨진 것과 맞은 칸을 넘긴다.
    var onIceLanding: ((PlazaIceBreak, TilePoint) -> Void)?
    /// 단단한 얼음이 바뀌었다(얼거나 가라앉음).
    var onIceChange: (() -> Void)?

    private func isFrozen(_ t: TilePoint) -> Bool {
        guard let i = icePondIndex[t] else { return false }
        return i == frozenIndex
    }
    /// 언 연못이거나, 깨지는 중이고 아직 0.6초 전인 연못.
    func isIce(_ t: TilePoint) -> Bool {
        guard let i = icePondIndex[t] else { return false }
        if i == frozenIndex { return true }
        if let b = breaking, b.pond == i, b.elapsed < PlazaIce.sinkAt { return true }
        return false
    }
    func isWaterNow(_ t: TilePoint) -> Bool { map.isWater(t) && !isIce(t) }
    func isWalkableNow(_ t: TilePoint) -> Bool { map.isWalkable(t) || isIce(t) }
    var frozenPondAnchor: TilePoint? { frozenIndex.map { icePonds[$0].anchor } }
    var isMeOnIce: Bool { isFrozen(walker.tile) }
    var breakingPondAnchor: TilePoint? { breaking.map { icePonds[$0.pond].anchor } }
    var breakingHit: TilePoint? { breaking?.hit }
    var iceLandingCount: Int { landings.count }

    /// 아는 마지막 깨짐을 바꾼다. 장면이 멈췄거나 아직 한 프레임도 안 그렸으면 그대로 적용하고, 아니면 깨지는 모습을 거친다.
    /// 받은 값의 `at` 이 내 시계보다 60초를 넘게 앞서거나 모르는 연못이면 버린다.
    func setIceBreak(_ b: PlazaIceBreak?, hit: TilePoint? = nil) {
        if let b, PlazaIce.accepted(b, now: now(), ponds: icePonds) == nil { return }
        iceBreak = b
        refreshIce(hit: hit)
    }

    private func refreshIce(hit: TilePoint?) {
        // 연못은 겨울에만 언다.
        let target = isSnowDay ? PlazaIce.frozenIndex(last: iceBreak, now: now(), ponds: icePonds) : nil
        freezeDue = isSnowDay && target == nil ? iceBreak.map { $0.at + PlazaIce.refreezeDelay } : nil
        guard target != frozenIndex else { drawIce(); return }
        let old = frozenIndex
        frozenIndex = target
        if let old {
            if !isPaused, updateCount > 0, iceBreak?.pond == icePonds[old].anchor {
                finishBreak()
                let pond = icePonds[old]
                breaking = (old, hit.map(pond.nearestTile(to:)) ?? pond.center, 0)
            } else {
                sink(old)
            }
        }
        drawIce()
        onIceChange?()
    }

    private(set) var iceDrawCount = 0
    /// 얼어 가는 중이라 알파가 1 전이다. 가만히 선 얼음은 프레임마다 그리지 않게 한다.
    private var iceFading = false
    var shownCrackCount: Int { iceLayer?.shownCrackCount ?? 0 }
    var shownShardCount: Int { iceLayer?.shownShardCount ?? 0 }
    var iceLayerNodeCount: Int { iceLayer?.nodeCount ?? 0 }
    func iceAlpha(pondAnchor: TilePoint) -> CGFloat? {
        icePonds.firstIndex { $0.anchor == pondAnchor }.flatMap { iceLayer?.iceAlpha(pond: $0) }
    }

    func iceTextureID(pondAnchor: TilePoint) -> ObjectIdentifier? {
        icePonds.firstIndex { $0.anchor == pondAnchor }.flatMap { iceLayer?.iceTextureID(pond: $0) }
    }

    private func drawIce() {
        guard let iceLayer else { return }
        iceDrawCount += 1
        let alpha = PlazaIce.freezeAlpha(now: now(), last: iceBreak, ponds: icePonds)
        iceFading = frozenIndex != nil && alpha < 1
        iceLayer.show(frozen: frozenIndex, alpha: alpha, breaking: breaking)
    }

    /// 깨지는 중인 연못을 0.6초 전이어도 바로 가라앉히고 깨짐을 끝낸다.
    private func finishBreak() {
        guard let b = breaking else { return }
        breaking = nil
        if b.elapsed < PlazaIce.sinkAt { sink(b.pond) }
    }

    private func advanceIce(by dt: TimeInterval) {
        let drawn = breaking != nil
        if !landings.isEmpty {
            for i in landings.indices { landings[i].remaining -= dt }
            let due = landings.filter { $0.remaining <= 0 }
            landings.removeAll { $0.remaining <= 0 }
            for l in due { land(l.break, jumper: l.jumper) }
        }
        if var b = breaking {
            let before = b.elapsed
            b.elapsed += dt
            breaking = b
            if before < PlazaIce.sinkAt, b.elapsed >= PlazaIce.sinkAt {
                sink(b.pond)
                onIceChange?()
            }
            if b.elapsed >= PlazaIce.breakEnd { breaking = nil }
        }
        if let due = freezeDue, now().timeIntervalSince1970 >= due { refreshIce(hit: nil) }
        if breaking != nil || drawn || iceFading { drawIce() }
    }

    /// 점프한 사람(nil이면 나)이 선 칸을 깨진 연못 안으로 맞춰 알린다. 서 있는 칸을 모르면 연못 가운데다.
    private func land(_ b: PlazaIceBreak, jumper: String?) {
        guard let pond = icePonds.first(where: { $0.anchor == b.pond }) else { return }
        let shown = jumper.map { remotes[$0]?.motion.tile } ?? walker.tile
        onIceLanding?(b, shown.map(pond.nearestTile(to:)) ?? pond.center)
    }

    /// 깨는 점프가 땅에 닿을 때까지 줄을 세운다(0.36초). 멈춘 장면이거나 줄이 가득이면 바로 닿는다.
    func queueIceLanding(_ b: PlazaIceBreak, jumper: String?) {
        if isPaused || landings.count >= Self.maxIceLandings {
            land(b, jumper: jumper)
        } else {
            landings.append((b, jumper, PlazaActor.jumpDuration))
        }
    }

    func isIceLandingQueued(_ b: PlazaIceBreak) -> Bool { landings.contains { $0.break == b } }

    /// 멈추면 줄 선 착지를 모두 닿게 하고, 깨지는 중이면 바로 가라앉혀 끝낸다.
    private func finishIceNow() {
        let due = landings
        landings.removeAll()
        for l in due { land(l.break, jumper: l.jumper) }
        if breaking != nil {
            finishBreak()
            drawIce()
            onIceChange?()
        }
    }

    /// 그 연못에 선(걷는 중이면 도착할) 모두에게 큰 물보라. 멈춘 장면은 물보라 없이 알을 물가로 올린다.
    private func sink(_ pond: Int) {
        let p = icePonds[pond]
        if isPaused {
            climbOutNowIfPaused()
            return
        }
        if p.contains(walker.tile) { splash(at: walker.tile, big: true, stage: myEvolutionStage, splasher: nil) }
        for (id, r) in remotes where p.contains(r.motion.tile) {
            splash(at: r.motion.tile, big: true, stage: r.stage, splasher: id)
        }
    }

    /// `plunge`가 부른 점프를 아직 못 낸 걸음의 도착 칸. 그 걸음이 시작될 때 `update`가 낸다(진행 중인 땅 걸음이 끝나야 시작한다).
    private var plungeJumpOwed: TilePoint?

    /// 물보라 하나: 입자를 내고 땅에 선 배우를 젖게 한다. 연못 그림이 없거나 배경이 숨으면 아무것도 내지 않는다.
    private func splash(at tile: TilePoint, big: Bool, stage: Int, splasher: String?) {
        guard let layer = pondLayer, !isBackgroundHidden else { return }
        layer.splash(at: tile, big: big)
        let actors: [(id: String?, tile: TilePoint)] = [(nil, walker.tile)] + remotes.map { ($0.key, $0.value.motion.tile) }
        for id in PlazaPond.wetTargets(splash: tile, radius: big ? PlazaPond.splashRadius(stage: stage) : 1,
                                       splasher: splasher, actors: actors, isWater: { isWaterNow($0) }) {
            actor(id)?.showWet()
        }
    }

    /// 그 팀원이 잠수한 것으로 보인다: 지금 보이는 자리가 물일 때만. 자리 비움이면 쉼터 칸으로 옮겨져 물이 아니다.
    private func isShownDiving(_ r: Remote) -> Bool { r.diving && isWaterNow(r.motion.tile) }
    func memberIsDiving(_ id: String) -> Bool? { remotes[id].map(isShownDiving) }
    var myVisibleHeight: CGFloat { me.visibleSpriteHeight }
    func memberVisibleHeight(_ id: String) -> CGFloat? { remotes[id]?.actor.visibleSpriteHeight }
    var myActor: PlazaActor { me }
    func memberActor(_ id: String) -> PlazaActor? { remotes[id]?.actor }
    func memberSwimRingVisible(_ id: String) -> Bool? { remotes[id]?.actor.isSwimRingVisible }
    func memberSwimRingY(_ id: String) -> CGFloat? { remotes[id]?.actor.swimRingY }

    /// 시간이 다했거나 물 밖으로 나가면 내 잠수를 끝내고 알린다. 잠수 흐려짐을 흘리고 연못 레이어 시간을 흘린다.
    private func advancePond(by dt: TimeInterval) {
        if isDiving {
            diveElapsed += dt
            if diveElapsed >= diveLimit || !isMeInWater {
                splashSurfacing()
                isDiving = false
                // 물에서 나가며 끝난 잠수는 땅 칸을 먼저 알린다. 옛 물 칸에 '잠수 끝'만 가면 받는 쪽이 없던 떠오름을 그린다.
                if !isMeInWater { reportLocalPosition() }
                onDivingChange?(false)
            }
        }
        myDive.advance(toward: isDiving, dt: dt)
        watchPond(id: nil, stage: myEvolutionStage, tile: walker.tile, step: walker.currentStep, actor: me,
                  facing: walker.facing, diving: isDiving, dt: dt)
        for id in Array(remotes.keys) {
            guard let r = remotes[id] else { continue }
            remotes[id]?.dive.advance(toward: isShownDiving(r), dt: dt)
            watchPond(id: id, stage: r.stage, tile: r.motion.tile, step: r.motion.currentStep, actor: r.actor,
                      facing: r.motion.facing, diving: isShownDiving(r), dt: dt)
        }
        pondLayer?.update(dt: dt)
    }

    /// 한 배우의 연못 기록을 한 프레임 흘리고, 땅→물 착지의 큰 물보라·땅 점프 착지의 작은 물보라·잠수 거품을 낸다.
    private func watchPond(id: String?, stage: Int, tile: TilePoint, step: PlazaStep?, actor: PlazaActor,
                           facing: PlazaDirection, diving: Bool, dt: TimeInterval) {
        guard pondLayer != nil else { return }
        var watch: PondWatch
        if let id {
            guard let theirs = remotes[id]?.pond else { return }
            watch = theirs
        } else {
            watch = myPond
        }
        let events = watch.advance(tile: tile, step: step, lift: actor.jumpLift, facing: facing, diving: diving, dt: dt,
                                   isWater: { isWaterNow($0) })
        if let id { remotes[id]?.pond = watch } else { myPond = watch }
        if let landed = events.landedInWater { splash(at: landed, big: true, stage: stage, splasher: id) }
        if let shore = events.shoreSplash { splash(at: shore, big: false, stage: stage, splasher: id) }
        if events.bubble { pondLayer?.bubble(at: tile) }
    }

    /// 헤엄 높이 자르기. 배경이 보이는 연못 그림일 때, 물 칸에 선 배우가 걷는 중이 아니거나 물에서 출발한 걸음일 때만 0보다 크다.
    /// 땅에서 뛰어드는 걸음은 물에 내려앉은 뒤에야 잘린다. 물에서 나오는 마지막 걸음은 도착 칸이 땅이라 걸음이 시작되면 바로 선 모습이다(헤엄치다 나오는 포켓몬과 같다. 일부러 그렇다).
    private func swimSink(tile: TilePoint, step: PlazaStep?, actor: PlazaActor) -> CGFloat {
        guard pondVisuals, !isBackgroundHidden, isWaterNow(tile), step.map({ isWaterNow($0.from) }) ?? true,
              actor.fullSpriteHeight > 0 else { return 0 }
        return PlazaPond.swimSink(spriteHeight: actor.fullSpriteHeight)
    }

    /// `foot` 아래 물 칸을 둘러싼 연못 사각형(장면 좌표, y 위로). 땅이면 nil이다. 연못은 늘 꽉 찬 사각형이다.
    func waterRect(foot: CGPoint) -> CGRect? {
        let ts = CGFloat(PlazaMap.tileSize)
        let t = TilePoint(x: Int(foot.x / ts), y: Int(foot.y / ts))
        guard isWaterNow(t) else { return nil }
        var x0 = t.x, x1 = t.x, y0 = t.y, y1 = t.y
        while isWaterNow(TilePoint(x: x0 - 1, y: t.y)) { x0 -= 1 }
        while isWaterNow(TilePoint(x: x1 + 1, y: t.y)) { x1 += 1 }
        while isWaterNow(TilePoint(x: t.x, y: y0 - 1)) { y0 -= 1 }
        while isWaterNow(TilePoint(x: t.x, y: y1 + 1)) { y1 += 1 }
        return CGRect(x: CGFloat(x0) * ts, y: worldSize.height - CGFloat(y1 + 1) * ts, width: CGFloat(x1 - x0 + 1) * ts, height: CGFloat(y1 - y0 + 1) * ts)
    }

    /// `waterRect`를 사진 좌표(월드, y 아래로)로 옮긴 값.
    private func photoWaterClip(foot: CGPoint) -> CGRect? {
        waterRect(foot: foot).map { CGRect(x: $0.minX, y: worldSize.height - $0.maxY, width: $0.width, height: $0.height) }
    }

    /// 땅에서는 걸을 수 있는 빈 칸만, 물속에서는 물 칸과 걸을 수 있는 땅 칸에 들어간다.
    private func canEnterTile(occupied: Set<TilePoint>) -> (TilePoint, TilePoint) -> Bool {
        { [unowned self] from, to in
            guard !occupied.contains(to) else { return false }
            return isWalkableNow(to) || (isWaterNow(from) && isWaterNow(to))
        }
    }

    /// 밀려 가는 걸음은 땅에서 물로도 들어간다(떨어진다). 빈 칸이어야 하고, 막힌 칸은 그대로 막는다.
    private func canPushTile(occupied: Set<TilePoint>) -> (TilePoint, TilePoint) -> Bool {
        { [unowned self] _, to in !occupied.contains(to) && (isWalkableNow(to) || isWaterNow(to)) }
    }

    private var pondStepDuration: (TilePoint, TilePoint, Bool) -> TimeInterval {
        { [unowned self] from, to, running in
            PlazaPond.stepDuration(from: from, to: to, running: running, isWater: { isWaterNow($0) })
        }
    }

    /// 다른 팀원이 서 있는(걷는 중이면 도착할) 칸. 나는 이 칸에 들어가지 못한다. 이미 겹쳐 서 있으면 빠져나갈 수는 있다.
    /// 팀원 쪽 Mac도 같은 규칙으로 나를 피하므로 서로 겹치지 않는다(동시에 같은 칸에 들어가면 잠깐 겹칠 수 있다).
    func occupiedTiles(except id: String? = nil) -> Set<TilePoint> {
        Set(remotes.filter { $0.key != id && $0.key != pullerID }.map(\.value.motion.tile))
    }

    /// 물귀신이 나를 끌어들이는 동안 그 팀원: 물러나는 중인 그의 칸이 내 길을 막지 않는다. 미끄러짐이 끝나면 지워진다.
    private var pullerID: String?

    /// 길은 한 칸 갈 때마다 다시 찾는다. 팀원이 움직이거나 길을 막으면 바로 돌아간다(지도가 작아 금방 찾는다).
    private func advanceWalkToMember() {
        guard let id = autoWalk else { return }
        guard canWalk, let target = remotes[id]?.motion.tile else { return stopWalkingToMember() }
        if isOverlayOpen {
            if !isFollowing { stopWalkingToMember() }
            return
        }
        // 물속의 팀원은 따라갈 수 없고, 물속의 나는 길을 찾지 않는다.
        if isFollowing && isWaterNow(target) { return stopWalkingToMember() }
        guard !walker.isWalking else { return }
        if isMeInWater { return stopWalkingToMember() }
        if PlazaPathfinder.isAdjacent(walker.tile, target) {
            walker.face(PlazaPathfinder.direction(from: walker.tile, to: target))
            if !isFollowing { stopWalkingToMember() }
            return
        }
        let blocked = occupiedTiles()
        var goal = target
        var route = PlazaPathfinder.path(from: walker.tile, toNextTo: goal, map: map, blocked: blocked, isWalkable: isWalkableNow)
        if route == nil, isWaterNow(target),
           let edge = PlazaPond.nearestEdgeWater(to: target, from: walker.tile, isWater: { isWaterNow($0) }, isLand: { isWalkableNow($0) && !blocked.contains($0) }) {
            // 물 가운데의 팀원: 가장 가까운 테두리 물 칸 옆 땅까지만 간다.
            goal = edge
            if PlazaPathfinder.isAdjacent(walker.tile, edge) {
                walker.face(PlazaPathfinder.direction(from: walker.tile, to: edge))
                stopWalkingToMember()
                return
            }
            route = PlazaPathfinder.path(from: walker.tile, toNextTo: goal, map: map, blocked: blocked, isWalkable: isWalkableNow)
        }
        guard let first = route?.first else {
            // 따라가는 중이면 길이 트일 때까지 기다린다.
            if !isFollowing { stopWalkingToMember() }
            return
        }
        walker.step(first)
    }

    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func showEmote(memberID: String?, kind: TeamEmoteKind) {
        // 메타몽 복사본 소식은 말풍선이 아니다.
        guard kind != .decoyFound, kind != .decoyJump, let actor = actor(memberID) else { return }
        actor.showEmote(kind)
        layout()
    }

    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func showChat(memberID: String?, text: String) {
        guard let actor = actor(memberID) else { return }
        actor.showChat(text)
        layout()
    }

    /// 지금 화면에 보이는 영역(사진 모드면 프레임 안, `photoFrame ?? visibleRect`)을 기념사진 입력으로 모은다. 그림을 아직 못 받은 캐릭터는 뺀다(알과 자리 비움은 다른 팀원처럼 찍힌다).
    func photoInput() -> PlazaPhotoInput? {
        let rect = photoFrame ?? visibleRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        func pose(_ facing: PlazaDirection, _ isWalking: Bool) -> PlazaSpriteChoice {
            PlazaPose.choice(facing: facing, isWalking: isWalking, clock: clock)
        }
        var actors = [me.photoActor(foot: walker.footPoint, pose: pose(walker.facing, walker.isWalking), waterClip: photoWaterClip(foot: walker.footPoint))]
        for id in remotes.keys.sorted() {
            guard let r = remotes[id] else { continue }
            actors.append(r.actor.photoActor(foot: r.motion.footPoint, pose: pose(r.motion.facing, r.motion.isWalking),
                                          waterClip: photoWaterClip(foot: r.motion.footPoint)))
        }
        let tint = daylightTint
        return PlazaPhotoInput(mapImage: mapImage, visibleRect: rect, pixelsPerWorld: zoom * 2, actors: actors.compactMap { $0 },
                               tint: tint, weather: weatherLayer.photoParticles(worldHeight: worldSize.height),
                               items: itemPhotoParticles,
                               ice: iceLayer?.photoParticles() ?? [],
                               bands: tallGrassLayer?.photoBands(in: rect) ?? [],
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
        // 창이 가려져 멈춘 장면에서는 지우는 화면과 동작이 돌지 않아 쌓이기만 한다. 아래 몸통박치기와 점프도 같다.
        guard !isPaused, let actor = actor(memberID) else { return }
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

    /// 그 캐릭터(nil이면 나) 머리 위로 한 발이 올라가 터진다. 내 불꽃은 0.5초에 한 발까지 쏠 수 있다(앞의 불꽃이 떠 있어도 된다).
    /// 간격은 불꽃 층의 시간으로 재서 창이 멈추면 기다림도 멈춘다. 팀원의 불꽃은 그 팀원의 Mac이 막았으니 여기서는 막지 않는다.
    /// 터뜨리지 못했으면 false. 창이 가려져 멈춘 장면은 볼 수 없으니 터뜨리지 않는다.
    @discardableResult
    func playFirework(memberID: String?, style: String?) -> Bool {
        guard !isPaused, let actor = actor(memberID) else { return false }
        if memberID == nil, !fireworkLayer.canLaunchOwn { return false }
        let foot = memberID.flatMap { remotes[$0]?.motion.footPoint } ?? walker.footPoint
        let head = CGPoint(x: foot.x, y: worldSize.height - foot.y + actor.characterSize.height)
        // 양옆의 안내판과 목록이 덮는 폭은 빼고 본다. 멀리 있는 팀원의 불꽃이 그 뒤에서 터지면 보이지 않는다.
        let v = visibleRect, z = CGFloat(zoom)
        let left = PlazaShortcutGuide.coveredWidth / z, right = PlazaRosterMetrics.coveredWidth / z
        let burst = PlazaFireworks.burstPoint(head: head, visible: CGRect(x: v.minX + left, y: worldSize.height - v.maxY,
                                                                          width: v.width - left - right, height: v.height))
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
        showImpact(on: target, direction: direction)
    }

    /// 맞은 쪽 몸 가운데에서 민 쪽으로 조금 나온 곳에 터졌다 사라지는 충격 그림. 멈춘 장면에서는 그리지 않는다.
    private func showImpact(on target: String?, direction: PlazaDirection) {
        guard !isPaused, let hit = actor(target) else { return }
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

    /// 눈덩이를 던질 수 있는 자리: `interactionTiles`에서 잠수 중인 팀원을 뺀다.
    var snowballTargets: [String: TilePoint] {
        interactionTiles.filter { remotes[$0.key]?.diving != true }
    }

    /// 던진 쪽(nil = 나)이 뛰어들고 눈덩이 하나가 `shot`을 따라 난다. 멈췄거나 가득 찼으면 아무것도 그리지 않고 `onLand`를 바로 부른다.
    /// 닿을 때 맞으면 충격 그림, 물에 빠지면 작은 물보라가 먼저 나온 뒤 `onLand`가 불린다.
    func playSnowball(by thrower: String?, shot: PlazaSnowballShot, onLand: @escaping @MainActor () -> Void) {
        actor(thrower)?.lunge(toward: shot.direction)
        let unit: CGPoint = switch shot.direction {
        case .right: CGPoint(x: 1, y: 0)
        case .left: CGPoint(x: -1, y: 0)
        case .down: CGPoint(x: 0, y: 1)
        case .up: CGPoint(x: 0, y: -1)
        }
        func foot(_ t: TilePoint) -> CGPoint { PlazaWalker.footPoint(from: t, to: t, progress: 0) }
        let origin = foot(shot.from)
        let start = CGPoint(x: origin.x + unit.x * PlazaSnowball.handReach, y: origin.y + unit.y * PlazaSnowball.handReach)
        let end: CGPoint, endHeight: CGFloat, burst: PlazaSnowballFlight.Burst
        switch shot.end {
        case .actor(let id, let tile):
            let f = foot(tile)
            end = CGPoint(x: f.x - unit.x * PlazaSnowball.bodyInset, y: f.y - unit.y * PlazaSnowball.bodyInset)
            endHeight = PlazaSnowball.bodyHeight(spriteHeight: actor(id)?.characterSize.height ?? 0)
            burst = .air
        case .ground(let tile):
            end = foot(tile)
            endHeight = 0
            burst = isWaterNow(tile) ? .none : .ground
        }
        let effects: @MainActor () -> Void = { [weak self] in
            if let self, !self.isPaused {
                switch shot.end {
                case .actor(let id, let tile):
                    // 맞힌 자리에 더는 없으면(걸어서 피했다) 별 없이 공중에서 터지기만 한다.
                    let standing = id.map { self.remotes[$0]?.motion.tile } ?? self.walker.tile
                    if standing == tile { self.showImpact(on: id, direction: shot.direction) }
                case .ground(let tile): if self.isWaterNow(tile) { self.pondLayer?.splash(at: tile, big: false) }
                }
            }
        }
        let landing: @MainActor () -> Void = { effects(); onLand() }
        let flight = PlazaSnowballFlight(start: start, end: end, endHeight: endHeight, frames: shot.frames, burst: burst)
        // 멈췄거나 가득 찬 장면은 그림 없이 바로 닿은 것으로 친다. 가득 찬 뒤 몰려오는 프레임이 충격 노드를 만들지 못하게 한다.
        if isPaused || !snowballLayer.launch(flight, onLand: landing) { onLand() }
    }

    private static let impactName = "tackle-impact"
    private static let dustName = "jump-dust"

    // MARK: - 춤

    /// D. 새 판을 무작위 춤으로 시작한다(직전과 다른 춤). 춤은 멈출 때까지 판마다 새 춤으로 이어진다. 못 출 때(걷는 중, 물속, 집중 중, 멈춘 장면)는 아무것도 하지 않는다.
    private func pressDance() {
        guard canDance, !isDanceRoundTooSoon else { return }
        // 팀원의 춤을 이미 따라 추고 있으면 그대로 둔다. 판을 다시 시작하면 그 팀원과 동작이 어긋난다.
        if let lead = danceLeaderStyle(), me.dance?.style == lead { return }
        startLocalDanceRound(continuing: me.isDancing)
    }

    /// 새 판은 박자마다 한 번까지. 연타는(따라 추는 팀원의 소식이 몰려와도) 판을 다시 시작하지도 팀원에게 보내지도 않는다.
    private var isDanceRoundTooSoon: Bool {
        guard let last = lastDanceRoundAt else { return false }
        let since = now().timeIntervalSince(last)
        return since >= 0 && since < PlazaDance.beat - 1e-3   // 시계 값의 오차로 딱 한 박자 뒤 누름이 막히지 않게 한다
    }

    /// 내가 따라 추는 팀원의 새 판이 왔다. 내가 추는 중이면 같은 춤으로 내 판을 다시 시작해 동작까지 맞춘다. 팀원에게도 내 새 판으로 보낸다.
    func followDance(_ style: PlazaDance.Style) {
        guard me.isDancing, canDance, !isDanceRoundTooSoon else { return }
        startLocalDanceRound(following: style, continuing: true)
    }

    /// 내가 마지막으로 새 판을 시작한 시각(장면의 `now`).
    private var lastDanceRoundAt: Date?

    /// 내가 지금 추는 춤을 시작한 시각(판이 이어져도 그대로다). 춤을 멈춘 뒤에는 지난 값이 남아 있다.
    private(set) var danceStartedAt: Date?

    /// 지금 내가 춤을 시작할 수 있다. 알은 춘다. 풀숲도 괜찮다. 걸을 참이어도(기다리는 걸음, 따라가지 않는 걸어가기) 못 춘다.
    var canDance: Bool {
        !isPaused && !walker.isWalking && !walker.hasPendingMove && !(autoWalk != nil && !isFollowing)
            && !isMeInWater && !isDiving && !isFocusing()
    }

    /// 따라 출 팀원이 근처에서 추고 있으면 그 춤을, 아니면 무작위 춤을 춘다. 따라 추는 판은 팀원 춤처럼 다음 판 소식을 조금 더
    /// 기다린다(소식이 격자보다 조금 늦게 오므로, 안 기다리면 그 사이에 내 판이 먼저 끝나 지난 춤으로 한 번 더 시작한다).
    /// `continuing`이 아니면(안 추다가 D를 누름) 지금이 춤을 시작한 시각이 된다. 누구를 따를지가 이 시각으로 정해지므로 먼저 정한다.
    private func startLocalDanceRound(following: PlazaDance.Style? = nil, continuing: Bool) {
        if !continuing || danceStartedAt == nil { danceStartedAt = now() }
        let lead = following ?? danceLeaderStyle()
        let style = lead ?? pickDanceStyle(lastDanceStyle)
        lastDanceStyle = style
        lastDanceRoundAt = now()
        beginDance(me, style: style, remote: lead != nil)
        onDanceRound?(style.id)
    }

    /// 판을 박자 격자에 맞춰 시작한다(♪는 배우가 띄운다). 시계는 장면의 `now`라, 따로 시작해도 같은 박자에 뛴다.
    /// 팀원 춤은 도착한 때부터 다음 판 소식을 `remoteGrace`만큼 더 기다린다(격자가 아니라 도착 시각 기준이라 늘 한 박자 여유가 있다).
    private func beginDance(_ actor: PlazaActor, style: PlazaDance.Style, remote: Bool) {
        let offset = PlazaDance.gridOffset(at: now())
        actor.startDance(style, offset: offset, length: remote ? offset + PlazaDance.round + PlazaDance.remoteGrace : PlazaDance.round)
        layout()
    }

    /// 팀원이 춤을 춘다. 소식 하나가 한 판이고, 다음 소식이 없으면 한 판 + 여유 뒤에 끝난다. 모르는 팀원, 물속이나 잠수 중, 멈춘 장면이면 false.
    /// 움직이는 중이면 지금은 false지만, 한 박자 안에 멈추면 그때 시작한다(걸음을 막 마친 팀원의 춤이 소식보다 먼저 와서 버려지지 않게).
    /// 새 춤이 기다리던 춤을 갈아 끼운다. 모르는 이름의 춤은 좌우 흔들기다. 집중 중인지는 컨트롤러가 먼저 가린다.
    @discardableResult
    func playDance(memberID: String, style: String?) -> Bool {
        guard !isPaused, let r = remotes[memberID], !isWaterNow(r.motion.tile) else { return false }
        let chosen = PlazaDance.Style.style(id: style)
        if r.motion.isWalking {
            pendingDances[memberID] = (chosen, PlazaDance.beat)
            return false
        }
        pendingDances[memberID] = nil
        beginDance(r.actor, style: chosen, remote: true)
        return true
    }

    /// 걷는 중에 받아 멈추기를 기다리는 팀원의 춤과 남은 시간. 노드를 만들지 않는 값 하나라 몰려와도 팀원 수를 넘지 않는다.
    private var pendingDances: [String: (style: PlazaDance.Style, remaining: TimeInterval)] = [:]

    /// 기다리던 춤을, 그 팀원이 멈췄으면 시작하고 한 박자가 지났으면 버린다.
    private func advancePendingDances(by dt: TimeInterval) {
        for (id, pending) in pendingDances {
            guard let r = remotes[id], !isPaused, !isWaterNow(r.motion.tile) else { pendingDances[id] = nil; continue }
            if !r.motion.isWalking {
                pendingDances[id] = nil
                beginDance(r.actor, style: pending.style, remote: true)
            } else if pending.remaining - dt <= 0 {
                pendingDances[id] = nil
            } else {
                pendingDances[id]?.remaining -= dt
            }
        }
    }

    /// 그 캐릭터(nil이면 나)의 춤을 멈춘다. 떠 있던 ♪도 지운다.
    func stopDance(memberID: String?) {
        if let memberID { pendingDances[memberID] = nil }   // 걸으며 기다리던 춤도 버린다
        actor(memberID)?.stopDance()
    }

    private func stopAllDances() {
        me.stopDance()
        for r in remotes.values { r.actor.stopDance() }
        pendingDances.removeAll()
    }

    /// 걷기 시작했거나 물에 든 캐릭터의 춤을 끊는다. 밀림, 뛰어들기, 물가로 올라오기 같은 모든 이유를 한 곳에서 잡는다.
    private func stopMovingDancers() {
        if walker.isWalking || isMeInWater { me.stopDance() }
        for r in remotes.values where r.motion.isWalking || isWaterNow(r.motion.tile) { r.actor.stopDance() }
    }

    /// 내 판이 저절로 끝났으면 새 춤으로 이어 춘다. 못 이으면 그대로 끝난다.
    private func continueDance() {
        guard me.takeFinishedDance(), canDance else { return }
        startLocalDanceRound(continuing: true)
    }

    /// 그 캐릭터(nil이면 나)의 춤과 자세.
    func isDancing(memberID: String?) -> Bool { actor(memberID)?.isDancing ?? false }
    func danceStyle(memberID: String?) -> PlazaDance.Style? { actor(memberID)?.dance?.style }
    func dancePose(memberID: String?) -> PlazaDancePose? { actor(memberID)?.dancePose }

    /// 기도: 그 캐릭터 위에 기도 말풍선이 뜨고 그림이 좌우로 흔들린다. 새 노드를 만들지 않아 멈춘 장면에서도 쌓이지 않는다.
    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func playPray(memberID: String?) {
        guard let actor = actor(memberID) else { return }
        actor.wobble()
        showEmote(memberID: memberID, kind: .pray)
    }

    /// 점프: 그 캐릭터가 위로 폴짝 뛰고, 뛸 때와 내려올 때 발밑에서 먼지가 양옆으로 퍼진다. `memberID`가 nil이면 나.
    func playJump(memberID: String?) {
        guard !isPaused, let actor = actor(memberID) else { return }
        actor.jump()
        puffDust(under: memberID)
        run(.sequence([.wait(forDuration: PlazaActor.jumpDuration), .run { [weak self] in self?.puffDust(under: memberID) }]))
    }

    private func puffDust(under memberID: String?) {
        guard actor(memberID) != nil else { return }
        // 내가 뛰어드는 걸음을 막 시작했다면 먼지는 떠난 땅 칸에서 인다(walker.tile은 이미 도착할 물 칸이다).
        let tile = memberID.flatMap { remotes[$0]?.motion.tile } ?? walker.currentStep?.from ?? walker.tile
        if isWaterNow(tile) { return }   // 물 위에는 먼지가 일지 않는다
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
    func wobbleTilt(memberID: String?) -> CGFloat? { actor(memberID)?.wobbleTilt }
    func isWet(memberID: String?) -> Bool? { actor(memberID)?.isWet }
    /// 테스트용: 떠 있는 충격 그림 수와 내가 뛰어든 만큼.
    var impactCount: Int { children.filter { $0.name == Self.impactName }.count }
    func lungeOffset(memberID: String?) -> CGPoint? { actor(memberID)?.lungeOffset }

    /// 몸통박치기에 맞아 `tiles`칸 밀린다. 막힌 칸을 만나면 그 앞에 서고, 땅에서 물로 떨어지면 그 첫 물 칸에서 끝난다(큰 물보라).
    /// 헤엄치는 중에도 밀리고 물 칸을 지나 땅까지 밀려 나올 수 있지만, 잠수 중에는 밀리지 않는다. 알도 밀린다.
    /// 창이 가려져 장면이 멈춰 있으면(`isPaused`) 다음 화면이 오지 않으므로 그 자리에서 다 밀리고 팀원에게 바로 알린다.
    func pushMe(_ d: PlazaDirection, tiles: Int = 1, pulledBy puller: String? = nil) {
        guard !isDiving else { return }
        pullerID = puller
        let occupied = occupiedTiles()
        let canEnter = canPushTile(occupied: occupied)
        var reach = 0
        var at = walker.tile
        while reach < tiles {
            let next = PlazaWalker.offset(at, d)
            guard canEnter(at, next) else { break }
            reach += 1
            let fell = !isWaterNow(at) && isWaterNow(next)
            at = next
            if fell { break }
        }
        guard reach > 0 else { return }
        stopDance(memberID: nil)
        walker.push(d, tiles: reach)
        guard isPaused else { return }
        walker.advance(by: PlazaPond.plungeStepDuration * Double(reach), canEnterFrom: canEnterTile(occupied: occupied),
                       canPushInto: canEnter, stepDuration: pondStepDuration)
        reportLocalPosition()   // 먼저 빠진 칸을 알려 팀원이 첨벙을 본 뒤 올라오는 것을 본다
        climbOutNowIfPaused()
    }

    /// 장면이 멈춰 있는데(`isPaused`) 알이 물에 있으면 `update`가 오지 않으므로 그 자리에서 가장 가까운 물가까지 올라와 팀원에게 알린다.
    /// 올라올 빈 물가가 없으면 물에 남고 장면이 다시 돌 때 `update`가 맡는다. 
    private func climbOutNowIfPaused() {
        guard isPaused, !canWalk, !isDiving, isMeInWater else { return }
        for _ in 0..<64 {   // 걸음마다 물 칸을 하나씩 벗어나니 이 정도면 충분하다(끝없이 돌지 않게 하는 상한)
            var stepped = false
            if !walker.isWalking {
                guard isMeInWater else { break }
                let taken = occupiedTiles()
                guard let d = PlazaPond.stepAshore(from: walker.tile, isWater: { isWaterNow($0) },
                                                   isLand: { isWalkableNow($0) && !taken.contains($0) }) else { break }
                walker.step(d)
                stepped = true
            }
            let occupied = occupiedTiles()
            let before = walker.tile
            walker.advance(by: 2, canEnterFrom: canEnterTile(occupied: occupied), canPushInto: canPushTile(occupied: occupied),
                           stepDuration: pondStepDuration)
            if stepped, walker.tile == before { break }   // 길 위 물 칸에 팀원이 있어 못 간다: 더 돌지 않고 물에 남는다
        }
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
    private static let vKeyCode: UInt16 = 9
    private static let gKeyCode: UInt16 = 5
    private static let fKeyCode: UInt16 = 3
    private static let dKeyCode: UInt16 = 2
    private static let aKeyCode: UInt16 = 0
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
        advanceIce(by: dt)
        let modifiers = currentModifiers()
        if modifiers.contains(.command) { walker.releaseAll(); panKeys.removeAll() }
        if let c = photoCenter {
            let speed = modifiers.contains(.shift) ? PlazaPhotoFrame.fastPanSpeed : PlazaPhotoFrame.panSpeed
            let dx = (panKeys.contains(.right) ? 1 : 0) - (panKeys.contains(.left) ? 1 : 0)
            let dy = (panKeys.contains(.down) ? 1 : 0) - (panKeys.contains(.up) ? 1 : 0)
            if dx != 0 || dy != 0 {
                // 지도 안으로 잘린 채 보이는 중심에서 밀고 다시 자른다. 가장자리에서 더 민 만큼을 쌓지 않는다.
                // 확대·창 크기 변경은 저장한 중심을 건드리지 않아야 돌아왔을 때 틀이 제자리다(그래서 자르기는 여기서만 저장한다).
                let from = photoShownCenter ?? c
                let moved = CGPoint(x: from.x + CGFloat(dx) * speed * CGFloat(dt), y: from.y + CGFloat(dy) * speed * CGFloat(dt))
                photoCenter = PlazaPhotoFrame.layout(center: moved, viewport: size, zoom: zoom, backingScale: backingOverride ?? view?.window?.backingScaleFactor ?? 2,
                                                     world: worldSize)?.center ?? moved
            }
        }
        // 방향키와 Shift를 함께 누르고 있거나, 따라가는 팀원이 달리면 달린다. Shift만으로는 달리지 않아,
        // 따라가며 한마디에 대문자를 쳐도 달리지 않는다.
        walker.wantsToRun = (modifiers.contains(.shift) && walker.isHoldingKey)
            || (followingMember.flatMap { remotes[$0]?.motion.senderIsRunning } ?? false)
        if !canWalk {
            walker.clearInput()
            // 알은 헤엄치지 못한다. 헤엄치다 알이 됐으면(졸업, 놓아주기, 대표 포켓몬 해제) 가장 가까운 물가로 저절로 올라온다.
            if isMeInWater, !walker.isWalking {
                let taken = occupiedTiles()
                if let d = PlazaPond.stepAshore(from: walker.tile, isWater: { isWaterNow($0) },
                                                isLand: { isWalkableNow($0) && !taken.contains($0) }) {
                    walker.step(d)
                }
            }
        }
        advanceWalkToMember()
        let occupied = occupiedTiles()
        walker.advance(by: dt, canEnterFrom: canEnterTile(occupied: occupied), canPushInto: canPushTile(occupied: occupied),
                       stepDuration: pondStepDuration)
        if pullerID != nil, !walker.hasPendingMove, !walker.isWalking { pullerID = nil }
        if let owed = plungeJumpOwed, let step = walker.currentStep, step.to == owed {
            plungeJumpOwed = nil
            playJump(memberID: nil)
        }
        advanceAnimation(by: dt)
        advanceTallGrass(by: dt)
        advanceFootprints(by: dt)
        snowballLayer.advance(by: dt)
        advancePond(by: dt)
        advanceSparkles(by: dt)
        fireworkLayer.advance(by: dt, tint: appliedTint, firelight: firelight(at:))
        applyDaylight()
        advanceCampfire(by: dt)
        layout()
        advanceWeather(by: dt)
        refreshSnowDay()
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

    /// 칸의 아이템은 칸이 끝날 때까지 같으니 칸이 바뀔 때만 다시 센다.
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
        weatherLayer.update(weather: season.weather, isHidden: isBackgroundHidden, dt: dt,
                            visible: CGRect(x: v.minX, y: worldSize.height - v.maxY, width: v.width, height: v.height),
                            step: PlazaPixelSnap.step(backing: backing, zoom: zoom))
    }

    /// 그 계절의 지도와 풀숲 그림. 컨트롤러가 넣고, 원본 그대로인 계절(여름)이거나 그림을 못 만들면 nil이라 원본을 쓴다.
    var seasonLook: (PlazaSeason) -> PlazaSnowLook? = { _ in nil }
    /// 보이는 계절이 바뀌었다.
    var onSeasonChange: ((PlazaSeason) -> Void)?
    /// 지금이 겨울인가(눈이 오고 발자국이 찍히고 연못이 언다). 배경을 숨겨도 그대로다.
    var isSnowDay: Bool { season == .winter }
    /// `refreshSnowDay`가 마지막으로 적용한 계절. 처음 지도는 원본(여름)이다.
    private(set) var shownSeason = PlazaSeason.summer
    var isSnowShown: Bool { shownSeason == .winter }
    /// 테스트용: 지금 그리는 지도 그림.
    var shownMapImage: CGImage { mapImage }

    private static let waterBalloon = PlazaResources.waterBalloon()

    /// 계절과 보이는 모습을 맞춘다. `update`(달력을 따르는 계절은 날이 바뀌며 바뀐다)와 계절 변경, 컨트롤러가 부른다.
    func refreshSnowDay() {
        let s = season
        guard s != shownSeason else { return }
        var image = normalMapImage
        var grass = normalTallGrass
        if let look = seasonLook(s) {
            image = look.mapImage
            grass = look.tallGrass ?? normalTallGrass
        }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        mapNode.texture = texture
        mapImage = image
        iceLayer?.setMapImage(image)
        if let grass { tallGrassLayer?.setArt(grass) }
        shownSeason = s
        snowballLayer.setArt(PlazaSnowballArt.pieces(s, balloon: PlazaScene.waterBalloon))
        if s != .winter { footprintLayer.removeAll() }
        refreshIce(hit: nil)
        onSeasonChange?(s)
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
        stopMovingDancers()
        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        me.animate(by: dt, useBack: pose.useBack)
        for id in Array(remotes.keys) {
            // 쉼터에서 어슬렁거리는 팀원도 나와 다른 팀원이 선 칸으로는 옮기지 않는다.
            // `remotes`를 읽는 값은 먼저 구한다. 같은 식 안에서 고치는 원소와 함께 읽으면 접근 충돌로 멈춘다.
            let blocked = occupiedTiles(except: id).union([walker.tile])
            remotes[id]?.advance(by: dt, blocked: blocked, stepDuration: pondStepDuration)
            guard let r = remotes[id] else { continue }
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.animate(by: dt, useBack: p.useBack)
        }
        continueDance()
        advancePendingDances(by: dt)
    }

    /// 눈 오는 날, 끝난 걸음마다 발자국을 찍고 레이어 시간을 흘린다. 밀려 간 걸음은 찍지 않는다.
    private func advanceFootprints(by dt: TimeInterval) {
        var ended: [(from: TilePoint, to: TilePoint)] = []
        if let e = myPrintWatch.advance(step: walker.currentStep, sliding: walker.isSliding) { ended.append(e) }
        for id in Array(remotes.keys) {
            guard let r = remotes[id] else { continue }
            var watch = r.printWatch
            if let e = watch.advance(step: r.motion.currentStep, sliding: r.isBouncing) { ended.append(e) }
            remotes[id]?.printWatch = watch
        }
        if isSnowShown, !isBackgroundHidden {
            for e in ended { footprintLayer.stamp(PlazaSnow.footprints(from: e.from, to: e.to, map: map)) }
        }
        footprintLayer.advance(by: dt)
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
    /// 잠수로 가려진 정도와 `max`로 합친다. 연못 그림이 꺼져 있으면(배경 숨김 포함) 잠수는 가리지 않는다.
    private func concealment(tile: TilePoint, step: PlazaStep?, actor: PlazaActor, dive: CGFloat) -> CGFloat {
        let grass = PlazaTallGrass.concealment(tile: tile, step: step, jumpLift: actor.jumpLift) { [tallGrassLayer] in tallGrassLayer?.isGrass($0) ?? false }
        return pondVisuals && !isBackgroundHidden ? max(grass, dive) : grass
    }

    /// 카메라, 캐릭터, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다.
    private func layout() {
        let z = CGFloat(zoom)
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2

        let foot = walker.footPoint
        var rect: CGRect
        photoFrame = nil
        photoShownCenter = nil
        if let c = photoCenter, let photo = PlazaPhotoFrame.layout(center: c, viewport: size, zoom: zoom, backingScale: backing, world: worldSize) {
            rect = photo.visible
            photoFrame = photo.frame
            photoShownCenter = photo.center
        } else {
            // 큰 포켓몬의 머리가 잘리지 않게 앞모습 높이의 절반만큼 위를 본다(앞모습 기준이라 돌아봐도 카메라가 흔들리지 않는다).
            let lift = me.cameraLift
            let focus = PlazaCamera.focus(for: foot, viewportWidth: size.width, rightInset: PlazaRosterMetrics.coveredWidth,
                                          characterHalfWidth: me.characterSize.width * z / 2, zoom: zoom, lift: lift)
            rect = PlazaCamera.visibleRect(focus: focus, viewport: size, zoom: zoom, backingScale: backing, world: worldSize,
                                           rightInset: PlazaRosterMetrics.coveredWidth)
        }
        visibleRect = rect
        let cameraPos = CGPoint(x: rect.midX, y: worldSize.height - rect.midY)   // 원점은 visibleRect가 이미 기기 격자에 맞췄다
        cameraNode.position = cameraPos
        cameraNode.setScale(1 / z)

        let pose = PlazaPose.choice(facing: walker.facing, isWalking: walker.isWalking, clock: clock)
        let context = PlazaActorContext(worldHeight: worldSize.height, cameraPosition: cameraPos,
                                        zoom: zoom, backing: backing, viewport: size)
        me.place(foot: foot, pose: pose, in: context,
                 concealment: concealment(tile: walker.tile, step: walker.currentStep, actor: me, dive: myDive.level), isMe: true,
                 swimSink: swimSink(tile: walker.tile, step: walker.currentStep, actor: me), waterRect: waterRect(foot: foot))
        for r in remotes.values {
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.place(foot: r.motion.footPoint, pose: p, in: context,
                          concealment: concealment(tile: r.motion.tile, step: r.motion.currentStep, actor: r.actor, dive: r.dive.level),
                          swimSink: swimSink(tile: r.motion.tile, step: r.motion.currentStep, actor: r.actor),
                          waterRect: waterRect(foot: r.motion.footPoint))
        }
    }

    /// 내 화면에 보이는 팀원 자리(걷는 중이면 도착할 칸, 자리 비움은 쉼터 칸). 표적 찾기에 쓴다.
    var memberTiles: [String: TilePoint] {
        remotes.filter { $0.key != PlazaDitto.sceneKey }.mapValues { $0.motion.tile }
    }
    /// 말을 걸 수 있는 자리: 팀원 자리에 팀원 흉내를 내는 동안의 메타몽을 더한다. 메타몽 모습은 `interactionTiles`에만 든다.
    var targetTiles: [String: TilePoint] {
        var tiles = memberTiles
        if let tile = decoyTile { tiles[PlazaDitto.sceneKey] = tile }
        return tiles
    }
    /// 스페이스와 몸통박치기의 대상 자리: `targetTiles`에 메타몽 모습의 메타몽을 더한다. 메타몽 모습에게는 몸통박치기만 할 수 있고,
    /// 박치기하면 그 사람으로 변한다. 인사, 말풍선 표적, 따라가기는 `targetTiles`를 쓴다.
    var interactionTiles: [String: TilePoint] {
        var tiles = targetTiles
        if let tile = dittoTile { tiles[PlazaDitto.sceneKey] = tile }
        return tiles
    }
    /// 테스트용
    func memberFoot(_ id: String) -> CGPoint? { remotes[id]?.motion.footPoint }
    func memberName(_ id: String) -> String? { remotes[id]?.displayName }
    func memberNameColor(_ id: String) -> CGColor? { remotes[id]?.color }
    func memberIsAway(_ id: String) -> Bool? { remotes[id]?.isAway }
    func shownChat(memberID: String?) -> String? { actor(memberID)?.chatText }
    func shownEmote(memberID: String?) -> TeamEmoteKind? { actor(memberID)?.emoteKind }
    func emoteFrame(memberID: String?) -> CGRect? { actor(memberID)?.emoteFrame }
    func memberNamePlateTop(_ id: String) -> CGFloat? { remotes[id]?.actor.namePlateTop }
    func memberTitle(_ id: String) -> String? { remotes[id]?.actor.title }
    func memberZ(_ id: String) -> CGFloat? { remotes[id]?.actor.characterZ }
    var myOpacity: CGFloat { me.characterOpacity }
    var myShadowOpacity: CGFloat { me.shadowOpacity }
    var myNamePlateTop: CGFloat { me.namePlateTop }
    var myTitle: String? { me.title }
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

/// 광장 메타몽이 지금 보여줄 모습. 이름·색·칭호는 호출하는 쪽이 정해 넘긴다.
struct PlazaDittoShown: Equatable {
    var tile: TilePoint
    var facing: PlazaDirection
    var isWalking: Bool
    var isRunning: Bool
    var isBouncing: Bool = false
    var name: String
    var nameColor: CGColor
    var title: String?
    var isDecoy: Bool
}
