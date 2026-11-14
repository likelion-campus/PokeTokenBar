import AppKit
import QuartzCore

/// One HUD panel in the Mac's plaza window (Track A Task 14). The view covers the window, so it can sit at its panel's
/// place in the subview order, and draws nothing itself; one sublayer per layer of the panel's drawing shows it inside
/// the panel's frame (an image layer: `contents` = the `CGImage`, `contentsScale` = the backing scale, nearest
/// magnification; a colour layer: only a background colour, no bitmap; never an implicit animation). Clicks reach it
/// only where the HUD reports a hit on its panel (`hitTest`); everywhere else they go to the views below (the scene).
/// It never takes the keyboard, so the scene or the chat field keeps it. VoiceOver sees the drawing's accessibility
/// items as its children; the view itself is not an element.
///
/// Sizing: four constraints pin it to the window's content view and it has no intrinsic size, so its frame never depends
/// on what the panel shows. A panel that grows or shrinks (a banner wrapping to three lines, a countdown coming and
/// going) only changes the sublayers' frames and contents in one step, without implicit animation, never invalidating
/// the view's layout or intrinsic size (the roster's hosting view on `main` crashed by re-invalidating inside the
/// constraint pass).
///
/// The mouse: only a drawing that `tracksMouse` (a panel with a hover or pressed look) gets a tracking area, over the
/// panel's frame, for moves and exits; other panels add nothing. A scroll no panel takes goes on up the responder chain.
@MainActor final class PlazaPanelHostView: NSView {
    let panelID: PlazaPanelID
    private let hud: PlazaHUD
    private var sublayers: [CALayer] = []
    private var drawing = PlazaPanelDrawing()
    /// The shown frame in window points, origin top-left (the HUD's coordinates).
    private(set) var panelFrame: CGRect?
    private var elements: [PlazaPanelAccessibilityElement] = []
    private var tracking: NSTrackingArea?

    init(hud: PlazaHUD, panel: PlazaPanelID) {
        self.hud = hud
        panelID = panel
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// No implicit animation for anything the host sets on a sublayer.
    static let noAnimations: [String: any CAAction] = ["contents": NSNull(), "contentsScale": NSNull(), "position": NSNull(),
                                                      "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]

    /// The sublayers, bottom first (tests).
    var panelLayersForTesting: [CALayer] { sublayers }
    /// For tests: layout passes this view went through, intrinsic-size invalidations (AppKit sends a couple while the
    /// window is set up; a panel's change must send none) and those that came inside a layout pass (never).
    private(set) var layoutPassesForTesting = 0
    private(set) var intrinsicInvalidationsForTesting = 0
    private(set) var intrinsicInvalidationsInLayoutForTesting = 0
    /// For tests: how often VoiceOver was told the elements changed (only when the item list changed).
    private(set) var accessibilityChangesForTesting = 0
    private var isInLayout = false

    override func layout() {
        isInLayout = true
        super.layout()
        isInLayout = false
        layoutPassesForTesting += 1
    }

    override func invalidateIntrinsicContentSize() {
        intrinsicInvalidationsForTesting += 1
        if isInLayout { intrinsicInvalidationsInLayoutForTesting += 1 }
        super.invalidateIntrinsicContentSize()
    }

    func show(drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
        while sublayers.count < drawing.layers.count {
            let l = CALayer()
            l.actions = Self.noAnimations
            l.magnificationFilter = .nearest
            layer?.addSublayer(l)
            sublayers.append(l)
        }
        while sublayers.count > drawing.layers.count { sublayers.removeLast().removeFromSuperlayer() }
        for (l, part) in zip(sublayers, drawing.layers) {
            switch part {
            case .image(let image, _):
                let cg = image.cgImage
                if l.contents as AnyObject? !== cg { l.contents = cg }
                l.contentsScale = scale
                l.backgroundColor = nil
            case .color(let color, _):
                l.contents = nil
                l.backgroundColor = color.cgColor
            }
        }
        let itemsChanged = drawing.accessibility != self.drawing.accessibility || panelFrame == nil
        self.drawing = drawing
        panelFrame = frame
        if itemsChanged { rebuildElements() }
        place()
        updateTrackingAreas()
    }

    func hide() {
        for l in sublayers { l.removeFromSuperlayer() }
        sublayers = []
        let hadItems = !drawing.accessibility.isEmpty
        drawing = PlazaPanelDrawing()
        panelFrame = nil
        elements = []
        if hadItems { announceElements() }
        updateTrackingAreas()
    }

    /// Window points (top-left) to this view's coordinates (bottom-left; the view is not flipped).
    private func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) }

    private func place() {
        guard let f = panelFrame else { return }
        for (l, part) in zip(sublayers, drawing.layers) {
            switch part {
            case .image(_, let r), .color(_, let r): l.frame = local(r.offsetBy(dx: f.minX, dy: f.minY))
            }
        }
        for (e, item) in zip(elements, drawing.accessibility) {
            e.setAccessibilityFrameInParentSpace(local(item.frame.offsetBy(dx: f.minX, dy: f.minY)))
        }
    }

    private func rebuildElements() {
        elements = drawing.accessibility.map { item in
            let e = PlazaPanelAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(Self.role(item.role))
            e.setAccessibilityLabel(item.label)
            if let value = item.value { e.setAccessibilityValue(value) }
            if let action = item.action {
                let hud = hud, id = panelID
                e.onPress = { hud.press(action, in: id) }
            }
            return e
        }
        announceElements()
    }

    private func announceElements() {
        accessibilityChangesForTesting += 1
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private static func role(_ r: PlazaAccessibilityItem.Role) -> NSAccessibility.Role {
        switch r {
        case .staticText: .staticText
        case .button: .button
        case .menuItem: .menuItem
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    private func reportViewport() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        hud.setViewport(bounds.size, scale: window.backingScaleFactor)
    }

    /// Only a drawing that tracks the mouse gets a tracking area (over its frame): hover costs nothing otherwise.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard drawing.tracksMouse, let f = panelFrame else { return }
        let area = NSTrackingArea(rect: local(f), options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    var hasTrackingAreaForTesting: Bool { tracking != nil }

    /// `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), hud.hit(at: topLeft(local), in: panelID) != nil else { return nil }
        return self
    }

    override var acceptsFirstResponder: Bool { false }

    private func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    @discardableResult
    private func forward(_ kind: PlazaMouseEvent.Kind, _ event: NSEvent) -> Bool {
        hud.handleMouse(PlazaMouseEvent(kind: kind, location: topLeft(convert(event.locationInWindow, from: nil))), in: panelID)
    }

    override func mouseDown(with event: NSEvent) { forward(.down, event) }
    override func mouseUp(with event: NSEvent) { forward(.up, event) }
    override func mouseDragged(with event: NSEvent) { forward(.moved, event) }
    override func mouseMoved(with event: NSEvent) { forward(.moved, event) }
    override func mouseEntered(with event: NSEvent) { forward(.moved, event) }
    override func mouseExited(with event: NSEvent) { forward(.exited, event) }

    override func scrollWheel(with event: NSEvent) {
        if !forward(.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), event) { super.scrollWheel(with: event) }
    }
}

/// One accessibility item of a panel as AppKit shows it to VoiceOver; its press goes the way a click goes.
final class PlazaPanelAccessibilityElement: NSAccessibilityElement {
    var onPress: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }
}
