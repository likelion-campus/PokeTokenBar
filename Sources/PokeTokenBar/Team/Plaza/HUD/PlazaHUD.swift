import Foundation

/// The overlay panels over the plaza scene, in z order (bottom first), and when they render. A panel renders only when
/// it changed (`PlazaPanel.onChange`), the backing scale changed or its size changed, and only while `isRendering` and a
/// host is attached; anything else (a window resize that keeps its size) only moves the image it already has. While the
/// plaza is hidden (`isRendering == false`) changes are only remembered, and the changed panels render once when it
/// shows again. The controller's `setRendering` is the one switch, with the render loop and the scene.
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

    /// A click (down and up on the same hit) on a panel.
    var onAction: ((PlazaPanelID, PlazaPanelHit) -> Void)?

    private struct Shown {
        let image: PlazaImage
        let frame: CGRect
        let scale: CGFloat
    }

    private var dirty: Set<PlazaPanelID>
    private var shown: [PlazaPanelID: Shown] = [:]
    private var pressed: (id: PlazaPanelID, hit: PlazaPanelHit)?

    init(panels: [any PlazaPanel], graphics: any PlazaGraphics = PlatformPlaza.graphics) {
        self.panels = panels
        self.graphics = graphics
        dirty = Set(panels.map(\.id))
        for panel in panels {
            let id = panel.id
            panel.onChange = { [weak self] in self?.setNeedsRender(id) }
        }
    }

    /// The host reports its size and backing scale; panels move, and re-render only if their size or the scale changed.
    func setViewport(_ size: CGSize, scale: CGFloat) {
        guard size != viewport || scale != self.scale else { return }
        viewport = size
        self.scale = scale
        flush()
    }

    /// The panel's content changed: it renders now if the plaza is shown, else when it is shown again.
    func setNeedsRender(_ id: PlazaPanelID) {
        dirty.insert(id)
        if let panel = panels.first(where: { $0.id == id }) { update(panel) }
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

    /// The top-most shown panel that takes a click at `point`.
    func hit(at point: CGPoint) -> (id: PlazaPanelID, hit: PlazaPanelHit)? {
        for panel in panels.reversed() {
            if let hit = hit(at: point, in: panel.id) { return (panel.id, hit) }
        }
        return nil
    }

    /// true when a panel takes the event (the scene must not get it). A click is a down and an up on the same hit;
    /// it goes to `onAction`.
    func handleMouse(_ e: PlazaMouseEvent) -> Bool {
        switch e.kind {
        case .down:
            pressed = hit(at: e.location)
            return pressed != nil
        case .up:
            defer { pressed = nil }
            guard let p = pressed else { return false }
            if let now = hit(at: e.location), now == p { onAction?(p.id, p.hit) }
            return true
        case .moved, .exited, .scroll:
            return hit(at: e.location) != nil
        }
    }

    private func frame(of panel: any PlazaPanel, viewport: CGSize, scale: CGFloat) -> CGRect {
        let size = panel.size(in: viewport, scale: scale, text: graphics.text)
        let o = panel.offset, w = viewport.width, h = viewport.height
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
            return
        }
        let frame = frame(of: panel, viewport: viewport, scale: scale)
        if !dirty.contains(id), let s = shown[id], s.scale == scale, s.frame.size == frame.size {
            guard s.frame != frame else { return }
            shown[id] = Shown(image: s.image, frame: frame, scale: scale)
            host.show(id, image: s.image, frame: frame, scale: scale)
            return
        }
        dirty.remove(id)
        renderCounts[id, default: 0] += 1
        guard let image = panel.render(scale: scale, viewport: viewport, graphics: graphics) else {
            if shown.removeValue(forKey: id) != nil { host.hide(id) }
            return
        }
        shown[id] = Shown(image: image, frame: frame, scale: scale)
        host.show(id, image: image, frame: frame, scale: scale)
    }
}
