import AppKit
import SpriteKit

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
    /// While the chat field is open the chat log sits above it (the panel's `inputHeight`); the field's frame changes (its emoji
    /// panel opening) move the log with it.
    private var chatLogAbove = false
    private var chatBarObserver: (any NSObjectProtocol)?
    /// The system's scroller style and the window's appearance, as the scrolling panels' indicators show them.
    private var scrollerObservers: [any NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
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
        let container = PlazaWindowContentView(frame: view.frame)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let hud = overlays.hud
        // One host per panel, added bottom first in the shared stack order (the Windows window draws the same list); each takes the
        // clicks of its panel only (`hitTest`) and never the keyboard.
        var panelHosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        for id in PlazaPanelID.stackOrder {
            let host = PlazaPanelHostView(hud: hud, panel: id)
            host.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host)
            panelHosts[id] = host
        }
        let chatBar = chatInput.view
        chatBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chatBar)   // 판 위. 열린 동안에만 입력창이 첫 응답자가 된다.
        NSLayoutConstraint.activate([
            chatBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            chatBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            chatBar.widthAnchor.constraint(equalToConstant: PlazaChatLog.width),
        ])
        // The panel hosts cover the window; the HUD places each panel (the clock on the minimap, the guide under the toggle and the picker beside it, as their constraints did).
        for host in PlazaPanelID.stackOrder.compactMap({ panelHosts[$0] }) {
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        hudViews = PlazaPanelID.stackOrder.filter { PlazaPanelID.hiddenInPhotoMode.contains($0) }.compactMap { panelHosts[$0] }
        w.contentView = container
        w.center()
        Self.restoreFrame(w, into: overlays.rosterModel, autosaveName: autosaveName)
        for id in PlazaPanelID.swallowingWholeWindow { panelHosts[id]?.swallowsWholeWindow = true }
        self.panelHosts = panelHosts
        self.hud = hud
        hud.setViewport(container.bounds.size, scale: w.backingScaleFactor)
        self.chatInput = chatInput
        chatBar.postsFrameChangedNotifications = true
        chatBarObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: chatBar, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeChatLog(forceLayout: false) }   // read the frame only: this can run inside a layout pass
        }
        window = w
        watchScrollers(w)
        hud.host = self   // renders the visible panels once
        view.presentScene((stage as! SpriteKitStage).skScene)
        w.makeFirstResponder(view)
        skView = view
    }

    /// 저장된 창 크기를 되살린 뒤에 목록 칸 수를 잰다. 되살리는 동안의 windowDidResize 는 `window` 가 아직 nil 이라 못 잰다.
    static func restoreFrame(_ w: NSWindow, into roster: PlazaRosterModel, autosaveName: String = frameAutosaveName) {
        w.setFrameAutosaveName(autosaveName)   // center 뒤에 불러야 저장된 위치가 이긴다
        roster.capacity = PlazaRoster.capacity(forHeight: w.contentView?.bounds.height ?? 0)
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
        if let chatBarObserver { NotificationCenter.default.removeObserver(chatBarObserver) }
        chatBarObserver = nil
        scrollerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        scrollerObservers = []
        appearanceObservation = nil
        chatLogAbove = false
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
        hud?.hiddenPanels = hidden ? Set(hudViews.compactMap { ($0 as? PlazaPanelHostView)?.panelID }) : []
    }

    func focusScene() {
        if let skView { window?.makeFirstResponder(skView) }
    }

    func focusChatInput() {
        if let field = chatInput?.field { window?.makeFirstResponder(field) }
    }

    func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
        panelHosts[id]?.show(drawing: drawing, frame: frame, scale: scale)
        if id == .board || id == .card { coverRoster() }
    }

    func hide(_ id: PlazaPanelID) {
        panelHosts[id]?.hide()
        if id == .board || id == .card { coverRoster() }
    }

    /// An open board or card covers the roster: no tooltips under it.
    private func coverRoster() {
        panelHosts[.roster]?.tooltipsSuspended = [PlazaPanelID.board, .card].contains { panelHosts[$0]?.panelFrame != nil }
    }

    func setChatLogAboveInput(_ above: Bool) {
        chatLogAbove = above
        placeChatLog(forceLayout: true)
    }

    /// The log sits above the chat field's top (16 + the field's height + 8 from the bottom) while the field is open.
    /// Layout is forced only at the explicit moment the field opens, and never from inside a layout pass (the emoji panel resizes the bar
    /// DURING the window's pass; forcing layout from that notification re-entered it: the #169 class).
    private func placeChatLog(forceLayout: Bool) {
        guard let panel = hud?.panels.first(where: { $0.id == .chatLog }) as? PlazaChatLogPanel else { return }
        if chatLogAbove, let bar = chatInput?.view {
            if forceLayout, let content = window?.contentView as? PlazaWindowContentView, !content.isInLayout { content.layoutSubtreeIfNeeded() }
            panel.inputHeight = bar.frame.height
        } else {
            panel.inputHeight = nil
        }
    }

    /// "Always show scroll bars" keeps the indicator on; the dark appearance makes it light. Both follow changes while open.
    private func watchScrollers(_ w: NSWindow) {
        func apply() {
            let always = NSScroller.preferredScrollerStyle == .legacy
            let dark = w.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (hud?.panels.first { $0.id == .card } as? PlazaCardPanel)?.isDark = dark   // the card's rarity colours are adaptive system colours
            for case let panel as any PlazaScrollIndicating in hud?.panels ?? [] {
                panel.scrollIndicator.alwaysVisible = always
                panel.scrollIndicator.isDark = dark
            }
        }
        apply()
        scrollerObservers = [NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
                                                                    queue: .main) { _ in MainActor.assumeIsolated { apply() } }]
        appearanceObservation = w.observe(\.effectiveAppearance) { _, _ in MainActor.assumeIsolated { apply() } }
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

/// Mac-only conveniences of the shared controller (the shortcut guide's text lives here).
extension PlazaWindowController {
    /// 테스트용: 단축키 안내의 V 줄에 적힌 던지는 것.
    var shortcutThrowLabel: String? { PlazaShortcutGuide.entries(season: shortcutSeason).first { $0.key == "V" }?.label }
}

/// The window's content view. It only counts (for tests) the layout calls made while it is laying out: nothing may force layout from inside
/// a pass.
final class PlazaWindowContentView: NSView {
    private(set) var isInLayout = false
    private(set) var forcedLayoutsDuringLayoutForTesting = 0

    override func layout() {
        let was = isInLayout
        isInLayout = true
        super.layout()
        isInLayout = was
    }

    override func layoutSubtreeIfNeeded() {
        if isInLayout { forcedLayoutsDuringLayoutForTesting += 1 }
        super.layoutSubtreeIfNeeded()
    }
}
