import AppKit
import QuartzCore

/// One HUD panel in the Mac's plaza window (Track A Task 14). The view covers the window, so it can sit at its panel's
/// place in the subview order, and draws nothing itself; one sublayer shows the panel's image at the panel's frame
/// (`contents` = the panel's `CGImage`, `contentsScale` = the backing scale, nearest magnification, no implicit
/// animations). Clicks reach it only where the HUD reports an interactive hit on its panel (`hitTest`); everywhere else
/// they go to the views below (the scene). It never takes the keyboard, so the scene or the chat field keeps it.
///
/// Sizing: four constraints pin it to the window's content view and it has no intrinsic size, so its frame never depends
/// on what the panel shows. A panel that grows or shrinks (a banner wrapping to three lines, a countdown coming and
/// going) only changes the sublayer's frame and contents in one step, without implicit animation, never invalidating
/// the view's layout or intrinsic size (the roster's hosting view on `main` crashed by re-invalidating inside the
/// constraint pass).
@MainActor final class PlazaPanelHostView: NSView {
    let panelID: PlazaPanelID
    private let hud: PlazaHUD
    private let panelLayer = CALayer()
    /// The shown frame in window points, origin top-left (the HUD's coordinates).
    private(set) var panelFrame: CGRect?

    init(hud: PlazaHUD, panel: PlazaPanelID) {
        self.hud = hud
        panelID = panel
        super.init(frame: .zero)
        wantsLayer = true
        panelLayer.magnificationFilter = .nearest
        panelLayer.isHidden = true
        panelLayer.actions = ["contents": NSNull(), "contentsScale": NSNull(), "position": NSNull(), "bounds": NSNull(),
                              "hidden": NSNull()]
        layer?.addSublayer(panelLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sublayer, for tests.
    var panelLayerForTesting: CALayer { panelLayer }
    /// For tests: layout passes this view went through, intrinsic-size invalidations (AppKit sends a couple while the
    /// window is set up; a panel's change must send none) and those that came inside a layout pass (never).
    private(set) var layoutPassesForTesting = 0
    private(set) var intrinsicInvalidationsForTesting = 0
    private(set) var intrinsicInvalidationsInLayoutForTesting = 0
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

    func show(image: CGImage, frame: CGRect, scale: CGFloat) {
        panelLayer.contents = image
        panelLayer.contentsScale = scale
        panelFrame = frame
        placeLayer()
        panelLayer.isHidden = false
    }

    func hide() {
        panelLayer.isHidden = true
        panelLayer.contents = nil
        panelFrame = nil
    }

    /// The layer's coordinates have their origin at the bottom (the view is not flipped).
    private func placeLayer() {
        guard let f = panelFrame else { return }
        panelLayer.frame = CGRect(x: f.minX, y: bounds.height - f.maxY, width: f.width, height: f.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeLayer()
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

    /// `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), hud.hit(at: topLeft(local), in: panelID) != nil else { return nil }
        return self
    }

    override var acceptsFirstResponder: Bool { false }

    private func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    private func forward(_ kind: PlazaMouseEvent.Kind, _ event: NSEvent) {
        _ = hud.handleMouse(PlazaMouseEvent(kind: kind, location: topLeft(convert(event.locationInWindow, from: nil))))
    }

    override func mouseDown(with event: NSEvent) { forward(.down, event) }
    override func mouseUp(with event: NSEvent) { forward(.up, event) }
    override func scrollWheel(with event: NSEvent) { forward(.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), event) }
}
