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
}

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
    /// 키 1–5. 한글 입력기에서는 문자가 달라지므로 keyCode로만 판정한다.
    var onEmoteKey: ((TeamEmoteKind) -> Void)?
    /// 스페이스. 판이 닫혀 있을 때만 온다.
    var onInteractKey: (() -> Void)?
    /// 판이 열린 동안 Esc와 스페이스.
    var onCloseOverlay: (() -> Void)?
    /// 판이 열리면 방향키와 말풍선 키를 무시하고 눌린 키를 놓는다. Cmd+W는 그대로 창을 닫는다.
    var isOverlayOpen = false {
        didSet { if isOverlayOpen && !oldValue { walker.clearInput() } }
    }
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

    /// 팀원 한 명의 장면 쪽 상태. 그림은 내 캐릭터와 같은 `PlazaActor`를 쓴다.
    private struct Remote {
        let actor: PlazaActor
        let color: CGColor
        var nickname: String
        var isAway: Bool
        var motion: PlazaRemoteMotion
        var wanderer: PlazaShelterWanderer?

        var displayName: String { Self.displayName(nickname, isAway: isAway) }

        static func displayName(_ nickname: String, isAway: Bool) -> String {
            isAway ? nickname + " " + L(.ko).plazaAwaySuffix : nickname
        }

        mutating func advance(by dt: TimeInterval) {
            if let moved = wanderer?.advance(by: dt) { motion.moveTo(moved) }
            motion.advance(by: dt)
        }
    }

    private var remotes: [String: Remote] = [:]
    private var lastReported: (tile: TilePoint, facing: PlazaDirection, isWalking: Bool)
    /// 칸, 방향, 걷는 중 여부가 바뀔 때만 부른다.
    var onLocalPositionChange: ((TilePoint, PlazaDirection, Bool) -> Void)?

    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0

    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String) {
        self.map = map
        self.worldSize = map.pixelSize
        self.walker = PlazaWalker(tile: start)
        self.lastReported = (start, .down, false)
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
                if !m.isAway { r.motion.facing = m.facing }
                r.nickname = m.nickname
                r.actor.setName(r.displayName, color: r.color)
                remotes[m.memberID] = r
            } else {
                let color = PlazaNameColor.color(forMemberID: m.memberID)
                let wanderer = m.isAway ? shelterWanderer(m.memberID) : nil
                var motion = PlazaRemoteMotion(tile: wanderer?.tile ?? target, facing: m.facing)
                motion.senderIsWalking = !m.isAway && m.isWalking
                let r = Remote(actor: PlazaActor(name: Remote.displayName(m.nickname, isAway: m.isAway), color: color),
                               color: color, nickname: m.nickname, isAway: m.isAway, motion: motion, wanderer: wanderer)
                r.actor.attach(world: self, camera: cameraNode)
                remotes[m.memberID] = r
            }
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
            // 판이 열린 동안에는 닫는 키만 듣는다. 이후 키 분기(사진 등)도 이 아래에 둔다.
            if (keyCode == Self.escapeKeyCode || keyCode == Self.spaceKeyCode) && !isRepeat { onCloseOverlay?() }
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
        if let d = Self.direction(keyCode) {
            // Command+방향키는 keyUp이 오지 않아 계속 걷게 되므로 무시한다.
            if canWalk && !isRepeat && !modifiers.contains(.command) { walker.press(d) }
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

    /// `memberID`가 nil이면 나. 모르는 팀원이면 아무것도 안 한다.
    func showEmote(memberID: String?, kind: TeamEmoteKind) {
        guard let actor = actor(memberID) else { return }
        actor.showEmote(kind)
        layout()
    }

    private func actor(_ memberID: String?) -> PlazaActor? {
        guard let memberID else { return me }
        return remotes[memberID]?.actor
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let wKeyCode: UInt16 = 13
    private static let spaceKeyCode: UInt16 = 49

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
        reportLocalPosition()
    }

    private func reportLocalPosition() {
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
            remotes[id]?.advance(by: dt)
            guard let r = remotes[id] else { continue }
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.animate(by: dt, useBack: p.useBack)
        }
    }

    /// 카메라, 캐릭터, 이름표 위치를 정한다. 위치는 기기 픽셀 단위로 맞춘다.
    private func layout() {
        let z = CGFloat(zoom)
        let backing = backingOverride ?? view?.window?.backingScaleFactor ?? 2

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
        let context = PlazaActorContext(worldHeight: worldSize.height, cameraPosition: cameraPos,
                                        zoom: zoom, backing: backing, viewport: size)
        me.place(foot: foot, pose: pose, in: context)
        for r in remotes.values {
            let p = PlazaPose.choice(facing: r.motion.facing, isWalking: r.motion.isWalking, clock: clock)
            r.actor.place(foot: r.motion.footPoint, pose: p, in: context)
        }
    }

    /// 내 화면에 보이는 팀원 자리(걷는 중이면 도착할 칸, 자리 비움은 쉼터 칸). 표적 찾기에 쓴다.
    var memberTiles: [String: TilePoint] { remotes.mapValues { $0.motion.tile } }
    /// 테스트용
    func memberFoot(_ id: String) -> CGPoint? { remotes[id]?.motion.footPoint }
    func memberName(_ id: String) -> String? { remotes[id]?.displayName }
    func memberNameColor(_ id: String) -> CGColor? { remotes[id]?.color }
    func shownEmote(memberID: String?) -> TeamEmoteKind? { actor(memberID)?.emoteKind }
    func emoteFrame(memberID: String?) -> CGRect? { actor(memberID)?.emoteFrame }
    func memberNamePlateTop(_ id: String) -> CGFloat? { remotes[id]?.actor.namePlateTop }
    func memberZ(_ id: String) -> CGFloat? { remotes[id]?.actor.characterZ }

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
