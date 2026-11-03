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
    /// 지금 팀의 저장된 이름. 창 제목에 붙인다.
    private let teamName: () -> String?
    /// 내가 고른 이름 색. nil이면 멤버 ID의 색.
    private let nameColor: () -> UInt32?
    /// 고른 이름 색을 저장한다(팀 설정). 팀원에게는 세션이 보낸다.
    private let chooseNameColor: (UInt32) -> Void
    /// 내 광장 캐릭터의 진화 단계(1부터). 몸통박치기가 미는 칸 수다.
    private let evolutionStage: () -> Int
    private let nameColorModel = PlazaNameColorModel()
    private let rosterModel = PlazaRosterModel()
    private let clock: () -> Date
    private let profileTimeout: Duration
    private let overlayModel = PlazaOverlayModel()
    private let feed: TeamFeedStore?
    /// 큰 소식 배너를 보여 주는 시간.
    static let bannerDuration: Duration = .seconds(4)
    private let bannerSleep: @MainActor (Duration) async -> Void
    private let spriteRetrySleep: @MainActor (Duration) async -> Void
    /// A failed sprite request is made again after this long, while the plaza stays open.
    static let spriteRetryDelay: Duration = .seconds(30)
    /// 뒷모습은 원래 없는 그림일 수 있어(404와 오프라인을 구분할 수 없다) 몇 번만 다시 묻는다.
    static let backRetryLimit = 3
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
    private var lastChatAt: Date?
    private var lastLoudAt: Date?
    static let loudInterval: TimeInterval = 60
    private let minimap = PlazaMinimapModel()
    private let chatInput = PlazaChatInput()
    private let chatLog = PlazaChatLog()
    private let backgroundModel = PlazaBackgroundModel()
    /// 입력창이 열리면 대화 기록을 입력창 위로 올린다.
    private var chatLogAboveInput: NSLayoutConstraint?
    private var chatLogAtBottom: NSLayoutConstraint?
    /// 사진 PNG를 내보낸다. 성공하면 true. 테스트가 클립보드를 건드리지 않게 바꿔 끼운다.
    private let photoWriter: (Data) -> Bool
    /// 인사하기로 띄우는 말풍선. 누를 때마다 이 가운데 하나를 고른다.
    static let greetingKinds: [TeamEmoteKind] = [.heart, .party]
    /// 테스트에서 고정한다.
    private let greetingKind: () -> TeamEmoteKind

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
         teamName: @escaping () -> String? = { nil },
         nameColor: @escaping () -> UInt32? = { nil },
         chooseNameColor: @escaping (UInt32) -> Void = { _ in },
         evolutionStage: @escaping () -> Int = { 1 },
         session: TeamSession? = nil,
         feed: TeamFeedStore? = nil,
         clock: @escaping () -> Date = Date.init,
         photoWriter: @escaping (Data) -> Bool = PlazaWindowController.writePhotoToClipboard,
         greetingKind: @escaping () -> TeamEmoteKind = { PlazaWindowController.greetingKinds.randomElement() ?? .heart },
         profileTimeout: Duration = .seconds(5),
         bannerSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         spriteRetrySleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.spriteRetrySleep = spriteRetrySleep
        self.session = session
        self.feed = feed
        self.bannerSleep = bannerSleep
        self.profileTimeout = profileTimeout
        self.clock = clock
        self.photoWriter = photoWriter
        self.greetingKind = greetingKind
        self.preferences = preferences
        self.loader = loader
        self.nickname = nickname
        self.memberID = memberID
        self.subject = subject
        self.myRosterEntry = myRosterEntry
        self.teamName = teamName
        self.nameColor = nameColor
        self.chooseNameColor = chooseNameColor
        self.evolutionStage = evolutionStage
        super.init()
        chatInput.onSubmit = { [weak self] in self?.submitChat($0) ?? true }
        chatInput.onClose = { [weak self] in
            guard let self else { return }
            setChatLogAboveInput(false)
            refreshHint()
            if let skView { window?.makeFirstResponder(skView) }
        }
    }

    /// 창이 없으면 만들고, 앱을 앞으로 가져와 창을 앞에 둔다. 이미 열려 있으면 앞으로만.
    func show() {
        if window == nil {
            prepareScene()
            guard let scene else { return }
            let view = SKView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
            view.ignoresSiblingOrder = true
            view.allowsTransparency = true   // 배경 숨기기
            let w = NSWindow(contentRect: view.frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = title
            w.contentMinSize = NSSize(width: 600, height: 320)   // 왼쪽 아래 대화 기록과 오른쪽 아래 작은 지도가 겹치지 않는 폭
            w.isReleasedWhenClosed = false
            w.level = .normal
            w.delegate = self
            let container = NSView(frame: view.frame)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            let roster = PlazaRosterHostingView(rootView: PlazaRosterView(model: rosterModel, onSelect: { [weak self] in
                self?.walkToMember($0)
            }))
            roster.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(roster)   // SKView 위. 입력은 받지 않고 SKView가 첫 응답자를 유지한다.
            NSLayoutConstraint.activate([
                roster.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
                roster.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlazaRosterMetrics.margin),
                roster.widthAnchor.constraint(equalToConstant: PlazaRosterMetrics.width),
            ])
            let overlay = PlazaOverlayHostingView(rootView: PlazaOverlayView(model: overlayModel, feed: feed, myMemberID: memberID(),
                                                                       onReact: { [weak self] in self?.session?.react(to: $0, kind: $1) },
                                                                       onMenuChoose: { [weak self] in self?.chooseMenu($0, memberID: $1) },
                                                                       onMenuCancel: { [weak self] in self?.closeOverlay() }),
                                                model: overlayModel)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)   // 목록 위. 마우스만 받고 SKView가 첫 응답자를 유지한다.
            let chatLogView = PlazaChatLogHostingView(rootView: PlazaChatLogView(log: chatLog, toggle: { [weak self] in
                self?.toggleChatLog()
            }), log: chatLog)
            chatLogView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(chatLogView)   // 입력은 받지 않는다.
            let map = PlazaMinimapHostingView(rootView: PlazaMinimapView(
                model: minimap, background: backgroundModel, mapImage: NSImage(cgImage: mapImage, size: .zero),
                worldSize: self.map.pixelSize))
            map.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(map)   // 입력은 받지 않는다.
            let clock = PlazaClockHostingView(rootView: PlazaClock())
            clock.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(clock)   // 입력은 받지 않는다.
            let shortcuts = PlazaShortcutGuideHostingView(rootView: PlazaShortcutGuide())
            shortcuts.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shortcuts)   // 입력은 받지 않는다.
            let toggle = PlazaBackgroundToggleHostingView(rootView: PlazaBackgroundToggle(
                model: backgroundModel, toggle: { [weak self] in self?.toggleBackground() }))
            toggle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toggle)
            let colorPicker = PlazaNameColorPickerHostingView(rootView: PlazaNameColorPicker(
                model: nameColorModel, toggle: { [weak self] in self?.toggleNameColorPicker() },
                choose: { [weak self] in self?.pickNameColor($0) }))
            colorPicker.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(colorPicker)
            let chatBar = chatInput.view
            chatBar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(chatBar)   // 판 위. 열린 동안에만 입력창이 첫 응답자가 된다.
            let chatLogAtBottom = chatLogView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
            self.chatLogAtBottom = chatLogAtBottom
            chatLogAboveInput = chatLogView.bottomAnchor.constraint(equalTo: chatBar.topAnchor, constant: -8)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                chatBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
                chatBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                chatBar.widthAnchor.constraint(equalToConstant: PlazaChatLog.width),
                chatLogView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                chatLogAtBottom,
                map.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlazaRosterMetrics.margin),
                map.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
                clock.trailingAnchor.constraint(equalTo: map.trailingAnchor),
                clock.bottomAnchor.constraint(equalTo: map.topAnchor, constant: -6),
                toggle.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
                toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PlazaRosterMetrics.margin),
                shortcuts.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
                shortcuts.leadingAnchor.constraint(equalTo: toggle.leadingAnchor),
                colorPicker.topAnchor.constraint(equalTo: toggle.topAnchor),
                colorPicker.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 8),
            ])
            w.contentView = container
            w.center()
            Self.restoreFrame(w, into: rosterModel)
            view.presentScene(scene)
            w.makeFirstResponder(view)
            skView = view
            renderLoop = view
            window = w
            applyBackground()
            Task { await refreshCharacter() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 창 제목. 팀 이름이 바뀌면 `refreshTitle`로 다시 붙인다.
    var title: String { L(.ko).plazaWindowTitle(teamName: teamName()) }

    func refreshTitle() {
        window?.title = title
    }

    /// 저장된 창 크기를 되살린 뒤에 목록 칸 수를 잰다. 되살리는 동안의 windowDidResize 는 `window` 가 아직 nil 이라 못 잰다.
    static func restoreFrame(_ w: NSWindow, into roster: PlazaRosterModel, autosaveName: String = frameAutosaveName) {
        w.setFrameAutosaveName(autosaveName)   // center 뒤에 불러야 저장된 위치가 이긴다
        roster.capacity = PlazaRoster.capacity(forHeight: w.contentView?.bounds.height ?? 0)
    }

    /// 창 없이 장면만 만든다.
    func prepareScene() {
        guard scene == nil else { return }
        let s = PlazaScene(map: map, mapImage: mapImage,
                           start: preferences.lastTile(validIn: map),
                           zoom: preferences.zoom, nickname: nickname())
        s.setNameColor(PlazaNameColor.color(forMemberID: memberID(), chosen: nameColor()))
        nameColorModel.current = PlazaNameColor.hex(forMemberID: memberID(), chosen: nameColor())
        nameColorModel.isOpen = false
        s.canWalk = subject().speciesID != nil
        s.onZoomChange = { [weak self, preferences] in
            preferences.zoom = $0
            self?.refreshMinimap()
        }
        s.onCloseRequest = { [weak self] in self?.window?.performClose(nil) }
        s.onEmoteKey = { [weak self] in self?.handleEmoteKey($0) }
        s.onInteractKey = { [weak self] in self?.handleInteractKey() }
        s.onPhotoKey = { [weak self] in self?.handlePhotoKey() }
        s.onJumpKey = { [weak self] in self?.handleJumpKey() }
        s.onGreetKey = { [weak self] in
            if let self, let id = self.faceNearbyMember() { self.greet(id) }
        }
        s.onTackleKey = { [weak self] in
            if let self, let id = self.faceNearbyMember() { self.tackle(id) }
        }
        s.onChatKey = { [weak self] in self?.openChat() }
        s.onInteractionTargetChange = { [weak self] _ in self?.refreshHint() }
        s.onFollowChange = { [weak self] _ in self?.refreshHint() }
        s.setBackgroundHidden(preferences.isBackgroundHidden)
        backgroundModel.isHidden = preferences.isBackgroundHidden
        s.onOverlayKey = { [weak self] in self?.handleOverlayKey($0) }
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
                self.refreshMinimap()
            }
            membersGeneration += 1
            observeMembers(session: session, generation: membersGeneration)
        }
        refreshRoster()
        refreshMinimap()
        s.refreshInteractionTarget()
    }

    /// 내 말풍선은 바로 띄운다. ♥, ㅋㅋ, 🎉는 바라보거나 바로 옆에 있는 팀원을 표적으로 보내고, !, ?는 표적 없이 보낸다.
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

    private func openChat() {
        guard let scene else { return }
        scene.clearInput()
        chatInput.open()
        refreshHint()
        setChatLogAboveInput(true)
        window?.makeFirstResponder(chatInput.field)
    }

    private func setChatLogAboveInput(_ above: Bool) {
        chatLogAtBottom?.isActive = !above
        chatLogAboveInput?.isActive = above
    }

    /// 이름 색 팔레트를 펼치거나 접는다. 누른 뒤에도 키는 장면이 받는다.
    func toggleNameColorPicker() {
        nameColorModel.isOpen.toggle()
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 고른 색을 저장하고 내 이름표에 바로 칠한 뒤 팔레트를 접는다. 팀원에게는 세션이 다음 위치 소식으로 보낸다.
    func pickNameColor(_ hex: UInt32) {
        chooseNameColor(hex)
        nameColorModel.current = PlazaNameColor.hex(forMemberID: memberID(), chosen: hex)
        nameColorModel.isOpen = false
        scene?.setNameColor(PlazaNameColor.color(forMemberID: memberID(), chosen: hex))
        refreshMinimap()
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 테스트용 읽기 전용 값.
    var isNameColorPickerOpen: Bool { nameColorModel.isOpen }
    var shownNameColor: UInt32 { nameColorModel.current }

    /// 지도와 바탕을 숨기거나 되살린다. 창도 투명하게 바꿔 뒤의 작업 화면이 비치게 한다.
    func toggleBackground() {
        preferences.isBackgroundHidden.toggle()
        applyBackground()
        if let skView { window?.makeFirstResponder(skView) }
    }

    private func applyBackground() {
        let hidden = preferences.isBackgroundHidden
        backgroundModel.isHidden = hidden
        scene?.setBackgroundHidden(hidden)
        guard let window else { return }
        window.isOpaque = !hidden
        window.backgroundColor = hidden ? .clear : .windowBackgroundColor
        window.hasShadow = !hidden
    }

    /// 테스트용 읽기 전용 값.
    var chatLogLines: [PlazaChatLog.Line] { chatLog.lines }
    var isBackgroundHidden: Bool { backgroundModel.isHidden }

    /// 내 말풍선은 바로 띄운다. 보낼 글이 없으면 true(입력창을 닫는다), 너무 빠르면 false(글을 남겨 둔다).
    private func submitChat(_ raw: String) -> Bool {
        guard let scene, let text = TeamChat.prepared(raw) else { return true }
        let now = clock()
        let loud = chatInput.isLoud
        if let last = lastChatAt, now.timeIntervalSince(last) < Self.emoteInterval { return false }
        if loud, let last = lastLoudAt, now.timeIntervalSince(last) < Self.loudInterval {
            showBanner(L(.ko).plazaLoudTooSoon)
            return false
        }
        lastChatAt = now
        if loud { lastLoudAt = now }
        scene.showChat(memberID: nil, text: text)
        chatLog.append(time: now, name: nickname(), text: text, color: scene.nameColor, isLoud: loud)
        session?.sendChat(text, loud: loud)
        if loud { showBanner(L(.ko).teamMegaphoneNotice(nickname: nickname(), text: text)) }
        return true
    }

    /// 떠 있는 동안 또 뛰지 않는다.
    private var lastJumpAt: Date?

    /// 나를 폴짝 뛰게 하고 팀원들에게 보낸다. 내려오기 전에는 다시 뛰지 않는다.
    private func handleJumpKey() {
        guard let scene else { return }
        let now = clock()
        if let last = lastJumpAt, now.timeIntervalSince(last) < PlazaActor.jumpDuration { return }
        lastJumpAt = now
        scene.playJump(memberID: nil)
        session?.sendEmote(.jump, target: nil)
    }

    /// X와 C가 메뉴 없이 바로 할 팀원. 말풍선 키와 같이 바라보거나 바로 옆에 있는 팀원이고, 옆이면 그쪽으로 돌아선다.
    /// 옆에 팀원이 없으면 nil이라 아무것도 하지 않는다.
    private func faceNearbyMember() -> String? {
        guard let scene else { return nil }
        let me = scene.walker.tile
        guard let id = PlazaTargeting.member(from: me, facing: scene.walker.facing, members: scene.memberTiles),
              let tile = scene.memberTiles[id] else { return nil }
        if PlazaPathfinder.isAdjacent(me, tile) { scene.face(PlazaPathfinder.direction(from: me, to: tile)) }
        return id
    }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다.
    func showJump(memberID: String) {
        scene?.playJump(memberID: memberID)
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

    /// 바라보거나 바로 옆에 있는 대상에 말을 건다. 그쪽으로 돌아선 뒤, 소식판이면 소식판을 열고(열 때 모두 읽음),
    /// 팀원이면 인사하기와 포켓몬 보기 메뉴를 띄운다.
    private func handleInteractKey() {
        guard let scene,
              let hit = PlazaInteraction.target(from: scene.walker.tile, facing: scene.walker.facing, map: map,
                                                members: scene.memberTiles) else { return }
        scene.face(hit.facing)
        switch hit.target {
        case .board:
            feed?.markAllRead()
            openOverlay(.board)
        case .member(let id):
            guard let state = members[id] else { return }
            var menu = PlazaMemberMenu(memberID: id, nickname: state.nickname, nameColor: state.nameColor)
            if scene.canWalk == false { menu.actions.removeAll { $0 == .follow } }
            openOverlay(.memberMenu(menu))
        }
    }

    /// 소식판과 카드는 스페이스와 Esc로 닫는다. 메뉴는 방향키로 고르고 스페이스나 Enter로 하고 Esc로 닫는다.
    private func handleOverlayKey(_ key: PlazaOverlayKey) {
        switch overlayModel.content {
        case .none:
            break
        case .board, .card:
            if key == .space || key == .escape { closeOverlay() }
        case .memberMenu(var menu):
            switch key {
            case .up, .down:
                menu.move(by: key == .up ? -1 : 1)
                overlayModel.content = .memberMenu(menu)
            case .space, .enter:
                chooseMenu(menu.selection, memberID: menu.memberID)
            case .escape:
                closeOverlay()
            }
        }
    }

    /// 메뉴에서 고른 일을 한다. 키로 고르든 눌러 고르든 여기로 온다.
    func chooseMenu(_ action: PlazaMemberAction, memberID id: String) {
        switch action {
        case .greet:
            closeOverlay()
            greet(id)
        case .tackle:
            closeOverlay()
            tackle(id)
        case .follow:
            closeOverlay()
            scene?.follow(member: id)
        case .viewCard:
            // 메뉴를 연 사이에 연결이 끊긴 팀원이면 카드를 받을 수 없다.
            guard let session, let state = members[id] else { return closeOverlay() }
            let generation = openOverlay(.card(.loading(state)))
            Task {
                let profile = await session.requestProfile(memberID: id, timeout: profileTimeout)
                guard generation == overlayGeneration else { return }
                overlayModel.content = .card(profile.map { .loaded(state, $0) } ?? .failed(state))
            }
        }
    }

    /// 그 팀원에게 뛰어들고 충격 그림을 띄운 뒤 팀원들에게 보낸다. 내 진화 단계만큼(1–3칸) 밀라고 보내고, 실제로 미는 것은
    /// 그 팀원의 Mac이 정한다. 말풍선 키와 같은 연타 제한을 쓴다.
    private func tackle(_ id: String) {
        guard let scene, let target = scene.memberTiles[id] else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        let me = scene.walker.tile
        let direction = PlazaPathfinder.isAdjacent(me, target) ? PlazaPathfinder.direction(from: me, to: target) : scene.walker.facing
        scene.playTackle(by: nil, on: id, direction: direction)
        session?.sendEmote(.tackle, target: id, pushTiles: TeamEmote.pushTiles(evolutionStage()))
    }

    /// 런타임이 부른다. 누군가 몸통박치기를 했다. 맞은 게 나이고 민 팀원이 내 바로 옆(또는 같은 칸)이면 그 반대쪽으로 `tiles`칸
    /// 밀린다. 메뉴를 연 사이에 내가 걸어가 버렸으면 충격 그림만 보이고 밀리지 않는다. 창이 닫혀 있으면 아무것도 안 한다.
    func showTackle(from sender: String, on target: String?, tiles: Int = 1) {
        guard let scene, let target, let from = scene.memberTiles[sender] else { return }
        let isMe = target == memberID()
        guard let to = isMe ? scene.walker.tile : scene.memberTiles[target] else { return }
        let direction = PlazaPathfinder.isAdjacent(from, to) ? PlazaPathfinder.direction(from: from, to: to)
            : members[sender]?.facing ?? .down
        scene.playTackle(by: sender, on: isMe ? nil : target, direction: direction)
        if isMe && (PlazaPathfinder.isAdjacent(from, to) || from == to) { scene.pushMe(direction, tiles: tiles) }
    }

    /// 하트나 폭죽을 나와 그 팀원 머리 위에 함께 띄우고 팀원들에게 보낸다. 말풍선 키와 같은 연타 제한을 쓴다.
    private func greet(_ id: String) {
        guard let scene else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        let kind = greetingKind()
        scene.showEmote(memberID: nil, kind: kind, large: true)
        scene.showEmote(memberID: id, kind: kind, large: true)
        session?.sendEmote(kind, target: id, shared: true)
    }

    @discardableResult
    private func openOverlay(_ content: PlazaOverlayContent) -> Int {
        overlayGeneration += 1
        overlayModel.content = content
        scene?.isOverlayOpen = true
        refreshHint()
        return overlayGeneration
    }

    private func closeOverlay() {
        if overlayModel.content == .board { feed?.markAllRead() }
        overlayGeneration += 1
        overlayModel.content = .none
        scene?.isOverlayOpen = false
        refreshHint()
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 스페이스로 말을 걸 수 있으면 위쪽에 안내를 띄운다. 판이나 입력창이 열려 있으면 스페이스가 다른 일을 하므로 숨긴다.
    private func refreshHint() {
        var text: String?
        if let id = scene?.followingMember, overlayModel.content == .none, !chatInput.isOpen {
            text = members[id].map { L(.ko).plazaFollowHint(nickname: $0.nickname) }
        } else if let hit = scene?.interactionTarget, overlayModel.content == .none, !chatInput.isOpen {
            switch hit.target {
            case .board: text = L(.ko).plazaBoardHint
            case .member(let id): text = members[id].map { L(.ko).plazaMemberHint(nickname: $0.nickname) }
            }
        }
        if overlayModel.hint != text { overlayModel.hint = text }
    }

    /// 앱이 앞이고 광장 창이 키 창이다. 알림 대신 광장 안 안내를 쓸지 가른다.
    var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true }

    /// 테스트용 읽기 전용 값.
    var overlayContent: PlazaOverlayContent { overlayModel.content }
    var chatInputForTesting: PlazaChatInput { chatInput }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다. 인사하기(`other`가 있다)면 받는 팀원(나일 수도
    /// 있다) 위에도 띄우고, 두 말풍선 모두 1.5배로 그린다.
    func showEmote(memberID: String, kind: TeamEmoteKind, alsoOver other: String? = nil) {
        let large = other != nil
        scene?.showEmote(memberID: memberID, kind: kind, large: large)
        if let other { scene?.showEmote(memberID: other == self.memberID() ? nil : other, kind: kind, large: large) }
    }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다.
    func showChat(memberID: String, text: String, isLoud: Bool = false) {
        guard let scene, let member = members[memberID] else { return }
        scene.showChat(memberID: memberID, text: text)
        chatLog.append(time: clock(), name: member.nickname, text: text,
                       color: scene.memberNameColor(memberID) ?? PlazaNameColor.palette[0], isLoud: isLoud)
    }

    /// 목록에서 고른 팀원에게 걸어간다. 누른 뒤에도 키는 장면이 받는다.
    func walkToMember(_ id: String) {
        scene?.walk(toMember: id)
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 대화 기록을 펼치거나 접는다. 누른 뒤에도 키는 장면이 받는다.
    func toggleChatLog() {
        chatLog.isExpanded.toggle()
        if let skView { window?.makeFirstResponder(skView) }
    }

    var isChatLogExpanded: Bool { chatLog.isExpanded }

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
    var hint: String? { overlayModel.hint }

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
                                     isWalking: scene.walker.isWalking, isRunning: scene.walker.isRunning)
    }

    /// 작은 지도의 점과 보이는 영역을 지금 상태로 맞춘다.
    private func refreshMinimap() {
        guard let scene else { return }
        var dots = members.values.sorted { $0.memberID < $1.memberID }.compactMap { m -> PlazaMinimapModel.Dot? in
            guard let tile = scene.memberTiles[m.memberID] else { return nil }
            return .init(id: m.memberID, tile: tile, color: scene.memberNameColor(m.memberID) ?? PlazaNameColor.palette[0],
                         isMe: false, isAway: m.isIdle)
        }
        dots.append(.init(id: memberID(), tile: scene.walker.tile, color: scene.nameColor, isMe: true, isAway: false))
        if dots != minimap.dots { minimap.dots = dots }
        if scene.visibleWorldRect != minimap.view { minimap.view = scene.visibleWorldRect }
    }

    /// 테스트용 읽기 전용 값.
    var minimapDots: [PlazaMinimapModel.Dot] { minimap.dots }
    var minimapView: CGRect { minimap.view }

    /// 다시 등록을 먼저 하고 값을 반영한다(그 사이 변경을 놓치지 않는다). 세대가 바뀌었으면 끝낸다.
    private func observeMembers(session: TeamSession, generation: Int) {
        guard generation == membersGeneration else { return }
        // 목록은 끊긴 팀원(잠)과 내 자리비움도 보므로 함께 지켜본다.
        let current = withObservationTracking {
            _ = session.asleepMembers
            _ = session.isIdle
            return session.members
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMembers(session: session, generation: generation) }
        }
        members = current
        applyMembersToScene()
        refreshRoster()
        refreshHint()
    }

    private func applyMembersToScene() {
        guard let scene else { return }
        let list = members.values.sorted { $0.memberID < $1.memberID }
        scene.applyMembers(list.map {
            PlazaSceneMember(memberID: $0.memberID, nickname: $0.nickname, isAway: !$0.inPlaza, tile: $0.tile,
                             facing: $0.facing ?? .down, isWalking: $0.isWalking, isIdle: $0.isIdle, nameColor: $0.nameColor,
                             isRunning: $0.isRunning)
        })
        refreshMinimap()
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
            startMemberLoad(m.memberID, subject: subject)
        }
    }

    /// 앞모습은 받을 때까지, 뒷모습은 `backRetryLimit`번까지 다시 묻는다.
    private static func shouldRetry(_ frames: PlazaCharacterFrames, attempt: Int) -> Bool {
        frames.isPlaceholder || (frames.backIsFront && attempt < backRetryLimit)
    }

    private func startMemberLoad(_ id: String, subject: CompanionStore.RepresentativeSubject, attempt: Int = 0) {
        nextLoadToken += 1
        let token = nextLoadToken
        memberLoadTokens[id] = token
        Task { await loadMemberFrames(id, subject: subject, token: token, attempt: attempt) }
    }

    private func loadMemberFrames(_ id: String, subject: CompanionStore.RepresentativeSubject, token: Int, attempt: Int) async {
        let frames = await loader.frames(for: subject)
        guard memberLoadTokens[id] == token, let scene else { return }
        scene.setMemberFrames(id, frames)
        appliedMemberLoads.append((id, subject.speciesID))
        if Self.shouldRetry(frames, attempt: attempt) {
            await retryMemberLoad(id, subject: subject, token: token, attempt: attempt)
        }
    }

    /// A failed request must not stay a grey circle until the plaza is reopened. Asks again only if the plaza
    /// is still open and this member still shows the same character (a newer request or a close bumps the token).
    private func retryMemberLoad(_ id: String, subject: CompanionStore.RepresentativeSubject, token: Int, attempt: Int) async {
        await spriteRetrySleep(Self.spriteRetryDelay)
        guard !Task.isCancelled, memberLoadTokens[id] == token, memberSubjects[id] == subject else { return }
        startMemberLoad(id, subject: subject, attempt: attempt + 1)
    }

    func appliedMemberSpecies(_ id: String) -> [Int?] { appliedMemberLoads.filter { $0.id == id }.map(\.speciesID) }

    /// 지금 대표 포켓몬 그림을 다시 받아 장면에 넣는다. 장면이 없으면 아무것도 안 한다.
    func refreshCharacter() async {
        await loadCharacter(attempt: 0)
    }

    private func loadCharacter(attempt: Int) async {
        guard let current = scene else { return }
        // 그림 로딩을 기다리지 않고 바로 반영한다(알이면 지금 걷는 칸만 마치고 선다).
        current.canWalk = subject().speciesID != nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let frames = await loader.frames(for: subject())
        // 기다리는 동안 닫혔거나 더 새 요청이 있었으면 버린다.
        guard generation == refreshGeneration, let scene else { return }
        scene.setCharacter(frames)
        if Self.shouldRetry(frames, attempt: attempt) {
            Task { await retryCharacter(generation, attempt: attempt) }
        }
    }

    /// 내 그림도 팀원처럼 다시 묻는다. 더 새 요청이나 닫기가 세대를 올리면 그만둔다.
    private func retryCharacter(_ generation: Int, attempt: Int) async {
        await spriteRetrySleep(Self.spriteRetryDelay)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        await loadCharacter(attempt: attempt + 1)
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
        let next = PlazaRoster.entries(me: me, meIsIdle: session?.isIdle ?? false, members: Array(members.values),
                                       asleep: session.map { Array($0.asleepMembers.values) } ?? [])
        if next != rosterModel.entries { rosterModel.entries = next }
    }

    /// 테스트용 읽기 전용 값.
    var rosterEntries: [PlazaRosterEntry] { rosterModel.entries }
    var rosterIsAnimating: Bool { rosterModel.isAnimating }

    /// 마지막 칸을 저장하고 장면과 창 내용을 해제해 그리기를 멈춘다.
    func handleClose() {
        chatInput.close()
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
        overlayModel.hint = nil
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
            scene.onJumpKey = nil
            scene.onGreetKey = nil
            scene.onTackleKey = nil
            scene.onChatKey = nil
            scene.onOverlayKey = nil
            scene.onInteractionTargetChange = nil
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
        refreshMinimap()
    }
    func windowDidMiniaturize(_ notification: Notification) { setRendering(visible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { setRendering(visible: true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        setRendering(visible: window?.occlusionState.contains(.visible) ?? true)
    }
    func windowWillClose(_ notification: Notification) { handleClose() }
    func windowDidResignKey(_ notification: Notification) { handleResignKey() }
}
