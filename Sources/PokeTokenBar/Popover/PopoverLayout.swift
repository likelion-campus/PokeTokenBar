import Foundation

/// The numbers of the Mac's inset-grouped Settings page (`SettingsView`: `settingsSection`, `groupRow`, `toggleRow`, the
/// body's stack), in the Mac's points = DIP (stage 7 D6). `pixels(dpi:)` makes the device-pixel set the Windows kit lays
/// out with, so a page is laid out once per DPI and never mixes units.
struct PopoverStackMetrics: Equatable, Sendable {
    /// Around the page (`.padding(16)`).
    var pagePadding: CGFloat = 16
    /// Between sections (`VStack(spacing: 18)`).
    var sectionSpacing: CGFloat = 18
    /// Between a section's caption and its card (`VStack(spacing: 6)`).
    var captionSpacing: CGFloat = 6
    /// The caption's leading inset (`.padding(.leading, 4)`).
    var captionInset: CGFloat = 4
    /// Inside a card row (`.padding(.horizontal, 12).padding(.vertical, 8)`).
    var rowPaddingH: CGFloat = 12
    var rowPaddingV: CGFloat = 8
    /// A card row's least height (`.frame(minHeight: 38)`).
    var rowMinHeight: CGFloat = 38
    /// Between a row's label and its control (`HStack(spacing: 10)`).
    var rowSpacing: CGFloat = 10
    /// Between a label and its hint (`VStack(spacing: 1)`).
    var hintSpacing: CGFloat = 1
    /// Between the rows of a section without a card.
    var plainSpacing: CGFloat = 8
    /// The card's corner (`RoundedRectangle(cornerRadius: 8)`).
    var cardRadius: CGFloat = 8
    /// A `Divider()` between rows; it takes its height in the stack.
    var divider: CGFloat = 1
    /// Above the first and below the last region instead of `pagePadding` (a pane pinned above or below a scroller has no
    /// padding on the side it shares with it).
    var padTop: CGFloat?
    var padBottom: CGFloat?

    static let settings = PopoverStackMetrics()

    /// The Home and Recap pages (`PopoverMetrics.padding` 14, the page `VStack`'s spacing 12; `plainSpacing` is the header
    /// group's `VStack(spacing: 6)`). Settings keeps its own 16 / 18.
    static let home = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 12, plainSpacing: 6)
    /// Home's three panes (the Mac's `mainContent`): the update offer and plaza button above the 520 pt scroller, the scrolling
    /// middle (no vertical padding: it starts at the scroller's edge), the footer below.
    static let homeTop = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 12, plainSpacing: 6, padTop: 14, padBottom: 0)
    static let homeScroll = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 12, plainSpacing: 6, padTop: 0, padBottom: 0)
    static let homeFooter = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 12, plainSpacing: 6, padTop: 0, padBottom: 14)
    /// The Shop's `VStack(spacing: 10)` and the Bag's `VStack(spacing: 8)` in the scroller (14 pt sides, no vertical padding).
    static let shopScroll = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 10, plainSpacing: 6, padTop: 0, padBottom: 0)
    static let bagScroll = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 8, plainSpacing: 6, padTop: 0, padBottom: 0)
    /// The scroller's height in the Mac's points (`.frame(height: 520)`): fixed, also when the content is shorter.
    static let homeScrollerHeight: CGFloat = 520

    /// The Recap page's `VStack(spacing: 8)`.
    static let recap = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 8, plainSpacing: 2)

    /// Every length in whole device pixels at `dpi` (rounded; a line stays at least one pixel).
    func pixels(dpi: Int) -> PopoverStackMetrics {
        func p(_ v: CGFloat) -> CGFloat { CGFloat(PopoverTextStyle.pixels(v, dpi: dpi)) }
        var m = self
        m.pagePadding = p(pagePadding)
        m.sectionSpacing = p(sectionSpacing)
        m.captionSpacing = p(captionSpacing)
        m.captionInset = p(captionInset)
        m.rowPaddingH = p(rowPaddingH)
        m.rowPaddingV = p(rowPaddingV)
        m.rowMinHeight = p(rowMinHeight)
        m.rowSpacing = p(rowSpacing)
        m.hintSpacing = p(hintSpacing)
        m.plainSpacing = p(plainSpacing)
        m.cardRadius = p(cardRadius)
        m.divider = p(divider)
        m.padTop = padTop.map(p)
        m.padBottom = padBottom.map(p)
        return m
    }
}

/// One row of a page section.
struct PopoverStackRow {
    enum Style: Equatable, Sendable {
        /// Label (and hint under it) on the left, the control on the right (`groupRow`, `toggleRow`); stacked instead when
        /// the control would take more than 60 % of the row, or a word of the label does not fit beside it.
        case trailing
        /// The label (and hint) on top, the control under it at the row's full width (a multi-line field).
        case stacked
        /// The control alone at the row's full width (a drawn part, a radio pair).
        case full
        /// A check box that is its own label, across the row with the box on the right (`toggleRow`), its hint under it.
        case toggle
    }
    var style: Style = .trailing
    var isVisible = true
    /// The control's preferred size; `stacked` and `full` controls take the row's width.
    var control: CGSize?
    /// The label's and the hint's size when the text may be `width` wide (it wraps there).
    var text: (CGFloat) -> (label: CGSize?, hint: CGSize?) = { _ in (nil, nil) }
}

/// A section: an optional caption over a card of rows with dividers between them, or (`card` false) rows stacked plainly.
struct PopoverStackSection {
    var caption: CGSize?
    var isVisible = true
    var card = true
    var rows: [PopoverStackRow] = []
    /// A `Divider()` between two regions of the page: no rows, one rule `divider` high, the section spacing around it.
    var isRule = false
    /// The space above this section instead of `sectionSpacing` (a region the Mac stacks tighter than its page).
    var spacingAbove: CGFloat?
    /// The space between this plain section's rows instead of `plainSpacing`.
    var rowSpacing: CGFloat?
}

/// Where everything of a page goes, in the units of the metrics (device pixels on Windows); hidden sections and rows are nil.
struct PopoverStackFrames: Equatable {
    struct Row: Equatable {
        var frame: CGRect
        var label: CGRect?
        var hint: CGRect?
        var control: CGRect?
    }
    struct Section: Equatable {
        var caption: CGRect?
        var card: CGRect?
        var rows: [Row?]
        var dividers: [CGRect]
    }
    var sections: [Section?]
    var height: CGFloat
}

enum PopoverStackLayout {
    /// The page at `width`, top to bottom, every frame on whole units of `metrics` (pass `metrics.pixels(dpi:)`).
    static func layout(_ sections: [PopoverStackSection], width: CGFloat, metrics m: PopoverStackMetrics) -> PopoverStackFrames {
        let x0 = m.pagePadding, w = max(0, width - 2 * m.pagePadding)
        var y = m.padTop ?? m.pagePadding
        var out: [PopoverStackFrames.Section?] = []
        var first = true
        for section in sections {
            if section.isRule {
                guard section.isVisible else { out.append(nil); continue }
                if !first { y += section.spacingAbove ?? m.sectionSpacing }
                first = false
                out.append(PopoverStackFrames.Section(caption: nil, card: nil, rows: [], dividers: [CGRect(x: x0, y: y, width: w, height: m.divider)]))
                y += m.divider
                continue
            }
            guard section.isVisible, section.caption != nil || section.rows.contains(where: \.isVisible) else {
                out.append(nil)
                continue
            }
            if !first { y += section.spacingAbove ?? m.sectionSpacing }
            first = false
            var caption: CGRect?
            if let size = section.caption {
                caption = CGRect(x: x0 + m.captionInset, y: y, width: min(size.width.rounded(.up), max(0, w - m.captionInset)),
                                 height: size.height.rounded(.up))
                y += size.height.rounded(.up) + m.captionSpacing
            }
            let top = y
            var rows: [PopoverStackFrames.Row?] = []
            var dividers: [CGRect] = []
            var placed = 0
            for row in section.rows {
                guard row.isVisible else { rows.append(nil); continue }
                if placed > 0 {
                    if section.card {
                        dividers.append(CGRect(x: x0, y: y, width: w, height: m.divider))
                        y += m.divider
                    } else {
                        y += section.rowSpacing ?? m.plainSpacing
                    }
                }
                placed += 1
                let frame = layoutRow(row, x: x0, y: y, width: w, metrics: m, card: section.card)
                rows.append(frame)
                y += frame.frame.height
            }
            out.append(PopoverStackFrames.Section(caption: caption, card: section.card ? CGRect(x: x0, y: top, width: w, height: y - top) : nil,
                                                  rows: rows, dividers: dividers))
        }
        return PopoverStackFrames(sections: out, height: y + (m.padBottom ?? m.pagePadding))
    }

    private static func layoutRow(_ row: PopoverStackRow, x: CGFloat, y: CGFloat, width: CGFloat, metrics m: PopoverStackMetrics,
                                  card: Bool) -> PopoverStackFrames.Row {
        let padH = card ? m.rowPaddingH : 0, padV = card ? m.rowPaddingV : 0, minH = card ? m.rowMinHeight : 0
        let innerX = x + padH, innerW = max(0, width - 2 * padH)
        func up(_ s: CGSize?) -> CGSize? { s.map { CGSize(width: $0.width.rounded(.up), height: $0.height.rounded(.up)) } }
        var style = row.style
        // A control wider than 60 % of the row would squeeze its label (Windows' text size, a long picker): label above,
        // control under it, as SwiftUI's rows fall back when they do not fit.
        var besideControl: (label: CGSize?, hint: CGSize?)?  // the text measured beside the control (measured once)
        if style == .trailing, let c = row.control {
            let textW = max(0, innerW - min(c.width.rounded(.up), innerW) - m.rowSpacing)
            if c.width > innerW * 0.6, row.text(innerW).label != nil {
                style = .stacked
            } else {
                let text = row.text(textW)
                besideControl = text
                // a word of the label is wider than the room beside the control ("Aktualisierungsintervall" at 125 %)
                if let label = text.label, label.width.rounded(.up) > textW { style = .stacked }
            }
        }
        switch style {
        case .trailing:
            let control = up(row.control)
            let cw = min(control?.width ?? 0, innerW)
            let textW = max(0, innerW - cw - (control == nil ? 0 : m.rowSpacing))
            let text = besideControl ?? row.text(textW)
            let label = up(text.label), hint = up(text.hint)
            let textH = (label?.height ?? 0) + (hint.map { m.hintSpacing + $0.height } ?? 0)
            let contentH = max(textH, control?.height ?? 0)
            let h = max(minH, contentH + 2 * padV)
            let textTop = y + ((h - textH) / 2).rounded(.down)
            let labelFrame = label.map { CGRect(x: innerX, y: textTop, width: min($0.width, textW), height: $0.height) }
            let hintFrame = hint.map { CGRect(x: innerX, y: textTop + (label?.height ?? 0) + m.hintSpacing, width: min($0.width, textW), height: $0.height) }
            let controlFrame = control.map { CGRect(x: innerX + innerW - cw, y: y + ((h - $0.height) / 2).rounded(.down), width: cw, height: $0.height) }
            return PopoverStackFrames.Row(frame: CGRect(x: x, y: y, width: width, height: h), label: labelFrame, hint: hintFrame, control: controlFrame)
        case .toggle:
            let control = up(row.control), hint = up(row.text(innerW).hint)
            let blockH = (control?.height ?? 0) + (hint.map { m.hintSpacing + $0.height } ?? 0)
            let h = max(minH, blockH + 2 * padV)
            let top = y + ((h - blockH) / 2).rounded(.down)
            let controlFrame = control.map { CGRect(x: innerX, y: top, width: innerW, height: $0.height) }
            let hintFrame = hint.map { CGRect(x: innerX, y: top + (control?.height ?? 0) + m.hintSpacing, width: min($0.width, innerW), height: $0.height) }
            return PopoverStackFrames.Row(frame: CGRect(x: x, y: y, width: width, height: h), label: nil, hint: hintFrame, control: controlFrame)
        case .stacked, .full:
            let text: (label: CGSize?, hint: CGSize?) = style == .stacked ? row.text(innerW) : (nil, nil)
            let label = up(text.label), hint = up(text.hint)
            var cursor = y + padV
            let labelFrame = label.map { CGRect(x: innerX, y: cursor, width: min($0.width, innerW), height: $0.height) }
            if let label { cursor += label.height }
            let hintFrame = hint.map { CGRect(x: innerX, y: cursor + m.hintSpacing, width: min($0.width, innerW), height: $0.height) }
            if let hint { cursor += m.hintSpacing + hint.height }
            if (label != nil || hint != nil), row.control != nil { cursor += m.captionSpacing }
            let controlFrame = up(row.control).map { CGRect(x: innerX, y: cursor, width: innerW, height: $0.height) }
            if let controlFrame { cursor = controlFrame.maxY }
            let h = max(minH, cursor + padV - y)
            return PopoverStackFrames.Row(frame: CGRect(x: x, y: y, width: width, height: h), label: labelFrame, hint: hintFrame, control: controlFrame)
        }
    }

    /// Whether `frames` (in creation order) read top to bottom and, within a line, left to right: the order Tab visits
    /// controls in (the dialog manager follows creation order), held to what the eye reads.
    static func isReadingOrder(_ frames: [CGRect]) -> Bool {
        zip(frames, frames.dropFirst()).allSatisfy { a, b in
            b.minY >= a.maxY - 1 || (b.minY < a.maxY && b.maxY > a.minY && b.minX >= a.maxX - 1)
        }
    }
}

/// Scrolling a page in a viewport (stage 7 D6), in device pixels.
enum PopoverScrollMath {
    /// `offset` kept inside 0…max(0, content − viewport).
    static func clamped(_ offset: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, content - viewport))
    }

    /// Whether a scroll bar is on the screen: only while there is something to scroll (the Mac's overlay scroller is not drawn
    /// otherwise; Windows' overlay thumb is hidden when the content fits).
    static func showsBar(content: CGFloat, viewport: CGFloat) -> Bool { content > viewport }

    /// The overlay scroll thumb (Windows' replacement for its system bar) inside a track `track` long: where it starts and how long
    /// it is, in the units of the arguments. Its length is the visible share of the content, never under `minLength` (or the track);
    /// nil while there is nothing to scroll.
    struct Thumb: Equatable {
        var top: CGFloat
        var length: CGFloat
        var bottom: CGFloat { top + length }
    }

    static func thumb(content: CGFloat, viewport: CGFloat, offset: CGFloat, track: CGFloat, minLength: CGFloat) -> Thumb? {
        guard showsBar(content: content, viewport: viewport), track > 0, viewport > 0 else { return nil }
        let length = min(track, max(minLength, (track * viewport / content).rounded()))
        let travel = track - length, range = content - viewport
        let at = clamped(offset, content: content, viewport: viewport)
        return Thumb(top: travel > 0 ? (travel * at / range).rounded() : 0, length: length)
    }

    /// The scroll offset a thumb whose top edge is at `thumbTop` stands for (the inverse of `thumb`, clamped to the track).
    static func offset(thumbTop: CGFloat, content: CGFloat, viewport: CGFloat, track: CGFloat, minLength: CGFloat) -> CGFloat {
        guard let t = thumb(content: content, viewport: viewport, offset: 0, track: track, minLength: minLength) else { return 0 }
        let travel = track - t.length
        guard travel > 0 else { return 0 }
        return clamped((min(max(0, thumbTop), travel) / travel * (content - viewport)).rounded(), content: content, viewport: viewport)
    }

    /// A click in the track outside the thumb pages towards it (`page` pixels); a click on the thumb changes nothing.
    static func paged(clickY: CGFloat, thumb: Thumb, offset: CGFloat, page: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        if clickY < thumb.top { return clamped(offset - page, content: content, viewport: viewport) }
        if clickY >= thumb.bottom { return clamped(offset + page, content: content, viewport: viewport) }
        return offset
    }

    /// The smallest move that shows `top…bottom` (content coordinates) with `margin` around it; unchanged when it is
    /// already inside the viewport; an item taller than the viewport shows its top.
    static func revealing(top: CGFloat, bottom: CGFloat, offset: CGFloat, viewport: CGFloat, content: CGFloat,
                          margin: CGFloat) -> CGFloat {
        let wantTop = top - margin, wantBottom = bottom + margin
        var next = offset
        if wantBottom - wantTop >= viewport || wantTop < offset {
            next = wantTop
        } else if wantBottom > offset + viewport {
            next = wantBottom - viewport
        }
        return clamped(next, content: content, viewport: viewport)
    }
}

/// The mouse wheel and a precision touchpad (`WM_MOUSEWHEEL`): 120 is one notch, a touchpad sends parts of one. A notch
/// scrolls `lines` (`SPI_GETWHEELSCROLLLINES`) lines of `lineHeight`; `UInt32.max` (`WHEEL_PAGESCROLL`) scrolls a page.
/// Fractions are kept, so many small deltas add up to exactly what one notch scrolls.
struct PopoverWheel: Equatable, Sendable {
    private var remainder: Double = 0

    /// The change of the scroll offset for `delta` (positive = wheel away from the user = towards the top: a negative change).
    mutating func offsetChange(delta: Int, lines: UInt32, lineHeight: CGFloat, page: CGFloat) -> CGFloat {
        guard lines > 0, delta != 0 else { return 0 }
        let perNotch = lines == UInt32.max ? Double(page) : Double(lines) * Double(lineHeight)
        let total = remainder - Double(delta) / 120 * perNotch
        let step = total.rounded(.towardZero)
        remainder = total - step
        return CGFloat(step)
    }

    mutating func reset() { remainder = 0 }
}
