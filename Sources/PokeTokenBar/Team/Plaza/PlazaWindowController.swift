import AppKit
import SpriteKit

/// 그리기 루프를 멈출 수 있는 뷰. 테스트에서 창 없이 바꿔 끼운다.
@MainActor protocol PlazaPausableView: AnyObject { var isPaused: Bool { get set } }
extension SKView: PlazaPausableView {}

/// 광장 창. 창을 만들지 않고도 장면을 만들 수 있게(`prepareScene`) 나눠 두었다.
@MainActor final class PlazaWindowController: NSObject, NSWindowDelegate {
    private let map = PlazaMapData.map
    private let session: TeamSession?
    private let preferences: PlazaPreferences
    private let loader: PlazaCharacterLoader
    private let nickname: () -> String
    private let memberID: () -> String
    private let subject: () -> CompanionStore.RepresentativeSubject
    private let myRosterEntry: () -> PlazaRosterEntry?
    private let rosterModel = PlazaRosterModel()
    private let clock: () -> Date
    /// 말풍선 연타 제한: 마지막으로 받아들인 키의 시각부터 잰다.
    static let emoteInterval: TimeInterval = 0.3
    private var lastEmoteAt: Date?

    /// 창 위치·크기 기억용 이름. 사용자에게 보이는 글이 아니다.
    private static let frameAutosaveName = "TeamPlazaWindow"

    /// 프로세스에서 한 번만 만든다. 다시 열 때(와 테스트마다) 메인 스레드에서 지도를 다시 그리지 않는다. 앱의 지도는 하나뿐이다.
    /// 시트를 못 읽으면 단색 잔디로 대신한다.
    private static var cachedMapImage: CGImage?

    private var mapImage: CGImage {
        if let cached = Self.cachedMapImage { return cached }
        let image = PlazaResources.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0) } ?? PlazaTileArt.plainGrassImage(map)
        Self.cachedMapImage = image
        return image
    }

    private var window: NSWindow?
    private var skView: SKView?
    /// 가려지면 멈추는 그리기 루프. 창을 열면 `skView`가 들어간다.
    var renderLoop: (any PlazaPausableView)?
    private var refreshGeneration = 0
    /// 팀원 관찰의 세대. 닫거나 다시 열면 올려서 낡은 관찰 콜백을 버린다.
    private var membersGeneration = 0
    private var members: [String: TeamMemberState] = [:]
    /// 팀원별로 마지막에 받으러 간 캐릭터와 그 요청 번호(낡은 결과를 버린다).
    private var memberSubjects: [String: CompanionStore.RepresentativeSubject] = [:]
    private var memberLoadTokens: [String: Int] = [:]
    private var nextLoadToken = 0
    /// 장면에 들어간 팀원 그림의 종 번호를 순서대로 남긴다(테스트용 읽기 전용).
    private var appliedMemberLoads: [(id: String, speciesID: Int?)] = []
    /// 닫혀 있으면 nil
    private(set) var scene: PlazaScene?

    init(preferences: PlazaPreferences,
         loader: PlazaCharacterLoader,
         nickname: @escaping () -> String,
         memberID: @escaping () -> String,
         subject: @escaping () -> CompanionStore.RepresentativeSubject,
         myRosterEntry: @escaping () -> PlazaRosterEntry? = { nil },
         session: TeamSession? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.clock = clock
        self.preferences = preferences
        self.loader = loader
        self.nickname = nickname
        self.memberID = memberID
        self.subject = subject
        self.myRosterEntry = myRosterEntry
        super.init()
    }

    /// 창이 없으면 만들고, 앱을 앞으로 가져와 창을 앞에 둔다. 이미 열려 있으면 앞으로만.
    func show() {
        if window == nil {
            prepareScene()
            guard let scene else { return }
            let view = SKView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
            view.ignoresSiblingOrder = true
            let w = NSWindow(contentRect: view.frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L(.ko).plazaWindowTitle
            w.contentMinSize = NSSize(width: 480, height: 320)
            w.isReleasedWhenClosed = false
            w.level = .normal
            w.delegate = self
            let container = NSView(frame: view.frame)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            let roster = PlazaRosterHostingView(rootView: PlazaRosterView(model: rosterModel))
            roster.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(roster)   // SKView 위. 입력은 받지 않고 SKView가 첫 응답자를 유지한다.
            NSLayoutConstraint.activate([
                roster.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
                roster.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlazaRosterMetrics.margin),
                roster.widthAnchor.constraint(equalToConstant: PlazaRosterMetrics.width),
            ])
            w.contentView = container
            w.center()
            rosterModel.capacity = PlazaRoster.capacity(forHeight: container.bounds.height)
            w.setFrameAutosaveName(Self.frameAutosaveName)   // center 뒤에 불러야 저장된 위치가 이긴다
            view.presentScene(scene)
            w.makeFirstResponder(view)
            skView = view
            renderLoop = view
            window = w
            Task { await refreshCharacter() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 창 없이 장면만 만든다.
    func prepareScene() {
        guard scene == nil else { return }
        let s = PlazaScene(map: map, mapImage: mapImage,
                           start: preferences.lastTile(validIn: map),
                           zoom: preferences.zoom, nickname: nickname())
        s.setNameColor(PlazaNameColor.color(forMemberID: memberID()))
        s.canWalk = subject().speciesID != nil
        s.onZoomChange = { [preferences] in preferences.zoom = $0 }
        s.onCloseRequest = { [weak self] in self?.window?.performClose(nil) }
        s.onEmoteKey = { [weak self] in self?.handleEmoteKey($0) }
        scene = s
        if let session {
            sendPosition(inPlaza: true, scene: s)
            s.onLocalPositionChange = { [weak self] _, _, _ in
                guard let self, let scene = self.scene else { return }
                self.sendPosition(inPlaza: true, scene: scene)
            }
            membersGeneration += 1
            observeMembers(session: session, generation: membersGeneration)
        }
        refreshRoster()
    }

    /// 내 말풍선은 바로 띄운다. ♥, ㅋㅋ, 🎉는 바라보는 팀원을 표적으로 보내고, !, ?는 표적 없이 보낸다.
    private func handleEmoteKey(_ kind: TeamEmoteKind) {
        guard let scene else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.showEmote(memberID: nil, kind: kind)
        let target = kind.notifiesTarget
            ? PlazaTargeting.member(from: scene.walker.tile, facing: scene.walker.facing, members: scene.memberTiles) : nil
        session?.sendEmote(kind, target: target)
    }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다.
    func showEmote(memberID: String, kind: TeamEmoteKind) {
        scene?.showEmote(memberID: memberID, kind: kind)
    }

    private func sendPosition(inPlaza: Bool, scene: PlazaScene) {
        session?.updatePlazaPosition(inPlaza: inPlaza, tile: scene.walker.tile, facing: scene.walker.facing,
                                     isWalking: scene.walker.isWalking)
    }

    /// 다시 등록을 먼저 하고 값을 반영한다(그 사이 변경을 놓치지 않는다). 세대가 바뀌었으면 끝낸다.
    private func observeMembers(session: TeamSession, generation: Int) {
        guard generation == membersGeneration else { return }
        let current = withObservationTracking {
            session.members
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMembers(session: session, generation: generation) }
        }
        members = current
        applyMembersToScene()
        refreshRoster()
    }

    private func applyMembersToScene() {
        guard let scene else { return }
        let list = members.values.sorted { $0.memberID < $1.memberID }
        scene.applyMembers(list.map {
            PlazaSceneMember(memberID: $0.memberID, nickname: $0.nickname, isAway: !$0.inPlaza, tile: $0.tile,
                             facing: $0.facing ?? .down, isWalking: $0.isWalking)
        })
        let ids = Set(members.keys)
        for id in memberSubjects.keys where !ids.contains(id) {
            memberSubjects[id] = nil
            memberLoadTokens[id] = nil
        }
        for m in list {
            let subject = CompanionStore.RepresentativeSubject(speciesID: m.character.speciesID, isShiny: m.character.isShiny,
                                                               form: m.character.form)
            guard memberSubjects[m.memberID] != subject else { continue }
            memberSubjects[m.memberID] = subject
            nextLoadToken += 1
            let token = nextLoadToken
            memberLoadTokens[m.memberID] = token
            Task { await loadMemberFrames(m.memberID, subject: subject, token: token) }
        }
    }

    private func loadMemberFrames(_ id: String, subject: CompanionStore.RepresentativeSubject, token: Int) async {
        let frames = await loader.frames(for: subject)
        guard memberLoadTokens[id] == token, let scene else { return }
        scene.setMemberFrames(id, frames)
        appliedMemberLoads.append((id, subject.speciesID))
    }

    func appliedMemberSpecies(_ id: String) -> [Int?] { appliedMemberLoads.filter { $0.id == id }.map(\.speciesID) }

    /// 지금 대표 포켓몬 그림을 다시 받아 장면에 넣는다. 장면이 없으면 아무것도 안 한다.
    func refreshCharacter() async {
        guard let current = scene else { return }
        // 그림 로딩을 기다리지 않고 바로 반영한다(알이면 지금 걷는 칸만 마치고 선다).
        current.canWalk = subject().speciesID != nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let frames = await loader.frames(for: subject())
        // 기다리는 동안 닫혔거나 더 새 요청이 있었으면 버린다.
        guard generation == refreshGeneration, let scene else { return }
        scene.setCharacter(frames)
    }

    func refreshNickname() {
        scene?.setNickname(nickname())
        refreshRoster()
    }

    /// 내 칸을 다시 만들어 목록에 넣는다. 창이 닫혀 있으면 아무것도 안 한다.
    func refreshRoster() {
        guard window != nil || scene != nil else { return }
        let next = PlazaRoster.entries(me: myRosterEntry(), members: Array(members.values))
        if next != rosterModel.entries { rosterModel.entries = next }
    }

    /// 테스트용 읽기 전용 값.
    var rosterEntries: [PlazaRosterEntry] { rosterModel.entries }
    var rosterIsAnimating: Bool { rosterModel.isAnimating }

    /// 마지막 칸을 저장하고 장면과 창 내용을 해제해 그리기를 멈춘다.
    func handleClose() {
        persistState()
        if let scene, session != nil {
            session?.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
            scene.onLocalPositionChange = nil
        }
        membersGeneration += 1
        members = [:]
        memberSubjects = [:]
        memberLoadTokens = [:]
        appliedMemberLoads = []
        if let scene {
            scene.releaseAllKeys()
            scene.isPaused = true
            scene.onZoomChange = nil
            scene.onCloseRequest = nil
            scene.onEmoteKey = nil
        }
        skView?.presentScene(nil)
        skView = nil
        renderLoop = nil
        scene = nil
        rosterModel.entries = []
        rosterModel.isAnimating = true
        refreshGeneration += 1
        if let w = window {
            w.delegate = nil
            w.contentView = nil
        }
        window = nil
    }

    /// 장면이 있으면 지금 칸을 저장한다. 아무것도 해제하지 않는다(앱 종료 때도 부른다).
    /// 창이 있으면 닫는다(`performClose`). 팀 준비가 풀릴 때 부른다.
    func closeIfOpen() {
        window?.performClose(nil)
    }

    func persistState() {
        if let scene { preferences.saveLastTile(scene.walker.tile) }
    }

    /// 최소화·완전히 가려진 동안은 그리지 않는다.
    func setRendering(visible: Bool) {
        rosterModel.isAnimating = visible
        renderLoop?.isPaused = !visible
        guard let scene else { return }
        if !visible { scene.releaseAllKeys() }
        scene.isPaused = !visible
    }

    /// 눌린 키를 모두 뗀다.
    func handleResignKey() {
        scene?.releaseAllKeys()
    }

    func windowDidResize(_ notification: Notification) {
        guard let height = window?.contentView?.bounds.height else { return }
        rosterModel.capacity = PlazaRoster.capacity(forHeight: height)
    }
    func windowDidMiniaturize(_ notification: Notification) { setRendering(visible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { setRendering(visible: true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        setRendering(visible: window?.occlusionState.contains(.visible) ?? true)
    }
    func windowWillClose(_ notification: Notification) { handleClose() }
    func windowDidResignKey(_ notification: Notification) { handleResignKey() }
}
