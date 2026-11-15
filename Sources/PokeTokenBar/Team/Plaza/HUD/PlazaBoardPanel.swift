import Foundation
import Observation

/// The look of the news board, copied from `PlazaBoardView` / `PlazaOverlayView` (SwiftUI, which the Mac still shows).
enum PlazaBoardStyle {
    static let size = CGSize(width: 340, height: 380)
    static let inset = PlazaCardMetrics.panelInset
    static let titleHeight: CGFloat = 24, gap: CGFloat = 8, rowGap: CGFloat = 6
    static let rowPadding: CGFloat = 6, rowRadius: CGFloat = 6, lineGap: CGFloat = 4, reactionGap: CGFloat = 1
    static let buttonMinWidth: CGFloat = 30, buttonPadding: CGFloat = 2, buttonGap: CGFloat = 4, buttonRadius: CGFloat = 4
    static let body = PlazaFont.plaza(.body), small = PlazaFont.plaza(.small)
    static let ink = PlazaColor(hex: 0x2D4048), cream = PlazaColor(hex: 0xF8F8F0), yellow = PlazaColor(hex: 0xFFE060)
    static let shadow = 0.45
    /// What `.disabled(true)` does to a `.plain` button's label (measured: the pill's 0.4 fill and the text both come out at 0.44 of it).
    static let disabledOpacity: CGFloat = 0.44
    /// The scrolling list: inside the plate's inset, under the title and its gap.
    static var list: CGRect {
        CGRect(x: inset, y: inset + titleHeight + gap, width: size.width - 2 * inset, height: size.height - 2 * inset - titleHeight - gap)
    }
}

/// The news board (`PlazaBoardView`, SwiftUI, which the Mac still shows) as a panel: the striped plate `340 x 380`, centred in
/// the window (the overlay's ZStack centred it), with the title "소식판" and under it the events newest first, each a
/// rounded row: the text (a ★ and yellow when shiny, thickened with a one-point shadow when big), its date, who reacted (a
/// line per reaction kind) and three buttons (귀여워 / 웃겨 / 축하해) that are dimmed and inert once I have given that
/// reaction. The rows scroll (`PlazaScrollState`, the wheel over the list); with no events the plate says so. A click on a
/// reaction button is `("react", row * 3 + kind)` (the owner reacts with `reaction(forHit:)`), anywhere else on the plate
/// `("board")` (taken, nothing happens); outside the plate nothing. The keys that close it (Space/Esc) go through the scene as
/// before. There is no text input.
@MainActor final class PlazaBoardPanel: PlazaPanel, PlazaScrollIndicating {
    let id = PlazaPanelID.board
    let anchor = PlazaPanelAnchor.center
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let model: PlazaOverlayModel
    private let feed: TeamFeedStore
    private let myMemberID: String
    private var observer: PlazaChangeObserver?

    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaNameColorPickerPanel.held(oldValue) != PlazaNameColorPickerPanel.held(interaction) { onChange?() } }
    }

    private(set) var scrollState = PlazaScrollState()
    let scrollIndicator = PlazaScrollIndicator()

    init(model: PlazaOverlayModel, feed: TeamFeedStore, myMemberID: String) {
        self.model = model
        self.feed = feed
        self.myMemberID = myMemberID
        scrollIndicator.onChange = { [weak self] in self?.onChange?() }
        observer = PlazaChangeObserver(track: { _ = model.content; _ = PlazaBoardRow.rows(feed: feed, myMemberID: myMemberID) },
                                       changed: { [weak self] in self?.modelChanged() })
    }

    var isVisible: Bool { model.content == .board }

    private var rendered: String?
    private var state: String { "\(model.content == .board) \(PlazaBoardRow.rows(feed: feed, myMemberID: myMemberID))" }
    private func modelChanged() {
        if !isVisible { scrollState = PlazaScrollState(); rowImages = [:]; scrollIndicator.reset() }   // each opening starts at the top (a new ScrollView)
        if rendered != state { onChange?() }
    }

    // MARK: layout

    struct Row {
        let row: PlazaBoardRow
        let frame: CGRect                         // content points: x 0, y from the list's top
        let text: [PlazaTextLine], date: PlazaTextLine
        let reactions: [[PlazaTextLine]]
        let buttons: [(kind: TeamReactionKind, line: PlazaTextLine, frame: CGRect)]   // in the row
        let textTop: CGFloat, dateTop: CGFloat, reactionTop: CGFloat
        let label: String
    }

    struct Layout {
        let title: PlazaTextLine
        let empty: PlazaTextLine
        let rows: [Row]
        let content: CGFloat
        let body: PlazaFontMetrics, small: PlazaFontMetrics
        let bodyHeight: CGFloat, smallHeight: CGFloat
    }

    private struct LayoutKey: Equatable { let rows: [PlazaBoardRow], scale: CGFloat, engine: String }
    private var laidOut: (key: LayoutKey, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let rows = PlazaBoardRow.rows(feed: feed, myMemberID: myMemberID)
        let engine = String(describing: type(of: text))
        let key = LayoutKey(rows: rows, scale: scale, engine: engine)
        if let laidOut, laidOut.key == key { return laidOut.layout }
        let s = PlazaBoardStyle.self
        let l = L(.ko)
        let body = text.metrics(s.body), small = text.metrics(s.small)
        let bodyH = (body.ascender - body.descender).rounded(), smallH = (small.ascender - small.descender).rounded()
        let inner = s.list.width - 2 * s.rowPadding
        var placed: [Row] = []
        var y: CGFloat = 0
        for (n, row) in rows.enumerated() {
            if n > 0 { y += s.rowGap }
            let lines = text.wrappedLines((row.isShiny ? "★ " : "") + row.text, font: s.body, width: inner)
            let date = text.line(row.date, font: s.small)
            var cursor = s.rowPadding
            let textTop = cursor
            cursor += CGFloat(lines.count) * bodyH + s.lineGap
            let dateTop = cursor
            cursor += smallH
            var reactionLines: [[PlazaTextLine]] = []
            let reactionTop = cursor + s.lineGap
            if !row.reactions.isEmpty {
                cursor += s.lineGap
                for (i, r) in row.reactions.enumerated() {
                    if i > 0 { cursor += s.reactionGap }
                    let wrapped = text.wrappedLines(l.teamReactionLabel(r.kind) + " " + r.nicknames.joined(separator: ", "), font: s.small, width: inner)
                    reactionLines.append(wrapped)
                    cursor += CGFloat(wrapped.count) * smallH
                }
            }
            cursor += s.lineGap
            var buttons: [(TeamReactionKind, PlazaTextLine, CGRect)] = []
            var x = s.rowPadding
            for kind in PlazaBoardRow.buttonKinds {
                let line = text.line(l.teamReactionLabel(kind), font: s.small)
                let width = max(s.buttonMinWidth, PlazaPanelStyle.pixelUp(line.width, scale: scale))
                buttons.append((kind, line, CGRect(x: x, y: cursor, width: width, height: smallH + 2 * s.buttonPadding)))
                x += width + s.buttonGap
            }
            cursor += smallH + 2 * s.buttonPadding + s.rowPadding
            let label = ([lines.isEmpty ? "" : (row.isShiny ? "★ " : "") + row.text, row.date]).joined(separator: ", ")
            placed.append(Row(row: row, frame: CGRect(x: 0, y: y, width: s.list.width, height: cursor), text: lines, date: date, reactions: reactionLines,
                              buttons: buttons.map { ($0.0, $0.1, $0.2) }, textTop: textTop, dateTop: dateTop, reactionTop: reactionTop, label: label))
            y += cursor
        }
        let result = Layout(title: text.line(l.plazaBoardTitle, font: s.body), empty: text.line(l.plazaBoardEmpty, font: s.body), rows: placed, content: y,
                            body: body, small: small, bodyHeight: bodyH, smallHeight: smallH)
        laidOut = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { PlazaBoardStyle.size }

    // MARK: drawing

    private var drawnOffset: CGFloat = 0
    private var rowImages: [String: PlazaImage] = [:]
    private var rowImageKey = ""
    private var plate: (key: String, image: PlazaImage?) = ("", nil)

    private func image(_ size: CGSize, scale: CGFloat, graphics: any PlazaGraphics, _ draw: (any PlazaCanvas) -> Void) -> PlazaImage? {
        guard let canvas = graphics.makeCanvas(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()), colorSpace: .sRGB) else { return nil }
        canvas.scale(x: scale, y: scale)
        draw(canvas)
        return canvas.makeImage()
    }

    private func held(_ row: PlazaBoardRow, _ index: Int) -> Bool {
        guard let h = PlazaNameColorPickerPanel.held(interaction), h.action == "react", let i = h.index else { return false }
        return i == index
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        let text = graphics.text
        let l = layout(scale: scale, text: text)
        let s = PlazaBoardStyle.self
        let list = s.list
        scrollState.setMetrics(content: l.content, viewport: list.height)
        var layers: [PlazaPanelLayer] = []
        var items: [PlazaAccessibilityItem] = []

        // The plate with the title (and the empty note).
        let plateKey = "\(scale) \(String(describing: type(of: text))) \(l.rows.isEmpty)"
        if plate.key != plateKey {
            let space = PlazaPanelSpace(content: s.size, room: 0)
            plate = (plateKey, space.image(scale: scale, graphics: graphics) { canvas in
                PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: s.size)))
                let pen = PlazaPen(canvas: canvas, space: space, ascender: l.body.ascender)
                pen.line(l.title, x: s.inset, top: s.inset + PlazaPanelStyle.pixel((s.titleHeight - l.bodyHeight) / 2, scale: scale), color: .white, shadow: s.shadow)
                if l.rows.isEmpty {
                    pen.line(l.empty, x: list.minX + PlazaPanelStyle.pixel((list.width - l.empty.width) / 2, scale: scale),
                             top: list.minY + PlazaPanelStyle.pixel((list.height - l.bodyHeight) / 2, scale: scale), color: .white)
                }
            })
        }
        if let p = plate.image { layers.append(.image(p, frame: CGRect(origin: .zero, size: s.size))) }
        items.append(PlazaAccessibilityItem(frame: CGRect(x: s.inset, y: s.inset, width: PlazaPanelStyle.pixelUp(l.title.width, scale: scale), height: s.titleHeight),
                                            role: .staticText, label: L(.ko).plazaBoardTitle))
        if l.rows.isEmpty {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: list.minX + PlazaPanelStyle.pixel((list.width - l.empty.width) / 2, scale: scale), y: list.minY + (list.height - l.bodyHeight) / 2,
                                                              width: PlazaPanelStyle.pixelUp(l.empty.width, scale: scale), height: l.bodyHeight),
                                                role: .staticText, label: L(.ko).plazaBoardEmpty))
            return PlazaPanelDrawing(layers: layers, accessibility: items)
        }

        // The rows in the viewport, each cut at the viewport's edges.
        let offset = PlazaPanelStyle.pixel(scrollState.offset, scale: scale)
        drawnOffset = offset
        let key = "\(scale) \(String(describing: type(of: text)))"
        if rowImageKey != key { rowImageKey = key; rowImages = [:] }
        var kept: [String: PlazaImage] = [:]
        for i in scrollState.visibleRows(l.rows.map(\.frame)) {
            let row = l.rows[i]
            guard let shown = scrollState.visible(row.frame, offset: offset) else { continue }
            let pressed = (0..<3).filter { held(row.row, i * 3 + $0) }
            let cacheKey = "\(i) \(row.row) \(pressed)"
            var picture: PlazaImage? = rowImages[cacheKey] ?? image(row.frame.size, scale: scale, graphics: graphics) { canvas in
                let space = PlazaPanelSpace(content: row.frame.size, room: 0)
                let pen = PlazaPen(canvas: canvas, space: space, ascender: l.body.ascender)
                pen.fill(CGRect(origin: .zero, size: row.frame.size), PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12), radius: s.rowRadius)
                let color = row.row.isShiny ? s.yellow : .white
                for (n, line) in row.text.enumerated() {
                    let top = row.textTop + CGFloat(n) * l.bodyHeight
                    if row.row.isBig { pen.line(line, x: s.rowPadding + 1, top: top, color: color) }   // thickened: a same-colour shadow one point to the side
                    pen.line(line, x: s.rowPadding, top: top, color: color)
                }
                let small = PlazaPen(canvas: canvas, space: space, ascender: l.small.ascender)
                small.line(row.date, x: s.rowPadding, top: row.dateTop, color: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.65))
                var y = row.reactionTop
                for (n, wrapped) in row.reactions.enumerated() {
                    if n > 0 { y += s.reactionGap }
                    for line in wrapped {
                        small.line(line, x: s.rowPadding, top: y, color: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
                        y += l.smallHeight
                    }
                }
                for (k, b) in row.buttons.enumerated() {
                    let mine = row.row.mine.contains(b.kind)
                    canvas.saveState()
                    if mine { canvas.setAlpha(s.disabledOpacity) }   // a disabled plain button dims its whole label
                    if pressed.contains(k) && !mine { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
                    small.fill(b.frame, PlazaColor(hex: 0xF8F8F0, alpha: mine ? 0.4 : 1), radius: s.buttonRadius)
                    small.line(b.line, x: b.frame.minX + (b.frame.width - b.line.width) / 2, top: b.frame.minY + s.buttonPadding, color: s.ink)
                    canvas.restoreState()
                }
            }
            if let full = picture {
                kept[cacheKey] = full
                if shown.height < row.frame.height {
                    let top = max(0, offset - row.frame.minY)
                    picture = full.cropping(to: PlazaPixelRect(x: 0, y: Int((top * scale).rounded()), width: full.width, height: Int((shown.height * scale).rounded())))
                }
            }
            if let p = picture { layers.append(.image(p, frame: shown.offsetBy(dx: list.minX, dy: list.minY))) }
        }
        rowImages = kept
        layers += scrollIndicator.layers(state: scrollState, offset: offset, viewport: list, scale: scale, graphics: graphics)

        // VoiceOver: the shown rows' texts and buttons, frames cut to the list.
        for (i, row) in l.rows.enumerated() {
            guard let shown = scrollState.visible(row.frame, offset: offset) else { continue }
            func place(_ r: CGRect) -> CGRect {
                let moved = r.offsetBy(dx: row.frame.minX, dy: row.frame.minY - offset)
                let cut = moved.intersection(CGRect(x: 0, y: 0, width: list.width, height: list.height))
                return (cut.isNull ? CGRect(x: moved.minX, y: moved.minY < 0 ? 0 : list.height, width: moved.width, height: 0) : cut).offsetBy(dx: list.minX, dy: list.minY)
            }
            _ = shown
            items.append(PlazaAccessibilityItem(frame: place(CGRect(x: s.rowPadding, y: row.textTop, width: list.width - 2 * s.rowPadding, height: CGFloat(row.text.count) * l.bodyHeight)),
                                                role: .staticText, label: (row.row.isShiny ? "★ " : "") + row.row.text))
            items.append(PlazaAccessibilityItem(frame: place(CGRect(x: s.rowPadding, y: row.dateTop, width: PlazaPanelStyle.pixelUp(row.date.width, scale: scale), height: l.smallHeight)),
                                                role: .staticText, label: row.row.date))
            var y = row.reactionTop
            for (n, r) in row.row.reactions.enumerated() {
                if n > 0 { y += s.reactionGap }
                let h = CGFloat(row.reactions[n].count) * l.smallHeight
                items.append(PlazaAccessibilityItem(frame: place(CGRect(x: s.rowPadding, y: y, width: list.width - 2 * s.rowPadding, height: h)), role: .staticText,
                                                    label: L(.ko).teamReactionLabel(r.kind) + " " + r.nicknames.joined(separator: ", ")))
                y += h
            }
            for (k, b) in row.buttons.enumerated() {
                let mine = row.row.mine.contains(b.kind)
                items.append(PlazaAccessibilityItem(frame: place(b.frame), role: .button, label: L(.ko).teamReactionLabel(b.kind),
                                                    action: mine ? nil : PlazaPanelHit(action: "react", index: i * 3 + k)))
            }
        }
        return PlazaPanelDrawing(layers: layers, accessibility: items)
    }

    // MARK: input

    /// The event and reaction a `("react", n)` hit names (nil for a stale index).
    func reaction(forHit hit: PlazaPanelHit) -> (eventID: String, kind: TeamReactionKind)? {
        guard hit.action == "react", let n = hit.index, let rows = laidOut?.layout.rows, rows.indices.contains(n / 3) else { return nil }
        return (rows[n / 3].row.id, PlazaBoardRow.buttonKinds[n % 3])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard isVisible, let l = laidOut?.layout else { return nil }
        let s = PlazaBoardStyle.self
        let frame = CGRect(origin: .zero, size: s.size)
        guard frame.contains(point) else { return nil }
        let list = s.list
        if list.contains(point) {
            let y = point.y - list.minY + drawnOffset
            let x = point.x - list.minX
            for (i, row) in l.rows.enumerated() where row.frame.minY <= y && y < row.frame.maxY {
                for (k, b) in row.buttons.enumerated() where b.frame.offsetBy(dx: 0, dy: row.frame.minY).contains(CGPoint(x: x, y: y)) {
                    return row.row.mine.contains(b.kind) ? PlazaPanelHit(action: "board", index: nil) : PlazaPanelHit(action: "react", index: i * 3 + k)
                }
            }
        }
        return PlazaPanelHit(action: "board", index: nil)
    }

    /// Only the list takes the wheel: over the title, the plate's margin or outside it goes on.
    func scroll(dx: CGFloat, dy: CGFloat, at point: CGPoint) -> Bool {
        guard isVisible, PlazaBoardStyle.list.contains(point), scrollState.scroll(deltaY: dy) else { return false }
        scrollIndicator.scrolled()
        onChange?()
        return true
    }
}
