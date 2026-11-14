import Foundation

/// The overlay panels the plaza draws through the canvas (Track A Tasks 14–16). The scrolling panels (roster, chat log,
/// board, card) are not here: they stay SwiftUI on the Mac until the Task 17 decision.
enum PlazaPanelID: Hashable, Sendable { case pills, clock, shortcuts, backgroundToggle, nameColorPicker, photoFrame, menu, minimap }

/// The window edge a panel keeps its distance from, as its old Auto Layout constraints did. `offset.x` is the distance
/// from the leading or trailing edge (unused by `topCenter`, which centres), `offset.y` from the top or bottom edge.
/// `fill` covers the window and ignores `offset`.
enum PlazaPanelAnchor: Sendable { case topLeading, topTrailing, topCenter, bottomLeading, bottomTrailing, fill }

/// What a click on a panel picks: `action` names it for whoever owns the panel, `index` the row or swatch, if any.
struct PlazaPanelHit: Equatable, Sendable {
    let action: String
    let index: Int?
}

/// What assistive technology (VoiceOver) finds on a panel. Every panel supplies its items with its drawing, the way its
/// SwiftUI view exposed itself: a `Text` is one `staticText` read as its whole string (also when the pill cuts it), a
/// control is a `button` (later a menu row a `menuItem`) whose press is the same hit a click reports. Decorative parts
/// (strokes, fills, the menu's ▶ marker) get no item. `frame` is in panel points, origin top-left.
struct PlazaAccessibilityItem: Equatable, Sendable {
    enum Role: Equatable, Sendable { case staticText, button, menuItem }
    var frame: CGRect
    var role: Role
    var label: String
    var value: String?
    /// Pressing it (VoiceOver's press) does what a click on it does: `PlazaHUD.press` reports this hit to `onAction`.
    var action: PlazaPanelHit?

    init(frame: CGRect, role: Role, label: String, value: String? = nil, action: PlazaPanelHit? = nil) {
        self.frame = frame
        self.role = role
        self.label = label
        self.value = value
        self.action = action
    }
}

/// One piece of a panel's picture, in panel points (origin top-left), on whole device pixels. A large uniform area is a
/// `color` (no bitmap: the window shows a filled rectangle, so a full-window dim costs nothing to resize); text and
/// shapes are small `image`s, each its drawn content's size.
enum PlazaPanelLayer: Equatable {
    case image(PlazaImage, frame: CGRect)
    case color(PlazaColor, frame: CGRect)

    static func == (a: PlazaPanelLayer, b: PlazaPanelLayer) -> Bool {
        switch (a, b) {
        case let (.image(i, f), .image(j, g)): i === j && f == g
        case let (.color(c, f), .color(d, g)): c == d && f == g
        default: false
        }
    }
}

/// What a panel shows: its layers, bottom first — none at all is a panel that draws nothing but still takes clicks where
/// `hit` says (a full-window click catcher) —, what VoiceOver reads, and whether it changes look under the mouse or while
/// pressed (`tracksMouse`: only then does the window follow the mouse over it).
struct PlazaPanelDrawing {
    var layers: [PlazaPanelLayer] = []
    var accessibility: [PlazaAccessibilityItem] = []
    var tracksMouse = false
}

/// The hit under the mouse and the hit held down, on one panel. The HUD sets it on a panel whose drawing `tracksMouse`
/// (hover only reaches those); a panel that draws a pressed or hovered look renders again (`onChange`) when it changes.
struct PlazaPanelInteraction: Equatable, Sendable {
    var hovered: PlazaPanelHit?
    var pressed: PlazaPanelHit?
}

/// One overlay panel: lays itself out, draws itself (layers and accessibility items) and says where it can be clicked.
/// It renders only when the HUD asks, which happens only after `onChange`, a new size or a new backing scale (and never
/// while the plaza is hidden).
@MainActor protocol PlazaPanel: AnyObject {
    var id: PlazaPanelID { get }
    var anchor: PlazaPanelAnchor { get }
    /// Points between the panel's frame and the anchored edges (see `PlazaPanelAnchor`).
    var offset: CGPoint { get }
    /// The same, for a panel whose place depends on text that is measured (the name-colour picker sits right of the
    /// background toggle, whose width is its text's). The default is `offset`.
    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint
    /// Nothing to show: the HUD hides it, does not render it, and it takes no clicks.
    var isVisible: Bool { get }
    /// The panel's frame size in points, a whole number of device pixels at `scale`. `text` measures; it is the engine
    /// of the graphics `render` gets.
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize
    /// The panel at `scale` device pixels per point, its frame `size(in:scale:text:)` big.
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing
    /// What a click at `point` (panel points, origin top-left) picks; nil lets the click through to what is below.
    func hit(_ point: CGPoint) -> PlazaPanelHit?
    /// The HUD sets it; the panel calls it whenever what it draws has changed.
    var onChange: (() -> Void)? { get set }
    /// Hover and press on this panel (only for a drawing that `tracksMouse`). Panels without a hover or pressed look
    /// leave the default, which ignores it.
    var interaction: PlazaPanelInteraction { get set }
}

extension PlazaPanel {
    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint { offset }

    var interaction: PlazaPanelInteraction {
        get { PlazaPanelInteraction() }
        set {}
    }
}

/// What shows the HUD's panels: the window on each OS (the Mac's `PlazaMacWindow`, one layer-backed view per panel).
/// `frame` is in window points, origin top-left; the drawing's layers are placed inside it. A move shows the same
/// drawing at a new frame.
@MainActor protocol PlazaPanelHost: AnyObject {
    func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat)
    func hide(_ id: PlazaPanelID)
}

/// A panel's drawing space, so no panel converts by hand: layout is in points with the origin top-left (as frames, hits
/// and accessibility items are), the canvas has CoreGraphics' origin at the bottom, and `room` is kept around the
/// content for the half of a stroke that falls outside it (`PlazaPanelStyle.strokeRoom`).
struct PlazaPanelSpace {
    /// The content (the pills, the clock) without the room.
    let content: CGSize
    let room: CGFloat

    init(content: CGSize, room: CGFloat = PlazaPanelStyle.strokeRoom) {
        self.content = content
        self.room = room
    }

    /// The panel's (and its image's) size: the content and the room around it.
    var size: CGSize { CGSize(width: content.width + 2 * room, height: content.height + 2 * room) }

    /// A content rect in panel coordinates (top-left; for hits, accessibility items and layers).
    func panel(_ r: CGRect) -> CGRect { r.offsetBy(dx: room, dy: room) }

    /// A content rect in the canvas's coordinates (bottom-left).
    func canvas(_ r: CGRect) -> CGRect {
        let p = panel(r)
        return CGRect(x: p.minX, y: size.height - p.maxY, width: p.width, height: p.height)
    }

    /// A content point (top-left; a text baseline) in the canvas's coordinates.
    func canvas(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + room, y: size.height - (p.y + room)) }

    /// One image of the whole space at `scale`: `draw` gets a canvas already scaled to points.
    func image(scale: CGFloat, graphics: any PlazaGraphics, _ draw: (any PlazaCanvas) -> Void) -> PlazaImage? {
        guard let canvas = graphics.makeCanvas(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                               colorSpace: .sRGB) else { return nil }
        canvas.scale(x: scale, y: scale)
        draw(canvas)
        return canvas.makeImage()
    }
}
