import Foundation
import Observation

/// One pill laid out in its panel: the frame (content points, origin top-left, strokes not included — see
/// `PlazaPanelSpace`), its text lines, each with the point where it is drawn (x from the pill's left edge, the
/// baseline's y from the pill's top edge), and the whole text (what VoiceOver reads, also when the pill cuts it).
struct PlazaPill {
    let style: PlazaPanelStyle.Pill
    var frame: CGRect
    let lines: [(line: PlazaTextLine, at: CGPoint)]
    let text: String

    /// A one-line pill (`lineLimit(1)`): the text is cut at the end with "…" when it is wider than `maxTextWidth`.
    static func oneLine(_ string: String, style: PlazaPanelStyle.Pill, maxTextWidth: CGFloat, scale: CGFloat,
                        text: any PlazaTextEngine) -> PlazaPill {
        var line = text.line(string, font: style.font)
        if line.width > maxTextWidth {
            line = text.truncated(line, width: maxTextWidth, ellipsis: text.line("…", font: style.font)) ?? text.line("", font: style.font)
        }
        let box = textBox(lines: [line], font: style.font, text: text)
        let width = PlazaPanelStyle.pixelUp(box.width, scale: scale)
        let size = CGSize(width: width + 2 * style.padding.width, height: box.height + 2 * style.padding.height)
        return PlazaPill(style: style, frame: CGRect(origin: .zero, size: size),
                         lines: [(line, CGPoint(x: style.padding.width, y: style.padding.height + box.baselines[0]))], text: string)
    }

    /// A centred, wrapping pill `width` wide (the banner): the lines break as SwiftUI's `Text` breaks them
    /// (`PlazaTextEngine.wrappedLines`). As SwiftUI places them (measured): the text, as wide as its widest line, is
    /// centred on whole device pixels, and each line is centred in the text without rounding (at 1x a line can start
    /// on a half pixel, as before).
    static func wrapped(_ string: String, style: PlazaPanelStyle.Pill, width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> PlazaPill {
        let inner = width - 2 * style.padding.width
        let lines = text.wrappedLines(string, font: style.font, width: inner)
        let box = textBox(lines: lines, font: style.font, text: text)
        let size = CGSize(width: width, height: box.height + 2 * style.padding.height)
        let textWidth = PlazaPanelStyle.pixelUp(box.width, scale: scale)
        let textX = style.padding.width + PlazaPanelStyle.pixel((inner - textWidth) / 2, scale: scale)
        let placed = zip(lines, box.baselines).map { line, baseline in
            (line, CGPoint(x: textX + (textWidth - line.width) / 2, y: style.padding.height + baseline))
        }
        return PlazaPill(style: style, frame: CGRect(origin: .zero, size: size), lines: placed, text: string)
    }

    /// The text's size and each line's baseline from its top, as SwiftUI's `Text` lays a font's lines out (measured):
    /// every line is the font's ascender − descender tall, rounded (no leading, whatever a fallback font such as the
    /// emoji's would need), the baseline an ascender below the line's top; the width is the widest line.
    static func textBox(lines: [PlazaTextLine], font: PlazaFont, text: any PlazaTextEngine) -> (width: CGFloat, height: CGFloat, baselines: [CGFloat]) {
        let m = text.metrics(font)
        let lineHeight = (m.ascender - m.descender).rounded()
        let width = lines.map(\.width).max() ?? 0
        let baselines = lines.indices.map { CGFloat($0) * lineHeight + m.ascender }
        return (width, CGFloat(lines.count) * lineHeight, baselines)
    }

    /// Fill, text, then the stroke on top (SwiftUI's background, the `Text`, the overlay).
    func draw(on canvas: any PlazaCanvas, in space: PlazaPanelSpace) {
        let r = space.canvas(frame)
        canvas.setFillColor(style.fill)
        canvas.fillRoundedRect(r, radius: style.cornerRadius)
        canvas.setFillColor(style.text)
        for (line, at) in lines {
            canvas.draw(line, at: space.canvas(CGPoint(x: frame.minX + at.x, y: frame.minY + at.y)))
        }
        canvas.setStrokeColor(style.stroke)
        canvas.strokeRoundedRect(r, radius: style.cornerRadius, lineWidth: style.lineWidth)
    }

    /// One static text per pill, read as its whole text, over the pill (SwiftUI's `Text` with its padding and
    /// background was one element; the pills were separate elements, none combined).
    func accessibilityItem(in space: PlazaPanelSpace) -> PlazaAccessibilityItem {
        PlazaAccessibilityItem(frame: space.panel(frame), role: .staticText, label: text)
    }

    /// `pills` (laid out in a content of `content` points) as a panel's drawing: one image of the whole panel, strokes'
    /// room included, and one accessibility item per pill, top to bottom.
    static func drawing(_ pills: [PlazaPill], content: CGSize, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        let space = PlazaPanelSpace(content: content)
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            for pill in pills { pill.draw(on: canvas, in: space) }
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: pills.map { $0.accessibilityItem(in: space) })
    }
}

/// The countdown, banner and hint pills under the window's top edge, in that order (`PlazaOverlayView`'s top stack
/// before Track A Task 14). None of them takes clicks. It follows `PlazaOverlayModel` itself.
@MainActor final class PlazaPillsPanel: PlazaPanel {
    let id = PlazaPanelID.pills
    let anchor = PlazaPanelAnchor.topCenter
    var offset: CGPoint { CGPoint(x: 0, y: PlazaPanelStyle.pillsTop - PlazaPanelStyle.strokeRoom) }
    var onChange: (() -> Void)?
    private let model: PlazaOverlayModel

    private struct Content: Equatable { let countdown: String?, banner: String?, hint: String? }
    private var content: Content { Content(countdown: model.countdown, banner: model.banner, hint: model.hint) }
    /// The last layout: `size`, the overlay's menu room and `render` ask for the same one, and the banner's wrapping
    /// (TextKit on the Mac) is the costly part.
    private struct StackKey: Equatable { let content: Content, width: CGFloat, scale: CGFloat, engine: String }
    private var laidOut: (key: StackKey, size: CGSize, pills: [PlazaPill])?
    /// The content last rendered or reported: a model write that changes nothing since (the same value again, or a
    /// change the window already rendered when it opened) is not reported.
    private var reported: Content?

    init(model: PlazaOverlayModel) {
        self.model = model
        observe()
    }

    var isVisible: Bool { model.countdown != nil || model.banner != nil || model.hint != nil }

    /// The pills as the old `VStack` placed them: frames relative to the stack's top-left corner, strokes not included.
    func stack(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> (size: CGSize, pills: [PlazaPill]) {
        let key = StackKey(content: content, width: viewport.width, scale: scale, engine: String(describing: type(of: text)))
        if let laidOut, laidOut.key == key { return (laidOut.size, laidOut.pills) }
        // A one-line pill is cut to the window's width (SwiftUI offered it the whole width); before the window has
        // reported its size (the SwiftUI overlay can ask that early) nothing is cut.
        func room(_ style: PlazaPanelStyle.Pill) -> CGFloat {
            viewport.width > 0 ? viewport.width - 2 * style.padding.width : .greatestFiniteMagnitude
        }
        var pills: [PlazaPill] = []
        if let countdown = model.countdown {
            pills.append(.oneLine(countdown, style: PlazaPanelStyle.countdown, maxTextWidth: room(PlazaPanelStyle.countdown),
                                  scale: scale, text: text))
        }
        if let banner = model.banner {
            pills.append(.wrapped(banner, style: PlazaPanelStyle.banner, width: PlazaPanelStyle.bannerWidth, scale: scale, text: text))
        }
        if let hint = model.hint {
            pills.append(.oneLine(hint, style: PlazaPanelStyle.hint, maxTextWidth: room(PlazaPanelStyle.hint), scale: scale, text: text))
        }
        let width = pills.map(\.frame.width).max() ?? 0
        var y: CGFloat = 0
        for i in pills.indices {
            if i > 0 { y += PlazaPanelStyle.pillSpacing }
            pills[i].frame.origin = CGPoint(x: PlazaPanelStyle.pixel((width - pills[i].frame.width) / 2, scale: scale), y: y)
            y += pills[i].frame.height
        }
        let size = CGSize(width: width, height: y)
        laidOut = (key, size, pills)
        return (size, pills)
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        PlazaPanelSpace(content: stack(in: viewport, scale: scale, text: text).size).size
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        reported = content
        let (size, pills) = stack(in: viewport, scale: scale, text: graphics.text)
        return PlazaPill.drawing(pills, content: size, scale: scale, graphics: graphics)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }

    /// Re-registers first, then reports, as `observeUnread` does: SwiftUI read the model in its body; the panel follows
    /// the same three properties.
    private func observe() {
        withObservationTracking {
            _ = model.countdown
            _ = model.banner
            _ = model.hint
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observe()
                let now = self.content
                guard now != self.reported else { return }
                self.reported = now
                self.onChange?()
            }
        }
    }
}
