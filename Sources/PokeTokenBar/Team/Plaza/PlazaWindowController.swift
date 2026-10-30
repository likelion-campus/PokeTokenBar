import AppKit
import SpriteKit

/// 광장 창. 창을 만들지 않고도 장면을 만들 수 있게(`prepareScene`) 나눠 두었다.
@MainActor final class PlazaWindowController: NSObject, NSWindowDelegate {
    private let map: PlazaMap
    private let preferences: PlazaPreferences
    private let loader: PlazaCharacterLoader
    private let nickname: () -> String
    private let subject: () -> CompanionStore.RepresentativeSubject

    /// 창 위치·크기 기억용 이름. 사용자에게 보이는 글이 아니다.
    private static let frameAutosaveName = "TeamPlazaWindow"

    /// 한 번만 만든다. 다시 열 때 메인 스레드에서 지도를 다시 그리지 않는다.
    private lazy var mapImage: CGImage = PlazaTileArt.mapImage(map)

    private var window: NSWindow?
    private var skView: SKView?
    private var refreshGeneration = 0
    /// 닫혀 있으면 nil
    private(set) var scene: PlazaScene?

    init(map: PlazaMap = PlazaMapData.map,
         preferences: PlazaPreferences,
         loader: PlazaCharacterLoader,
         nickname: @escaping () -> String,
         subject: @escaping () -> CompanionStore.RepresentativeSubject) {
        self.map = map
        self.preferences = preferences
        self.loader = loader
        self.nickname = nickname
        self.subject = subject
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
            w.contentView = view
            w.center()
            w.setFrameAutosaveName(Self.frameAutosaveName)   // center 뒤에 불러야 저장된 위치가 이긴다
            view.presentScene(scene)
            w.makeFirstResponder(view)
            skView = view
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
        s.onZoomChange = { [preferences] in preferences.zoom = $0 }
        s.onCloseRequest = { [weak self] in self?.window?.performClose(nil) }
        scene = s
    }

    /// 지금 대표 포켓몬 그림을 다시 받아 장면에 넣는다. 장면이 없으면 아무것도 안 한다.
    func refreshCharacter() async {
        guard scene != nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let frames = await loader.frames(for: subject())
        // 기다리는 동안 닫혔거나 더 새 요청이 있었으면 버린다.
        guard generation == refreshGeneration, let scene else { return }
        scene.setCharacter(frames)
    }

    func refreshNickname() {
        scene?.setNickname(nickname())
    }

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
        scene = nil
        refreshGeneration += 1
        if let w = window {
            w.delegate = nil
            w.contentView = nil
        }
        window = nil
    }

    /// 장면이 있으면 지금 칸을 저장한다. 아무것도 해제하지 않는다(앱 종료 때도 부른다).
    func persistState() {
        if let scene { preferences.saveLastTile(scene.walker.tile) }
    }

    /// 최소화·완전히 가려진 동안은 그리지 않는다.
    func setRendering(visible: Bool) {
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
