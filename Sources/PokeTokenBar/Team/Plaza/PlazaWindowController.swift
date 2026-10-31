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
    private let profileTimeout: Duration
    private let overlayModel = PlazaOverlayModel()
    private let feed: TeamFeedStore?
    /// 큰 소식 배너를 보여 주는 시간.
    static let bannerDuration: Duration = .seconds(4)
    private let bannerSleep: @MainActor (Duration) async -> Void
    /// 배너를 새로 띄우거나 창을 닫을 때마다 올린다. 낡은 타이머가 새 배너를 지우지 못하게 한다.
    private var bannerGeneration = 0
    private var bannerTask: Task<Void, Never>?
    /// 안 읽은 소식 관찰의 세대. 닫거나 다시 열면 올려서 낡은 관찰 콜백을 버린다.
    private var unreadGeneration = 0
    /// 판을 열거나 닫을 때마다 올린다. 닫힌 뒤(또는 다른 판이 뜬 뒤) 도착한 카드 결과를 버린다.
    private var overlayGeneration = 0
    /// 말풍선 연타 제한: 마지막으로 받아들인 키의 시각부터 잰다.
    static let emoteInterval: TimeInterval = 0.3
    private var lastEmoteAt: Date?
    /// 사진 PNG를 내보낸다. 성공하면 true. 테스트가 클립보드를 건드리지 않게 바꿔 끼운다.
    private let photoWriter: (Data) -> Bool

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
         feed: TeamFeedStore? = nil,
         clock: @escaping () -> Date = Date.init,
         photoWriter: @escaping (Data) -> Bool = PlazaWindowController.writePhotoToClipboard,
         profileTimeout: Duration = .seconds(5),
         bannerSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.session = session
        self.feed = feed
        self.bannerSleep = bannerSleep
        self.profileTimeout = profileTimeout
        self.clock = clock
        self.photoWriter = photoWriter
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
            let overlay = PlazaOverlayHostingView(rootView: PlazaOverlayView(model: overlayModel, feed: feed, myMemberID: memberID(),
                                                                       onReact: { [weak self] in self?.session?.react(to: $0, kind: $1) }),
                                                model: overlayModel)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)   // 목록 위. 마우스만 받고 SKView가 첫 응답자를 유지한다.
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
        s.onInteractKey = { [weak self] in self?.handleInteractKey() }
        s.onPhotoKey = { [weak self] in self?.handlePhotoKey() }
        s.onCloseOverlay = { [weak self] in self?.closeOverlay() }
        scene = s
        if let feed {
            unreadGeneration += 1
            observeUnread(feed: feed, generation: unreadGeneration)
        }
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

    /// 보이는 장면을 사진으로 합성해 클립보드에 PNG로 넣고 번쩍인다. 합성이나 인코딩이 실패하면 클립보드를 그대로 두고 번쩍이지 않는다.
    private func handlePhotoKey() {
        guard let scene, let input = scene.photoInput(), let png = PlazaPhotoRenderer.pngData(for: input) else { return }
        if photoWriter(png) { scene.playShutterFlash() }
    }

    nonisolated private static func writePhotoToClipboard(_ png: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }

    /// 바라보는 대상에 말을 건다. 소식판이면 소식판을 열고(열 때 모두 읽음), 팀원이면 카드를 받아 띄운다.
    private func handleInteractKey() {
        guard let scene,
              let target = PlazaInteraction.target(from: scene.walker.tile, facing: scene.walker.facing, map: map,
                                                   members: scene.memberTiles) else { return }
        switch target {
        case .board:
            feed?.markAllRead()
            openOverlay(.board)
        case .member(let id):
            guard let session, let state = members[id] else { return }
            let generation = openOverlay(.card(.loading(state)))
            Task {
                let profile = await session.requestProfile(memberID: id, timeout: profileTimeout)
                guard generation == overlayGeneration else { return }
                overlayModel.content = .card(profile.map { .loaded(state, $0) } ?? .failed(state))
            }
        }
    }

    @discardableResult
    private func openOverlay(_ content: PlazaOverlayContent) -> Int {
        overlayGeneration += 1
        overlayModel.content = content
        scene?.isOverlayOpen = true
        return overlayGeneration
    }

    private func closeOverlay() {
        if overlayModel.content == .board { feed?.markAllRead() }
        overlayGeneration += 1
        overlayModel.content = .none
        scene?.isOverlayOpen = false
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 앱이 앞이고 광장 창이 키 창이다. 알림 대신 광장 안 안내를 쓸지 가른다.
    var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true }

    /// 테스트용 읽기 전용 값.
    var overlayContent: PlazaOverlayContent { overlayModel.content }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다.
    func showEmote(memberID: String, kind: TeamEmoteKind) {
        scene?.showEmote(memberID: memberID, kind: kind)
    }

    /// 큰 소식 연출: 쓴 사람 위에 반짝임, 위쪽에 배너. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다. 진화는 연출하지 않는다.
    func showBigEvent(_ e: TeamEvent) {
        guard let scene, e.kind.isBig else { return }
        scene.playSparkle(memberID: e.authorID == memberID() ? nil : e.authorID)
        showBanner(L(.ko).teamEventText(e))
    }

    /// 배너를 띄우고 4초 뒤 지운다. 그 사이 새 배너가 오면 새 배너가 처음부터 4초를 받는다.
    func showBanner(_ text: String) {
        guard scene != nil else { return }
        bannerTask?.cancel()
        bannerGeneration += 1
        let generation = bannerGeneration
        overlayModel.banner = text
        bannerTask = Task { [weak self] in
            guard let self else { return }
            await self.bannerSleep(Self.bannerDuration)
            guard !Task.isCancelled, generation == self.bannerGeneration else { return }
            self.overlayModel.banner = nil
        }
    }

    /// 테스트용 읽기 전용 값.
    var banner: String? { overlayModel.banner }

    /// 다시 등록을 먼저 하고 값을 반영한다. 안 읽은 소식이 있으면 소식판 위에 `!`를 띄운다.
    private func observeUnread(feed: TeamFeedStore, generation: Int) {
        guard generation == unreadGeneration else { return }
        let unread = withObservationTracking {
            feed.unreadCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUnread(feed: feed, generation: generation) }
        }
        scene?.setBoardMarker(visible: unread > 0)
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
        refreshMyEntry()
    }

    /// 내 칸은 도감 전체를 훑어 만들므로 캐시한다. 내 쪽이 바뀔 때(`refreshMyEntry`)와 창을 열 때만 다시 만든다.
    private var myEntryCache: PlazaRosterEntry??

    /// 내 대표·닉네임이 바뀌었을 때 내 칸을 다시 만들어 목록에 넣는다.
    func refreshMyEntry() {
        myEntryCache = nil
        refreshRoster()
    }

    /// 목록을 다시 만든다. 내 칸은 캐시를 쓴다. 창이 닫혀 있으면 아무것도 안 한다.
    func refreshRoster() {
        guard window != nil || scene != nil else { return }
        let me = myEntryCache ?? myRosterEntry()
        myEntryCache = .some(me)
        let next = PlazaRoster.entries(me: me, members: Array(members.values))
        if next != rosterModel.entries { rosterModel.entries = next }
    }

    /// 테스트용 읽기 전용 값.
    var rosterEntries: [PlazaRosterEntry] { rosterModel.entries }
    var rosterIsAnimating: Bool { rosterModel.isAnimating }

    /// 마지막 칸을 저장하고 장면과 창 내용을 해제해 그리기를 멈춘다.
    func handleClose() {
        if overlayModel.content == .board { feed?.markAllRead() }
        persistState()
        bannerTask?.cancel()
        bannerTask = nil
        bannerGeneration += 1
        overlayModel.banner = nil
        unreadGeneration += 1
        if let scene, session != nil {
            session?.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
            scene.onLocalPositionChange = nil
        }
        membersGeneration += 1
        overlayGeneration += 1
        overlayModel.content = .none
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
            scene.onInteractKey = nil
            scene.onPhotoKey = nil
            scene.onCloseOverlay = nil
            scene.isOverlayOpen = false
        }
        skView?.presentScene(nil)
        skView = nil
        renderLoop = nil
        scene = nil
        rosterModel.entries = []
        rosterModel.isAnimating = true
        myEntryCache = nil
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
