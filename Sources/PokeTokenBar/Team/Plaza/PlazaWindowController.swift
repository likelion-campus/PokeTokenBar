import AppKit
import SpriteKit

/// 그리기 루프를 멈출 수 있는 뷰. 테스트에서 창 없이 바꿔 끼운다.
@MainActor protocol PlazaPausableView: AnyObject { var isPaused: Bool { get set } }
extension SKView: PlazaPausableView {}

/// 광장 창. 창을 만들지 않고도 장면을 만들 수 있게(`prepareScene`) 나눠 두었다.
@MainActor final class PlazaWindowController: NSObject, NSWindowDelegate {
    private let map: PlazaMap
    private let preferences: PlazaPreferences
    private let loader: PlazaCharacterLoader
    private let nickname: () -> String
    private let memberID: () -> String
    private let subject: () -> CompanionStore.RepresentativeSubject
    private let myRosterEntry: () -> PlazaRosterEntry?
    private let rosterModel = PlazaRosterModel()

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
    /// 닫혀 있으면 nil
    private(set) var scene: PlazaScene?

    init(map: PlazaMap = PlazaMapData.map,
         preferences: PlazaPreferences,
         loader: PlazaCharacterLoader,
         nickname: @escaping () -> String,
         memberID: @escaping () -> String,
         subject: @escaping () -> CompanionStore.RepresentativeSubject,
         myRosterEntry: @escaping () -> PlazaRosterEntry? = { nil }) {
        self.map = map
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
        scene = s
        refreshRoster()
    }

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
        let next = PlazaRoster.sorted(myRosterEntry().map { [$0] } ?? [])
        if next != rosterModel.entries { rosterModel.entries = next }
    }

    /// 테스트용 읽기 전용 값.
    var rosterEntries: [PlazaRosterEntry] { rosterModel.entries }
    var rosterIsAnimating: Bool { rosterModel.isAnimating }

    /// 마지막 칸을 저장하고 장면과 창 내용을 해제해 그리기를 멈춘다.
    func handleClose() {
        persistState()
        if let scene {
            scene.releaseAllKeys()
            scene.isPaused = true
            scene.onZoomChange = nil
            scene.onCloseRequest = nil
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

    func windowDidMiniaturize(_ notification: Notification) { setRendering(visible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { setRendering(visible: true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        setRendering(visible: window?.occlusionState.contains(.visible) ?? true)
    }
    func windowWillClose(_ notification: Notification) { handleClose() }
    func windowDidResignKey(_ notification: Notification) { handleResignKey() }
}
