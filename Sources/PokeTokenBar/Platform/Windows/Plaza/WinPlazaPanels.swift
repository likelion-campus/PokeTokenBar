#if os(Windows)
import Foundation

/// Test-only switches that break one rule of the panel host each, so the tests prove they notice
/// (`WindowsPlazaPanelsTests.testEachInjectedFaultIsCaught`). Debug builds only; in a release build `has` is always false.
@MainActor enum WinPanelFaults {
    enum Fault: CaseIterable, Sendable {
        /// The z list drawn bottom-to-top reversed.
        case wrongZ
        /// A click goes to the top-most panel that is shown instead of the one the hit is on.
        case topPanelTakesHit
        /// An open board or card takes only the clicks on its own plate, not the whole window.
        case coverNotFullWindow
        /// A panel the window hides in photo mode still takes clicks.
        case hiddenStillHit
        /// The backing scale reported to the HUD is always 1 (DPI ignored).
        case dpiIgnored
        /// Every scene frame marks every panel for a new render.
        case rerenderEveryFrame
    }
    static var active: Set<Fault> = []

    @inline(__always) static func has(_ f: Fault) -> Bool {
        #if DEBUG
        return !active.isEmpty && active.contains(f)
        #else
        return false
        #endif
    }
}

/// The Windows window's host of the HUD's panels (D8, D18): the Mac stacks one layer-backed view per panel
/// (`PlazaPanelHostView`) and lets AppKit route a click to the top-most view whose `hitTest` says yes. The Windows window
/// has ONE Direct2D surface, so each panel is a VIRTUAL host here, in the Mac's subview order (`zOrder`), with the same
/// rules: a host takes a click only where the HUD reports a hit on its panel; the board and the card take every click,
/// hover and scroll over the whole window while shown (the roster and the scene under them take none); hidden panels take
/// nothing and are not drawn; a press goes to the host that got the press until the release; a scroll goes to the host
/// under the mouse and no further. The drawing is composed into the window's frame after the scene (`drawList`, in z
/// order), cached: the list changes only when a panel's drawing, frame or visibility changes.
///
/// It owns no timer and draws nothing itself. Main thread only.
@MainActor final class WinPlazaPanels: PlazaPanelHost {
    /// Bottom first: the order `PlazaMacWindow.open` adds its panel hosts to the window.
    static let zOrder: [PlazaPanelID] = [.roster, .board, .card, .photoFrame, .menu, .pills, .chatLog, .minimap, .clock, .shortcuts,
                                         .backgroundToggle, .nameColorPicker]
    /// The hosts that take every click, hover and scroll over the whole window while shown (`swallowsWholeWindow`).
    static let swallowing: Set<PlazaPanelID> = [.board, .card]
    /// What photo mode hides (`PlazaMacWindow.hudViews`): the photo frame, menu, pills, board and card stay.
    static let hiddenInPhotoMode: Set<PlazaPanelID> = [.roster, .chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker]

    struct Entry {
        var drawing: PlazaPanelDrawing
        var frame: CGRect
        var scale: CGFloat
    }

    /// A hover text in window points (origin top-left).
    struct PointTip: Equatable {
        var frame: CGRect
        var text: String
    }

    struct Counts: Equatable {
        var shows = 0, hides = 0, changes = 0, routed = 0, swallowed = 0, scrollsPassedOn = 0
    }

    let hud: PlazaHUD
    /// The drawing or the tooltips changed: the window draws again and rebuilds its tool list.
    var onChange: (() -> Void)?
    private(set) var entries: [PlazaPanelID: Entry] = [:]
    /// The panels to draw over the scene, bottom first (hidden ones left out). The same array until something changes.
    private(set) var drawList: [WinPanelDraw] = []
    /// The hover texts of the shown panels, top-most first, without those of a panel an open board or card covers.
    private(set) var tips: [PointTip] = []
    private(set) var counts = Counts()
    /// The host that got the last press, until the release (the Mac view that got `mouseDown` gets the drag and the `mouseUp`).
    private(set) var captured: PlazaPanelID?
    private var hovered: Set<PlazaPanelID> = []
    private var attached = false
    private static var loggedAccessibility = false

    init(hud: PlazaHUD) {
        self.hud = hud
    }

    // MARK: attaching

    /// Makes this the HUD's host: every visible panel renders once.
    func attach() {
        guard !attached else { return }
        attached = true
        if !Self.loggedAccessibility {
            Self.loggedAccessibility = true
            AppLog.write("plaza window: Narrator / UI Automation for the drawn panels is not available on Windows yet (deferred); "
                + "the accessibility items are kept in WinPlazaPanels.accessibility for stage 7/8")
        }
        hud.host = self
    }

    func detach() {
        guard attached else { return }
        attached = false
        if hud.host === self { hud.host = nil }
        entries = [:]
        hovered = []
        captured = nil
        rebuild()
    }

    /// The window's content size in points and its backing scale (`GetDpiForWindow / 96`).
    func report(size: CGSize, scale: CGFloat) {
        hud.setViewport(size, scale: WinPanelFaults.has(.dpiIgnored) ? 1 : scale)
    }

    // MARK: window states

    /// Photo mode: `PlazaMacWindow.setHUDHidden`.
    func setHidden(_ hidden: Bool) {
        hud.hiddenPanels = hidden ? Self.hiddenInPhotoMode : []
        if hidden { hovered.subtract(Self.hiddenInPhotoMode); if let c = captured, Self.hiddenInPhotoMode.contains(c) { captured = nil } }
        rebuild()
    }

    /// The reserved bar of the chat field (Task 11 sets the real field's height; the Mac reads the bar's frame): the field's line
    /// height + 12 above and 4 below it (`PlazaChatInput`: fieldTop 12, bottom -4).
    var chatBarHeight: CGFloat {
        get { storedChatBarHeight ?? defaultChatBarHeight }
        set { storedChatBarHeight = newValue; if chatLogAbove { applyChatLog() } }
    }
    private var storedChatBarHeight: CGFloat?
    private var chatLogAbove = false

    private var defaultChatBarHeight: CGFloat {
        let m = hud.graphics.text.metrics(.plaza(.body))
        return (m.ascender - m.descender + m.leading).rounded(.up) + 16
    }

    /// While the field is open the chat log sits above it (the panel's `inputHeight`).
    func setChatLogAbove(_ above: Bool) {
        chatLogAbove = above
        applyChatLog()
    }

    private func applyChatLog() {
        guard let panel = hud.panels.first(where: { $0.id == .chatLog }) as? PlazaChatLogPanel else { return }
        panel.inputHeight = chatLogAbove ? chatBarHeight : nil
    }

    /// "Always show scrollbars" (Windows 11: Accessibility > Visual effects) keeps the scrolling panels' indicator on.
    func applyScrollers(alwaysVisible: Bool) {
        for case let panel as any PlazaScrollIndicating in hud.panels where panel.scrollIndicator.alwaysVisible != alwaysVisible {
            panel.scrollIndicator.alwaysVisible = alwaysVisible
        }
    }

    /// `HKCU\Control Panel\Accessibility\DynamicScrollbars` = 0: the user turned "Always show scrollbars" on. Missing or other: overlay.
    static func alwaysShowScrollbars() -> Bool {
        if case .value(let bytes) = WinRegistry.bytes("Control Panel\\Accessibility", "DynamicScrollbars"), bytes.count >= 4 {
            return bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0
        }
        return false
    }

    // MARK: PlazaPanelHost

    func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
        counts.shows += 1
        if let old = entries[id], old.frame == frame, old.scale == scale, old.drawing.layers == drawing.layers,
           old.drawing.tooltips == drawing.tooltips, old.drawing.tracksMouse == drawing.tracksMouse {
            entries[id]?.drawing = drawing   // same picture (accessibility items may differ): nothing to draw again
            return
        }
        entries[id] = Entry(drawing: drawing, frame: frame, scale: scale)
        rebuild()
    }

    func hide(_ id: PlazaPanelID) {
        counts.hides += 1
        guard entries.removeValue(forKey: id) != nil else { return }
        hovered.remove(id)
        if captured == id { captured = nil }
        rebuild()
    }

    /// The window calls this on every frame of its clock: nothing, unless the fault asks for a render per scene frame.
    func frame() {
        if WinPanelFaults.has(.rerenderEveryFrame) { for p in hud.panels { hud.setNeedsRender(p.id) } }
    }

    private var order: [PlazaPanelID] { WinPanelFaults.has(.wrongZ) ? Array(Self.zOrder.reversed()) : Self.zOrder }

    private func isHidden(_ id: PlazaPanelID) -> Bool { hud.hiddenPanels.contains(id) }

    private func rebuild() {
        let list: [WinPanelDraw] = order.compactMap { id in
            guard let e = entries[id], !isHidden(id) else { return nil }
            return WinPanelDraw(layers: e.drawing.layers, frame: e.frame)
        }
        if list != drawList { drawList = list }
        var newTips: [PointTip] = []
        for id in order.reversed() {
            guard let e = entries[id], !isHidden(id), !isCovered(id) else { continue }
            for tip in e.drawing.tooltips where !tip.text.isEmpty {
                newTips.append(PointTip(frame: tip.frame.offsetBy(dx: e.frame.minX, dy: e.frame.minY), text: tip.text))
            }
        }
        tips = newTips
        counts.changes += 1
        onChange?()
    }

    // MARK: routing (the virtual hosts)

    private func zIndex(_ id: PlazaPanelID) -> Int { Self.zOrder.firstIndex(of: id) ?? 0 }

    /// An open board or card is above `id`: it covers it (no click, hover or tooltip reaches `id`).
    func isCovered(_ id: PlazaPanelID) -> Bool {
        Self.swallowing.contains { s in entries[s] != nil && !isHidden(s) && zIndex(s) > zIndex(id) }
    }

    /// `PlazaPanelHostView.hitTest`: whether host `id` takes a click at `point` (window points, top-left).
    func hostTakes(_ id: PlazaPanelID, at point: CGPoint) -> Bool {
        guard let e = entries[id] else { return false }
        if isHidden(id), !WinPanelFaults.has(.hiddenStillHit) { return false }
        if Self.swallowing.contains(id) {
            return WinPanelFaults.has(.coverNotFullWindow) ? e.frame.contains(point) : true
        }
        if WinPanelFaults.has(.topPanelTakesHit) { return true }
        if isHidden(id) { return e.frame.contains(point) }
        return hud.hit(at: point, in: id) != nil
    }

    /// The top-most host, in the Mac's order, that takes a click at `point`; nil: it goes to the scene (which takes none).
    func host(at point: CGPoint) -> PlazaPanelID? {
        order.reversed().first { hostTakes($0, at: point) }
    }

    /// The hosts whose drawing follows the mouse and whose frame holds `point`: what their tracking areas catch.
    private func trackingHosts(at point: CGPoint) -> Set<PlazaPanelID> {
        Set(order.filter { id in
            guard let e = entries[id], e.drawing.tracksMouse, !isHidden(id), !isCovered(id) else { return false }
            return e.frame.contains(point)
        })
    }

    /// For the router: a drawing that tracks the mouse is under this point.
    func tracks(_ point: CGPoint) -> Bool { !trackingHosts(at: point).isEmpty || !hovered.isEmpty }

    /// `WinPlazaInputRouter.onMouse`: true when a panel took the event.
    @discardableResult
    func mouse(_ e: PlazaMouseEvent) -> Bool {
        switch e.kind {
        case .down:
            guard let id = host(at: e.location) else { captured = nil; return false }
            captured = id
            counts.routed += 1
            _ = hud.handleMouse(e, in: id)
            return true   // a host that takes the press owns it, even where the HUD reports no hit (the covers)
        case .up:
            guard let id = captured else { return false }
            captured = nil
            counts.routed += 1
            return hud.handleMouse(e, in: id)
        case .moved:
            if let id = captured {
                counts.routed += 1
                return hud.handleMouse(e, in: id)   // a drag goes to the host that got the press
            }
            let now = trackingHosts(at: e.location)
            for id in hovered.subtracting(now) { _ = hud.handleMouse(PlazaMouseEvent(kind: .exited, location: e.location), in: id) }
            for id in now { _ = hud.handleMouse(e, in: id) }
            hovered = now
            return !now.isEmpty
        case .exited:
            let was = hovered
            hovered = []
            for id in was { _ = hud.handleMouse(e, in: id) }
            return false
        case .scroll:
            guard let id = host(at: e.location) else { return false }
            counts.routed += 1
            let taken = hud.handleMouse(e, in: id)
            if taken { return true }
            if Self.swallowing.contains(id) { counts.swallowed += 1; return true }
            counts.scrollsPassedOn += 1   // the Mac passes it up the responder chain: nothing takes it
            return false
        }
    }

    // MARK: what stage 7/8 will expose

    /// The accessibility items of every shown panel, bottom first (no UI Automation provider yet).
    var accessibility: [(id: PlazaPanelID, items: [PlazaAccessibilityItem])] {
        order.compactMap { id in
            guard let e = entries[id], !isHidden(id), !e.drawing.accessibility.isEmpty else { return nil }
            return (id, e.drawing.accessibility)
        }
    }
}
#endif
