import Foundation

/// Draws text lines into a panel image by their top-left corner (panel points, origin top-left), the way the content panels
/// (roster, board, card) place the `Text`s of their SwiftUI originals: `ascender` puts the baseline, `shadow` is SwiftUI's
/// `.shadow(color: .black.opacity(a), radius: 0, x: 1, y: 1)` (the same line one point right and down, under it).
struct PlazaPen {
    let canvas: any PlazaCanvas
    let space: PlazaPanelSpace
    let ascender: CGFloat

    func line(_ line: PlazaTextLine, x: CGFloat, top: CGFloat, color: PlazaColor, shadow: Double? = nil) {
        let base = space.canvas(CGPoint(x: x, y: top + ascender))
        if let shadow {
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: shadow))
            canvas.draw(line, at: CGPoint(x: base.x + 1, y: base.y - 1))
        }
        canvas.setFillColor(color)
        canvas.draw(line, at: base)
    }

    func fill(_ rect: CGRect, _ color: PlazaColor, radius: CGFloat? = nil) {
        canvas.setFillColor(color)
        if let radius { canvas.fillRoundedRect(space.canvas(rect), radius: radius) } else { canvas.fill(space.canvas(rect)) }
    }
}

/// The cut-off text SwiftUI shows for a `lineLimit(1)` `Text` that is too wide: the end replaced by "…".
enum PlazaPanelText {
    static func cut(_ line: PlazaTextLine, width: CGFloat, font: PlazaFont, text: any PlazaTextEngine, scale: CGFloat) -> PlazaTextLine {
        guard PlazaPanelStyle.pixelUp(line.width, scale: scale) > width else { return line }
        return text.truncated(line, width: max(0, width), ellipsis: text.line("…", font: font)) ?? text.line("", font: font)
    }
}
