import Foundation

/// A drawn part of the Windows popover (stage 7, D7): limit and growth bars, badges, the companion header art, the
/// evolution line, trend bars, the heatmap, the recap card. It renders a `PlazaPanelDrawing` (layers, accessibility
/// items, tooltips) through `PlatformPlaza.graphics` and leaves sprite slots for the host to animate. Headless, so the
/// parts are tested on both systems. Stub from Task 1 so Task 3's host and Task 2's models share one signature; Task 3
/// owns it from here.
@MainActor protocol PopoverPart: AnyObject {
    /// The part's size at `width` (DIP) and `scale` (pixels per DIP), measured with `text`.
    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize
    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing
    /// What the point (DIP, part coordinates) hits, as the plaza panels report it.
    func hit(_ point: CGPoint) -> PlazaPanelHit?
    /// Set by the host; the part calls it when it must be measured and rendered again.
    var onChange: (() -> Void)? { get set }
}

/// One render of a part: the drawing, and where the host draws sprite frames on top of it.
struct PopoverDrawing {
    var drawing: PlazaPanelDrawing
    var spriteSlots: [SpriteSlot] = []
    // --- stage 7 Task 9: what is drawn over the sprites, and what changed (begin) ---
    /// Layers drawn over the sprites (part coordinates, the drawing's own space): a celebration's flash and bursts, the
    /// evolution line's edge fade and chevrons. Empty for most parts.
    var overlays: [PlazaPanelLayer] = []
    /// The region (part coordinates) that differs from the previous render, when the part knows it (a celebration frame
    /// changes only the sprite box); nil = everything.
    var dirty: CGRect? = nil
    // --- stage 7 Task 9 (end) ---
}

/// A place the host draws a sprite into (D16): the frame in part coordinates, which sprite, whether it bobs (a still
/// sprite) and whether it animates.
struct SpriteSlot: Equatable {
    var frame: CGRect
    var subject: PlazaSpriteSubjectKey?
    var bob: Bool
    var animated: Bool
    // --- stage 7 Task 9: how the sprite is drawn into the slot (begin) ---
    /// The Mac's `.opacity` on the sprite (an evolution line's future node: 0.32).
    var opacity: Double = 1
    /// The Mac's `.saturation` (a future node: 0.4; 0 = grey, 1 = as it is).
    var saturation: Double = 1
    /// The Mac's `.rotationEffect`, degrees clockwise about the slot's centre (the imminent egg's wiggle, ±5).
    var rotation: Double = 0
    // --- stage 7 Task 9 (end) ---
}

/// Which sprite a slot shows, in the terms `PlazaStoreSpriteFetcher` loads by: a species with its shiny, form and back
/// flags, or the egg (`speciesID` nil).
struct PlazaSpriteSubjectKey: Hashable, Sendable {
    var speciesID: Int?
    var shiny = false
    var form: PokemonForm?
    var back = false
}
