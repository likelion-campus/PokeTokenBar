import AppKit
import CoreText

/// Plaza text sizes. Galmuri is a pixel font: strokes are even only when one font pixel is a whole number of
/// device pixels. At 14pt one Galmuri11 pixel is 2.33 device pixels on a Retina screen, so strokes come out 2 or
/// 3 pixels wide and the letters look broken. Both sizes below are whole on 1x and 2x screens.
enum PlazaTextSize: CaseIterable {
    /// Galmuri14 (a 15-pixel grid) at 15pt.
    case body
    /// Galmuri11 (a 12-pixel grid) at 12pt.
    case small

    var points: CGFloat {
        switch self {
        case .body: 15
        case .small: 12
        }
    }

    /// PostScript name (read with `fc-scan`).
    var fontName: String {
        switch self {
        case .body: "Galmuri14-Regular"
        case .small: "Galmuri11-Regular"
        }
    }

    var fileName: String {
        switch self {
        case .body: "Galmuri14"
        case .small: "Galmuri11"
        }
    }
}

/// Loads the plaza tileset and pixel fonts from the SwiftPM resource bundle.
/// `Bundle.module` fatalErrors when its bundle is missing, so the bundle is located here first
/// and `Bundle.module` is only a last candidate for `swift test` / `swift run`.
enum PlazaResources {
    static let bundleName = "PokeTokenBar_PokeTokenBar.bundle"

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

    /// True when every plaza font is available.
    @discardableResult
    static func registerFonts(in bundle: Bundle?) -> Bool {
        PlazaTextSize.allCases.map { size in
            guard let url = resourceURL(size.fileName, "ttf", in: bundle) else { return false }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            error?.release()   // the out-parameter error is returned retained
            // Registering the same file again reports "already registered"; that is still success.
            return NSFont(name: size.fontName, size: size.points) != nil
        }.allSatisfy { $0 }
    }

    static func font(_ size: PlazaTextSize) -> NSFont {
        if defaultRegistration, let font = NSFont(name: size.fontName, size: size.points) { return font }
        return NSFont.monospacedSystemFont(ofSize: size.points, weight: .regular)
    }

    static func font(_ size: PlazaTextSize, in bundle: Bundle?) -> NSFont {
        if registerFonts(in: bundle), let font = NSFont(name: size.fontName, size: size.points) { return font }
        return NSFont.monospacedSystemFont(ofSize: size.points, weight: .regular)
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
