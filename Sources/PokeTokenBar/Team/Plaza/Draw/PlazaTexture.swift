import Foundation

/// An image (or a part of one) as sprites draw it. Always nearest filtering: the plaza is pixel art and every
/// `SKTexture` it made was set to `.nearest`. A backend keeps its own texture in `nativeCache` (the Mac: one
/// `SKTexture` per `PlazaTexture`, so sprites that shared a texture object before still share one).
@MainActor final class PlazaTexture {
    let image: PlazaImage
    /// The part of `image` shown: a unit rect, origin bottom-left (`SKTexture(rect:in:)`). As in SpriteKit, a rect cut
    /// from a cut texture is a part of the whole image, not of the cut.
    let rect: CGRect
    /// The texture this one was cut from. A backend cuts from that texture's own native texture, as
    /// `SKTexture(rect:in:)` did, so the image is not uploaded twice.
    let parent: PlazaTexture?
    var nativeCache: AnyObject?

    init(_ image: PlazaImage) {
        self.image = image
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        parent = nil
    }

    init(rect: CGRect, in parent: PlazaTexture) {
        image = parent.image
        self.rect = rect
        self.parent = parent
    }

    /// `SKTexture.size()`: the image's pixel size times the unit rect.
    var pixelSize: CGSize {
        CGSize(width: CGFloat(image.width) * rect.width, height: CGFloat(image.height) * rect.height)
    }
}
