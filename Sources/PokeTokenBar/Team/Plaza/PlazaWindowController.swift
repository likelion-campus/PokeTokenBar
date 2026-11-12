import AppKit
import SpriteKit

/// 그리기 루프를 멈출 수 있는 뷰. 테스트에서 창 없이 바꿔 끼운다.
@MainActor protocol PlazaPausableView: AnyObject { var isPaused: Bool { get set } }
extension SKView: PlazaPausableView {}

/// 집중이 끝났다. `completed`면 시간을 다 채웠고, 아니면 일어선 것이다.
struct PlazaFocusEnd: Equatable, Sendable {
    let minutes: Int
    let elapsedMinutes: Int
    let completed: Bool
}

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
    private let schedule: () -> PlazaSchedule?
    /// 고른 이름 색을 저장한다(팀 설정). 팀원에게는 세션이 보낸다.
    private let chooseNameColor: (UInt32) -> Void
    /// 내 광장 캐릭터의 진화 단계(1부터). 몸통박치기가 미는 칸 수다.
    private let evolutionStage: () -> Int
    /// 종 번호의 타입 목록. 물 타입이면 잠수를 더 오래 한다. 못 구하면 nil.
    private let pokemonTypes: (Int) async -> [String]?
    /// 광장에서 주운 아이템을 가방에 넣는다.
    private let grantItem: (ItemKind) -> Void
    /// 누군가 주운 것으로 아는 아이템 칸: 내가 주운 것, 팀원이 알려 온 것, 팀원 presence가 전해 준 것. 저장하고, 가장 최근
    /// 것을 내 presence로 다시 전한다. 그래서 주운 사람이 떠난 뒤 광장을 연 팀원도 그때 있던 누군가에게서 전해 듣는다.
    private var takenItemSlots: Set<Int> = []
    /// 지금 칸까지 저장해 두는 지난 칸 수. 아이템은 지금 칸 것만 보이니 몇 칸이면 충분하다.
    private static let keptTakenSlots = 8
    private let nameColorModel = PlazaNameColorModel()
    let rosterModel = PlazaRosterModel()
    private let clock: () -> Date
    private let profileTimeout: Duration
    private let overlayModel = PlazaOverlayModel()
    /// 사진 모드에서 숨기는 HUD 뷰. 판과 대화 입력창은 넣지 않는다.
    private var hudViews: [NSView] = []
    private let feed: TeamFeedStore?
    /// 큰 소식 배너를 보여 주는 시간.
    static let bannerDuration: Duration = .seconds(4)
    private let bannerSleep: @MainActor (Duration) async -> Void
    /// 단체 사진 카운트다운의 1초. 테스트에서 바꿔 끼운다.
    private let groupPhotoSleep: @MainActor (Duration) async -> Void
    private let frontmostOverride: (@MainActor () -> Bool)?
    private let spriteRetrySleep: @MainActor (Duration) async -> Void
    /// 그리기 감시의 간격. 테스트에서 바꿔 끼운다.
    private let renderCheckSleep: @MainActor (Duration) async -> Void
    /// 창이 열려 있는 동안 1초마다 모닥불·타이머·안내를 다시 맞추는 틱. 테스트에서 바꿔 끼운다.
    private let focusTickSleep: @MainActor (Duration) async -> Void
    private var focusTick: Task<Void, Never>?
    /// 창이 열려 있는 동안 0.05초마다 메타몽을 한 걸음 진행하는 틱. 테스트에서 바꿔 끼운다.
    private let dittoLoopSleep: @MainActor (Duration) async -> Void
    private var dittoLoop: Task<Void, Never>?
    /// 내가 호스트일 때만 있는 메타몽 두뇌.
    private var dittoBrain: PlazaDittoBrain?
    /// 내가 찾은 복사본의 `since`. 호스트의 소식이 따라잡기 전에 온 옛 복사본 소식을 다시 그리지 않는다.
    private var foundDittoSince: Date?
    /// 메타몽에게 메뉴를 열 때 보인 메타몽. 고를 때 누구 모습인지가 바뀌었으면 고른 일을 하지 않는다.
    private var menuDitto: PlazaDittoState?
    /// 이 Mac이 지금 보여 주는 메타몽. 호스트가 바뀌어도 이어 받는다.
    private(set) var shownDitto: PlazaDittoState?
    /// `shownDitto`에 입힌 이름·색·칭호·그림. 둘 다 그대로면 0.05초 틱마다 장면과 지도를 다시 건드리지 않는다.
    private var shownDittoLook: DittoLook?
    private let dittoSeed: () -> UInt64

    private struct DittoLook: Equatable {
        var name: String
        var color: CGColor
        var title: String?
        var subject: CompanionStore.RepresentativeSubject
    }
    /// 지금 모닥불에 앉아 집중 중인 나. 앉으면 저장하고, 끝나거나 일어서면 지운다.
    private(set) var focus: PlazaFocus?
    /// 앉은 자리가 바라보는 방향. 다시 열거나 닫을 때 그대로 알린다.
    private var focusFacing: PlazaDirection = .down
    /// 집중이 끝났다(시간이 다 됐거나 일어섰다). 조용히 끝낼 때는 부르지 않는다.
    var onFocusEnd: ((PlazaFocusEnd) -> Void)?
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
    /// 왼쪽 아래 대화 기록과 오른쪽 아래 작은 지도가 겹치지 않는 폭, 펼친 단축키 안내가 다 보이는 높이.
    static let minContentSize = NSSize(width: 600, height: 352)
    private var lastEmoteAt: Date?
    private var lastChatAt: Date?
    private var lastLoudAt: Date?
    static let loudInterval: TimeInterval = 60
    private let minimap = PlazaMinimapModel()
    private let chatInput = PlazaChatInput()
    private let chatLog = PlazaChatLog()
    private let backgroundModel = PlazaBackgroundModel()
    private let shortcutModel = PlazaShortcutGuideModel()
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
    /// 연못 그림은 타일 시트의 물 칸을 쓰므로 시트를 읽었을 때만 켠다. `mapImage`가 채운다.
    private static var cachedHasTileSheet = false
    /// 풀숲 조각 그림도 프로세스당 한 번만 읽는다. 못 읽으면 바깥 nil(=읽어 봤지만 없음)로 기억한다.
    private static var cachedTallGrass: PlazaTallGrassArt??

    private static func tallGrassArt() -> PlazaTallGrassArt? {
        if let loaded = cachedTallGrass { return loaded }
        let art = PlazaTallGrassArt.load()
        cachedTallGrass = .some(art)
        return art
    }

    /// 눈 오는 날의 그림도 프로세스당 한 번만 만든다. 타일 시트가 없으면 바깥 nil(=만들어 봤지만 없음)이다.
    private static var cachedSnowLook: PlazaSnowLook??

    private static func snowLook(for map: PlazaMap) -> PlazaSnowLook? {
        if let built = cachedSnowLook { return built }
        var look: PlazaSnowLook?
        if let sheet = PlazaResources.tileSheet() {
            let art = PlazaResources.tallGrassSheet().map(PlazaSnowSheet.tallGrass).flatMap(PlazaTallGrassArt.init(sheet:))
            look = PlazaSnowLook(mapImage: PlazaTileArt.mapImage(map, sheet: PlazaSnowSheet.tiles(sheet), tallGrass: art), tallGrass: art)
        }
        cachedSnowLook = .some(look)
        return look
    }

    private func snowDayChanged(_ on: Bool) {
        minimap.snowMapImage = on ? Self.snowLook(for: map).map { NSImage(cgImage: $0.mapImage, size: .zero) } : nil
        shortcutModel.isSnowDay = on
    }

    /// 테스트용: 단축키 안내에 V(눈뭉치) 줄이 보이는가.
    var shortcutsShowSnowball: Bool { shortcutModel.isSnowDay }

    var minimapShowsSnow: Bool { minimap.snowMapImage != nil }

    private var mapImage: CGImage {
        if let cached = Self.cachedMapImage { return cached }
        let tallGrass = Self.tallGrassArt()
        let sheet = PlazaResources.tileSheet()
        let image = sheet.map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: tallGrass) } ?? PlazaTileArt.plainGrassImage(map)
        Self.cachedMapImage = image
        Self.cachedHasTileSheet = sheet != nil
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
         schedule: @escaping () -> PlazaSchedule? = { nil },
         evolutionStage: @escaping () -> Int = { 1 },
         pokemonTypes: @escaping (Int) async -> [String]? = { _ in nil },
         grantItem: @escaping (ItemKind) -> Void = { _ in },
         session: TeamSession? = nil,
         feed: TeamFeedStore? = nil,
         clock: @escaping () -> Date = Date.init,
         photoWriter: @escaping (Data) -> Bool = PlazaWindowController.writePhotoToClipboard,
         greetingKind: @escaping () -> TeamEmoteKind = { PlazaWindowController.greetingKinds.randomElement() ?? .heart },
         profileTimeout: Duration = .seconds(5),
         bannerSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         groupPhotoSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         spriteRetrySleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         renderCheckSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         focusTickSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         dittoLoopSleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         dittoSeed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) },
         isFrontmost: (@MainActor () -> Bool)? = nil) {
        self.frontmostOverride = isFrontmost
        self.focusTickSleep = focusTickSleep
        self.dittoLoopSleep = dittoLoopSleep
        self.dittoSeed = dittoSeed
        self.spriteRetrySleep = spriteRetrySleep
        self.renderCheckSleep = renderCheckSleep
        self.session = session
        self.feed = feed
        self.bannerSleep = bannerSleep
        self.groupPhotoSleep = groupPhotoSleep
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
        self.schedule = schedule
        self.chooseNameColor = chooseNameColor
        self.evolutionStage = evolutionStage
        self.pokemonTypes = pokemonTypes
        self.grantItem = grantItem
        super.init()
        // 다시 켜도 주운 것으로 아는 아이템을 기억하고 팀원에게 전한다.
        takenItemSlots = keptSlots(Set(preferences.takenItemSlots))
        session?.updateTakenItemSlot(takenItemSlots.max())
        restoreFocus()
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
            w.contentMinSize = Self.minContentSize
            w.isReleasedWhenClosed = false
            w.level = .normal
            w.delegate = self
            let container = NSView(frame: view.frame)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            let roster = PlazaRosterHostingView(rootView: rosterView())
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
                                                                       onMenuCancel: { [weak self] in self?.closeOverlay() },
                                                                       onCampfireChoose: { [weak self] in self?.chooseCampfire(index: $0) }),
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
            let clock = PlazaClockHostingView(rootView: PlazaClock(model: minimap))
            clock.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(clock)   // 입력은 받지 않는다.
            let shortcuts = PlazaShortcutGuideHostingView(rootView: PlazaShortcutGuide(
                model: shortcutModel, toggle: { [weak self] in self?.toggleShortcuts() }))
            shortcuts.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shortcuts)
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
            hudViews = [roster, chatLogView, map, clock, shortcuts, toggle, colorPicker]
            w.contentView = container
            w.center()
            Self.restoreFrame(w, into: rosterModel)
            view.presentScene(scene)
            w.makeFirstResponder(view)
            skView = view
            renderLoop = view
            window = w
            startRenderWatchdog()
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

    /// 창 없이 장면만 만든다. 창이 열려 있을 때만 불러야 한다(`show()`뿐): 여기서 메타몽 준비를 알리면 이 Mac이 호스트 후보가 된다.
    func prepareScene() {
        guard scene == nil else { return }
        let image = mapImage
        let s = PlazaScene(map: map, mapImage: image,
                           start: preferences.lastTile(validIn: map),
                           zoom: preferences.zoom, nickname: nickname(),
                           tallGrass: Self.tallGrassArt(), pondVisuals: Self.cachedHasTileSheet)
        s.now = clock   // 낮밤·날씨도 컨트롤러와 같은 시계를 쓴다
        if let focus { s.sit(at: .init(tile: focus.seat, facing: focusFacing)) }
        s.setNameColor(PlazaNameColor.color(forMemberID: memberID(), chosen: nameColor()))
        nameColorModel.current = PlazaNameColor.hex(forMemberID: memberID(), chosen: nameColor())
        nameColorModel.isOpen = false
        s.canWalk = subject().speciesID != nil
        s.myEvolutionStage = evolutionStage()
        s.onDivingChange = { [weak self] in self?.session?.updateDiving($0); self?.refreshHint() }
        s.onZoomChange = { [weak self, preferences] in
            preferences.zoom = $0
            self?.refreshMinimap()
        }
        s.onCloseRequest = { [weak self] in self?.window?.performClose(nil) }
        s.onEmoteKey = { [weak self] in self?.handleEmoteKey($0) }
        s.onInteractKey = { [weak self] in self?.handleInteractKey() }
        s.onPhotoKey = { [weak self] in self?.handlePhotoKey() }
        s.onPhotoModeChange = { [weak self] in self?.photoModeChanged($0) }
        s.onJumpKey = { [weak self] in self?.handleJumpKey() }
        s.onGreetKey = { [weak self] in
            if let self, let id = self.faceNearbyMember() { self.greet(id) }
        }
        s.onTackleKey = { [weak self] in
            guard let self, !self.isFocusing else { return }
            if self.scene?.isDiving == true { return self.pullUnder() }
            if let id = self.faceNearbyMember(in: self.scene?.interactionTiles) { self.tackle(id) }
        }
        s.onSnowballKey = { [weak self] in self?.handleSnowballKey() }
        s.onGroupPhotoKey = { [weak self] in self?.handleGroupPhotoKey() }
        s.onFireworkKey = { [weak self] in self?.handleFireworkKey() }
        s.onDanceRound = { [weak self] in
            self?.session?.sendEmote(.dance, target: nil, danceStyle: $0, danceSince: self?.scene?.danceStartedAt)
            self?.danceAlong(with: nil, style: $0)
        }
        s.danceLeaderStyle = { [weak self] in self?.danceLeader().flatMap { self?.scene?.danceStyle(memberID: $0) } }
        s.isFocusing = { [weak self] in self?.isFocusing ?? false }
        s.onItemPickup = { [weak self] in self?.pickUp($0) }
        s.onItemChange = { [weak self] _ in self?.refreshMinimap() }
        s.onFrameClockStall = { [weak self] in self?.logState($0 ? "frame clock stalled" : "frame clock resumed") }
        s.pickedItemSlots = takenItemSlots
        s.onChatKey = { [weak self] in self?.openChat() }
        s.onInteractionTargetChange = { [weak self] _ in self?.refreshHint() }
        s.onFollowChange = { [weak self] _ in self?.refreshHint() }
        // 일정을 먼저 넣어야 낮밤·날씨·모닥불빛이 기본값으로 한 번 그려졌다가 다시 만들어지지 않는다.
        scene = s
        s.snowLook = { [map] in Self.snowLook(for: map) }
        s.onSnowDayChange = { [weak self] in self?.snowDayChanged($0) }
        applySchedule()
        s.refreshSnowDay()
        snowDayChanged(s.isSnowShown)
        s.setBackgroundHidden(preferences.isBackgroundHidden)
        backgroundModel.isHidden = preferences.isBackgroundHidden
        shortcutModel.isFolded = preferences.areShortcutsFolded
        s.onOverlayKey = { [weak self] in self?.handleOverlayKey($0) }
        s.onWalkKey = { [weak self] in self?.standUp() }
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
                self.refreshHint()
            }
            membersGeneration += 1
            observeMembers(session: session, generation: membersGeneration)
        }
        refreshRoster()
        refreshMinimap()
        s.refreshInteractionTarget()
        refreshCampfire()
        startFocusTick()
        // 내가 가장 작은 ID로 막 열었다면 첫 틱에 호스트가 된다. 옛 호스트는 내 준비 소식을 보는 즉시 물러나 그 전에 소식을
        // 거둘 수 있으므로, 알리는 쪽을 지금 한 번 받아 그린다. 호스트 두뇌는 보이는 모습에서 이어 간다(명세 §5.6).
        showReceivedDitto(smallestReceivedDitto())
        session?.updateDitto(ready: true, state: nil)
        startDittoLoop()
    }

    /// 내 말풍선은 바로 띄운다. ♥, ㅋㅋ, 🎉는 바라보거나 바로 옆에 있는 팀원을 표적으로 보내고, !, ?는 표적 없이 보낸다.
    private func handleEmoteKey(_ kind: TeamEmoteKind) {
        guard let scene else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.stopDance(memberID: nil)
        scene.showEmote(memberID: nil, kind: kind)
        var target = kind.notifiesTarget
            ? PlazaTargeting.member(from: scene.walker.tile, facing: scene.walker.facing, members: targetTiles) : nil
        if target == PlazaDitto.sceneKey { target = nil }   // 복사본에게 보낸 마음은 진짜 팀원에게 가지 않는다
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

    /// 단축키 안내를 접거나 펼치고 기억한다.
    func toggleShortcuts() {
        preferences.areShortcutsFolded.toggle()
        shortcutModel.isFolded = preferences.areShortcutsFolded
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 테스트용 읽기 전용 값.
    var areShortcutsFolded: Bool { shortcutModel.isFolded }

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
        scene.stopDance(memberID: nil)
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
        switch scene.pondAction(canMove: scene.canWalk && !isFocusing) {
        case .jump, .shoreJump:
            scene.stopDance(memberID: nil)
            scene.playJump(memberID: nil)
            session?.sendEmote(.jump, target: nil)
        case .plunge(let d):
            scene.plunge(d)
            session?.sendEmote(.jump, target: nil)
        case .dive:
            scene.setDiving(true)
            session?.updateDiving(true)
        case .surface:
            scene.setDiving(false)
            session?.updateDiving(false)
        }
        refreshHint()
    }

    /// X와 C가 메뉴 없이 바로 할 팀원. 말풍선 키와 같이 바라보거나 바로 옆에 있는 팀원이고, 옆이면 그쪽으로 돌아선다.
    /// 옆에 팀원이 없으면 nil이라 아무것도 하지 않는다. C는 메타몽 모습도 고르도록 `tiles`에 `interactionTiles`를 준다.
    private func faceNearbyMember(in tiles: [String: TilePoint]? = nil) -> String? {
        guard let scene else { return nil }
        let me = scene.walker.tile
        let tiles = tiles ?? targetTiles
        guard let id = PlazaTargeting.member(from: me, facing: scene.walker.facing, members: tiles),
              let tile = tiles[id] else { return nil }
        if PlazaPathfinder.isAdjacent(me, tile) { scene.face(PlazaPathfinder.direction(from: me, to: tile)) }
        return id
    }

    /// 말을 걸 수 있는 팀원의 칸. 메타몽은 팀원 흉내를 내는 동안에만 들어간다.
    private var targetTiles: [String: TilePoint] { scene?.targetTiles ?? [:] }

    /// 안내 문구에 쓰는 이름. 복사본은 따라 한 팀원의 이름이라 진짜와 같은 문구가 나온다. 메타몽 모습이면 메타몽.
    private func hintName(of id: String) -> String? {
        guard id == PlazaDitto.sceneKey else { return members[id]?.nickname }
        guard let copied = shownDitto?.decoyOf else { return L(.ko).plazaDittoName }
        return copied == memberID() ? nickname() : members[copied]?.nickname
    }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다.
    func showJump(memberID: String) {
        scene?.playJump(memberID: memberID)
        startleMe(by: memberID)
    }

    private var lastStartledAt: Date?

    /// 풀숲에서 뛴 팀원이 내 바로 옆이면 그쪽으로 돌아서 "!"와 함께 펄쩍 뛰고 팀원들에게 보낸다. 사진 모드에서는 놀라지 않는다.
    /// 풀숲 옆에는 물도 모닥불 자리도 없어서 헤엄치거나 집중하는 중에는 이 조건이 맞지 않는다.
    private func startleMe(by id: String) {
        guard let scene, let from = scene.memberTiles[id], !isPhotoMode,
              PlazaStartle.startles(jumper: from, victim: scene.walker.tile, isGrass: scene.isGrass) else { return }
        let now = clock()
        if let last = lastStartledAt, now.timeIntervalSince(last) < PlazaStartle.cooldown { return }
        lastStartledAt = now
        lastJumpAt = now
        scene.face(PlazaPathfinder.direction(from: scene.walker.tile, to: from))
        scene.stopDance(memberID: nil)
        scene.playJump(memberID: nil)
        scene.showEmote(memberID: nil, kind: .exclaim)
        session?.sendEmote(.jump, target: nil)
        session?.sendEmote(.exclaim, target: nil)
    }

    /// 풀숲에 숨은 내가 Z로 놀래킬 수 있을 때의 안내. 옆에 놀랄 팀원이 없으면 숨었다는 것과 방법만 알린다. 숨지 않았으면 nil.
    private func startleHint() -> (text: String, hasTarget: Bool)? {
        guard let scene, scene.isGrass(scene.walker.tile) else { return nil }
        let ids = PlazaStartle.targets(me: scene.walker.tile, members: scene.memberTiles, isGrass: scene.isGrass)
        if ids.isEmpty { return (L(.ko).plazaHiddenHint, false) }
        if ids.count == 1, let name = members[ids[0]]?.nickname { return (L(.ko).plazaStartleHint(nickname: name), true) }
        return (L(.ko).plazaStartleManyHint, true)
    }

    /// 직전에 쏜 불꽃 종류. 같은 종류가 연달아 나오지 않게 기억한다.
    private var lastFireworkStyle: String?

    /// 무작위 종류로 한 발을 쏘고 팀원들에게 보낸다. 쏜 지 0.5초가 안 지났으면 장면이 거절해 아무에게도 보내지 않는다.
    private func handleFireworkKey() {
        var rng = SystemRandomNumberGenerator()
        let style = PlazaFireworks.next(after: lastFireworkStyle, using: &rng)
        guard scene?.playFirework(memberID: nil, style: style.id) == true else { return }
        scene?.stopDance(memberID: nil)
        lastFireworkStyle = style.id
        session?.sendEmote(.firework, target: nil, fireworkStyle: style.id)
    }

    /// 런타임이 부른다. 팀원이 불꽃을 쐈다. 창이 닫혀 있으면 아무것도 안 한다.
    func showFirework(memberID: String, style: String?) {
        scene?.playFirework(memberID: memberID, style: style)
    }

    /// 런타임이 부른다. 팀원이 다른 동작(말풍선, 글, 점프 같은)을 해 그 팀원의 춤을 멈춘다. 창이 닫혀 있으면 아무것도 안 한다.
    func stopDance(memberID: String) {
        scene?.stopDance(memberID: memberID)
    }

    /// 런타임이 부른다. 팀원이 춤 한 판을 춘다. 집중 중인 팀원은 앉아 있으니 추지 않는다. 창이 닫혀 있으면 아무것도 안 한다.
    /// `since`는 그 팀원이 춤을 시작한 시각이다. 안 보내는 이전 버전이면 내 화면에서 그 춤이 시작된 때로 친다.
    func showDance(memberID: String, style: String?, since: Date? = nil) {
        guard focusRemaining(of: memberID) == nil else { return }
        danceSince = danceSince.filter { scene?.memberTiles[$0.key] != nil }   // 떠난 팀원의 값이 쌓이지 않게 한다
        if let since {
            danceSince[memberID] = since
        } else if danceSince[memberID] == nil || scene?.isDancing(memberID: memberID) != true {
            danceSince[memberID] = clock()
        }
        scene?.playDance(memberID: memberID, style: style)
        // 팀원의 춤이 내 화면에서 아직 안 시작됐어도(걸음을 마치는 중, 창이 가려져 장면이 멈춤) 메타몽 쪽은 자리로 정한다.
        danceAlong(with: memberID, style: style)
        // 내가 따라 추는 팀원의 새 판이면 나도 같은 춤으로 새 판을 시작한다.
        if danceLeader(alsoDancing: memberID) == memberID { scene?.followDance(PlazaDance.Style.style(id: style)) }
    }

    /// 내가 따라 출 팀원(`PlazaDance.leader`). 내 화면에서 춤추는 팀원과, 방금 춤 소식을 보낸 `extra`(걸음을 마치는 중이라 아직
    /// 안 추고 있을 수 있다)를 춤추는 팀원으로 본다. 메타몽은 팀원이 아니라 들어가지 않는다.
    private func danceLeader(alsoDancing extra: String? = nil) -> String? {
        guard let scene else { return nil }
        var dancers: [String: (tile: TilePoint, since: Date)] = [:]
        for (id, tile) in scene.memberTiles where id == extra || scene.isDancing(memberID: id) {
            if let since = danceSince[id] { dancers[id] = (tile, since) }
        }
        // 내 시각은 장면이 새 판마다 이걸 묻기 전에 정해 둔다(판이 끝나 이어 출 때는 그 순간 내가 안 추는 중이다). 춤을 멈춘 뒤의
        // 지난 값은 남의 판 소식에만 쓰이고, 그때는 내가 안 추니 따라 추지도 않는다.
        return PlazaDance.leader(me: memberID(), since: scene.danceStartedAt, at: scene.walker.tile, dancers: dancers)
    }

    /// 팀원이 춤을 시작한 시각(`showDance`). 춤을 멈춘 팀원의 값은 남아 있어도 춤추는 팀원만 보므로 쓰이지 않는다.
    private var danceSince: [String: Date] = [:]

    /// 메타몽 둘레 여덟 칸에서 누가(nil이면 나) 춤 한 판을 시작했으면 메타몽도 같은 춤을 같은 박자에 춘다. 메타몽 모습이든
    /// 복사본이든 같다. 춤 소식은 판마다 오므로 판마다 다시 추고, 소식이 끊기면 팀원 춤처럼 한 판과 여유 뒤에 멈춘다.
    /// 호스트는 그동안 메타몽을 세워 둔다(달아나는 중이면 그대로 간다). 창이 가려져 내 장면이 그리지 않아도 다른 Mac에서는
    /// 춤추고 있으므로, 세워 두기는 그리기와 따로 자리만으로 정한다.
    private func danceAlong(with dancer: String?, style: String?) {
        guard let scene, let ditto = scene.dittoTile else { return }
        let tile: TilePoint? = if let dancer { scene.memberTiles[dancer] } else { scene.walker.tile }
        guard let tile, PlazaDitto.dancesAlong(ditto: ditto, dancer: tile) else { return }
        scene.playDance(memberID: PlazaDitto.sceneKey, style: style)
        dittoBrain?.hold(until: clock().addingTimeInterval(PlazaDitto.danceHold))
    }

    /// 사진 모드 밖이면 연다. 안이면 찍는다.
    private func handlePhotoKey() {
        if scene?.isPhotoMode == true { takePhoto() } else { scene?.enterPhotoMode() }
    }

    var isPhotoMode: Bool { scene?.isPhotoMode ?? false }
    var overlayIsPhotoMode: Bool { overlayModel.isPhotoMode }

    /// 사진 모드를 열고 닫을 때: 틀을 그리고 HUD를 숨기거나 되살린다.
    private func photoModeChanged(_ on: Bool) {
        overlayModel.isPhotoMode = on
        for view in hudViews { view.isHidden = on }
        refreshHint()
        refreshCountdown()
        refreshMinimap()   // 나가면 지도의 보이는 영역도 따라가기 화면으로 돌아와야 한다(1초 뒤 틱을 기다리지 않는다)
    }

    /// 보이는 장면(사진 모드면 틀 안)을 사진으로 합성해 클립보드에 PNG로 넣고 번쩍인다. 합성이나 인코딩이 실패하면 클립보드를 그대로 두고 번쩍이지 않는다.
    /// 클립보드에 넣었으면 true.
    @discardableResult
    private func takePhoto() -> Bool {
        guard let scene, let input = scene.photoInput(), let png = PlazaPhotoRenderer.pngData(for: input), photoWriter(png) else { return false }
        scene.playShutterFlash()
        showBanner(L(.ko).plazaPhotoCopied)
        return true
    }

    /// 주운 것으로 아는 칸을 더한다. 새로 알게 됐으면 저장하고, 장면에 바로 넘기고, 가장 최근 칸을 presence로 전한다.
    private func learnTaken<S: Sequence>(_ slots: S) where S.Element == Int {
        let kept = keptSlots(takenItemSlots.union(slots))
        guard kept != takenItemSlots else { return }
        takenItemSlots = kept
        preferences.takenItemSlots = kept.sorted()
        scene?.pickedItemSlots = kept
        session?.updateTakenItemSlot(kept.max())
    }

    /// 내 시계로 지금 칸까지 몇 칸과, 시계가 조금 앞선 팀원이 먼저 넘어간 다음 칸 하나만 남긴다. 시계가 크게 틀린 팀원이
    /// 알려 온 먼 칸은 버린다. 가장 큰 칸을 기준으로 자르면 그런 칸이 방금 주운 지금 칸을 밀어내, 아이템이 사라지지 않고
    /// 서 있는 동안 화면마다 다시 주워진다. 그 칸이 내 presence로 모두에게 퍼지고 저장돼 재시작해도 남는다.
    private func keptSlots(_ slots: Set<Int>) -> Set<Int> {
        let now = PlazaItems.slot(at: clock())
        return slots.filter { (now - Self.keptTakenSlots + 1)...(now + 1) ~= $0 }
    }

    /// 내가 아이템 칸에 섰다. 가방에 넣고, 팀원들에게 알리고, 반짝이며 배너를 띄운다. 주운 칸을 장면에 바로 넘겨,
    /// 장면은 다음 화면부터 그 아이템을 없애고 다시 부르지 않는다.
    private func pickUp(_ spawn: PlazaItems.Spawn) {
        learnTaken([spawn.slot])
        grantItem(spawn.kind)
        session?.sendEmote(.pickup, target: nil, itemSlot: spawn.slot)
        scene?.playSparkle(memberID: nil)
        showBanner(L(.ko).plazaPickedUp(spawn.kind))
    }

    /// 런타임이 부른다. 팀원이 아이템을 주웠다. 창이 닫혀 있어도 기억하고, 그 아이템이 떠 있었으면 배너로 알린다.
    func showPickup(from memberID: String, slot: Int) {
        let wasShown = scene?.shownItem?.slot == slot ? scene?.shownItem : nil
        learnTaken([slot])
        guard let spawn = wasShown else { return }
        let name = session?.members[memberID]?.nickname ?? ""
        scene?.playSparkle(memberID: memberID)
        showBanner(L(.ko).plazaMemberPickedUp(nickname: name.isEmpty ? L(.ko).plazaGroupPhotoSomeone : name, kind: spawn.kind))
    }

    /// 테스트용 읽기 전용 값.
    var minimapItem: TilePoint? { minimap.item }

    static let groupPhotoSeconds = 5
    /// 끝난 뒤 이만큼은 G가 새 단체 사진을 시작하지 않는다. 함께 찍으려고 늦게 누른 G가 모두에게 새 카운트다운을 띄우지 않게 한다.
    static let groupPhotoCooldown: TimeInterval = 2
    private var groupPhotoEndedAt: Date?

    /// 진행 중인 단체 사진. 시작한 팀원(나면 nil), 남은 초. 함께 찍는지는 사진 모드인지로 정한다.
    private var groupPhoto: (starter: String?, left: Int, task: Task<Void, Never>)?

    /// G. 사진 모드가 아니면 먼저 들어간다. 진행 중인 단체 사진이 있으면 들어간 것이 곧 함께 찍는 것이라 더 하지 않고(팀원에게 다시 보내지 않는다), 아니면 시작해 팀원들에게 알린다.
    private func handleGroupPhotoKey() {
        if !isPhotoMode { scene?.enterPhotoMode() }
        if groupPhoto != nil { return }
        if let ended = groupPhotoEndedAt, clock().timeIntervalSince(ended) < Self.groupPhotoCooldown { return }
        session?.sendEmote(.groupPhoto, target: nil)
        startGroupPhoto(starter: nil)
    }

    /// 런타임이 부른다. 팀원이 단체 사진을 시작했다. 이미 진행 중이면 그대로 둔다. 창이 닫혀 있으면 아무것도 안 한다.
    func showGroupPhoto(from memberID: String) {
        guard scene != nil, groupPhoto == nil else { return }
        // 막 연결된 팀원은 이름이 담긴 presence가 오기 전이라 이름이 빌 수 있다.
        let name = session?.members[memberID]?.nickname ?? ""
        startGroupPhoto(starter: name.isEmpty ? L(.ko).plazaGroupPhotoSomeone : name)
    }

    /// 5초를 세고 0에 모두의 화면이 번쩍인다. 사진 모드에서 앞에 있는 사람은 기념사진처럼 클립보드에도 넣는다.
    private func startGroupPhoto(starter: String?) {
        let task = Task { [weak self] in
            for _ in 0..<Self.groupPhotoSeconds {
                await self?.groupPhotoSleep(.seconds(1))
                guard !Task.isCancelled, let self, self.groupPhoto != nil else { return }
                self.groupPhoto?.left -= 1
                if self.groupPhoto?.left ?? 0 > 0 { self.refreshCountdown() }
            }
            self?.finishGroupPhoto()
        }
        groupPhoto = (starter, Self.groupPhotoSeconds, task)
        refreshCountdown()
    }

    private func refreshCountdown() {
        overlayModel.countdown = groupPhoto.map {
            L(.ko).plazaGroupPhotoCountdown(starter: $0.starter, seconds: $0.left, joined: isPhotoMode,
                                               frontmost: isFrontmost)
        }
    }

    private func finishGroupPhoto() {
        guard groupPhoto != nil else { return }
        groupPhoto = nil
        groupPhotoEndedAt = clock()
        overlayModel.countdown = nil
        // 찍지 못했어도(합성·인코딩·쓰기 실패) 0에는 모두의 화면이 번쩍인다.
        if !(isPhotoMode && isFrontmost && takePhoto()) { scene?.playShutterFlash() }
    }

    /// 테스트용 읽기 전용 값.
    var countdown: String? { overlayModel.countdown }

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
                                                members: scene.interactionTiles) else { return }
        if !isFocusing { scene.face(hit.facing) }   // 앉아 있는 동안은 불을 바라본 채로 둔다
        switch hit.target {
        case .board:
            feed?.markAllRead()
            openOverlay(.board)
        case .campfire:
            let free = PlazaCampfire.nearestFreeSeat(from: scene.walker.tile, occupied: scene.occupiedTiles()) != nil
            openOverlay(.campfireMenu(PlazaCampfireMenu(isJoin: isCampfireLit, minutes: free ? PlazaCampfire.durations : [],
                                                         selection: 0)))
        case .member(let id):
            // 복사본의 메뉴는 따라 한 팀원의 이름과 색으로 연다. 나를 따라 했다면 카드는 없다.
            // 메타몽 모습의 메뉴에는 몸통박치기만 있다.
            let isDitto = id == PlazaDitto.sceneKey
            let isCopy = isDitto && shownDitto?.isDecoy == true
            let copied = isDitto ? shownDitto?.decoyOf : id
            var menu: PlazaMemberMenu
            if isDitto, !isCopy {
                menu = PlazaMemberMenu(memberID: id, nickname: L(.ko).plazaDittoName, nameColor: PlazaDitto.nameHex)
                menu.actions = [.tackle]
                menu.selection = .tackle
            } else if isCopy, copied == memberID() {
                menu = PlazaMemberMenu(memberID: id, nickname: nickname(), nameColor: nameColorModel.current)
                menu.actions.removeAll { $0 == .viewCard }
            } else if let state = copied.flatMap({ members[$0] }) {
                menu = PlazaMemberMenu(memberID: id, nickname: state.nickname, nameColor: state.nameColor)
            } else {
                return
            }
            if scene.canWalk == false { menu.actions.removeAll { $0 == .follow } }
            let remaining = copied.flatMap { focusRemaining(of: $0) }
            if let remaining { menu.status = L(.ko).plazaFocusStatus(seconds: remaining) }
            if isFocusing || remaining != nil { menu.actions.removeAll { $0 == .tackle || $0 == .follow } }
            // 물속에서는 따라갈 수 없다(내가 물속이어도 따라가기는 멈춘다). 몸통박치기는 헤엄치는 쪽끼리도 되지만 잠수한 쪽은 못 한다.
            if scene.isMeInWater || scene.memberIsInWater(id) == true { menu.actions.removeAll { $0 == .follow } }
            if scene.isDiving || scene.memberIsDiving(id) == true { menu.actions.removeAll { $0 == .tackle } }
            guard !menu.actions.isEmpty else { return }   // 집중 중이거나 잠수 중에 메타몽 모습을 보면 할 일이 없다
            if isDitto { menuDitto = shownDitto }
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
        case .campfireMenu(var menu):
            switch key {
            case .up, .down:
                menu.move(by: key == .up ? -1 : 1)
                overlayModel.content = .campfireMenu(menu)
            case .space, .enter:
                chooseCampfire(index: menu.selection)
            case .escape:
                closeOverlay()
            }
        }
    }

    /// 모닥불 메뉴에서 고른 시간으로 앉는다. 키로 고르든 눌러 고르든 여기로 온다. 고를 시간이 없으면 메뉴만 닫는다.
    func chooseCampfire(index: Int) {
        guard case .campfireMenu(let menu) = overlayModel.content, menu.minutes.indices.contains(index) else {
            return closeOverlay()
        }
        closeOverlay()
        startFocus(minutes: menu.minutes[index])
    }

    /// 메뉴에서 고른 일을 한다. 키로 고르든 눌러 고르든 여기로 온다.
    func chooseMenu(_ action: PlazaMemberAction, memberID id: String) {
        // 메뉴를 연 사이에 메타몽이 누구 모습인지가 바뀌었다면(복사본이 돌아왔거나, 메타몽이 누군가로 변했거나, 다른 팀원의
        // 복사본이 됐다) 메뉴의 이름과 할 일이 맞지 않으니 고른 일은 없던 일이다. 같은 모습으로 시각만 새로 찍힌 것은 괜찮다.
        if id == PlazaDitto.sceneKey {
            guard let opened = menuDitto, let shown = shownDitto, shown.decoyOf == opened.decoyOf else { return closeOverlay() }
        }
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
            // 복사본에서 열었으면 따라 한 팀원의 카드다.
            let cardID = id == PlazaDitto.sceneKey ? shownDitto?.decoyOf : id
            guard let session, let cardID, let state = members[cardID] else { return closeOverlay() }
            let generation = openOverlay(.card(.loading(state)))
            Task {
                let profile = await session.requestProfile(memberID: cardID, timeout: profileTimeout)
                guard generation == overlayGeneration else { return }
                overlayModel.content = .card(profile.map { .loaded(state, $0) } ?? .failed(state))
            }
        }
    }

    /// 그 팀원에게 뛰어들고 충격 그림을 띄운 뒤 팀원들에게 보낸다. 내 진화 단계만큼(1–3칸) 밀라고 보내고, 실제로 미는 것은
    /// 그 팀원의 Mac이 정한다. 말풍선 키와 같은 연타 제한을 쓴다.
    private func tackle(_ id: String) {
        // 장면의 메타몽과 `shownDitto`는 늘 같은 모습이라, 복사본이면 `copied`가 있고 메타몽 모습이면 nil이다.
        let isDitto = id == PlazaDitto.sceneKey
        let copied = isDitto ? shownDitto?.decoyOf : nil
        guard let scene, let target = scene.interactionTiles[id], !isFocusing, focusRemaining(of: id) == nil,
              !scene.isDiving, scene.memberIsDiving(id) != true else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.stopDance(memberID: nil)
        let me = scene.walker.tile
        let direction = PlazaPathfinder.isAdjacent(me, target) ? PlazaPathfinder.direction(from: me, to: target) : scene.walker.facing
        scene.playTackle(by: nil, on: id, direction: direction)
        if let copied {
            // 복사본은 밀리지 않고 정체를 드러낸다. 따라 한 팀원을 알려 모두가 같은 복사본을 찾았다고 안다.
            session?.sendEmote(.decoyFound, target: copied)
            showDecoyFound(from: memberID(), copied: copied)
            return
        }
        if isDitto {
            // 메타몽 모습은 밀리지 않고 나로 변한다. 정하는 것은 호스트다.
            session?.sendEmote(.tackle, target: id)
            dittoFormTackled(by: memberID())
            return
        }
        session?.sendEmote(.tackle, target: id, pushTiles: TeamEmote.pushTiles(evolutionStage()))
    }

    /// 런타임이 부른다. 누군가 몸통박치기를 했다. 맞은 게 나이고 민 팀원이 내 바로 옆(또는 같은 칸)이면 그 반대쪽으로 `tiles`칸
    /// 밀린다. 메뉴를 연 사이에 내가 걸어가 버렸으면 충격 그림만 보이고 밀리지 않는다. 창이 닫혀 있으면 아무것도 안 한다.
    /// 메타몽 모습이 맞았으면 아무도 밀리지 않고, 호스트가 민 팀원으로 바꾼다. 내 화면에서 이미 복사본이면 그리지 않는다.
    func showTackle(from sender: String, on target: String?, tiles: Int = 1) {
        guard let scene, let target, let from = scene.memberTiles[sender] else { return }
        let isMe = target == memberID()
        let isDitto = target == PlazaDitto.sceneKey
        if isDitto, shownDitto?.isDecoy != false { return }
        guard let to = isMe ? scene.walker.tile : isDitto ? scene.dittoTile : scene.memberTiles[target] else { return }
        let direction = PlazaPathfinder.isAdjacent(from, to) ? PlazaPathfinder.direction(from: from, to: to)
            : members[sender]?.facing ?? .down
        scene.playTackle(by: sender, on: isMe ? nil : target, direction: direction)
        if isDitto { return dittoFormTackled(by: sender) }
        // 집중 중이거나 모닥불 메뉴를 연 내 Mac은 밀지 않는다(옛 버전이 보낸 몸통박치기도 같다). 충격 그림만 보인다.
        if isMe && canBePushed && (PlazaPathfinder.isAdjacent(from, to) || from == to) { scene.pushMe(direction, tiles: tiles) }
    }

    /// V. 눈 오는 날에 바라보는 쪽으로 눈덩이를 던지고 팀원들에게 보낸다. 돌아서지 않는다. 집중 중, 알, 헤엄치는 중, 바로 앞이 막혔을 때는
    /// 아무것도 안 한다. 말풍선 키와 같은 연타 제한을 쓴다. 메타몽 모습이나 복사본을 맞히면 눈덩이가 닿을 때 몸통박치기처럼 반응한다.
    private func handleSnowballKey() {
        guard let scene, scene.isSnowDay, !isFocusing, scene.canWalk, !scene.isMeInWater else { return }
        let facing = scene.walker.facing
        guard let shot = PlazaSnowball.aim(from: scene.walker.tile, facing: facing, targets: scene.snowballTargets, map: map) else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.stopDance(memberID: nil)
        var target: String?
        if case .actor(let id, _) = shot.end { target = id }
        session?.sendEmote(.snowball, target: target, pushTiles: TeamEmote.pushTiles(evolutionStage()), snowballDirection: facing)
        let copied = target == PlazaDitto.sceneKey ? shownDitto?.decoyOf : nil
        scene.playSnowball(by: nil, shot: shot) { [weak self] in
            // 복사본이 닿기 전에 비켜섰으면 빗나간 것이다.
            guard let self, target == PlazaDitto.sceneKey, self.scene?.dittoTile == shot.endTile else { return }
            if let copied {
                // 복사본은 닿는 순간 정체를 드러낸다. 몸통박치기와 같이 따라 한 팀원을 알려 모두가 같은 복사본을 찾았다고 안다.
                guard self.shownDitto?.decoyOf == copied else { return }
                self.session?.sendEmote(.decoyFound, target: copied)
                self.showDecoyFound(from: self.memberID(), copied: copied)
            } else if self.shownDitto?.isDecoy == false {
                self.dittoFormTackled(by: self.memberID())
            }
        }
    }

    /// 런타임이 부른다. 누군가 눈덩이를 던졌다. 이 눈 오는 날의 내 화면에 날려 보내고, 맞은 게 나이고 던진 팀원과 같은 줄(6칸 안)이면
    /// 눈덩이가 닿을 때 `direction`으로 `tiles`칸 밀린다. 닿기 전에 창이 가려져도 눈덩이는 바로 닿는다. 눈 오는 날이 아니거나 방향이 없거나
    /// 던진 팀원이 내 광장에 보이지 않으면 버린다. 그린 자리에 없는 표적(모르는 ID, 잠수 중인 팀원)은 빗나간 것으로 날아간다.
    func showSnowball(from sender: String, on target: String?, tiles: Int, direction: PlazaDirection?) {
        guard let scene, let direction, scene.isSnowDay, let from = scene.memberTiles[sender] else { return }
        let isMe = target == memberID()
        let isDitto = target == PlazaDitto.sceneKey
        let resolved: (id: String?, tile: TilePoint)?
        if isMe {
            resolved = scene.isDiving ? nil : (nil, scene.walker.tile)
        } else if isDitto {
            resolved = scene.dittoTile.map { (PlazaDitto.sceneKey, $0) }
        } else if let target, let tile = scene.memberTiles[target], scene.memberIsDiving(target) != true {
            resolved = (target, tile)
        } else {
            resolved = nil
        }
        let shot: PlazaSnowballShot
        if let resolved {
            shot = PlazaSnowballShot(from: from, direction: direction, end: .actor(id: resolved.id, tile: resolved.tile))
        } else if let miss = PlazaSnowball.aim(from: from, facing: direction, targets: [:], map: map) {
            shot = miss
        } else {
            return
        }
        let hit = resolved.map { PlazaSnowball.hits(thrower: from, target: $0.tile, direction: direction) } ?? false
        let pushed = TeamEmote.pushTiles(tiles)
        scene.playSnowball(by: sender, shot: shot) { [weak self] in
            guard let self, hit else { return }
            // 닿을 때 겨눈 칸에 더는 없으면 빗나간 것이다(걸어서 피했다).
            if isMe {
                if self.canBePushed, self.scene?.walker.tile == shot.endTile { self.scene?.pushMe(direction, tiles: pushed) }
            } else if isDitto, self.shownDitto?.isDecoy == false, self.scene?.dittoTile == shot.endTile {
                self.dittoFormTackled(by: sender)
            }
        }
    }

    /// 집중 중이거나 모닥불 메뉴를 연 나는 밀리지 않는다.
    private var canBePushed: Bool { !isFocusing && !isCampfireMenuOpen }

    /// 잠수한 내가 지금 C로 끌어들일 수 있는 물가의 팀원들.
    private func pullTargets(_ scene: PlazaScene) -> [String: TilePoint] {
        let occupied = scene.occupiedTiles()
        return PlazaPullUnder.targets(diver: scene.walker.tile, members: scene.memberTiles, isWater: { [map] in map.isWater($0) },
                                      isFree: { !occupied.contains($0) })
    }

    /// 물귀신: 떠오르면서 한 칸 물러나고, 바라보거나 바로 옆 물가에 선 팀원에게 끌어들인다고 보낸다. 빠지는 것은 그 팀원의 Mac이 정한다.
    /// 끌어들일 팀원이 없으면 아무 일도 없다. 말풍선 키와 같은 연타 제한을 쓴다.
    private func pullUnder() {
        guard let scene, scene.isDiving else { return }
        let targets = pullTargets(scene)
        let me = scene.walker.tile
        guard let id = PlazaTargeting.member(from: me, facing: scene.walker.facing, members: targets), let tile = targets[id] else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.setDiving(false)
        session?.updateDiving(false)
        scene.pushMe(PlazaPathfinder.direction(from: tile, to: me))
        session?.sendEmote(.pull, target: id)
        refreshHint()
    }

    /// 런타임이 부른다. 물귀신이 나를 끌어들였다. 내가 물가에 서 있고 그 팀원이 바로 앞 물속에 있을 때만 그 물 칸으로 빠진다.
    /// 사진 모드에서는 끌려가지 않는다. 창이 닫혀 있으면 아무것도 안 한다.
    func showPull(from sender: String, on target: String?) {
        guard let scene, target == memberID(), !isPhotoMode, let from = scene.memberTiles[sender],
              let d = PlazaPullUnder.drag(victim: scene.walker.tile, puller: from, isWater: { [map] in map.isWater($0) }) else { return }
        scene.plunge(d)   // 끄는 팀원은 물러나는 중이라 그 칸이 비었는지 따지지 않는다
    }

    /// 하트나 폭죽을 나와 그 팀원 머리 위에 함께 띄우고 팀원들에게 보낸다. 말풍선 키와 같은 연타 제한을 쓴다.
    private func greet(_ id: String) {
        guard let scene else { return }
        let now = clock()
        if let last = lastEmoteAt, now.timeIntervalSince(last) < Self.emoteInterval { return }
        lastEmoteAt = now
        scene.stopDance(memberID: nil)
        let kind = greetingKind()
        scene.showEmote(memberID: nil, kind: kind)
        scene.showEmote(memberID: id, kind: kind)
        if id == PlazaDitto.sceneKey {
            session?.sendEmote(kind, target: nil, overDecoy: true)   // 진짜 팀원은 인사받은 줄 모른다
        } else {
            session?.sendEmote(kind, target: id, shared: true)
        }
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
        if isPhotoMode {
            text = nil
        } else if let focus, overlayModel.content == .none, !chatInput.isOpen {
            text = L(.ko).plazaFocusHint(remaining: L(.ko).plazaFocusRemaining(seconds: focus.endsAt.timeIntervalSince(clock())))
        } else if let id = scene?.followingMember, overlayModel.content == .none, !chatInput.isOpen {
            text = hintName(of: id).map { L(.ko).plazaFollowHint(nickname: $0) }
        } else if let scene, scene.isDiving, overlayModel.content == .none, !chatInput.isOpen {
            let targets = pullTargets(scene)
            let id = PlazaTargeting.member(from: scene.walker.tile, facing: scene.walker.facing, members: targets)
            text = id.flatMap { members[$0]?.nickname }.map { L(.ko).plazaPullHint(nickname: $0) } ?? L(.ko).plazaDivingHint
        } else if overlayModel.content == .none, !chatInput.isOpen, let startle = startleHint(), startle.hasTarget {
            text = startle.text
        } else if let hit = scene?.interactionTarget, overlayModel.content == .none, !chatInput.isOpen {
            switch hit.target {
            case .board: text = L(.ko).plazaBoardHint
            case .campfire: text = isCampfireLit ? L(.ko).plazaCampfireJoinHint : L(.ko).plazaCampfireLightHint
            case .member(let id): text = hintName(of: id).map { L(.ko).plazaMemberHint(nickname: $0) }
            }
        }
        if text == nil, !isPhotoMode, focus == nil, overlayModel.content == .none, !chatInput.isOpen { text = startleHint()?.text }
        if overlayModel.hint != text { overlayModel.hint = text }
    }

    func refreshHintForTesting() { refreshHint() }

    /// 앱이 앞이고 광장 창이 키 창이다. 알림 대신 광장 안 안내를 쓸지 가른다.
    var isFrontmost: Bool { frontmostOverride?() ?? (NSApp.isActive && window?.isKeyWindow == true) }

    /// 테스트용 읽기 전용 값.
    var overlayContent: PlazaOverlayContent { overlayModel.content }
    var chatInputForTesting: PlazaChatInput { chatInput }

    /// 런타임이 부른다. 창이 닫혀 있으면(장면이 없으면) 아무것도 안 한다. 인사하기(`other`가 있다)면 받는 팀원(나일 수도
    /// 있다) 위에도 띄운다.
    func showEmote(memberID: String, kind: TeamEmoteKind, alsoOver other: String? = nil, overDecoy: Bool = false) {
        scene?.showEmote(memberID: memberID, kind: kind)
        if let other { scene?.showEmote(memberID: other == self.memberID() ? nil : other, kind: kind) }
        // 복사본에게 한 인사: 복사본이 보일 때만 그 머리 위에도 띄운다.
        if overDecoy, shownDitto?.isDecoy == true { scene?.showEmote(memberID: PlazaDitto.sceneKey, kind: kind) }
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
        // 복사본이 된 팀원에게는 걸어가지 않는다. 진짜인지 묻는 ?만 띄운다(5번 키와 같다).
        if shownDitto?.decoyOf == id {
            handleEmoteKey(.question)
            if let skView { window?.makeFirstResponder(skView) }
            return
        }
        standUp()
        scene?.walk(toMember: id)
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 창에 올리는 목록. 칸은 그 팀원에게 걸어가고, < > 는 페이지를 넘긴다.
    func rosterView() -> PlazaRosterView {
        PlazaRosterView(model: rosterModel, onSelect: { [weak self] in self?.walkToMember($0) },
                        onTurn: { [weak self] in self?.turnRosterPage(by: $0) })
    }

    /// 목록 페이지를 넘긴다. 누른 뒤에도 키는 장면이 받는다.
    func turnRosterPage(by delta: Int) {
        rosterModel.turnPage(by: delta)
        if let skView { window?.makeFirstResponder(skView) }
    }

    /// 대화 기록을 펼치거나 접는다. 누른 뒤에도 키는 장면이 받는다.
    func toggleChatLog() {
        chatLog.isExpanded.toggle()
        if let skView { window?.makeFirstResponder(skView) }
    }

    var isChatLogExpanded: Bool { chatLog.isExpanded }

    // MARK: - 모닥불 집중

    var isFocusing: Bool { focus != nil }
    /// 테스트용 읽기 전용 값: 저장된 집중.
    var preferencesFocusForTesting: PlazaFocus? { preferences.focus }
    var isCampfireMenuOpen: Bool { if case .campfireMenu = overlayModel.content { true } else { false } }

    /// 그 팀원이 아직 집중 중이면 남은 초. 끝 시각은 받을 때만 걸러지므로 지금과 다시 견준다.
    private func focusRemaining(of id: String) -> TimeInterval? {
        guard let end = members[id]?.focusEndsAt else { return nil }
        let left = end.timeIntervalSince(clock())
        return left > 0 ? left : nil
    }

    /// 내가 앉아 있거나 팀원 중 누가 집중 중이면 불이 켜져 있다. 팀원의 끝 시각은 받을 때만 걸러지므로 지금과 다시 견준다.
    var isCampfireLit: Bool {
        let now = clock()
        return focus?.isActive(at: now) == true || members.values.contains { $0.focusEndsAt.map { $0 > now } ?? false }
    }

    /// 지난 실행에서 저장한 집중을 되살린다. 아직 안 끝났으면 창이 없어도 팀원에게 앉은 모습을 알린다. 끝났으면 지운다.
    private func restoreFocus() {
        guard let saved = preferences.focus, saved.isActive(at: clock()),
              let seat = PlazaCampfire.nearestSeat(to: saved.seat) else {
            preferences.focus = nil
            return
        }
        // 모닥불이 옮겨지기 전 버전에서 저장한 자리면 가장 가까운 새 자리로 옮겨 앉힌다(8시간 집중을 잃지 않게).
        let restored = saved.seat == seat.tile ? saved : PlazaFocus(endsAt: saved.endsAt, minutes: saved.minutes, seat: seat.tile)
        if restored != saved { preferences.focus = restored }
        focus = restored
        focusFacing = seat.facing
        session?.updateFocus(endsAt: restored.endsAt)
        session?.updatePlazaPosition(inPlaza: true, tile: seat.tile, facing: seat.facing, isWalking: false)
    }

    /// 가장 가까운 빈 자리에 앉아 집중을 시작한다. 이미 앉아 있거나 빈 자리가 없으면 아무것도 안 한다.
    func startFocus(minutes: Int) {
        guard let scene, focus == nil,
              let seat = PlazaCampfire.nearestFreeSeat(from: scene.walker.tile, occupied: scene.occupiedTiles()) else { return }
        let started = PlazaFocus(endsAt: clock().addingTimeInterval(TimeInterval(minutes * 60)), minutes: minutes, seat: seat.tile)
        focus = started
        focusFacing = seat.facing
        preferences.focus = started
        session?.updateFocus(endsAt: started.endsAt)   // 자리 위치보다 먼저: 자리만 알리고 끝 시각은 빠진 접속 알림이 나가지 않게
        scene.sit(at: seat)
        sendPosition(inPlaza: true, scene: scene)
        refreshCampfire()
    }

    /// 방향키나 목록 선택으로 일어선다. 앉아 있지 않으면 아무것도 안 한다.
    func standUp() {
        guard let focus else { return }
        if !focus.isActive(at: clock()) { endFocusIfDue(); return }   // 이미 끝 시각이 지났으면 마친 것으로 센다
        let total = TimeInterval(focus.minutes * 60)
        let elapsed = total - focus.endsAt.timeIntervalSince(clock())
        endFocus(focus, completed: false, elapsedMinutes: min(focus.minutes, max(0, Int(elapsed / 60))), silently: false)
    }

    /// 끝 시각이 지났으면 끝낸다. 여러 번 불러도 한 번만 끝난다.
    func endFocusIfDue() {
        guard let focus, !focus.isActive(at: clock()) else { return }
        endFocus(focus, completed: true, elapsedMinutes: focus.minutes, silently: false)
    }

    /// 알리지도 축하하지도 않고 끝낸다.
    func endFocusSilently() {
        guard let focus else { return }
        endFocus(focus, completed: false, elapsedMinutes: focus.minutes, silently: true)
    }

    private func endFocus(_ ended: PlazaFocus, completed: Bool, elapsedMinutes: Int, silently: Bool) {
        focus = nil
        preferences.focus = nil
        session?.updateFocus(endsAt: nil)
        if scene == nil {
            // 창이 닫혀 있는 동안 앉은 모습으로 남아 있었다. 이제 광장을 떠난 것으로 알린다.
            session?.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        } else {
            refreshCampfire()
        }
        if completed && !silently {
            scene?.showEmote(memberID: nil, kind: .party)
            session?.sendEmote(.party, target: nil)
        }
        if !silently { onFocusEnd?(PlazaFocusEnd(minutes: ended.minutes, elapsedMinutes: elapsedMinutes, completed: completed)) }
    }

    /// 불, 타이머 글, 안내를 이 순서로 지금에 맞춘다. 끝 시각이 지나도 새 소식은 오지 않으므로 목록의 🔥집중과 작은 지도의 불도 여기서 다시 맞춘다(둘 다 바뀔 때만 쓴다).
    private func refreshCampfire() {
        guard let scene else { return }
        scene.campfireLit = isCampfireLit
        scene.setCampfireTimer(focus.map { PlazaCampfire.clock($0.endsAt.timeIntervalSince(clock())) })
        refreshHint()
        refreshRoster()
        refreshMinimap()
    }

    private func startFocusTick() {
        focusTick?.cancel()
        let sleep = focusTickSleep
        focusTick = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(.seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.endFocusIfDue()
                self.refreshCampfire()
            }
        }
    }

    // MARK: - 메타몽

    var isDittoHost: Bool { dittoBrain != nil }

    private func startDittoLoop() {
        dittoLoop?.cancel()
        let sleep = dittoLoopSleep
        dittoLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.dittoLoopDelay() else { return }   // 기다리는 동안 self 를 붙들지 않는다
                await sleep(delay)
                guard !Task.isCancelled, let self else { return }
                self.advanceDitto(now: self.clock())
            }
        }
    }

    /// 다음 틱까지. 호스트가 걷는 중일 때만 0.05초이고, 서 있으면 두뇌의 다음 할 일까지(최대 0.25초) 잔다. 호스트가 아니면
    /// 시계가 필요 없다: 팀원 소식이 올 때마다 `observeMembers` 가 `advanceDitto` 를 부르니 호스트가 사라진 것을 놓칠 때를 위해서만 1초.
    private func dittoLoopDelay() -> Duration {
        let now = clock()
        guard let brain = dittoBrain else {
            return dittoHost() == memberID() ? Self.dittoWalkingTick : Self.dittoIdleTick
        }
        if brain.isMoving { return Self.dittoWalkingTick }
        let wait = brain.nextWake(now: now).timeIntervalSince(now)
        let ms = Int((wait * 1000).rounded(.up))
        return .milliseconds(min(max(ms, 50), 250))
    }
    private static let dittoWalkingTick = Duration.milliseconds(50)
    private static let dittoIdleTick = Duration.seconds(1)

    /// 한 걸음. 가장 작은 ID의 준비된 Mac이 호스트다. 호스트면 두뇌를 돌려 알리고, 아니면 호스트의 메타몽을 따라 그린다.
    func advanceDitto(now: Date) {
        guard let scene else { return }
        let me = memberID()
        let host = dittoHost()
        let smallerHosts = members.contains { $0.key < me && $0.value.ditto != nil }
        guard host == me, !smallerHosts else {
            dittoBrain = nil
            session?.updateDitto(ready: true, state: nil)
            showReceivedDitto(host.flatMap { members[$0]?.ditto } ?? smallestReceivedDitto())
            return
        }
        let world = dittoWorld(scene: scene, now: now)
        var brain = dittoBrain ?? PlazaDittoBrain(resuming: shownDitto, world: world, now: now,
                                                  seed: dittoSeed())
        let events = brain.tick(now: now, world: world)
        dittoBrain = brain
        if events.contains(.jumped) {
            scene.playJump(memberID: PlazaDitto.sceneKey)
            session?.sendEmote(.decoyJump, target: nil)
        }
        session?.updateDitto(ready: true, state: brain.state)
        showDitto(brain.state, change: PlazaDitto.change(from: shownDitto, to: brain.state))
        // 복사본의 장난. 복사본이 어디서 어느 쪽을 보는지 먼저 알린 뒤에 보낸다.
        for case .pranked(let id) in events {
            playDecoyTackle(on: id)
            session?.sendEmote(.decoyTackle, target: id)
        }
    }

    /// 복사본에게 밀리는 것은 이만큼에 한 번뿐이다. 호스트는 한 번 변신에 몇 번만, 2분 넘게 띄워서 보낸다.
    static let decoyTackleInterval: TimeInterval = 60
    private var lastDecoyTackleAt: Date?

    /// 런타임이 부른다. 메타몽을 돌리는 팀원이 복사본의 몸통박치기를 알렸다. 다른 팀원이 보낸 것은 버린다.
    func showDecoyTackle(from sender: String, on target: String?) {
        guard sender == dittoHost(), let target else { return }
        playDecoyTackle(on: target)
    }

    /// 복사본이 바로 옆의 `target`에게 뛰어든다. 맞은 게 나이면 반대쪽으로 한 칸 밀린다(집중, 모닥불 메뉴, 사진 모드에서는 밀리지 않는다).
    /// 복사본이 지금 보이지 않거나 그 팀원 옆에 없으면 아무것도 안 한다.
    private func playDecoyTackle(on target: String) {
        guard let scene, shownDitto?.isDecoy == true, let from = scene.dittoTile else { return }
        let isMe = target == memberID()
        guard let to = isMe ? scene.walker.tile : scene.memberTiles[target], PlazaPathfinder.isAdjacent(from, to) else { return }
        let direction = PlazaPathfinder.direction(from: from, to: to)
        scene.playTackle(by: PlazaDitto.sceneKey, on: isMe ? nil : target, direction: direction)
        guard isMe, canBePushed, !isPhotoMode else { return }
        let now = clock()
        if let last = lastDecoyTackleAt, now.timeIntervalSince(last) < Self.decoyTackleInterval { return }
        lastDecoyTackleAt = now
        scene.pushMe(direction)
    }

    /// 알리는 팀원들 가운데 가장 작은 ID의 메타몽.
    private func smallestReceivedDitto() -> PlazaDittoState? {
        members.filter { $0.value.ditto != nil }.min { $0.key < $1.key }?.value.ditto
    }

    /// 받은 메타몽을 그린다. 소식이 아직 없으면 마지막 모습 그대로 둔다. 땅이 아닌 칸과 이미 들킨 복사본은 믿지 않는다.
    private func showReceivedDitto(_ state: PlazaDittoState?) {
        guard let state, PlazaDitto.isGround(state.tile, in: map),
              !(state.isDecoy && state.since == foundDittoSince) else { return }
        showDitto(state, change: PlazaDitto.change(from: shownDitto, to: state))
    }

    /// 지금 호스트: 광장에 있고 준비됐거나 메타몽을 알리는 팀원과 나 가운데 가장 작은 ID.
    private func dittoHost() -> String? {
        let others = members.filter { $0.value.inPlaza && ($0.value.dittoReady || $0.value.ditto != nil) }.mapValues { _ in true }
        return PlazaDitto.host(me: memberID(), meReady: true, others: others)
    }

    /// 런타임이 부른다. 누군가 `copied`의 복사본을 몸통박치기로 찾았다. 지금 그 복사본이 보일 때만 받는다. 받으면 바로 메타몽 모습이라 같은 복사본의 두 번째 소식은 저절로 무시된다.
    /// 먼지와 배너를 띄우고 메타몽으로 바로 돌아간다. 호스트의 소식이 따라잡기 전의 옛 복사본은 다시 그리지 않는다.
    func showDecoyFound(from sender: String, copied: String?) {
        guard let scene, let copied, let shown = shownDitto, shown.decoyOf == copied else { return }
        foundDittoSince = shown.since
        let now = clock()
        dittoBrain?.found(now: now)
        showDitto(dittoBrain?.state ?? shown.turnedBack(now: now), change: .turnedBack(shown.tile))
        scene.showEmote(memberID: PlazaDitto.sceneKey, kind: .exclaim)
        let finder = sender == memberID() ? nickname() : members[sender]?.nickname
        if let finder { showBanner(L(.ko).plazaDecoyFound(nickname: finder)) }
    }

    /// 누가 메타몽 모습을 몸통박치기했다. 호스트만 정한다: 반은 그 팀원 반대쪽으로 통통 튕겨 나가고, 반은 쉬는 중이어도,
    /// 옆에 다른 팀원이 있어도 바로 그 팀원으로 변해 달아난다. 호스트가 아니면 호스트의 소식을 기다린다.
    private func dittoFormTackled(by sender: String) {
        guard let scene, var brain = dittoBrain else { return }
        let now = clock()
        guard brain.tackled(by: sender, now: now, world: dittoWorld(scene: scene, now: now)) != .nothing else { return }
        dittoBrain = brain
        session?.updateDitto(ready: true, state: brain.state)
        showDitto(brain.state, change: PlazaDitto.change(from: shownDitto, to: brain.state))
    }

    /// 런타임이 부른다. 호스트의 복사본이 폴짝 뛰었다. 호스트가 아닌 팀원이 보낸 것은 무시한다.
    func showDecoyJump(from sender: String) {
        guard sender == dittoHost(), shownDitto?.isDecoy == true else { return }
        scene?.stopDance(memberID: PlazaDitto.sceneKey)
        scene?.playJump(memberID: PlazaDitto.sceneKey)
    }

    private func dittoWorld(scene: PlazaScene, now: Date) -> PlazaDittoWorld {
        let myID = memberID()
        let myTile = scene.walker.tile
        var copyable: [String: TilePoint] = [:]
        var present: [String: TilePoint] = [myID: myTile]
        for m in members.values {
            guard m.inPlaza, let tile = scene.memberTiles[m.memberID] else { continue }
            present[m.memberID] = tile
            if PlazaDitto.canBeCopied(inPlaza: true, ready: m.dittoReady, isIdle: m.isIdle,
                                      isFocusing: focusRemaining(of: m.memberID) != nil, isEgg: m.character.speciesID == nil) {
                copyable[m.memberID] = tile
            }
        }
        if PlazaDitto.canBeCopied(inPlaza: true, ready: true, isIdle: session?.isIdle ?? false, isFocusing: isFocusing,
                                  isEgg: subject().speciesID == nil) {
            copyable[myID] = myTile
        }
        return PlazaDittoWorld(map: map, blocked: scene.occupiedTiles(except: PlazaDitto.sceneKey).union([myTile]),
                               copyable: copyable, present: present)
    }

    /// 장면, 그림, 작은 지도, 먼지를 한꺼번에 맞춘다. 따라 하는 팀원을 아직 모르면 그리지 않고 이전 모습으로 둔다.
    private func showDitto(_ state: PlazaDittoState?, change: PlazaDittoChange) {
        guard let scene else { return }
        guard let state else {
            shownDitto = nil
            shownDittoLook = nil
            scene.applyDitto(nil)
            refreshMinimap()
            return
        }
        let look: DittoLook
        if let id = state.decoyOf {
            if id == memberID() {
                // 내 칸은 창을 열 때 `refreshRoster` 가 이미 캐시해 두었다. 틱마다 도감을 훑지 않는다.
                look = DittoLook(name: nickname(), color: scene.nameColor,
                                 title: (myEntryCache ?? nil)?.nature.map(L(.ko).plazaNatureTitle), subject: subject())
            } else if let m = members[id], m.inPlaza {
                look = DittoLook(name: m.nickname, color: PlazaNameColor.color(forMemberID: id, chosen: m.nameColor),
                                 title: m.character.nature.map(L(.ko).plazaNatureTitle),
                                 subject: .init(speciesID: m.character.speciesID, isShiny: m.character.isShiny, form: m.character.form))
            } else {
                return
            }
        } else {
            look = DittoLook(name: L(.ko).plazaDittoName,
                             color: PlazaNameColor.color(forMemberID: PlazaDitto.sceneKey, chosen: PlazaDitto.nameHex), title: nil,
                             subject: .init(speciesID: PlazaDitto.speciesID, isShiny: false, form: nil))
        }
        if state == shownDitto, look == shownDittoLook, change == .none { return }
        shownDitto = state
        shownDittoLook = look
        scene.applyDitto(PlazaDittoShown(tile: state.tile, facing: state.facing, isWalking: state.isWalking ?? false,
                                         isRunning: state.isRunning ?? false,
                                         isBouncing: state.isBouncing == true && !state.isDecoy, name: look.name, nameColor: look.color,
                                         title: look.title, isDecoy: state.isDecoy))
        if memberSubjects[PlazaDitto.sceneKey] != look.subject {
            memberSubjects[PlazaDitto.sceneKey] = look.subject
            startMemberLoad(PlazaDitto.sceneKey, subject: look.subject)
        }
        switch change {
        case .none:
            break
        case .transformed:
            scene.stopDance(memberID: PlazaDitto.sceneKey)
            scene.playDittoPoof()
            if let id = state.decoyOf, scene.walkingToMember == id { scene.stopWalkingToMember() }
        case .turnedBack:
            scene.stopDance(memberID: PlazaDitto.sceneKey)
            scene.playDittoPoof()
            if scene.followingMember == PlazaDitto.sceneKey { scene.stopWalkingToMember() }
        }
        // 메타몽 모습도 대상이라, 그 자리에서 모습만 바뀌면 바라보는 대상은 그대로여서 안내가 저절로 다시 그려지지 않는다.
        if change != .none { refreshHint() }
        refreshMinimap()
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

    /// 팀이 정한 밝은 시간대와 날씨 주기를 장면과 지도에 넣는다. 정한 적이 없으면 기본값.
    func applySchedule() {
        let current = schedule()
        let core = current?.coreTime ?? .standard
        let period = current?.period ?? .day
        if minimap.coreTime != core { minimap.coreTime = core }
        scene?.coreTime = core
        scene?.weatherPeriod = period
    }

    /// 작은 지도의 점과 보이는 영역을 지금 상태로 맞춘다.
    private func refreshMinimap() {
        guard let scene else { return }
        var dots = members.values.sorted { $0.memberID < $1.memberID }.compactMap { m -> PlazaMinimapModel.Dot? in
            guard let tile = scene.memberTiles[m.memberID] else { return nil }
            return .init(id: m.memberID, tile: tile, color: scene.memberNameColor(m.memberID) ?? PlazaNameColor.palette[0],
                         isMe: false, isAway: m.isIdle)
        }
        if shownDitto?.isDecoy == true, let tile = scene.dittoTile, let color = scene.memberNameColor(PlazaDitto.sceneKey) {
            dots.append(.init(id: PlazaDitto.sceneKey, tile: tile, color: color, isMe: false, isAway: false))
        }
        dots.append(.init(id: memberID(), tile: scene.walker.tile, color: scene.nameColor, isMe: true, isAway: false))
        if dots != minimap.dots { minimap.dots = dots }
        if scene.visibleWorldRect != minimap.view { minimap.view = scene.visibleWorldRect }
        if scene.itemTile != minimap.item { minimap.item = scene.itemTile }
        let fire = isCampfireLit ? map.campfireTiles.first : nil
        if fire != minimap.campfire { minimap.campfire = fire }
    }

    /// 테스트용 읽기 전용 값.
    var minimapDots: [PlazaMinimapModel.Dot] { minimap.dots }
    var minimapView: CGRect { minimap.view }
    var minimapCoreTime: PlazaCoreTime { minimap.coreTime }
    var minimapCampfire: TilePoint? { minimap.campfire }

    /// 직전에 본 내 자리비움. 자리비움이 막 시작됐을 때만 춤을 멈추려고 기억한다.
    private var wasIdle = false

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
        if session.isIdle && !wasIdle { scene?.stopDance(memberID: nil) }   // 자리비움이 되는 순간만(돌아온 뒤 새 춤은 건드리지 않는다)
        wasIdle = session.isIdle
        if let followed = scene?.followingMember, focusRemaining(of: followed) != nil { scene?.stopWalkingToMember() }
        applyMembersToScene()
        refreshCampfire()
        // 팀원 소식(들어옴·나감·위치·메타몽)이 올 때마다 메타몽도 따라간다. 루프가 돌기 전(광장을 여는 중)에는 건드리지 않는다.
        if dittoLoop != nil { advanceDitto(now: clock()) }
    }

    private func applyMembersToScene() {
        guard let scene else { return }
        learnTaken(members.values.compactMap(\.takenItemSlot))
        let list = members.values.sorted { $0.memberID < $1.memberID }
        scene.applyMembers(list.map {
            PlazaSceneMember(memberID: $0.memberID, nickname: $0.nickname, isAway: !$0.inPlaza, tile: $0.tile,
                             facing: $0.facing ?? .down, isWalking: $0.isWalking, isIdle: $0.isIdle, nameColor: $0.nameColor,
                             isRunning: $0.isRunning, isDiving: $0.isDiving, evolutionStage: $0.evolutionStage,
                             nature: $0.character.nature)
        })
        refreshMinimap()
        let ids = Set(members.keys)
        for id in memberSubjects.keys where !ids.contains(id) && id != PlazaDitto.sceneKey {
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

    /// 재시도 대기 중에는 컨트롤러를 붙들지 않는다(약한 참조). 붙들면 그림이 영영 안 오는 동안 컨트롤러가 닫혀도 안 죽고
    /// 광장 틱이 남의 테스트·옛 클로저를 계속 부른다.
    private func startMemberLoad(_ id: String, subject: CompanionStore.RepresentativeSubject, attempt: Int = 0) {
        nextLoadToken += 1
        let token = nextLoadToken
        memberLoadTokens[id] = token
        Task { [weak self, sleep = spriteRetrySleep] in
            guard await self?.loadMemberFrames(id, subject: subject, token: token, attempt: attempt) == true else { return }
            await sleep(Self.spriteRetryDelay)
            guard !Task.isCancelled, let self, self.memberLoadTokens[id] == token, self.memberSubjects[id] == subject else { return }
            self.startMemberLoad(id, subject: subject, attempt: attempt + 1)
        }
    }

    /// 다시 물어야 하면 true.
    private func loadMemberFrames(_ id: String, subject: CompanionStore.RepresentativeSubject, token: Int, attempt: Int) async -> Bool {
        let frames = await loader.frames(for: subject)
        guard memberLoadTokens[id] == token, let scene else { return false }
        scene.setMemberFrames(id, frames)
        appliedMemberLoads.append((id, subject.speciesID))
        return Self.shouldRetry(frames, attempt: attempt)
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
        current.myEvolutionStage = evolutionStage()
        refreshGeneration += 1
        let generation = refreshGeneration
        applyDiveLimit(generation: generation, speciesID: subject().speciesID)
        let frames = await loader.frames(for: subject())
        // 기다리는 동안 닫혔거나 더 새 요청이 있었으면 버린다.
        guard generation == refreshGeneration, let scene else { return }
        scene.setCharacter(frames)
        if Self.shouldRetry(frames, attempt: attempt) {
            Task { [weak self, sleep = spriteRetrySleep] in
                await sleep(Self.spriteRetryDelay)
                guard !Task.isCancelled, let self, generation == self.refreshGeneration else { return }
                await self.loadCharacter(attempt: attempt + 1)
            }
        }
    }

    /// 종의 타입으로 잠수 한도를 정한다. 더 새 요청이나 닫기가 세대를 올렸으면 낡은 결과를 버린다.
    private func applyDiveLimit(generation: Int, speciesID: Int?) {
        guard let speciesID else { scene?.diveLimit = PlazaPond.diveLimit(types: nil); return }
        Task { [weak self] in
            guard let self else { return }
            let types = await pokemonTypes(speciesID)
            guard generation == refreshGeneration, let scene else { return }
            scene.diveLimit = PlazaPond.diveLimit(types: types)
        }
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
        scene?.setNature(me?.nature)
        let next = PlazaRoster.entries(me: me, meIsIdle: session?.isIdle ?? false, meIsFocusing: isFocusing, members: Array(members.values),
                                       asleep: session.map { Array($0.asleepMembers.values) } ?? [], now: clock())
        if next != rosterModel.entries { rosterModel.entries = next }
    }

    /// 테스트용 읽기 전용 값.
    var rosterEntries: [PlazaRosterEntry] { rosterModel.entries }
    var rosterIsAnimating: Bool { rosterModel.isAnimating }

    /// 마지막 칸을 저장하고 장면과 창 내용을 해제해 그리기를 멈춘다.
    func handleClose() {
        logState("closing")   // 멈춘 광장을 닫아 되살리는 순간의 상태
        if scene?.isDiving == true { scene?.setDiving(false) }
        session?.updateDiving(false)
        renderWatchdog?.cancel()
        renderWatchdog = nil
        focusTick?.cancel()
        focusTick = nil
        dittoLoop?.cancel()
        dittoLoop = nil
        dittoBrain = nil
        foundDittoSince = nil
        shownDitto = nil
        shownDittoLook = nil
        session?.updateDitto(ready: false, state: nil)
        chatInput.close()
        if overlayModel.content == .board { feed?.markAllRead() }
        persistState()
        bannerTask?.cancel()
        bannerTask = nil
        bannerGeneration += 1
        overlayModel.banner = nil
        groupPhoto?.task.cancel()
        groupPhoto = nil
        overlayModel.countdown = nil
        unreadGeneration += 1
        if let scene, session != nil {
            // 앉아 있으면 창을 닫아도 팀원에게는 그 자리에 앉은 채로 남는다.
            if let focus {
                session?.updatePlazaPosition(inPlaza: true, tile: focus.seat, facing: focusFacing, isWalking: false)
            } else {
                session?.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
            }
            scene.onLocalPositionChange = nil
        }
        membersGeneration += 1
        overlayGeneration += 1
        overlayModel.content = .none
        overlayModel.hint = nil
        overlayModel.isPhotoMode = false
        hudViews = []
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
            scene.onPhotoModeChange = nil
            scene.onJumpKey = nil
            scene.onGreetKey = nil
            scene.onTackleKey = nil
            scene.onSnowballKey = nil
            scene.onGroupPhotoKey = nil
            scene.onFireworkKey = nil
            scene.onDanceRound = nil
            scene.isFocusing = { false }
            scene.onItemPickup = nil
            scene.onItemChange = nil
            scene.onFrameClockStall = nil
            scene.onChatKey = nil
            scene.onOverlayKey = nil
            scene.onWalkKey = nil
            scene.onInteractionTargetChange = nil
            scene.isOverlayOpen = false
        }
        skView?.presentScene(nil)
        skView = nil
        renderLoop = nil
        scene = nil
        rosterModel.entries = []
        rosterModel.page = 0
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
        // 가려진 동안은 장면이 돌지 않아 잠수 제한 시간이 흐르지 않는다. 숨기면 잠수를 끝낸다.
        if !visible, scene.isDiving {
            scene.setDiving(false)
            session?.updateDiving(false)
        }
        scene.isPaused = !visible
        logState("rendering visible=\(visible)")
    }

    /// 광장이 멈추는 문제를 진단하려고, 그리기를 멈추거나 되살릴 때와 창이 키 창이 되거나 물러날 때 상태를 한 줄씩 남긴다.
    /// 상태 값만 남기고 내용은 남기지 않는다. `updates`는 장면이 돈 횟수라, 두 줄 사이에 늘지 않으면 장면이 멈춘 것이다.
    /// `t`는 마지막 프레임 시계라, `updates`는 늘어도 `t`가 그대로면 장면은 도는데 시계가 멈춘 것이다. 닫을 때와
    /// 시계가 2초 넘게 멈추거나 다시 흐를 때도 한 줄 남긴다.
    var stateLog: (String) -> Void = { AppLog.write($0) }

    private func logState(_ event: String) {
        func text(_ b: Bool?) -> String { b.map { "\($0)" } ?? "-" }
        stateLog("plaza \(event): occlusionVisible=\(text(window?.occlusionState.contains(.visible))) "
            + "key=\(text(window?.isKeyWindow)) viewPaused=\(text(renderLoop?.isPaused)) "
            + "scenePaused=\(text(scene?.isPaused)) updates=\(scene?.updateCount ?? 0) "
            + "t=\(scene?.lastFrameTime.map { String(format: "%.2f", $0) } ?? "-")")
    }

    /// 그리기를 켜 둔 동안 이만큼마다 장면이 돌았는지 본다.
    static let renderCheckInterval: Duration = .seconds(1)
    private var renderWatchdog: Task<Void, Never>?
    private var lastRenderCheckCount: Int?
    private var renderKicks = 0

    /// 창을 열면 그리기 감시를 시작하고 닫을 때 멈춘다. 다시 열면 새 장면이라 지난 확인 값을 버린다.
    func startRenderWatchdog() {
        renderWatchdog?.cancel()
        lastRenderCheckCount = nil
        renderKicks = 0
        let sleep = renderCheckSleep
        renderWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(Self.renderCheckInterval)
                guard !Task.isCancelled, let self else { return }
                self.checkRendering()
            }
        }
    }

    /// 그리기를 켜 두었는데 지난 확인 뒤로 장면이 한 번도 돌지 않았으면 일시정지했다 다시 풀어 깨운다.
    /// SpriteKit은 일시정지를 풀 때 화면 신호를 다른 큐에서 비동기로 다시 켜는데, 가끔 신호가 꺼진 채 남는다. 그러면
    /// `isPaused`는 false인데 `update`가 불리지 않아 아무도 움직이지 않고, 같은 값을 다시 넣어도 SpriteKit은 아무것도
    /// 하지 않는다. 창이 다시 가려졌다 보여 일시정지를 한 번 더 오가야 돌아왔다. 창 크기를 바꾸는 동안에는 SpriteKit이
    /// 일부러 그리지 않으므로 보지 않는다. 처음 세 번과 그 뒤 60번마다만 남긴다.
    func checkRendering() {
        guard let scene, let loop = renderLoop, !loop.isPaused, !scene.isPaused, window?.inLiveResize != true else {
            lastRenderCheckCount = nil
            return
        }
        defer { lastRenderCheckCount = scene.updateCount }
        guard let last = lastRenderCheckCount else { return }
        if scene.updateCount == last {
            renderKicks += 1
            if renderKicks <= 3 || renderKicks % 60 == 0 { logState("render loop stalled, kick \(renderKicks)") }
            loop.isPaused = true
            loop.isPaused = false
        } else if renderKicks > 0 {
            logState("render loop resumed after \(renderKicks) kick(s)")
            renderKicks = 0
        }
    }

    /// 눌린 키를 모두 뗀다.
    func handleResignKey() {
        scene?.releaseAllKeys()
        refreshCountdown()   // 앞에 있는지가 카운트다운 문구를 바꾼다
    }

    func handleBecomeKey() {
        refreshCountdown()
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
    func windowDidResignKey(_ notification: Notification) {
        handleResignKey()
        logState("resigned key")
    }
    func windowDidBecomeKey(_ notification: Notification) {
        handleBecomeKey()
        logState("became key")
    }
}
