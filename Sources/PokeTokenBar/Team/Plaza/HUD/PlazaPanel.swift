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

/// One overlay panel: lays itself out, draws itself to an image through the canvas and says where it can be clicked.
/// It renders only when the HUD asks, which happens only after `onChange` (and never while the plaza is hidden).
@MainActor protocol PlazaPanel: AnyObject {
    var id: PlazaPanelID { get }
    var anchor: PlazaPanelAnchor { get }
    /// Points between the panel's image and the anchored edges (see `PlazaPanelAnchor`).
    var offset: CGPoint { get }
    /// Nothing to show: the HUD hides it and does not render it.
    var isVisible: Bool { get }
    /// The image's size in points (what is drawn, strokes included), a whole number of device pixels at `scale`.
    /// `text` measures; it is the engine of the graphics `render` gets.
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize
    /// The panel at `scale` device pixels per point, `size(in:scale:text:)` big.
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaImage?
    /// What a click at `point` (panel points, origin top-left) picks; nil lets the click through to the scene.
    func hit(_ point: CGPoint) -> PlazaPanelHit?
    /// The HUD sets it; the panel calls it whenever what it draws has changed.
    var onChange: (() -> Void)? { get set }
}

/// What shows the HUD's panels: the window on each OS (the Mac's `PlazaMacWindow`, one layer-backed view per panel).
/// `frame` is in window points, origin top-left; the image is `frame.size × scale` pixels.
@MainActor protocol PlazaPanelHost: AnyObject {
    func show(_ id: PlazaPanelID, image: PlazaImage, frame: CGRect, scale: CGFloat)
    func hide(_ id: PlazaPanelID)
}
