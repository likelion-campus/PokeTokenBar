import AppKit
import CoreText

/// Loads the plaza tileset and pixel font from the SwiftPM resource bundle.
/// `Bundle.module` fatalErrors when its bundle is missing, so the bundle is located here first
/// and `Bundle.module` is only a last candidate for `swift test` / `swift run`.
enum PlazaResources {
    static let bundleName = "PokeTokenBar_PokeTokenBar.bundle"
    /// PostScript name of Galmuri11.ttf (read with `fc-scan`).
    static let fontName = "Galmuri11-Regular"

    static func tileSheet() -> CGImage? { tileSheet(in: resourceBundle()) }

    static func tileSheet(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL("plaza-tiles", "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Registered once, lazily (static let initializers run once and are thread safe).
    private static let defaultRegistration: Bool = registerFonts(in: resourceBundle())

    @discardableResult
    static func registerFonts() -> Bool { defaultRegistration }

    @discardableResult
    static func registerFonts(in bundle: Bundle?) -> Bool {
        guard let url = resourceURL("Galmuri11", "ttf", in: bundle) else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        error?.release()   // the out-parameter error is returned retained
        // Registering the same file again reports "already registered"; that is still success.
        return NSFont(name: fontName, size: 12) != nil
    }

    static func font(size: CGFloat) -> NSFont {
        if defaultRegistration, let font = NSFont(name: fontName, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func font(size: CGFloat, in bundle: Bundle?) -> NSFont {
        if registerFonts(in: bundle), let font = NSFont(name: fontName, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func resourceURL(_ name: String, _ ext: String, in bundle: Bundle?) -> URL? {
        guard let bundle else { return nil }
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "Plaza")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    static func resourceBundle() -> Bundle? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        if let found = resourceBundle(searching: roots) { return found }
        // Bundle.module would fatalError in a packaged .app, so only touch it outside one.
        if Bundle.main.bundleURL.pathExtension != "app" { return Bundle.module }
        return nil
    }

    static func resourceBundle(searching roots: [URL]) -> Bundle? {
        for root in roots {
            let url = root.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
