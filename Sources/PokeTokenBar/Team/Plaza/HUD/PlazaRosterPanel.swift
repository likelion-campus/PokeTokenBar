import Foundation
import Observation

/// The roster's look, copied from `PlazaRosterView` (SwiftUI, replaced by this panel on the Mac; the view is kept in Tests/Legacy): colours, radii, paddings.
enum PlazaRosterStyle {
    static let ink = PlazaColor(hex: 0x2D4048)
    static let cream = PlazaColor(hex: 0xF8F8F0)
    static let shadow = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
    static let yellow = PlazaColor(hex: 0xFFE060)
    static let male = PlazaColor(hex: 0xA8D8FF), female = PlazaColor(hex: 0xFFB0C8)
    static let font = PlazaFont.plaza(.body)
    /// The slot's shape (`UnevenRoundedRectangle`): round on the icon's side, tight on the status's.
    static let slotRadii = PlazaCornerRadii(topLeading: 22, bottomLeading: 22, bottomTrailing: 8, topTrailing: 8)
    static let iconFrame = CGSize(width: 40, height: 30)
    /// The icon's left padding, gaps (icon-text, name-gender-star, name-species) and the status's paddings.
    static let iconLeading: CGFloat = 6, iconGap: CGFloat = 4, nameGap: CGFloat = 3, lineGap: CGFloat = 1
    static let statusPadding = CGSize(width: 5, height: 1), statusTrailing: CGFloat = 6
    static let titlePadding = CGSize(width: 8, height: 2), titleRadius: CGFloat = 4
    /// `HStack`'s default gap between the header's pieces.
    static let headerGap: CGFloat = 8
    /// How far a bouncing icon rises and how often it steps (SwiftUI's `offset(y: -2)` toggled every 0.5 s).
    static let bounce: CGFloat = 2
    static let beat: TimeInterval = 0.5
    /// A disabled arrow (`.opacity(0.35)`).
    static let disabledOpacity: CGFloat = 0.35

    /// The slot's gradient (top, bottom) and border, by state.
    static func colors(_ e: PlazaRosterEntry) -> (top: PlazaColor, bottom: PlazaColor, border: PlazaColor) {
        if e.presence == .asleep { return (PlazaColor(hex: 0x8088A0), PlazaColor(hex: 0x707890), PlazaColor(hex: 0x3A4050)) }
        if e.presence == .idle { return (PlazaColor(hex: 0xA8B0C0), PlazaColor(hex: 0x9098A8), PlazaColor(hex: 0x4A5060)) }
        if e.isMe { return (PlazaColor(hex: 0xF8B878), PlazaColor(hex: 0xF09858), PlazaColor(hex: 0x8A4A28)) }
        return (PlazaColor(hex: 0x7CC8E8), PlazaColor(hex: 0x5FB0D8), PlazaColor(hex: 0x23464C))
    }

    static func gender(_ g: PokemonGender?) -> (text: String, color: PlazaColor)? {
        switch g {
        case .male: ("♂", male)
        case .female: ("♀", female)
        default: nil
        }
    }

    /// Whether the entry's icon bounces: online or focusing, and the plaza is showing.
    static func bounces(_ e: PlazaRosterEntry) -> Bool { e.presence == .online || e.presence == .focus }
}

/// The party-style member list at the window's top right (`PlazaRosterView`, SwiftUI, replaced by this panel on the Mac and kept in Tests/Legacy): a plate
/// `PlazaRosterMetrics.width` wide with a header (title, "접속 n / m" count, and < > when there is more than a page) and,
/// under it, one slot per member of the shown page (`PlazaRosterModel.capacity` slots at most): a box icon, the nickname
/// with gender and shiny marks, the species name, and the state's badge. The slot's colours follow the state. A click on a
/// member's slot is `("select", i)` (the owner walks to `entry(forHit:)`), on the "me" slot `("me")` (taken, nothing
/// happens), on an enabled arrow `("previous")` / `("next")`, anywhere else on the plate `("roster")`. Hovering a member's
/// slot shows "누르면 이 팀원에게 걸어가요" (a tooltip). The icons of online members hop 2 points every half second while
/// the plaza shows (the panel's `PlazaAnimationClock`, which runs only then); pictures arrive asynchronously through the
/// `PlazaIconSource` and draw again when they do (a grey placeholder until then).
@MainActor final class PlazaRosterPanel: PlazaPanel {
    let id = PlazaPanelID.roster
    let anchor = PlazaPanelAnchor.topTrailing
    let offset = CGPoint(x: PlazaRosterMetrics.margin, y: PlazaRosterMetrics.margin)
    var onChange: (() -> Void)?
    let isVisible = true
    private let model: PlazaRosterModel
    let pictures: PlazaPictureCache
    private let clock: PlazaAnimationClock
    private var observer: PlazaChangeObserver?

    /// Pressed on an arrow: its label dims while the mouse is still over it (`.plain`).
    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaNameColorPickerPanel.held(oldValue) != PlazaNameColorPickerPanel.held(interaction) { onChange?() } }
    }

    init(model: PlazaRosterModel, icons: any PlazaIconSource = PlatformPlaza.iconSource(), clock: PlazaAnimationClock? = nil) {
        self.model = model
        pictures = PlazaPictureCache(source: icons)
        self.clock = clock ?? PlazaAnimationClock(interval: PlazaRosterStyle.beat)
        observer = PlazaChangeObserver(track: { _ = model.entries; _ = model.isAnimating; _ = model.capacity; _ = model.page },
                                       changed: { [weak self] in self?.modelChanged() })
        pictures.onArrival = { [weak self] in self?.onChange?() }
        self.clock.onTick = { [weak self] in self?.tick() }
    }

    /// The beat of the bouncing icons.
    var animationClock: PlazaAnimationClock { clock }
    var isAnimating: Bool { clock.isRunning }

    private var rendered: String?
    private var state: String { "\(model.entries) \(model.page) \(model.capacity) \(model.isAnimating)" }
    /// The shown page and who is on it: a page turn or a new member is a slot appearing, so failed pictures get another try.
    private var shownSlots = ""
    func didAppear() { pictures.forgetFailures() }

    private func modelChanged() {
        let slots = "\(page.index) \(page.shown.map(\.id))"
        if slots != shownSlots { shownSlots = slots; pictures.forgetFailures() }
        if !model.isAnimating { clock.setRunning(false) }
        if rendered != state { onChange?() }
    }

    /// Whether the last beat drew anything: a beat nobody drew (no window, plaza hidden) ends the clock.
    private var drewSinceBeat = true
    private func tick() {
        guard drewSinceBeat else {
            clock.setRunning(false)
            rendered = nil   // draw once more whenever the plaza shows again
            onChange?()
            return
        }
        drewSinceBeat = false
        onChange?()
    }

    // MARK: model

    private var page: (shown: [PlazaRosterEntry], index: Int, count: Int) {
        PlazaRoster.page(model.entries, index: model.page, size: model.capacity)
    }

    /// The member a `("select", i)` hit names (the shown page's slot `i`).
    func entry(forHit hit: PlazaPanelHit) -> PlazaRosterEntry? {
        guard hit.action == "select", let i = hit.index, laidOut?.layout.slots.indices.contains(i) == true else { return nil }
        return laidOut?.layout.slots[i].entry
    }

    // MARK: layout

    struct Slot {
        let entry: PlazaRosterEntry
        let frame: CGRect               // panel points
        let nickname: PlazaTextLine, species: PlazaTextLine, status: PlazaTextLine
        let symbols: [(line: PlazaTextLine, color: PlazaColor)]   // gender, ★
        let nameWidth: CGFloat          // the nickname's width after truncation
        let textTop: CGFloat            // the two text lines' top, in the slot
        let statusFrame: CGRect         // in the slot
        let label: String
    }

    struct Layout {
        let size: CGSize
        let lineHeight: CGFloat, ascender: CGFloat
        let title: PlazaTextLine, count: PlazaTextLine
        let titleFrame: CGRect, countX: CGFloat
        let arrows: [(glyph: PlazaTextLine, frame: CGRect, enabled: Bool, delta: Int)]
        let slots: [Slot]
        let pageIndex: Int, pageCount: Int
        let online: Int, total: Int
    }

    private struct LayoutKey: Equatable { let shown: [PlazaRosterEntry], index: Int, count: Int, online: Int, total: Int, scale: CGFloat, engine: String }
    private var laidOut: (key: LayoutKey, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let entries = model.entries
        let online = entries.filter { $0.presence == .online || $0.presence == .focus }.count
        let p = page
        let engine = String(describing: type(of: text))
        let key = LayoutKey(shown: p.shown, index: p.index, count: p.count, online: online, total: entries.count, scale: scale, engine: engine)
        if let laidOut, laidOut.key == key { return laidOut.layout }
        let m = PlazaRosterMetrics.self, s = PlazaRosterStyle.self
        let l = L(.ko)
        let metrics = text.metrics(s.font)
        let lineHeight = (metrics.ascender - metrics.descender).rounded()
        func up(_ v: CGFloat) -> CGFloat { PlazaPanelStyle.pixelUp(v, scale: scale) }
        let inner = m.width - 2 * m.padding

        // Header.
        let title = text.line(l.plazaRosterTitle, font: s.font)
        let titleSize = CGSize(width: up(title.width) + 2 * s.titlePadding.width, height: lineHeight + 2 * s.titlePadding.height)
        let titleFrame = CGRect(x: m.padding, y: m.padding + PlazaPanelStyle.pixel((m.headerHeight - titleSize.height) / 2, scale: scale),
                                width: titleSize.width, height: titleSize.height)
        let count = text.line(l.plazaRosterCount(online: online, total: entries.count), font: s.font)
        var arrows: [(PlazaTextLine, CGRect, Bool, Int)] = []
        var right = m.padding + inner
        if p.count > 1 {
            let h = m.pagerHitSize
            for (n, spec) in [("<", p.index > 0, -1), (">", p.index < p.count - 1, 1)].enumerated() {
                let x = right - 2 * h + CGFloat(n) * h
                arrows.append((text.line(spec.0, font: s.font), CGRect(x: x, y: m.padding + (m.headerHeight - h) / 2, width: h, height: h), spec.1, spec.2))
            }
            right -= 2 * h + s.headerGap
        }
        let countX = right - up(count.width)

        // Slots.
        let slotWidth = inner
        var slots: [Slot] = []
        for (i, entry) in p.shown.enumerated() {
            let frame = CGRect(x: m.padding, y: m.padding + m.headerHeight + m.listTopPadding + CGFloat(i) * (m.slotHeight + m.slotSpacing),
                               width: slotWidth, height: m.slotHeight)
            let status = text.line(entry.presence.badge.text, font: s.font)
            let statusWidth = up(status.width) + 2 * s.statusPadding.width
            // The text column: what is left between the icon and the status (the status keeps its own width; the spacer
            // between them is zero wide but both sides of it have the stack's 4-point gap).
            let column = slotWidth - (s.iconLeading + s.iconFrame.width) - s.iconGap - 2 * s.iconGap - (statusWidth + s.statusTrailing)
            var symbols: [(PlazaTextLine, PlazaColor)] = []
            if let g = PlazaRosterStyle.gender(entry.gender) { symbols.append((text.line(g.text, font: s.font), g.color)) }
            if entry.isShiny { symbols.append((text.line("★", font: s.font), s.yellow)) }
            let rigid = symbols.reduce(CGFloat(0)) { $0 + s.nameGap + up($1.0.width) }
            var nickname = text.line(entry.nickname, font: s.font)
            let room = max(0, column - rigid)
            if up(nickname.width) > room {
                nickname = text.truncated(nickname, width: room, ellipsis: text.line("…", font: s.font)) ?? text.line("", font: s.font)
            }
            var species = text.line(entry.speciesName, font: s.font)
            if up(species.width) > column {
                species = text.truncated(species, width: max(0, column), ellipsis: text.line("…", font: s.font)) ?? text.line("", font: s.font)
            }
            let textHeight = 2 * lineHeight + s.lineGap
            let statusSize = CGSize(width: statusWidth, height: lineHeight + 2 * s.statusPadding.height)
            slots.append(Slot(entry: entry, frame: frame, nickname: nickname, species: species, status: status, symbols: symbols.map { ($0.0, $0.1) },
                              nameWidth: up(nickname.width), textTop: PlazaPanelStyle.pixel((m.slotHeight - textHeight) / 2, scale: scale),
                              statusFrame: CGRect(x: slotWidth - s.statusTrailing - statusWidth,
                                                  y: PlazaPanelStyle.pixel((m.slotHeight - statusSize.height) / 2, scale: scale),
                                                  width: statusWidth, height: statusSize.height),
                              label: [[entry.nickname] + (PlazaRosterStyle.gender(entry.gender).map { [$0.text] } ?? []) + (entry.isShiny ? ["★"] : []), [entry.speciesName],
                                      [entry.presence.badge.text]].map { $0.joined(separator: " ") }.joined(separator: ", ")))
        }
        let n = CGFloat(slots.count)
        let height = m.padding + m.headerHeight + m.listTopPadding + n * m.slotHeight + max(0, n - 1) * m.slotSpacing + m.padding
        let result = Layout(size: CGSize(width: m.width, height: height), lineHeight: lineHeight, ascender: metrics.ascender,
                            title: title, count: count, titleFrame: titleFrame, countX: countX, arrows: arrows, slots: slots,
                            pageIndex: p.index, pageCount: p.count, online: online, total: entries.count)
        laidOut = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        layout(scale: scale, text: text).size
    }

    // MARK: drawing

    /// Which beat each bouncing slot started on: its icon is up on an odd number of beats since (SwiftUI's own task per
    /// icon started when the slot appeared).
    private var born: [String: Int] = [:]

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        drewSinceBeat = true
        let text = graphics.text
        let l = layout(scale: scale, text: text)
        let s = PlazaRosterStyle.self
        // The clock: only while a shown slot bounces and the plaza shows.
        let bouncing = Set(l.slots.filter { s.bounces($0.entry) && model.isAnimating }.map(\.entry.id))
        clock.setRunning(!bouncing.isEmpty)
        born = born.filter { bouncing.contains($0.key) && clock.isRunning }
        for id in bouncing where born[id] == nil { born[id] = clock.beats }
        func up(_ id: String) -> Bool { born[id].map { (clock.beats - $0) % 2 == 1 } ?? false }

        let space = PlazaPanelSpace(content: l.size, room: 0)
        let held = PlazaNameColorPickerPanel.held(interaction)
        let ink = s.ink
        // Pictures are asked for as the slots are drawn (an unknown one starts loading; the placeholder stands in).
        let icons = l.slots.map { pictures.icon($0.entry.speciesID) }
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: l.size)))
            func line(_ line: PlazaTextLine, x: CGFloat, top: CGFloat, color: PlazaColor, shadow: Double? = nil, alpha: CGFloat = 1) {
                let base = space.canvas(CGPoint(x: x, y: top + l.ascender))
                if let shadow {
                    canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: shadow))
                    canvas.draw(line, at: CGPoint(x: base.x + 1, y: base.y - 1))
                }
                canvas.setFillColor(color)
                canvas.draw(line, at: base)
            }
            // Header.
            canvas.setFillColor(s.cream)
            canvas.fillRoundedRect(space.canvas(l.titleFrame), radius: s.titleRadius)
            line(l.title, x: l.titleFrame.minX + s.titlePadding.width, top: l.titleFrame.minY + s.titlePadding.height, color: ink)
            let headerTop = PlazaRosterMetrics.padding + PlazaPanelStyle.pixel((PlazaRosterMetrics.headerHeight - l.lineHeight) / 2, scale: scale)
            line(l.count, x: l.countX, top: headerTop, color: s.cream)
            for a in l.arrows {
                canvas.saveState()
                let pressed = a.enabled && held == PlazaPanelHit(action: a.delta < 0 ? "previous" : "next", index: nil)
                canvas.setAlpha((a.enabled ? 1 : s.disabledOpacity) * (pressed ? PlazaPanelStyle.pressedOpacity : 1))
                line(a.glyph, x: a.frame.minX + (a.frame.width - a.glyph.width) / 2, top: a.frame.minY + (a.frame.height - l.lineHeight) / 2, color: s.cream)
                canvas.restoreState()
            }
            // Slots.
            for (i, slot) in l.slots.enumerated() {
                let colors = s.colors(slot.entry)
                let f = slot.frame
                let box = space.canvas(f)
                canvas.saveState()
                canvas.clip(toUnevenRoundedRect: box, radii: s.slotRadii)
                canvas.setFillColor(colors.top)
                canvas.fill(CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2))
                canvas.setFillColor(colors.bottom)
                canvas.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height / 2))
                // Icon, 40x30 at the left with 6 of padding, centred vertically; it hops while it bounces.
                let hop: CGFloat = s.bounces(slot.entry) && model.isAnimating && up(slot.entry.id) ? -s.bounce : 0
                let iconBox = CGRect(x: f.minX + s.iconLeading, y: f.minY + (f.height - s.iconFrame.height) / 2 + hop,
                                     width: s.iconFrame.width, height: s.iconFrame.height)
                Self.drawIcon(icons[i], in: iconBox, on: canvas, space: space)
                // Text.
                let textX = f.minX + s.iconLeading + s.iconFrame.width + s.iconGap
                let top = f.minY + slot.textTop
                line(slot.nickname, x: textX, top: top, color: .white, shadow: s.shadow.alpha)
                var x = textX + slot.nameWidth
                for (symbol, color) in slot.symbols {
                    x += s.nameGap
                    line(symbol, x: x, top: top, color: color, shadow: s.shadow.alpha)
                    x += PlazaPanelStyle.pixelUp(symbol.width, scale: scale)
                }
                line(slot.species, x: textX, top: top + l.lineHeight + s.lineGap, color: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9), shadow: s.shadow.alpha * 0.9)
                // The status badge.
                let sf = slot.statusFrame.offsetBy(dx: f.minX, dy: f.minY)
                canvas.setFillColor(PlazaColor(hex: slot.entry.presence.badge.color))
                canvas.fillRoundedRect(space.canvas(sf), radius: sf.height / 2)
                line(slot.status, x: sf.minX + s.statusPadding.width, top: sf.minY + s.statusPadding.height, color: .white)
                canvas.restoreState()
                // The two strokes, the border over the white ring.
                canvas.setStrokeColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6))
                canvas.strokeUnevenRoundedRect(box.insetBy(dx: 3, dy: 3), radii: s.slotRadii.inset(by: 3), lineWidth: 2)
                canvas.setStrokeColor(colors.border)
                canvas.strokeUnevenRoundedRect(box.insetBy(dx: 1, dy: 1), radii: s.slotRadii.inset(by: 1), lineWidth: 2)
            }
        }

        // What VoiceOver finds and what hovering shows.
        var items = [PlazaAccessibilityItem(frame: l.titleFrame, role: .staticText, label: L(.ko).plazaRosterTitle),
                     PlazaAccessibilityItem(frame: CGRect(x: l.countX, y: PlazaRosterMetrics.padding, width: PlazaPanelStyle.pixelUp(l.count.width, scale: scale),
                                                          height: PlazaRosterMetrics.headerHeight),
                                            role: .staticText, label: L(.ko).plazaRosterCount(online: l.online, total: l.total))]
        for a in l.arrows where true {
            items.append(PlazaAccessibilityItem(frame: a.frame, role: .button, label: a.delta < 0 ? "<" : ">",
                                                action: a.enabled ? PlazaPanelHit(action: a.delta < 0 ? "previous" : "next", index: nil) : nil, isEnabled: a.enabled))
        }
        var tips: [PlazaTooltip] = []
        for (i, slot) in l.slots.enumerated() {
            let selectable = !slot.entry.isMe
            items.append(PlazaAccessibilityItem(frame: slot.frame, role: selectable ? .button : .staticText, label: slot.label,
                                                action: selectable ? PlazaPanelHit(action: "select", index: i, target: slot.entry.id) : nil))
            if selectable && slot.entry.presence != .asleep { tips.append(PlazaTooltip(frame: slot.frame, text: L(.ko).plazaRosterWalkHint)) }
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: l.size))] } ?? [], accessibility: items, tooltips: tips)
    }

    /// A box picture in a frame as SwiftUI's `Image(...).interpolation(.none).resizable().scaledToFit()` drew it (measured: it
    /// enlarges with soft edges, not nearest-neighbour, so the canvas keeps its default interpolation), or the
    /// placeholder (`RoundedRectangle(cornerRadius: 6)` at 25 % white, 4 inside the frame) while there is none.
    static func drawIcon(_ image: PlazaImage?, in frame: CGRect, on canvas: any PlazaCanvas, space: PlazaPanelSpace,
                         placeholderInset: CGFloat = 4, placeholderRadius: CGFloat = 6) {
        if let image {
            let fit = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
            canvas.saveState()
            canvas.draw(image, in: space.canvas(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)))
            canvas.restoreState()
        } else {
            canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
            canvas.fillRoundedRect(space.canvas(frame.insetBy(dx: placeholderInset, dy: placeholderInset)), radius: placeholderRadius)
        }
    }

    // MARK: input

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let l = laidOut?.layout, CGRect(origin: .zero, size: l.size).contains(point) else { return nil }
        for a in l.arrows where a.frame.contains(point) {
            return a.enabled ? PlazaPanelHit(action: a.delta < 0 ? "previous" : "next", index: nil) : PlazaPanelHit(action: "roster", index: nil)
        }
        for (i, slot) in l.slots.enumerated() where slot.frame.contains(point) {
            return slot.entry.isMe ? PlazaPanelHit(action: "me", index: nil) : PlazaPanelHit(action: "select", index: i, target: slot.entry.id)
        }
        return PlazaPanelHit(action: "roster", index: nil)   // the plate takes the click and does nothing
    }
}
