#if os(Windows)
import Foundation

/// The graphics the popover's drawn parts use (visual polish K1): the plaza's graphics with one change, the text engine maps
/// a part's `.system(size:)` font to the Windows type ramp (`WinTypeRamp.drawnSize`: +2 up to 10, +1 for 11-13, unchanged from
/// 14) and bold to semibold, so a drawn part's text grows with the labels around it. `.plaza`, `.emoji` and `.mono` (the recap's
/// LCD) are not mapped. Everything else is the plaza's, so the plaza and the floating pet (which use `PlatformPlaza.graphics`
/// directly) are untouched. A part must be measured and drawn through the SAME graphics: use `WinPopoverGraphics.shared`
/// for both (`WinDrawnView.render`, the companion header, the activity card).
struct WinPopoverGraphics: PlazaGraphics {
    static let shared = WinPopoverGraphics(base: PlatformPlaza.graphics)

    let base: any PlazaGraphics
    let text: any PlazaTextEngine

    init(base: any PlazaGraphics) {
        self.base = base
        text = WinPopoverTextEngine(base: base.text)
    }

    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? { base.makeCanvas(width: width, height: height, colorSpace: colorSpace) }
    func assetURL(_ name: String, ext: String) -> URL? { base.assetURL(name, ext: ext) }
    func decodeImage(at url: URL) -> PlazaImage? { base.decodeImage(at: url) }
    func decodeImage(_ data: Data) -> PlazaImage? { base.decodeImage(data) }
    func decodeImageFrames(at url: URL) -> [PlazaImage] { base.decodeImageFrames(at: url) }
    func encodePNG(_ image: PlazaImage) -> Data? { base.encodePNG(image) }
}

/// The text engine of `WinPopoverGraphics`: the base engine called with mapped fonts. Lines and paragraphs it returns are the
/// base engine's own, so the canvas draws them as before.
struct WinPopoverTextEngine: PlazaTextEngine {
    let base: any PlazaTextEngine

    /// The Windows step of a font.
    static func mapped(_ font: PlazaFont) -> PlazaFont {
        guard case .system(let size, let weight) = font else { return font }
        return .system(size: WinTypeRamp.drawnSize(size), weight: WinTypeRamp.drawnWeight(weight))
    }

    private func mapped(_ runs: [PlazaTextRun]) -> [PlazaTextRun] {
        runs.map { PlazaTextRun(text: $0.text, font: Self.mapped($0.font), color: $0.color) }
    }

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics { WinPopoverLanguage.syncLocale(); return base.metrics(Self.mapped(font)) }
    func line(_ text: String, font: PlazaFont) -> PlazaTextLine { WinPopoverLanguage.syncLocale(); return base.line(text, font: Self.mapped(font)) }
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? { base.truncated(line, width: width, ellipsis: ellipsis) }
    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph { WinPopoverLanguage.syncLocale(); return base.paragraph(text, font: Self.mapped(font), alignment: alignment) }
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine] { WinPopoverLanguage.syncLocale(); return base.wrappedLines(text, font: Self.mapped(font), width: width) }
    func line(_ runs: [PlazaTextRun]) -> PlazaTextLine { WinPopoverLanguage.syncLocale(); return base.line(mapped(runs)) }
    func wrappedLines(_ runs: [PlazaTextRun], width: CGFloat) -> [PlazaTextLine] { WinPopoverLanguage.syncLocale(); return base.wrappedLines(mapped(runs), width: width) }
}
#endif

#if os(Windows)
/// What follows the app language in the popover's text: the DirectWrite format locale (Han and kana glyph forms) and whether GDI
/// semibold is asked as bold (`WinFonts.semiboldIsBold`). The locale reaches the engine when drawn-part text is first made after it
/// changed (`syncLocale`), so a page that has no drawn part never loads DirectWrite for it.
enum WinPopoverLanguage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var wanted = "ko-kr"
    nonisolated(unsafe) private static var applied = "ko-kr"

    @MainActor static func apply(_ language: AppLanguage) {
        lock.lock()
        wanted = WinTextFonts.locale(for: language)
        lock.unlock()
        WinFonts.semiboldIsBold = language == .ko || language == .ja
    }

    /// Called before text is made or measured for a drawn part.
    static func syncLocale() {
        lock.lock()
        let change = wanted != applied ? wanted : nil
        if let change { applied = change }
        lock.unlock()
        if let change { WinTextFonts.shared.setLocale(change) }
    }
}
#endif
