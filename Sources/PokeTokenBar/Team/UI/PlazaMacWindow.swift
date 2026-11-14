import AppKit
import SpriteKit
import SwiftUI

extension SKView: PlazaPausableView {}

/// The Mac's plaza window (Track A Task 12): the `NSWindow`, the `SKView` that presents the stage's `SKScene`, the SwiftUI
/// HUD and overlay views over the controller's models, the hosts of the canvas-drawn panels (`PlazaPanelHostView`, Task
/// 14), their constraints, first responder, transparency and the saved frame. Window events go to `events` (the
/// controller); this type decides nothing about the plaza.
@MainActor final class PlazaMacWindow: NSObject, NSWindowDelegate, PlazaWindowShell, PlazaPanelHost {
    weak var events: (any PlazaWindowEvents)?

    /// 창 위치·크기 기억용 이름. 사용자에게 보이는 글이 아니다.
    static let frameAutosaveName = "TeamPlazaWindow"

    private let autosaveName: String
    private let styleMask: NSWindow.StyleMask
    private let front: @MainActor (NSWindow) -> Void
    private var window: NSWindow?
    private var skView: SKView?
    private var chatInput: PlazaChatInput?
    /// 사진 모드에서 숨기는 HUD 뷰. 판과 대화 입력창은 넣지 않는다.
    private var hudViews: [NSView] = []
    /// 입력창이 열리면 대화 기록을 입력창 위로 올린다.
    private var chatLogAboveInput: NSLayoutConstraint?
    private var chatLogAtBottom: NSLayoutConstraint?
    /// The open window's panel hosts and the HUD they show.
    private var panelHosts: [PlazaPanelID: PlazaPanelHostView] = [:]
    private weak var hud: PlazaHUD?

    /// `autosaveName`, `styleMask` and `front` are for tests (a borderless window placed off screen, no activation). `front`
    /// is the only place that activates the app, and it runs only with a window.
    init(autosaveName: String = PlazaMacWindow.frameAutosaveName,
         styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
         front: @escaping @MainActor (NSWindow) -> Void = { NSApp.activate(ignoringOtherApps: true); $0.makeKeyAndOrderFront(nil) }) {
        self.autosaveName = autosaveName
        self.styleMask = styleMask
        self.front = front
    }

    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings) {
        guard let chatInput = overlays.chatInput as? PlazaChatInput else {
            preconditionFailure("PlazaMacWindow needs the AppKit chat field PlazaChatInput (PlatformPlaza.makeChatInput()), got \(type(of: overlays.chatInput))")
        }
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true   // 배경 숨기기
        let w = NSWindow(contentRect: view.frame,
                         styleMask: styleMask,
                         backing: .buffered, defer: false)
        w.title = title
        w.contentMinSize = PlazaWindowController.minContentSize
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.delegate = self
        let container = NSView(frame: view.frame)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let roster = PlazaRosterHostingView(rootView: Self.rosterView(overlays))
        roster.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(roster)   // SKView 위. 입력은 받지 않고 SKView가 첫 응답자를 유지한다.
        NSLayoutConstraint.activate([
            roster.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
            roster.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlazaRosterMetrics.margin),
            roster.widthAnchor.constraint(equalToConstant: PlazaRosterMetrics.width),
        ])
        let hud = overlays.hud, pillsPanel = overlays.pills
        let overlay = PlazaOverlayHostingView(rootView: PlazaOverlayView(model: overlays.overlayModel, feed: overlays.feed,
                                                                   myMemberID: overlays.myMemberID,
                                                                   onReact: overlays.react,
                                                                   onMenuChoose: overlays.chooseMenu,
                                                                   onMenuCancel: overlays.closeOverlay,
                                                                   onCampfireChoose: overlays.chooseCampfire,
                                                                   pillsSize: { [weak hud, weak pillsPanel] in
                                                                       guard let hud, let pillsPanel else { return .zero }
                                                                       return pillsPanel.stack(in: hud.viewport, scale: hud.scale,
                                                                                               text: hud.graphics.text).size
                                                                   }),
                                            model: overlays.overlayModel)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)   // 목록 위. 마우스만 받고 SKView가 첫 응답자를 유지한다.
        let pills = PlazaPanelHostView(hud: hud, panel: .pills)
        pills.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pills)   // 판 바로 위: 안내 줄들은 판의 맨 위에 그려졌다. 입력은 받지 않는다.
        let chatLogView = PlazaChatLogHostingView(rootView: PlazaChatLogView(log: overlays.chatLog, toggle: overlays.toggleChatLog),
                                                  log: overlays.chatLog)
        chatLogView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chatLogView)   // 입력은 받지 않는다.
        let map = PlazaMinimapHostingView(rootView: PlazaMinimapView(
            model: overlays.minimap, background: overlays.backgroundModel, mapImage: overlays.mapImage.nsImage,
            worldSize: overlays.worldSize))
        map.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(map)   // 입력은 받지 않는다.
        let clock = PlazaPanelHostView(hud: hud, panel: .clock)
        clock.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clock)   // 작은 지도 위. 입력은 받지 않는다.
        let shortcuts = PlazaShortcutGuideHostingView(rootView: PlazaShortcutGuide(
            model: overlays.shortcutModel, toggle: overlays.toggleShortcuts))
        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shortcuts)
        let toggle = PlazaBackgroundToggleHostingView(rootView: PlazaBackgroundToggle(
            model: overlays.backgroundModel, toggle: overlays.toggleBackground))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggle)
        let colorPicker = PlazaNameColorPickerHostingView(rootView: PlazaNameColorPicker(
            model: overlays.nameColorModel, toggle: overlays.toggleNameColorPicker,
            choose: overlays.pickNameColor))
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
            toggle.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PlazaRosterMetrics.margin),
            shortcuts.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
            shortcuts.leadingAnchor.constraint(equalTo: toggle.leadingAnchor),
            colorPicker.topAnchor.constraint(equalTo: toggle.topAnchor),
            colorPicker.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 8),
        ])
        // The panel hosts cover the window; the HUD places each panel (the clock on the minimap, as its constraints did).
        for host in [pills, clock] {
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        hudViews = [roster, chatLogView, map, clock, shortcuts, toggle, colorPicker]
        w.contentView = container
        w.center()
        Self.restoreFrame(w, into: overlays.rosterModel, autosaveName: autosaveName)
        panelHosts = [.pills: pills, .clock: clock]
        self.hud = hud
        hud.setViewport(container.bounds.size, scale: w.backingScaleFactor)
        hud.host = self   // renders the visible panels once
        view.presentScene((stage as! SpriteKitStage).skScene)
        w.makeFirstResponder(view)
        self.chatInput = chatInput
        skView = view
        window = w
    }

    /// 저장된 창 크기를 되살린 뒤에 목록 칸 수를 잰다. 되살리는 동안의 windowDidResize 는 `window` 가 아직 nil 이라 못 잰다.
    static func restoreFrame(_ w: NSWindow, into roster: PlazaRosterModel, autosaveName: String = frameAutosaveName) {
        w.setFrameAutosaveName(autosaveName)   // center 뒤에 불러야 저장된 위치가 이긴다
        roster.capacity = PlazaRoster.capacity(forHeight: w.contentView?.bounds.height ?? 0)
    }

    /// 창에 올리는 목록. 칸은 그 팀원에게 걸어가고, < > 는 페이지를 넘긴다.
    static func rosterView(_ overlays: PlazaOverlayBindings) -> PlazaRosterView {
        PlazaRosterView(model: overlays.rosterModel, onSelect: overlays.walkToMember, onTurn: overlays.turnRosterPage)
    }

    /// No window, nothing to bring forward: the app is not activated.
    func bringToFront() {
        guard let window else { return }
        front(window)
    }

    func requestClose() {
        window?.performClose(nil)
    }

    func stopPresenting() {
        skView?.presentScene(nil)
        skView = nil
    }

    func dismantle() {
        hudViews = []
        hud?.host = nil
        hud = nil
        panelHosts = [:]
        if let w = window {
            w.delegate = nil
            w.contentView = nil
        }
        window = nil
    }

    func setTitle(_ title: String) {
        window?.title = title
    }

    func setTransparent(_ transparent: Bool) {
        guard let window else { return }
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.hasShadow = !transparent
    }

    func setHUDHidden(_ hidden: Bool) {
        for view in hudViews { view.isHidden = hidden }
    }

    func focusScene() {
        if let skView { window?.makeFirstResponder(skView) }
    }

    func focusChatInput() {
        if let field = chatInput?.field { window?.makeFirstResponder(field) }
    }

    func show(_ id: PlazaPanelID, image: PlazaImage, frame: CGRect, scale: CGFloat) {
        panelHosts[id]?.show(image: image.cgImage, frame: frame, scale: scale)
    }

    func hide(_ id: PlazaPanelID) {
        panelHosts[id]?.hide()
    }

    func setChatLogAboveInput(_ above: Bool) {
        chatLogAtBottom?.isActive = !above
        chatLogAboveInput?.isActive = above
    }

    var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true }
    var isInLiveResize: Bool { window?.inLiveResize == true }
    var renderLoop: (any PlazaPausableView)? { skView }
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) { (window?.occlusionState.contains(.visible), window?.isKeyWindow) }

    /// 테스트용 읽기 전용 값.
    var windowForTesting: NSWindow? { window }
    var skViewForTesting: SKView? { skView }

    func windowDidResize(_ notification: Notification) {
        guard let height = window?.contentView?.bounds.height else { return }
        events?.contentHeightDidChange(height)
    }
    func windowDidMiniaturize(_ notification: Notification) { events?.setRendering(visible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { events?.setRendering(visible: true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        events?.setRendering(visible: window?.occlusionState.contains(.visible) ?? true)
    }
    func windowWillClose(_ notification: Notification) { events?.handleClose() }
    func windowDidResignKey(_ notification: Notification) { events?.didResignKey() }
    func windowDidBecomeKey(_ notification: Notification) { events?.didBecomeKey() }
}

/// Mac-only conveniences of the shared controller (the SwiftUI roster and the shortcut guide's text live here).
extension PlazaWindowController {
    /// 창에 올리는 목록. 칸은 그 팀원에게 걸어가고, < > 는 페이지를 넘긴다(테스트용; 창은 `overlayBindings`로 같은 것을 만든다).
    func rosterView() -> PlazaRosterView {
        PlazaRosterView(model: rosterModel, onSelect: { [weak self] in self?.walkToMember($0) },
                        onTurn: { [weak self] in self?.turnRosterPage(by: $0) })
    }

    /// 테스트용: 단축키 안내의 V 줄에 적힌 던지는 것.
    var shortcutThrowLabel: String? { PlazaShortcutGuide.entries(season: shortcutSeason).first { $0.key == "V" }?.label }
}
