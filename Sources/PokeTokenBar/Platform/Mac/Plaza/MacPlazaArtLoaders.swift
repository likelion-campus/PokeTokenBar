import AppKit

/// The art builders' loaders that read bundled files (moved out of the shared `PlazaIceArt.swift` and
/// `PlazaTallGrassArt.swift`): the files are read as `CGImage`s (`MacPlazaAssets.swift`) and handed to the shared
/// builders as native `PlazaImage`s.
extension PlazaIceArt {
    static func load(bundle: Bundle? = PlazaResources.resourceBundle()) -> PlazaIceArt {
        PlazaIceArt(
            gloss: PlazaResources.iceGlossSheet(in: bundle).map { gloss(fromSheet: PlazaImage(cgImage: $0)) },
            cracks: PlazaResources.iceCrackSheet(in: bundle).map { cracks(fromSheet: PlazaImage(cgImage: $0)) } ?? [],
            shards: shards(fromFrames: PlazaResources.iceShatterFrames(in: bundle).map(PlazaImage.init(cgImage:))))
    }
}

extension PlazaTallGrassArt {
    static func load() -> PlazaTallGrassArt? {
        PlazaResources.tallGrassSheet().flatMap { PlazaTallGrassArt(sheet: PlazaImage(cgImage: $0)) }
    }
}

private final class NSImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private let table = NSMapTable<PlazaImage, NSImage>.weakToStrongObjects()

    func image(for plaza: PlazaImage) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = table.object(forKey: plaza) { return cached }
        let made = NSImage(cgImage: plaza.cgImage, size: .zero)
        table.setObject(made, forKey: plaza)
        return made
    }
}

extension PlazaImage {
    /// The image for AppKit/SwiftUI views. One `NSImage` per `PlazaImage`, so SwiftUI sees the same image each time.
    var nsImage: NSImage { Self.nsImages.image(for: self) }

    private static let nsImages = NSImageCache()
}
