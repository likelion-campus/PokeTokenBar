import Foundation
import Observation

/// The look of the member card, copied from `PlazaCardView` / `PlazaOverlayView` (SwiftUI, replaced by this panel on the Mac; the view is kept in Tests/Legacy).
enum PlazaCardStyle {
    static let body = PlazaFont.plaza(.body), small = PlazaFont.plaza(.small)
    static let ink = PlazaColor(hex: 0x2D4048), yellow = PlazaColor(hex: 0xFFE060)
    static let shadow = 0.45
    static let headerGap: CGFloat = 12, columnGap: CGFloat = 6, badgeGap: CGFloat = 4
    static let pillPadding = CGSize(width: 6, height: 1)
    static let boxRadius: CGFloat = 8, cellRadius: CGFloat = 6
    /// The activity box's inner padding and the gap between its two columns.
    static let activityInset: CGFloat = 10, activityColumnGap: CGFloat = 16, activityRadius: CGFloat = 8
    static let titleLines = 2

    /// SwiftUI's `rarityColor` (`.green`, `.blue`, `.orange`, `.gray`) as an `ImageRenderer` resolves them on this macOS
    /// (pinned by `testRarityColoursAreSwiftUIs`); `dark` is the dark appearance's set, which the panel follows (`PlazaCardPanel.isDark`).
    static func rarity(_ r: Rarity?, dark: Bool = false) -> PlazaColor {
        if dark {   // what SwiftUI resolves in the dark colour scheme (pinned by `testRarityColoursFollowTheAppearanceAsSwiftUIsDid`)
            switch r {
            case .uncommon: return PlazaColor(srgbRed: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)
            case .rare: return PlazaColor(srgbRed: 0, green: 145.0 / 255, blue: 1)
            case .legendary: return PlazaColor(srgbRed: 1, green: 146.0 / 255, blue: 48.0 / 255)
            default: return PlazaColor(srgbRed: 152.0 / 255, green: 152.0 / 255, blue: 157.0 / 255)
            }
        }
        switch r {
        case .uncommon: return PlazaColor(srgbRed: 0.204, green: 0.780, blue: 0.349)
        case .rare: return PlazaColor(srgbRed: 0, green: 136.0 / 255, blue: 1)
        case .legendary: return PlazaColor(srgbRed: 1, green: 141.0 / 255, blue: 40.0 / 255)
        default: return PlazaColor(srgbRed: 0.557, green: 0.557, blue: 0.576)
        }
    }

    /// The content inside the plate (panel points), and its three stacked parts.
    static var inner: CGRect {
        let m = PlazaCardMetrics.self
        return CGRect(x: m.panelInset, y: m.panelInset, width: m.panelSize.width - 2 * m.panelInset, height: m.panelSize.height - 2 * m.panelInset)
    }
    static var header: CGRect { CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: PlazaCardMetrics.spriteSide) }
    static var activity: CGRect {
        CGRect(x: inner.minX, y: header.maxY + PlazaCardMetrics.stackSpacing, width: inner.width, height: PlazaCardMetrics.activityHeight)
    }
    static var lower: CGRect {
        let top = activity.maxY + PlazaCardMetrics.stackSpacing
        return CGRect(x: inner.minX, y: top, width: inner.width, height: inner.maxY - top)
    }
    /// The grid's left edge in the lower area (the five fixed columns centred in it).
    static var gridWidth: CGFloat {
        CGFloat(PlazaCardMetrics.columns) * PlazaCardMetrics.cellSize.width + CGFloat(PlazaCardMetrics.columns - 1) * PlazaCardMetrics.spacing
    }
}

/// The member card (`PlazaCardView`, SwiftUI, replaced by this panel on the Mac and kept in Tests/Legacy) as a panel: the striped plate `PlazaCardMetrics.panelSize`,
/// centred in the window, with a header (the character's picture, "닉네임의 포켓몬" in the member's name colour, the
/// character's name, 이로치 / rarity pills, and the Pokémon in hand when it differs), the "오늘 광장" box (seven values in two
/// columns, or "기록 없음"; always the same height), and under it "불러오는 중…" while the dex loads, "도감을 받지 못했어요"
/// when it failed, or the dex grid (five fixed columns of 64 x 66 cells: box icon, name cut at the end, ★ for a shiny, the
/// legendary pill and outline) that scrolls. Hovering a cell shows the species name. The card has no buttons and no input:
/// a click anywhere on the plate is `("card")` (taken, nothing happens), outside it nothing; Space/Esc close it through the
/// scene. Pictures arrive through the `PlazaIconSource` (grey placeholders until then).
@MainActor final class PlazaCardPanel: PlazaPanel, PlazaScrollIndicating {
    let id = PlazaPanelID.card
    let anchor = PlazaPanelAnchor.center
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    private let model: PlazaOverlayModel
    let pictures: PlazaPictureCache
    private var observer: PlazaChangeObserver?
    private let now: () -> Date
    private(set) var scrollState = PlazaScrollState()
    let scrollIndicator = PlazaScrollIndicator()
    /// The window's dark appearance: the rarity colours (SwiftUI's adaptive `.green`, `.blue`, `.orange`, `.gray`) are the dark set, and the
    /// card renders again when it changes.
    var isDark = false { didSet { if isDark != oldValue { onChange?() } } }
    /// The card the scroll position belongs to: another card (a different member, or one that finished loading) starts at the top,
    /// as a new `ScrollView` did.
    private var scrollOwner: PlazaCardState?

    init(model: PlazaOverlayModel, icons: any PlazaIconSource = PlatformPlaza.iconSource(), now: @escaping () -> Date = Date.init) {
        self.model = model
        self.now = now
        pictures = PlazaPictureCache(source: icons)
        observer = PlazaChangeObserver(track: { _ = model.content }, changed: { [weak self] in self?.modelChanged() })
        scrollIndicator.onChange = { [weak self] in self?.onChange?() }
        pictures.onArrival = { [weak self] in self?.onChange?() }
    }

    private var state: PlazaCardState? {
        if case .card(let s) = model.content { s } else { nil }
    }
    var isVisible: Bool { state != nil }

    private var rendered: PlazaCardState??
    func didAppear() { pictures.forgetFailures() }

    private func modelChanged() {
        if state == nil { scrollOwner = nil; scrollState = PlazaScrollState(); rowImages = [:]; scrollIndicator.reset(); rendered = nil }   // reopening the same card draws it again
        if rendered != .some(state) { onChange?() }
    }

    // MARK: layout

    struct Pill { let line: PlazaTextLine, frame: CGRect, fill: PlazaColor, ink: PlazaColor, text: String }   // frame: panel points

    struct Header {
        let title: [PlazaTextLine], titleTop: CGFloat
        let name: PlazaTextLine?, nameTop: CGFloat
        let pills: [Pill]
        let currentTop: CGFloat?
        let x: CGFloat
    }

    struct Layout {
        let size: CGSize
        let bodyHeight: CGFloat, smallHeight: CGFloat, body: PlazaFontMetrics, small: PlazaFontMetrics
        let header: Header
        let activityTitle: PlazaTextLine
        let activity: [(label: PlazaTextLine, value: PlazaTextLine, row: PlazaActivity.Row)]
        let none: PlazaTextLine
        let message: PlazaTextLine?
        let columnWidth: CGFloat
        let dex: [TeamDexSpecies]
        let names: [PlazaTextLine]
        let cellPills: PlazaTextLine?         // the legendary pill's text
        let star: PlazaTextLine
        let legendary: Pill?
        let rows: Int, content: CGFloat
        var rowFrames: [CGRect] {
            let m = PlazaCardMetrics.self
            let pitch = m.cellSize.height + m.spacing
            return (0..<rows).map { CGRect(x: 0, y: CGFloat($0) * pitch - 1, width: PlazaCardStyle.lower.width, height: m.cellSize.height + 2) }
        }
    }

    private struct LayoutKey: Equatable { let state: PlazaCardState, day: String, scale: CGFloat, engine: String, dark: Bool }
    private var laidOut: (key: LayoutKey, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout? {
        guard let state else { return nil }
        let day = PlazaActivity.dayKey(now())
        let engine = String(describing: type(of: text))
        let key = LayoutKey(state: state, day: day, scale: scale, engine: engine, dark: isDark)
        if let laidOut, laidOut.key == key { return laidOut.layout }
        let s = PlazaCardStyle.self, m = PlazaCardMetrics.self
        let l = L(.ko)
        let body = text.metrics(s.body), small = text.metrics(s.small)
        let bodyH = (body.ascender - body.descender).rounded(), smallH = (small.ascender - small.descender).rounded()
        func up(_ v: CGFloat) -> CGFloat { PlazaPanelStyle.pixelUp(v, scale: scale) }

        // Header: the text column, centred vertically beside the picture.
        let textX = s.header.minX + m.spriteSide + s.headerGap
        // The stack puts its gap on both sides of the trailing spacer, so the column is 12 narrower than what is left of the picture.
        let columnWidth = s.header.maxX - textX - s.headerGap
        let member = state.member
        let titleLines = Array(text.wrappedLines(l.plazaCardTitle(nickname: member.nickname), font: s.body, width: columnWidth).prefix(s.titleLines))
        let name = state.characterName.map { text.line($0, font: s.body) }
        let name1 = name.map { PlazaPanelText.cut($0, width: columnWidth, font: s.body, text: text, scale: scale) }
        let badges = state.characterBadges
        var heights: [CGFloat] = [CGFloat(titleLines.count) * bodyH]
        if name1 != nil { heights.append(bodyH) }
        let pillHeight = smallH + 2 * s.pillPadding.height
        if !badges.isEmpty { heights.append(pillHeight) }
        if state.differingCurrent != nil { heights.append(30) }
        let total = heights.reduce(0, +) + CGFloat(heights.count - 1) * s.columnGap
        var y = s.header.minY + PlazaPanelStyle.pixel((s.header.height - total) / 2, scale: scale)
        let titleTop = y
        y += CGFloat(titleLines.count) * bodyH + s.columnGap
        let nameTop = y
        if name1 != nil { y += bodyH + s.columnGap }
        let pillTop = y
        var pills: [Pill] = []
        if !badges.isEmpty {
            var x = textX
            for badge in badges {
                let (string, fill, ink): (String, PlazaColor, PlazaColor) = switch badge {
                case .shiny: (l.plazaCardShiny, s.yellow, s.ink)
                case .rarity(let r): (l.rarityLabel(r), s.rarity(r, dark: isDark), .white)
                }
                let line = text.line(string, font: s.small)
                let w = up(line.width) + 2 * s.pillPadding.width
                pills.append(Pill(line: line, frame: CGRect(x: x, y: pillTop, width: w, height: pillHeight), fill: fill, ink: ink, text: string))
                x += w + s.badgeGap
            }
            y += pillHeight + s.columnGap
        }
        let header = Header(title: titleLines, titleTop: titleTop, name: name1, nameTop: nameTop, pills: pills, currentTop: state.differingCurrent == nil ? nil : y, x: textX)

        // Activity.
        let colW = (s.activity.width - 2 * s.activityInset - s.activityColumnGap) / 2
        let rows = PlazaActivity.rows(state.todayActivity(now: now()))
        let activity = rows.map { r -> (PlazaTextLine, PlazaTextLine, PlazaActivity.Row) in
            let value = text.line(r.value, font: s.small)
            let label = PlazaPanelText.cut(text.line(r.label, font: s.small), width: max(0, colW - up(value.width) - 4), font: s.small, text: text, scale: scale)
            return (label, value, r)
        }

        // The dex.
        var dex: [TeamDexSpecies] = [], names: [PlazaTextLine] = []
        if case .loaded(_, let profile) = state {
            dex = profile.dex
            names = dex.map { PlazaPanelText.cut(text.line($0.name, font: s.small), width: m.cellSize.width - 4, font: s.small, text: text, scale: scale) }
        }
        let legendaryLine = text.line(l.rarityLabel(.legendary), font: s.small)
        let legendary = Pill(line: legendaryLine, frame: CGRect(x: 2, y: 2, width: up(legendaryLine.width) + 2 * s.pillPadding.width, height: pillHeight),
                             fill: s.rarity(.legendary, dark: isDark), ink: .white, text: l.rarityLabel(.legendary))
        let rowCount = (dex.count + m.columns - 1) / m.columns
        let content = rowCount == 0 ? 0 : CGFloat(rowCount) * m.cellSize.height + CGFloat(rowCount - 1) * m.spacing
        let message: PlazaTextLine? = switch state {
        case .loading: text.line(l.plazaCardLoading, font: s.body)
        case .failed: text.line(l.plazaCardFailed, font: s.body)
        case .loaded: nil
        }
        let result = Layout(size: m.panelSize, bodyHeight: bodyH, smallHeight: smallH, body: body, small: small, header: header,
                            activityTitle: text.line(l.plazaCardActivityTitle, font: s.small), activity: activity, none: text.line(l.plazaActivityNone, font: s.small),
                            message: message, columnWidth: colW, dex: dex, names: names, cellPills: nil, star: text.line("★", font: .system(size: 12, weight: .regular)),
                            legendary: legendary, rows: rowCount, content: content)
        laidOut = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { PlazaCardMetrics.panelSize }

    // MARK: drawing

    private var drawnOffset: CGFloat = 0
    private var rowImages: [String: PlazaImage] = [:]
    private var rowImageKey = ""
    private var staticImage: (key: String, image: PlazaImage?) = ("", nil)

    private func image(_ size: CGSize, scale: CGFloat, graphics: any PlazaGraphics, _ draw: (any PlazaCanvas) -> Void) -> PlazaImage? {
        guard let canvas = graphics.makeCanvas(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()), colorSpace: .sRGB) else { return nil }
        canvas.scale(x: scale, y: scale)
        draw(canvas)
        return canvas.makeImage()
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = .some(state)
        let text = graphics.text
        guard let state, let l = layout(scale: scale, text: text) else { return PlazaPanelDrawing() }
        let s = PlazaCardStyle.self, m = PlazaCardMetrics.self
        let lower = s.lower
        if scrollOwner != state { scrollOwner = state; scrollState = PlazaScrollState(); scrollIndicator.reset(); pictures.forgetFailures() }
        scrollState.setMetrics(content: l.content, viewport: lower.height)
        let sprite = pictures.sprite(state.member.character)
        let current = state.differingCurrent.flatMap { pictures.icon($0.speciesID) }
        let member = state.member
        var layers: [PlazaPanelLayer] = []
        var items: [PlazaAccessibilityItem] = []
        var tips: [PlazaTooltip] = []

        // Plate, header, activity and the message: one image, drawn again when a picture arrives.
        let key = "\(scale) \(String(describing: type(of: text))) \(state) \(PlazaActivity.dayKey(now())) \(sprite != nil) \(current != nil) \(isDark)"
        if staticImage.key != key {
            let space = PlazaPanelSpace(content: l.size, room: 0)
            staticImage = (key, space.image(scale: scale, graphics: graphics) { canvas in
                PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: l.size)))
                let pen = PlazaPen(canvas: canvas, space: space, ascender: l.body.ascender)
                let smallPen = PlazaPen(canvas: canvas, space: space, ascender: l.small.ascender)
                let white12 = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
                // The picture's box.
                let box = CGRect(x: s.header.minX, y: s.header.minY, width: m.spriteSide, height: m.spriteSide)
                pen.fill(box, white12, radius: s.boxRadius)
                PlazaRosterPanel.drawIcon(sprite, in: box, on: canvas, space: space, placeholderInset: 36, placeholderRadius: 8)
                let color = PlazaNameColor.color(forMemberID: member.memberID, chosen: member.nameColor)
                for (i, line) in l.header.title.enumerated() {
                    pen.line(line, x: l.header.x, top: l.header.titleTop + CGFloat(i) * l.bodyHeight, color: color, shadow: s.shadow)
                }
                if let name = l.header.name { pen.line(name, x: l.header.x, top: l.header.nameTop, color: .white) }
                for pill in l.header.pills {
                    pen.fill(pill.frame, pill.fill, radius: pill.frame.height / 2)
                    smallPen.line(pill.line, x: pill.frame.minX + s.pillPadding.width, top: pill.frame.minY + s.pillPadding.height, color: pill.ink)
                }
                if let top = l.header.currentTop {
                    PlazaRosterPanel.drawIcon(current, in: CGRect(x: l.header.x, y: top, width: 40, height: 30), on: canvas, space: space)
                }
                // Activity.
                let a = s.activity
                pen.fill(a, white12, radius: s.activityRadius)
                let titleTop = a.minY + m.activityPadding + PlazaPanelStyle.pixel((m.activityTitleHeight - l.smallHeight) / 2, scale: scale)
                let rowOffset = PlazaPanelStyle.pixel((m.activityRowHeight - l.smallHeight) / 2, scale: scale)
                smallPen.line(l.activityTitle, x: a.minX + s.activityInset, top: titleTop, color: .white, shadow: s.shadow)
                let rowsTop = a.minY + m.activityPadding + m.activityTitleHeight
                if l.activity.isEmpty {
                    smallPen.line(l.none, x: a.minX + s.activityInset, top: rowsTop + rowOffset, color: .white, shadow: s.shadow)
                }
                for (i, row) in l.activity.enumerated() {
                    let col = i < 4 ? 0 : 1, r = i < 4 ? i : i - 4
                    let x = a.minX + s.activityInset + CGFloat(col) * (l.columnWidth + s.activityColumnGap)
                    let top = rowsTop + CGFloat(r) * m.activityRowHeight + rowOffset
                    smallPen.line(row.label, x: x, top: top, color: .white, shadow: s.shadow)
                    smallPen.line(row.value, x: x + l.columnWidth - PlazaPanelStyle.pixelUp(row.value.width, scale: scale), top: top, color: .white, shadow: s.shadow)
                }
                // Loading / failed.
                if let message = l.message {
                    pen.line(message, x: lower.minX + PlazaPanelStyle.pixel((lower.width - message.width) / 2, scale: scale),
                             top: lower.minY + PlazaPanelStyle.pixel((lower.height - l.bodyHeight) / 2, scale: scale), color: .white)
                }
            })
        }
        if let p = staticImage.image { layers.append(.image(p, frame: CGRect(origin: .zero, size: l.size))) }

        // Accessibility of the static part.
        let titleHeight = CGFloat(l.header.title.count) * l.bodyHeight
        items.append(PlazaAccessibilityItem(frame: CGRect(x: l.header.x, y: l.header.titleTop, width: l.columnWidthText, height: titleHeight),
                                            role: .staticText, label: L(.ko).plazaCardTitle(nickname: member.nickname)))
        if let name = l.header.name, let label = state.characterName {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: l.header.x, y: l.header.nameTop, width: PlazaPanelStyle.pixelUp(name.width, scale: scale), height: l.bodyHeight),
                                                role: .staticText, label: label))
        }
        for pill in l.header.pills { items.append(PlazaAccessibilityItem(frame: pill.frame, role: .staticText, label: pill.text)) }
        let a = s.activity
        items.append(PlazaAccessibilityItem(frame: CGRect(x: a.minX + s.activityInset, y: a.minY + m.activityPadding, width: PlazaPanelStyle.pixelUp(l.activityTitle.width, scale: scale), height: m.activityTitleHeight),
                                            role: .staticText, label: L(.ko).plazaCardActivityTitle))
        if l.activity.isEmpty {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: a.minX + s.activityInset, y: a.minY + m.activityPadding + m.activityTitleHeight, width: PlazaPanelStyle.pixelUp(l.none.width, scale: scale), height: m.activityRowHeight),
                                                role: .staticText, label: L(.ko).plazaActivityNone))
        }
        for (i, row) in l.activity.enumerated() {
            let col = i < 4 ? 0 : 1, r = i < 4 ? i : i - 4
            items.append(PlazaAccessibilityItem(frame: CGRect(x: a.minX + s.activityInset + CGFloat(col) * (l.columnWidth + s.activityColumnGap),
                                                              y: a.minY + m.activityPadding + m.activityTitleHeight + CGFloat(r) * m.activityRowHeight, width: l.columnWidth, height: m.activityRowHeight),
                                                role: .staticText, label: row.row.label, value: row.row.value))
        }
        if let message = l.message, let text = Optional(state) {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: lower.minX + (lower.width - message.width) / 2, y: lower.minY + (lower.height - l.bodyHeight) / 2,
                                                              width: PlazaPanelStyle.pixelUp(message.width, scale: scale), height: l.bodyHeight),
                                                role: .staticText, label: { if case .loading = text { L(.ko).plazaCardLoading } else { L(.ko).plazaCardFailed } }()))
        }

        // The dex rows in the viewport, each cut at the viewport's edges.
        guard !l.dex.isEmpty else { return PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips) }
        let offset = PlazaPanelStyle.pixel(scrollState.offset, scale: scale)
        drawnOffset = offset
        let gridX = PlazaPanelStyle.pixel((lower.width - s.gridWidth) / 2, scale: scale)
        let imageKey = "\(scale) \(String(describing: type(of: text))) \(isDark)"
        if rowImageKey != imageKey { rowImageKey = imageKey; rowImages = [:] }
        var kept: [String: PlazaImage] = [:]
        let frames = l.rowFrames
        let pitch = m.cellSize.height + m.spacing
        for r in scrollState.visibleRows(frames) {
            let cells = (r * m.columns)..<min(l.dex.count, (r + 1) * m.columns)
            let icons = cells.map { pictures.icon(l.dex[$0].speciesID) }
            let cacheKey = "\(r) \(icons.map { $0 != nil })"
            guard let shown = scrollState.visible(frames[r], offset: offset) else { continue }
            var picture: PlazaImage? = rowImages[cacheKey] ?? image(frames[r].size, scale: scale, graphics: graphics) { canvas in
                let space = PlazaPanelSpace(content: frames[r].size, room: 0)
                let smallPen = PlazaPen(canvas: canvas, space: space, ascender: l.small.ascender)
                for (n, index) in cells.enumerated() {
                    let species = l.dex[index]
                    let cell = CGRect(x: gridX + CGFloat(n) * (m.cellSize.width + m.spacing), y: 1, width: m.cellSize.width, height: m.cellSize.height)
                    smallPen.fill(cell, PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15), radius: s.cellRadius)
                    let contentTop = cell.minY + PlazaPanelStyle.pixel((m.cellSize.height - (m.iconSize.height + 1 + l.smallHeight)) / 2, scale: scale)
                    PlazaRosterPanel.drawIcon(icons[n], in: CGRect(x: cell.minX + (m.cellSize.width - m.iconSize.width) / 2, y: contentTop, width: m.iconSize.width, height: m.iconSize.height),
                                              on: canvas, space: space)
                    let name = l.names[index]
                    smallPen.line(name, x: cell.minX + 2 + PlazaPanelStyle.pixel((m.cellSize.width - 4 - name.width) / 2, scale: scale), top: contentTop + m.iconSize.height + 1, color: .white)
                    if species.rarity == .legendary {
                        canvas.setStrokeColor(s.rarity(.legendary, dark: isDark))
                        canvas.strokeRoundedRect(space.canvas(cell), radius: s.cellRadius, lineWidth: 1.5)
                        if let pill = l.legendary {
                            let f = pill.frame.offsetBy(dx: cell.minX, dy: cell.minY)
                            smallPen.fill(f, pill.fill, radius: f.height / 2)
                            smallPen.line(pill.line, x: f.minX + s.pillPadding.width, top: f.minY + s.pillPadding.height, color: pill.ink)
                        }
                    }
                    if species.hasShiny {
                        let starPen = PlazaPen(canvas: canvas, space: space, ascender: graphics.text.metrics(.system(size: 12, weight: .regular)).ascender)
                        starPen.line(l.star, x: cell.maxX - 4 - PlazaPanelStyle.pixelUp(l.star.width, scale: scale), top: cell.minY + 2, color: s.yellow)
                    }
                }
            }
            if let full = picture {
                kept[cacheKey] = full
                if shown.height < frames[r].height {
                    let top = max(0, offset - frames[r].minY)
                    picture = full.cropping(to: PlazaPixelRect(x: 0, y: Int((top * scale).rounded()), width: full.width, height: Int((shown.height * scale).rounded())))
                }
            }
            if let p = picture { layers.append(.image(p, frame: shown.offsetBy(dx: lower.minX, dy: lower.minY))) }
            // Hover text and VoiceOver for each cell of the row, cut to the viewport.
            for (n, index) in cells.enumerated() {
                let cellRect = CGRect(x: gridX + CGFloat(n) * (m.cellSize.width + m.spacing), y: CGFloat(r) * pitch - offset, width: m.cellSize.width, height: m.cellSize.height)
                let cut = cellRect.intersection(CGRect(x: 0, y: 0, width: lower.width, height: lower.height))
                guard !cut.isNull, cut.height > 0 else { continue }
                let panelRect = cut.offsetBy(dx: lower.minX, dy: lower.minY)
                tips.append(PlazaTooltip(frame: panelRect, text: l.dex[index].name))
                items.append(PlazaAccessibilityItem(frame: panelRect, role: .staticText, label: l.dex[index].name))
            }
        }
        rowImages = kept
        layers += scrollIndicator.layers(state: scrollState, offset: offset, viewport: lower, scale: scale, graphics: graphics)
        return PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips)
    }

    // MARK: input

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard isVisible, CGRect(origin: .zero, size: PlazaCardMetrics.panelSize).contains(point) else { return nil }
        return PlazaPanelHit(action: "card", index: nil)
    }

    /// Only the dex grid takes the wheel (a `ScrollView` under the activity box): elsewhere it goes on.
    func scroll(dx: CGFloat, dy: CGFloat, at point: CGPoint) -> Bool {
        guard isVisible, PlazaCardStyle.lower.contains(point), scrollState.scroll(deltaY: dy) else { return false }
        scrollIndicator.scrolled()
        onChange?()
        return true
    }
}

private extension PlazaCardPanel.Layout {
    /// What the title's accessibility frame is as wide as: the column.
    var columnWidthText: CGFloat { PlazaCardStyle.header.maxX - header.x - PlazaCardStyle.headerGap }
}
