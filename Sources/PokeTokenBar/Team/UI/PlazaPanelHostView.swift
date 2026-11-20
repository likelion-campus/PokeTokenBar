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
/// panel's frame, for moves and exits; other panels add nothing. A scroll goes to the panel (a scrolling one takes it while it can move that way); one no panel takes goes on up the responder chain.
@MainActor final class PlazaPanelHostView: NSView {
    let panelID: PlazaPanelID
    private let hud: PlazaHUD
    private var sublayers: [CALayer] = []
    private var drawing = PlazaPanelDrawing()
    /// The shown frame in window points, origin top-left (the HUD's coordinates).
    private(set) var panelFrame: CGRect?
    /// One element per accessibility item, in item order; `topLevel` are the ones VoiceOver finds directly under the host (the others are
    /// the children of their scroll area).
    private var elements: [PlazaPanelAccessibilityElement] = []
    private var topLevel: [PlazaPanelAccessibilityElement] = []
    private var elementsByKey: [String: PlazaPanelAccessibilityElement] = [:]
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
        let old = self.drawing.accessibility
        let itemsChanged = panelFrame == nil || old.count != drawing.accessibility.count
            || !zip(old, drawing.accessibility).allSatisfy { $0.sameExceptFrame($1) }
        let tooltipsChanged = panelFrame == nil || drawing.tooltips != self.drawing.tooltips || panelFrame != frame
        self.drawing = drawing
        panelFrame = frame
        if itemsChanged { rebuildElements() }
        place()
        if tooltipsChanged { placeTooltips() }
        updateTrackingAreas()
    }

    // MARK: tooltips

    /// What the window shows when the mouse rests on a tooltip rectangle: the host is the owner, `userData` the index.
    private var tooltipTags: [NSView.ToolTipTag] = []
    private var tooltipTexts: [String] = []

    private func placeTooltips() {
        removeAllToolTips()
        tooltipTags = []
        tooltipTexts = []
        guard !tooltipsSuspended, let f = panelFrame else { return }
        for tip in drawing.tooltips where !tip.text.isEmpty {
            tooltipTexts.append(tip.text)
            let rect = local(tip.frame.offsetBy(dx: f.minX, dy: f.minY))
            tooltipTags.append(addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: tooltipTexts.count)))
        }
    }

    /// For tests: the hover text at a window point (top-left), as the window would ask for it.
    func tooltipForTesting(at point: CGPoint) -> String? {
        guard let f = panelFrame else { return nil }
        let p = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
        return drawing.tooltips.first { !$0.text.isEmpty && $0.frame.contains(p) }?.text
    }

    /// For tests: how many tooltip rectangles the view registered with AppKit.
    var tooltipCountForTesting: Int { tooltipTags.count }

    func hide() {
        removeAllToolTips()
        tooltipTags = []
        tooltipTexts = []
        for l in sublayers { l.removeFromSuperlayer() }
        sublayers = []
        let hadItems = !drawing.accessibility.isEmpty
        drawing = PlazaPanelDrawing()
        panelFrame = nil
        elements = []
        topLevel = []
        elementsByKey = [:]
        if hadItems { announceElements() }
        updateTrackingAreas()
    }

    /// The board and the card: while shown, this host takes every click, hover and scroll anywhere in the window (the full-window SwiftUI
    /// overlay did, above the roster and the scene and below every other panel); the HUD still reports only the plate's own hits.
    var swallowsWholeWindow = false
    private var swallowing: Bool { swallowsWholeWindow && hud.isShown(panelID) }

    /// The roster under an open overlay offers no tooltips (the overlay covered it).
    var tooltipsSuspended = false { didSet { if tooltipsSuspended != oldValue { placeTooltips() } } }

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
            let rect = local(item.frame.offsetBy(dx: f.minX, dy: f.minY))
            e.hostFrame = rect
            // A child's frame is in its scroll area's space (the area's frame origin is the child's zero).
            if let area = e.area { e.setAccessibilityFrameInParentSpace(rect.offsetBy(dx: -area.hostFrame.minX, dy: -area.hostFrame.minY)) }
            else { e.setAccessibilityFrameInParentSpace(rect) }
        }
    }

    /// Elements are kept for the same key (a chat line, a note part, a dex cell): when lines arrive or leave, the others stay the same
    /// objects, so the VoiceOver cursor does not lose its place. Items without a key are identified by position.
    private func rebuildElements() {
        var reuse = elementsByKey
        let before = elements.map { ObjectIdentifier($0) }
        var made: [PlazaPanelAccessibilityElement] = []
        var top: [PlazaPanelAccessibilityElement] = []
        var keyed: [String: PlazaPanelAccessibilityElement] = [:]
        var area: PlazaPanelAccessibilityElement?
        for (i, item) in drawing.accessibility.enumerated() {
            let e: PlazaPanelAccessibilityElement
            if let key = item.key, let old = reuse.removeValue(forKey: key) { e = old }
            else if item.key == nil, i < elements.count, elements[i].key == nil, elements[i].areaRole == (item.role == .scrollArea) { e = elements[i] }
            else { e = PlazaPanelAccessibilityElement() }
            e.key = item.key
            e.setAccessibilityRole(Self.role(item.role))
            e.areaRole = item.role == .scrollArea
            e.setAccessibilityLabel(item.label)
            e.setAccessibilityValue(item.value)
            e.setAccessibilityEnabled(item.isEnabled)
            let hud = hud, id = panelID
            if let action = item.action { e.onPress = { hud.press(action, in: id) } } else { e.onPress = nil }
            e.onScrollToVisible = { hud.scrollIntoView(i, in: id) }
            if item.role == .scrollArea {
                area = e
                e.areaChildren = []
                e.area = nil
                e.setAccessibilityParent(self)
                top.append(e)
            } else if item.inScrollArea, let area {
                e.area = area
                e.setAccessibilityParent(area)
                area.areaChildren.append(e)
            } else {
                e.area = nil
                e.setAccessibilityParent(self)
                top.append(e)
            }
            if let key = item.key { keyed[key] = e }
            made.append(e)
        }
        elements = made
        topLevel = top
        elementsByKey = keyed
        if before != made.map({ ObjectIdentifier($0) }) { announceElements() }
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
        case .scrollArea: .scrollArea
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { topLevel }

    /// For tests: every element in item order (the scroll areas' children included).
    var accessibilityElementsForTesting: [PlazaPanelAccessibilityElement] { elements }

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
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local) else { return nil }
        if swallowing { return self }
        guard hud.hit(at: topLeft(local), in: panelID) != nil else { return nil }
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

    /// A notched wheel reports whole lines, a trackpad points. A line is taken as this many points (AppKit's
    /// `NSScrollView` default line scroll; not measured against SwiftUI's `ScrollView`).
    static let lineScrollStep: CGFloat = 10

    /// For tests: scrolls this host handed on up the responder chain.
    private(set) var scrollsPassedOnForTesting = 0

    override func scrollWheel(with event: NSEvent) {
        let k = event.hasPreciseScrollingDeltas ? 1 : Self.lineScrollStep
        if !forward(.scroll(dx: event.scrollingDeltaX * k, dy: event.scrollingDeltaY * k), event), !swallowing {
            scrollsPassedOnForTesting += 1
            super.scrollWheel(with: event)
        }
    }
}

extension PlazaPanelHostView: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        return MainActor.assumeIsolated {
            return tooltipTexts.indices.contains(index) ? tooltipTexts[index] : ""
        }
    }
}

/// One accessibility item of a panel as AppKit shows it to VoiceOver; its press goes the way a click goes. A scroll area has its items as
/// children and, like any scroll view's content, can be asked to scroll an element into view (`AXScrollToVisible`).
final class PlazaPanelAccessibilityElement: NSAccessibilityElement {
    var onPress: (@MainActor () -> Void)?
    var onScrollToVisible: (@MainActor () -> Void)?
    var key: String?
    var areaRole = false
    var areaChildren: [PlazaPanelAccessibilityElement] = []
    weak var area: PlazaPanelAccessibilityElement?
    /// Where the element is in the host's space (the window's, y up), whatever the space its frame is given in.
    var hostFrame = CGRect.zero

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }

    override func accessibilityChildren() -> [Any]? { areaRole ? areaChildren : nil }

    static let scrollToVisible = NSAccessibility.Action(rawValue: "AXScrollToVisible")

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        var names: [NSAccessibility.Action] = []
        if onPress != nil { names.append(.press) }
        if !areaRole { names.append(Self.scrollToVisible) }
        return names
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        if action == Self.scrollToVisible, let onScrollToVisible { MainActor.assumeIsolated { onScrollToVisible() } }
        else if action == .press, let onPress { MainActor.assumeIsolated { onPress() } }
    }
}
