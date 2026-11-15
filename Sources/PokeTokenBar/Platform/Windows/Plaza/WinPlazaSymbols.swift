#if os(Windows)
import CPlazaD2D
import Foundation

/// The symbols the Mac draws with SF Symbols (`PlatformPlaza.symbolImage`), on Windows (D15): a glyph of Segoe Fluent Icons
/// (Windows 11), else Segoe MDL2 Assets (Windows 10) - the same code points exist in both - drawn through the text engine
/// into an image in the asked colour. A name this does not know, or neither font, gives nil: the panel then draws its own
/// glyph (the shared chrome fallback); nothing here can crash.
enum WinPlazaSymbols {
    enum Family: Equatable, Sendable { case fluent, mdl2 }

    /// Fluent first, MDL2 when only it exists, nil when neither does.
    static func family(fluent: Bool, mdl2: Bool) -> Family? { fluent ? .fluent : (mdl2 ? .mdl2 : nil) }

    /// `eye` = View (E7B3), `eye.slash` = Hide (ED1A); nothing else is drawn from the symbol font.
    static func glyph(for name: String) -> String? {
        switch name {
        case "eye": "\u{E7B3}"
        case "eye.slash": "\u{ED1A}"
        default: nil
        }
    }

    /// What the system has, asked once (the engine's system collection).
    static let installed: Family? = {
        let fonts = (WinPlazaGraphics.shared.text as? WinPlazaTextEngine)?.fonts
        let found = family(fluent: fonts?.hasFamily("Segoe Fluent Icons", system: true) ?? false,
                           mdl2: fonts?.hasFamily("Segoe MDL2 Assets", system: true) ?? false)
        if found == nil { AppLog.write("plaza symbols: neither Segoe Fluent Icons nor Segoe MDL2 Assets is installed; the HUD draws its own eye glyphs") }
        return found
    }()

    /// The glyph is set a quarter larger than the SF Symbol's point size (the symbol fonts' glyphs fill about 0.8 em); the image is
    /// the glyph's ink, whole device pixels, `size` in points.
    static func image(named name: String, pointSize: CGFloat, weight: PlazaFontWeight, scale: CGFloat,
                      color: PlazaColor) -> (image: PlazaImage, size: CGSize)? {
        image(named: name, pointSize: pointSize, scale: scale, color: color, family: installed)
    }

    static func image(named name: String, pointSize: CGFloat, scale: CGFloat, color: PlazaColor,
                      family: Family?) -> (image: PlazaImage, size: CGSize)? {
        guard family != nil, let glyph = glyph(for: name), scale > 0,
              let engine = WinPlazaGraphics.shared.text as? WinPlazaTextEngine,
              let line = engine.symbolLine(glyph, size: Double(pointSize * 1.25)) else { return nil }
        // The ink box comes from a scratch canvas: bounds are relative to the origin, y up.
        guard let probe = WinPlazaGraphics.shared.makeCanvas(width: 4, height: 4, colorSpace: .sRGB) else { return nil }
        let ink = probe.imageBounds(of: line)
        guard ink.width > 0, ink.height > 0 else { return nil }
        let w = Int((ink.width * scale).rounded(.up)), h = Int((ink.height * scale).rounded(.up))
        guard w > 0, h > 0, let canvas = WinPlazaGraphics.shared.makeCanvas(width: w, height: h, colorSpace: .sRGB) else { return nil }
        canvas.scale(x: scale, y: scale)
        canvas.setFillColor(color)
        canvas.draw(line, at: CGPoint(x: -ink.minX, y: -ink.minY))
        guard let image = canvas.makeImage() else { return nil }
        return (image, CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }
}
#endif
