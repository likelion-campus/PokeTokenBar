import Foundation

/// The overlay panels over the plaza scene, in z order (bottom first), and when they render. A panel renders only when
/// it changed (`PlazaPanel.onChange`; reports in one turn of the main actor render once), the backing scale changed or
/// its size changed, and only while `isRendering` and a host is attached; anything else (a window resize that keeps its
/// size) only moves the drawing it already has. While the plaza is hidden (`isRendering == false`) changes are only
/// remembered, and the changed panels render once when it shows again. The controller's `setRendering` is the one
/// switch, with the render loop and the scene.
@MainActor final class PlazaHUD {
    let panels: [any PlazaPanel]
    let graphics: any PlazaGraphics

    /// The window showing the panels, while one is open. Attaching renders every visible panel once.
    weak var host: (any PlazaPanelHost)? {
        didSet {
            guard host !== oldValue else { return }
            shown = [:]
            dirty = Set(panels.map(\.id))
            flush()
        }
    }

    /// false while the plaza is hidden: nothing renders. Turning it back on renders the panels that changed meanwhile.
    var isRendering = true {
        didSet { if isRendering, !oldValue { flush() } }
    }

    /// The window's content size (points) and backing scale, as the host last reported them.
    private(set) var viewport: CGSize = .zero
    private(set) var scale: CGFloat = 1

    /// How many times each panel has rendered (tests and the idle check).
    private(set) var renderCounts: [PlazaPanelID: Int] = [:]
    var renderCount: Int { renderCounts.values.reduce(0, +) }

    /// A click (down and up on the same hit) on a panel, or VoiceOver's press on an item with that action.
    var onAction: ((PlazaPanelID, PlazaPanelHit) -> Void)?

    private struct Shown {
        let drawing: PlazaPanelDrawing
        let frame: CGRect
        let scale: CGFloat
    }

    private var dirty: Set<PlazaPanelID>
    private var shown: [PlazaPanelID: Shown] = [:]
    private var flushScheduled = false
    private var pressed: (id: PlazaPanelID, hit: PlazaPanelHit)?
    private var hovered: (id: PlazaPanelID, hit: PlazaPanelHit)?

    init(panels: [any PlazaPanel], graphics: any PlazaGraphics = PlatformPlaza.graphics) {
        self.panels = panels
        self.graphics = graphics
        dirty = Set(panels.map(\.id))
        for panel in panels {
            let id = panel.id
            panel.onChange = { [weak self] in self?.setNeedsRender(id) }
        }
    }

    /// The host reports its size and backing scale; panels move at once, and re-render only if their size or the scale
    /// changed.
    func setViewport(_ size: CGSize, scale: CGFloat) {
        guard size != viewport || scale != self.scale else { return }
        viewport = size
        self.scale = scale
        flush()
    }

    /// The panel's content changed: it renders on the main actor's next turn if the plaza is shown (several reports
    /// before then render once), else when it is shown again.
    func setNeedsRender(_ id: PlazaPanelID) {
        dirty.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    /// Where each visible panel goes in a window of `viewport` points (origin top-left), on whole device pixels.
    func layout(viewport: CGSize, scale: CGFloat) -> [PlazaPanelID: CGRect] {
        var frames: [PlazaPanelID: CGRect] = [:]
        for panel in panels where panel.isVisible { frames[panel.id] = frame(of: panel, viewport: viewport, scale: scale) }
        return frames
    }

    /// What a click at `point` (window points, origin top-left) on the shown panel `id` picks.
    func hit(at point: CGPoint, in id: PlazaPanelID) -> PlazaPanelHit? {
        guard let frame = shown[id]?.frame, frame.contains(point),
              let panel = panels.first(where: { $0.id == id }), panel.isVisible else { return nil }
        return panel.hit(CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
    }

    /// The top-most shown panel, in this HUD's order, that takes a click at `point`: for a window that draws every
    /// panel itself in that order. A window that stacks its own views per panel (the Mac) asks per panel instead.
    func hit(at point: CGPoint) -> (id: PlazaPanelID, hit: PlazaPanelHit)? {
        for panel in panels.reversed() {
            if let hit = hit(at: point, in: panel.id) { return (panel.id, hit) }
        }
        return nil
    }

    /// A mouse event the window delivered to panel `id` (its view got it). true when the panel takes it, so it goes no
    /// further. A down and an up on the same hit is a click (`onAction`); moves and presses update the panel's
    /// `interaction` (only panels whose drawing `tracksMouse` get moves). No panel takes the scroll wheel (the scrolling
    /// panels stay SwiftUI), so a scroll is never taken.
    func handleMouse(_ e: PlazaMouseEvent, in id: PlazaPanelID) -> Bool {
        let hit = self.hit(at: e.location, in: id)
        switch e.kind {
        case .down:
            pressed = hit.map { (id, $0) }
            hovered = hit.map { (id, $0) }
            updateInteraction()
            return hit != nil
        case .up:
            guard let p = pressed else { return false }
            pressed = nil
            updateInteraction()
            if p.id == id, let hit, hit == p.hit { onAction?(id, hit) }
            return true
        case .moved:
            hovered = hit.map { (id, $0) }
            updateInteraction()
            return hit != nil
        case .exited:
            if hovered?.id == id { hovered = nil }
            updateInteraction()
            return false
        case .scroll:
            return false
        }
    }

    /// VoiceOver pressed an item of panel `id`: the same as a click on that hit.
    func press(_ hit: PlazaPanelHit, in id: PlazaPanelID) {
        onAction?(id, hit)
    }

    private func updateInteraction() {
        for panel in panels {
            let now = PlazaPanelInteraction(hovered: hovered?.id == panel.id ? hovered?.hit : nil,
                                            pressed: pressed?.id == panel.id ? pressed?.hit : nil)
            if panel.interaction != now { panel.interaction = now }
        }
    }

    private func frame(of panel: any PlazaPanel, viewport: CGSize, scale: CGFloat) -> CGRect {
        let size = panel.size(in: viewport, scale: scale, text: graphics.text)
        let o = panel.offset(in: viewport, scale: scale, text: graphics.text), w = viewport.width, h = viewport.height
        let origin: CGPoint
        switch panel.anchor {
        case .topLeading: origin = CGPoint(x: o.x, y: o.y)
        case .topTrailing: origin = CGPoint(x: w - o.x - size.width, y: o.y)
        case .topCenter: origin = CGPoint(x: PlazaPanelStyle.pixel((w - size.width) / 2, scale: scale), y: o.y)
        case .bottomLeading: origin = CGPoint(x: o.x, y: h - o.y - size.height)
        case .bottomTrailing: origin = CGPoint(x: w - o.x - size.width, y: h - o.y - size.height)
        case .fill: return CGRect(origin: .zero, size: viewport)
        }
        return CGRect(origin: origin, size: size)
    }

    private func flush() {
        for panel in panels { update(panel) }
    }

    private func update(_ panel: any PlazaPanel) {
        guard isRendering, let host, viewport.width > 0, viewport.height > 0 else { return }
        let id = panel.id
        guard panel.isVisible else {
            dirty.remove(id)
            if shown.removeValue(forKey: id) != nil { host.hide(id) }
            if pressed?.id == id { pressed = nil }
            if hovered?.id == id { hovered = nil }
            return
        }
        let frame = frame(of: panel, viewport: viewport, scale: scale)
        if !dirty.contains(id), let s = shown[id], s.scale == scale, s.frame.size == frame.size {
            guard s.frame != frame else { return }
            shown[id] = Shown(drawing: s.drawing, frame: frame, scale: scale)
            host.show(id, drawing: s.drawing, frame: frame, scale: scale)
            return
        }
        dirty.remove(id)
        renderCounts[id, default: 0] += 1
        let drawing = panel.render(scale: scale, viewport: viewport, graphics: graphics)
        shown[id] = Shown(drawing: drawing, frame: frame, scale: scale)
        host.show(id, drawing: drawing, frame: frame, scale: scale)
    }
}
