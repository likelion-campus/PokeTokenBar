import AppKit
import CoreText
import ImageIO

/// Loads the plaza tileset and pixel fonts from the SwiftPM resource bundle (moved from `PlazaResources.swift`).
/// `Bundle.module` fatalErrors when its bundle is missing, so the bundle is located here first
/// and `Bundle.module` is only a last candidate for `swift test` / `swift run`.
extension PlazaResources {
    static func tileSheet() -> CGImage? { tileSheet(in: resourceBundle()) }

    static func tileSheet(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL(tileSheetName, "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 여름에 던지는 물풍선 그림(14×18, 반투명).
    static func waterBalloon() -> CGImage? { waterBalloon(in: resourceBundle()) }

    static func waterBalloon(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL(waterBalloonName, "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func tallGrassSheet() -> CGImage? { tallGrassSheet(in: resourceBundle()) }

    static func tallGrassSheet(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL(tallGrassSheetName, "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func iceCrackSheet(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL(iceCrackSheetName, "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func iceGlossSheet(in bundle: Bundle?) -> CGImage? {
        guard let url = resourceURL(iceGlossSheetName, "png", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Every frame of the shattering-boulder gif; empty when the file is missing.
    static func iceShatterFrames(in bundle: Bundle?) -> [CGImage] {
        guard let url = resourceURL(iceShatterName, "gif", in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
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
