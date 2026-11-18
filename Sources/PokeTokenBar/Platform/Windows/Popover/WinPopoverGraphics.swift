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

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics { base.metrics(Self.mapped(font)) }
    func line(_ text: String, font: PlazaFont) -> PlazaTextLine { base.line(text, font: Self.mapped(font)) }
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? { base.truncated(line, width: width, ellipsis: ellipsis) }
    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph { base.paragraph(text, font: Self.mapped(font), alignment: alignment) }
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine] { base.wrappedLines(text, font: Self.mapped(font), width: width) }
    func line(_ runs: [PlazaTextRun]) -> PlazaTextLine { base.line(mapped(runs)) }
    func wrappedLines(_ runs: [PlazaTextRun], width: CGFloat) -> [PlazaTextLine] { base.wrappedLines(mapped(runs), width: width) }
}
#endif
