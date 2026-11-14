import Foundation

/// An image the platform made and keeps in its own form (the Mac: the very `CGImage` it got from ImageIO, SpriteKit or
/// a `CGContext`). Shared code never rebuilds it, so colour space and alpha handling stay the platform's.
protocol PlazaNativeImage: AnyObject, Sendable {
    var width: Int { get }
    var height: Int { get }
    /// The image drawn into a premultiplied sRGB RGBA8 buffer of its own size, row 0 at the top.
    func pixels() -> PlazaBitmap
    /// Origin top-left; nil when nothing of `rect` is inside the image.
    func cropping(to rect: PlazaPixelRect) -> (any PlazaNativeImage)?
}

/// A plaza image: either a shared `PlazaBitmap` or a native image. Immutable; the two caches are lock-guarded so an
/// image can be built and read off the main actor.
final class PlazaImage: @unchecked Sendable {
    let width: Int, height: Int
    /// The source, when the image was made from a bitmap.
    let bitmap: PlazaBitmap?
    let native: (any PlazaNativeImage)?

    private let lock = NSLock()
    private var nativePixels: PlazaBitmap?
    private var backend: AnyObject?

    init(bitmap: PlazaBitmap) {
        width = bitmap.width
        height = bitmap.height
        self.bitmap = bitmap
        native = nil
    }

    init(native: any PlazaNativeImage) {
        width = native.width
        height = native.height
        bitmap = nil
        self.native = native
    }

    /// The bitmap itself, or the native image's `pixels()`, computed once.
    var pixels: PlazaBitmap {
        if let bitmap { return bitmap }
        lock.lock()
        defer { lock.unlock() }
        if let nativePixels { return nativePixels }
        let made = native!.pixels()
        nativePixels = made
        return made
    }

    /// Origin top-left, clipped to the image like `CGImage.cropping(to:)`; nil when nothing is left. A native image
    /// crops natively (the Mac: `CGImage.cropping`), so the result is still the platform's own image.
    func cropping(to rect: PlazaPixelRect) -> PlazaImage? {
        if let bitmap {
            let cropped = bitmap.cropped(to: rect)
            return cropped.width > 0 && cropped.height > 0 ? PlazaImage(bitmap: cropped) : nil
        }
        return native!.cropping(to: rect).map(PlazaImage.init(native:))
    }

    /// What the backend made from this image (the Mac keeps the `CGImage` built from a bitmap here).
    var backendCache: AnyObject? {
        get { lock.lock(); defer { lock.unlock() }; return backend }
        set { lock.lock(); backend = newValue; lock.unlock() }
    }
}
