import Foundation
import Observation

/// What the berry five table shows; the controller derives it after every game step.
struct PlazaBerryBoard: Equatable {
    struct Seat: Equatable {
        var id: String
        var name: String
        var nameColor: PlazaColor
        /// Players are never eggs.
        var mon: TeamMonSummary
        /// 0...5, drawn as five ●○ circles.
        var score: Int
        var deckLeft: Int
        var top: PlazaBerry.Card?
        /// Pile cards under the top since the last clear; at most 2 are drawn, askew.
        var under: Int
        /// false: drawn faded.
        var isPlaying: Bool
    }

    enum Center: Equatable {
        case countdown(Int)
        case playing(event: String?)
        case result(lines: [String])
    }

    struct Ring: Equatable {
        /// Changes once per right bell: starts the rim, the sweep, the hop and 🔔.
        var clear: Int
        /// Who rang, an index into `seats`.
        var seat: Int
        /// The tops on the table at the clear, by `seats` index.
        var swept: [PlazaBerry.Card?]
        /// Seats whose card made the five (gold rim).
        var five: Set<Int>
    }

    /// Index 0 is me, at the bottom, then clockwise in seat order.
    var seats: [Seat]
    var center: Center
    /// Flips so far; +1 animates `flippedSeat`.
    var flip: Int
    var flippedSeat: Int?
    var ring: Ring?
    /// ✕ and "1초 쉬기" over the bell.
    var wrong: Bool
}

@MainActor @Observable final class PlazaBerryModel {
    /// nil hides the panel.
    var board: PlazaBerryBoard?
    /// The item pictures by item name, as they arrive.
    var items: [String: PlazaImage] = [:]
}

/// The berry five table: a full-window overlay with a dark scrim, the felt table, the centre plate with the bell, and around it each seat
/// (sprite, name, score) with its face-up pile and its deck, every card turned to face its seat. Everything is panel shapes and the apps' own
/// pictures; the cards are small rotated images of their own, cached, so a render draws only what changed.
///
/// Motion (never under Reduce Motion): a flip slides and unfolds the card from its deck onto its pile over `PlazaBerry.flipAnimation`, its face
/// visible from the first frame; a right bell rims the five cards gold for 0.4 s, then sweeps the piles to the ringer's pile over 0.4 s while
/// the ringer's sprite hops and 🔔 shows beside it. The clock runs only during such a motion, and only when the flip count grew by exactly one
/// or the ring's clear changed since the last board.
@MainActor final class PlazaBerryTablePanel: PlazaPanel {
    let id = PlazaPanelID.berryTable
    let anchor = PlazaPanelAnchor.fill
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    /// A press on the bell, at the press.
    var onBell: (() -> Void)?

    private let model: PlazaBerryModel
    private let pictures: PlazaPictureCache
    private let reduceMotion: () -> Bool
    private let clock: PlazaAnimationClock
    private var observer: PlazaChangeObserver?

    static let ringRim: TimeInterval = 0.4, ringSweep: TimeInterval = 0.4, ringHop: TimeInterval = 0.5
    static var ringTotal: TimeInterval { ringRim + ringSweep }
    private static let gold = PlazaColor(hex: 0xFFD76A)

    init(model: PlazaBerryModel, icons: any PlazaIconSource, reduceMotion: @escaping () -> Bool = { PlatformPlaza.reduceMotion() },
         clock: PlazaAnimationClock = PlazaAnimationClock(interval: 1.0 / 30)) {
        self.model = model
        pictures = PlazaPictureCache(source: icons)
        self.reduceMotion = reduceMotion
        self.clock = clock
        observer = PlazaChangeObserver(track: { _ = model.board; _ = model.items }, changed: { [weak self] in self?.modelChanged() })
        pictures.onArrival = { [weak self] in self?.onChange?() }
        self.clock.onTick = { [weak self] in self?.beat() }
    }

    var isVisible: Bool { model.board != nil }
    var isAnimating: Bool { clock.isRunning }
    func didAppear() { pictures.forgetFailures() }

    /// One drawn text row (or the bell) of the centre plate, in the panel's coordinates.
    struct PlateRow: Equatable {
        enum Kind { case head, bell, rule, digit, note, event, result, rank, close }
        var kind: Kind
        var text: String
        var frame: CGRect
        /// How many times as big the text is drawn; the row must be as tall as its glyphs.
        var magnify: CGFloat = 1
    }
    /// The centre plate and its rows as the last render drew them; the tests read it for overlap and wrapping.
    private(set) var plate: (frame: CGRect, rows: [PlateRow])?

    /// `s` broken at spaces only, greedy by `width` of each candidate line; a word wider than a line breaks between its characters. The
    /// engines' own `wrappedLines` also break between a digit and the Korean after it ("5 / 개면"), which the plate must not do.
    static func wordLines(_ s: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        var lines: [String] = [], current = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let joined = current.isEmpty ? word : current + " " + word
            if measure(joined) <= width { current = joined; continue }
            if !current.isEmpty { lines.append(current); current = "" }
            var rest = word[...]
            while measure(String(rest)) > width, rest.count > 1 {
                var cut = rest.startIndex
                for i in rest.indices.dropFirst() where measure(String(rest[..<rest.index(after: i)])) <= width { cut = rest.index(after: i) }
                if cut == rest.startIndex { cut = rest.index(after: rest.startIndex) }
                lines.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
            current = String(rest)
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: animation

    /// Clock beats at which each motion started.
    private var flipStart: (beat: Int, seat: Int)?
    private var ringStart: Int?
    private var seen: (flip: Int, clear: Int?)?
    /// Whether a render happened since the last beat: a beat nobody drew (no window, plaza hidden) ends the clock.
    private var drewSinceBeat = true

    private func modelChanged() {
        defer { onChange?() }
        guard let board = model.board else {
            seen = nil
            stopMotion()
            return
        }
        defer { seen = (board.flip, board.ring?.clear) }
        guard let before = seen else { return }   // the first board of a game is a start, not a step
        if board.flip != before.flip { flipStart = nil }
        if reduceMotion() { return }
        if board.flip == before.flip + 1, let seat = board.flippedSeat, board.seats.indices.contains(seat) {
            startClock()
            flipStart = (clock.beats, seat)
        }
        if let ring = board.ring, ring.clear != before.clear {
            startClock()
            ringStart = clock.beats
        }
    }

    private func startClock() {
        if !clock.isRunning { drewSinceBeat = true }
        clock.setRunning(true)
    }

    private func stopMotion() {
        flipStart = nil
        ringStart = nil
        clock.setRunning(false)
    }

    private func elapsed(since beat: Int) -> TimeInterval { Double(clock.beats - beat) * clock.interval }

    private func beat() {
        guard drewSinceBeat else {
            stopMotion()
            onChange?()
            return
        }
        drewSinceBeat = false
        if let f = flipStart, elapsed(since: f.beat) >= PlazaBerry.flipAnimation - 1e-9 { flipStart = nil }
        if let r = ringStart, elapsed(since: r) >= Self.ringTotal - 1e-9 { ringStart = nil }
        if flipStart == nil, ringStart == nil { clock.setRunning(false) }
        onChange?()
    }

    // MARK: layout

    private struct LayoutKey: Equatable { let viewport: CGSize, scale: CGFloat, seats: Int }
    private var laidOut: (key: LayoutKey, layout: PlazaBerryTableLayout)?
    private var lastViewport: CGSize = .zero

    func layout(viewport: CGSize, scale: CGFloat) -> PlazaBerryTableLayout {
        let key = LayoutKey(viewport: viewport, scale: scale, seats: model.board?.seats.count ?? 0)
        if let laidOut, laidOut.key == key { return laidOut.layout }
        let made = PlazaBerryTableLayout.make(viewport: viewport, seats: max(1, key.seats), scale: scale)
        laidOut = (key, made)
        return made
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        lastViewport = viewport
        return model.board == nil ? .zero : viewport
    }

    /// What the last render laid out, for tests: each seat's drawn name and where it sits (panel points).
    private(set) var placedNames: [(text: String, frame: CGRect)] = []
    private var placedScale: CGFloat = 1

    // MARK: hits

    private var bellActive: Bool {
        guard let board = model.board else { return false }
        if case .result = board.center { return false }
        return true
    }

    private var currentBell: CGRect? {
        guard lastViewport.width > 0, model.board != nil else { return nil }
        return layout(viewport: lastViewport, scale: placedScale).bell
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard model.board != nil else { return nil }
        if bellActive, let bell = currentBell, bell.contains(point) { return PlazaPanelHit(action: "bell", index: nil) }
        return PlazaPanelHit(action: "table", index: nil)
    }

    func scrollerContains(_ point: CGPoint) -> Bool { bellActive && currentBell?.contains(point) == true }

    func scrollerMouse(_ phase: PlazaScrollerPhase, at point: CGPoint) {
        if phase == .down { onBell?() }
    }

    // MARK: drawing

    private var cache: [String: PlazaImage] = [:]
    private var used: Set<String> = []

    /// The picture for `key`, drawn into a canvas of `size` points the first time and kept while renders keep asking for it.
    private func picture(_ key: String, size: CGSize, scale: CGFloat, graphics: any PlazaGraphics, _ draw: (any PlazaCanvas) -> Void) -> PlazaImage? {
        used.insert(key)
        if let image = cache[key] { return image }
        guard let image = PlazaPanelSpace(content: size, room: 0).image(scale: scale, graphics: graphics, draw) else { return nil }
        cache[key] = image
        return image
    }

    private func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func identity(_ image: PlazaImage?) -> Int { image.map { ObjectIdentifier($0).hashValue } ?? 0 }

    /// A picture fitted into `box` (canvas coordinates) without distortion; nearest sampling where it is enlarged.
    private func drawFitted(_ image: PlazaImage, in box: CGRect, on canvas: any PlazaCanvas, scale: CGFloat) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return }
        let k = min(box.width / w, box.height / h)
        let target = CGRect(x: box.midX - w * k / 2, y: box.midY - h * k / 2, width: w * k, height: h * k)
        canvas.saveState()
        if k * scale >= 1 { canvas.setInterpolationNone() }
        canvas.draw(image, in: target)
        canvas.restoreState()
    }

    private func drawText(_ line: PlazaTextLine, at p: CGPoint, color: PlazaColor, outline: Bool, on canvas: any PlazaCanvas) {
        if outline {
            canvas.setFillColor(PlazaColor(hex: 0x16242B))
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] as [(CGFloat, CGFloat)] { canvas.draw(line, at: CGPoint(x: p.x + dx, y: p.y + dy)) }
        }
        canvas.setFillColor(color)
        canvas.draw(line, at: p)
    }

    /// `name` cut with "…" so that it is at most `width` wide; its drawn text and width.
    private func fitName(_ name: String, width: CGFloat, text: any PlazaTextEngine, font: PlazaFont) -> (text: String, line: PlazaTextLine) {
        let whole = text.line(name, font: font)
        if whole.width <= width { return (name, whole) }
        let chars = Array(name)
        var lo = 0, hi = chars.count
        while lo < hi {   // the longest prefix that still fits with the ellipsis
            let mid = (lo + hi + 1) / 2
            if text.line(String(chars[..<mid]) + "…", font: font).width <= width { lo = mid } else { hi = mid - 1 }
        }
        let cut = String(chars[..<lo]) + "…"
        return (cut, text.line(cut, font: font))
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        guard let board = model.board else { return PlazaPanelDrawing() }
        drewSinceBeat = true
        lastViewport = viewport
        placedScale = scale
        used = []
        defer { cache = cache.filter { used.contains($0.key) } }
        let l = L(.ko)
        let layout = layout(viewport: viewport, scale: scale)
        let u = layout.unit, f = layout.shrink
        let text = graphics.text
        let small = PlazaFont.plaza(.small), body = PlazaFont.plaza(.body)
        let items = model.items
        let itemsKey = PlazaBerry.Berry.allCases.map { "\(identity(items[$0.itemName]))" }.joined(separator: ",")
        let flipT = flipStart.map { min(1, elapsed(since: $0.beat) / PlazaBerry.flipAnimation) }
        let ringT = ringStart.map { elapsed(since: $0) }
        var layers: [PlazaPanelLayer] = [.color(PlazaColor(srgbRed: 0.02, green: 0.04, blue: 0.04, alpha: 0.66), frame: CGRect(origin: .zero, size: viewport))]
        var seatItems: [PlazaAccessibilityItem] = []

        // The table.
        let pad = ceil(5 * u)
        let tableFrame = layout.felt.insetBy(dx: -pad, dy: -pad)
        if let image = picture("table \(tableFrame.size) \(scale)", size: tableFrame.size, scale: scale, graphics: graphics, { canvas in
            Self.drawTable(on: canvas, felt: CGRect(x: pad, y: pad, width: layout.felt.width, height: layout.felt.height), size: tableFrame.size, u: u, scale: scale)
        }) { layers.append(.image(image, frame: tableFrame)) }

        // Cards: a card's image is its rotated bounding box on whole device pixels about its snapped centre.
        func cardLayer(_ key: String, centre: CGPoint, size: CGSize, rotation: CGFloat, _ draw: @MainActor (any PlazaCanvas) -> Void) {
            let c = CGPoint(x: snap(centre.x, scale), y: snap(centre.y, scale))
            let corners = PlazaBerryTableLayout.corners(centre: .zero, size: size, rotation: rotation)
            let reach = max(corners.map { abs($0.x) }.max() ?? 0, corners.map { abs($0.y) }.max() ?? 0) + ceil(0.15 * size.width) + 3
            let half = (reach * scale).rounded(.up) / scale
            let frame = CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half)
            if let image = picture("\(key) \(size) \(rotation) \(half) \(scale)", size: frame.size, scale: scale, graphics: graphics, { canvas in
                canvas.translate(x: half, y: half)
                draw(canvas)
            }) { layers.append(.image(image, frame: frame)) }
        }
        let cardSize = layout.card, deckSize = layout.deckCard
        func face(_ card: PlazaBerry.Card, rotation: CGFloat, widthScale: CGFloat = 1, rim: Bool = false) -> @MainActor (_ canvas: any PlazaCanvas) -> Void {
            { canvas in
                canvas.rotate(by: -rotation)
                canvas.scale(x: widthScale, y: 1)
                Self.drawFace(card, size: cardSize, u: u * f, rim: rim, items: items, scale: scale, on: canvas)
            }
        }
        for (i, seat) in layout.seats.enumerated() {
            let s = board.seats[i]
            cardLayer("deck \(s.deckLeft)", centre: seat.deck, size: deckSize, rotation: seat.rotation) { canvas in
                let line = text.line("\(s.deckLeft)", font: small)
                Self.drawBack(size: deckSize, u: u * f, scale: scale, rotation: seat.rotation, label: line, on: canvas)
            }
        }
        let ringing = ringT != nil
        for (i, seat) in layout.seats.enumerated() where !ringing {
            let s = board.seats[i]
            for k in stride(from: min(max(s.under, 0), 2), to: 0, by: -1) {
                let askew = (k == 2 ? CGFloat(i % 3 - 1) * 7 : (i % 2 == 1 ? 4 : -5)) * .pi / 180
                cardLayer("under \(k)", centre: seat.pile, size: cardSize, rotation: seat.rotation + askew) { canvas in
                    canvas.rotate(by: -(seat.rotation + askew))
                    Self.drawUnder(size: cardSize, u: u * f, scale: scale, on: canvas)
                }
            }
            guard let top = s.top else { continue }
            let tilt = CGFloat(i % 3 - 1) * 2 * .pi / 180
            if let flipT, flipStart?.seat == i {
                let e = 1 - (1 - flipT) * (1 - flipT)
                let c = CGPoint(x: seat.deck.x + (seat.pile.x - seat.deck.x) * e, y: seat.deck.y + (seat.pile.y - seat.deck.y) * e)
                let w = (0.2 + 0.8 * e * 10).rounded() / 10   // the unfold, in tenths, so a beat draws one picture
                cardLayer("flip \(top) \(itemsKey) \(w)", centre: c, size: cardSize, rotation: seat.rotation + tilt * e, face(top, rotation: seat.rotation + tilt * e, widthScale: w))
            } else {
                cardLayer("face \(top) \(itemsKey)", centre: seat.pile, size: cardSize, rotation: seat.rotation + tilt, face(top, rotation: seat.rotation + tilt))
            }
        }
        if let ring = board.ring, let t = ringT {
            let target = layout.seats.indices.contains(ring.seat) ? layout.seats[ring.seat].pile : nil
            for (i, seat) in layout.seats.enumerated() where ring.swept.indices.contains(i) {
                guard let card = ring.swept[i] else { continue }
                var c = seat.pile
                if t > Self.ringRim, let target {
                    let p = min(1, (t - Self.ringRim) / Self.ringSweep), e = p * p * (3 - 2 * p)
                    c = CGPoint(x: seat.pile.x + (target.x - seat.pile.x) * e, y: seat.pile.y + (target.y - seat.pile.y) * e)
                }
                let rim = t <= Self.ringRim && ring.five.contains(i)
                cardLayer("swept \(card) \(rim) \(itemsKey)", centre: c, size: cardSize, rotation: seat.rotation, face(card, rotation: seat.rotation, rim: rim))
            }
        }

        // The centre plate: its own picture (head, rule, the event line), then the bell on it.
        let plateFrame = layout.center
        let rule = l.plazaBerryRule
        let centreKey: String = {
            switch board.center {
            case .countdown(let n): "count \(n)"
            case .playing(let e): "play \(e ?? "")"
            case .result(let lines): "result \(lines)"
            }
        }()
        var plateItems: [PlazaAccessibilityItem] = []
        let metricsSmall = text.metrics(small), metricsBody = text.metrics(body)
        let lineH = (metricsSmall.ascender - metricsSmall.descender).rounded()
        let platePad = max(4, (0.9 * u).rounded())
        let inner = plateFrame.width - 2 * platePad
        let headFont = text.line(l.plazaBerryHead, font: body).width <= inner ? body : small
        let headMetrics = headFont == body ? metricsBody : metricsSmall
        let headH = (headMetrics.ascender - headMetrics.descender).rounded()
        let bellRect = layout.bell.offsetBy(dx: -plateFrame.minX, dy: -plateFrame.minY)
        let isResult: Bool = { if case .result = board.center { return true } else { return false } }()
        var textTop = isResult ? platePad + headH + 3 : bellRect.maxY + 2
        var room = plateFrame.height - platePad - textTop
        // What goes under the head (and the bell): the rule, then the event, countdown digit or the result's lines.
        // Every plate text breaks at spaces only (`wordLines`); the engines' own wrapping splits "5개면".
        typealias Row = (line: PlazaTextLine, piece: String, text: String, color: PlazaColor, magnify: CGFloat, kind: PlateRow.Kind)
        func wrapped(_ s: String, _ color: PlazaColor, _ kind: PlateRow.Kind) -> [Row] {
            Self.wordLines(s, width: inner) { text.line($0, font: small).width }.map { (text.line($0, font: small), $0, s, color, 1, kind) }
        }
        var ruleLines: [Row] = isResult ? [] : wrapped(rule, PlazaColor(hex: 0xDFE9EE), .rule)
        var tail: [Row] = []
        switch board.center {
        case .countdown(let n):
            let digit = "\(n)"
            // The digit gets its own row, as tall as its glyphs (the body font's line): 3 times as big when the rule, the digit and the note
            // all fit, else 2. The note ("the cards turn by themselves") is the one line a first-time player needs now and the rule shows
            // again in every later state, so a small plate gives up the rule, never the note or the digit's 2x; only a plate too small for
            // even that draws the digit plain.
            let note = wrapped(l.plazaBerryCountdownNote, .white, .note)
            let bodyH = (metricsBody.ascender - metricsBody.descender).rounded()
            func fit(rule: Int) -> CGFloat? {
                let others = lineH * CGFloat(rule + note.count)
                return [CGFloat(3), 2].first { others + bodyH * $0 <= room }
            }
            var magnify = fit(rule: ruleLines.count)
            if magnify == nil { ruleLines = []; magnify = fit(rule: 0) }
            if magnify == nil { textTop -= 1; room += 1; magnify = fit(rule: 0) }   // the smallest plate: one point off the gap under the bell
            tail = [(text.line(digit, font: body), digit, digit, Self.gold, magnify ?? 1, .digit)] + note
        case .playing(let event):
            if let event { tail = wrapped(event, Self.gold, .event) }
        case .result(let lines):
            tail = lines.enumerated().flatMap { i, s in
                wrapped(s, i == 0 ? Self.gold : .white, i == 0 ? .result : i == lines.count - 1 ? .close : .rank)
            }
        }
        func rowHeight(_ r: Row) -> CGFloat { r.kind == .digit ? (metricsBody.ascender - metricsBody.descender).rounded() * r.magnify : lineH }
        func rowsHeight() -> CGFloat { ruleLines.map(rowHeight).reduce(0, +) + tail.map(rowHeight).reduce(0, +) }
        while rowsHeight() > room {   // too little room: the event's later lines go first, then the rule's, then the last of what is left
            if let rank = tail.lastIndex(where: { $0.kind == .rank }) { tail.remove(at: rank) }   // a result sheds its ranks from the bottom, never the close hint
            else if tail.count > 1 { tail.removeLast() }
            else if !ruleLines.isEmpty { ruleLines.removeLast() }
            else if !tail.isEmpty { tail.removeLast() }
            else { break }
        }
        let rows = ruleLines + tail
        let plateKey = "plate \(plateFrame.size) \(scale) \(centreKey) \(headFont == body)"
        var rowFrames: [CGRect] = []
        var ry = textTop
        for r in rows {
            let h = rowHeight(r)
            rowFrames.append(CGRect(x: platePad + (inner - r.line.width * r.magnify) / 2, y: ry, width: r.line.width * r.magnify, height: h))
            ry += h
        }
        if let image = picture(plateKey, size: plateFrame.size, scale: scale, graphics: graphics, { canvas in
            canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -0.6 * u * scale), blur: 1.6 * u * scale, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)))
            canvas.setFillColor(PlazaColor(srgbRed: 41 / 255, green: 88 / 255, blue: 104 / 255, alpha: 0.94))
            let r = CGRect(origin: .zero, size: plateFrame.size).insetBy(dx: 2 * u * 0.3, dy: 2 * u * 0.3)
            canvas.fillRoundedRect(r, radius: 1.2 * u)
            canvas.setShadow(nil)
            let head = text.line(l.plazaBerryHead, font: headFont)
            let hp = CGPoint(x: platePad + (inner - head.width) / 2, y: plateFrame.height - platePad - headMetrics.ascender)
            canvas.setFillColor(PlazaColor(hex: 0xF8F8F0))
            canvas.draw(head, at: hp)
            for (k, row) in rows.enumerated() {
                let fr = rowFrames[k]
                canvas.saveState()
                canvas.translate(x: fr.minX, y: plateFrame.height - fr.minY - fr.height)
                canvas.scale(x: row.magnify, y: row.magnify)
                if row.magnify > 1 { canvas.setShouldAntialias(false); canvas.setShouldSmoothFonts(false) }
                canvas.setFillColor(row.color)
                canvas.draw(row.line, at: CGPoint(x: 0, y: -(row.kind == .digit ? metricsBody.descender : metricsSmall.descender)))
                canvas.restoreState()
            }
        }) { layers.append(.image(image, frame: plateFrame)) }
        let headFrame = CGRect(x: plateFrame.minX + platePad, y: plateFrame.minY + platePad, width: inner, height: headH)
        plateItems.append(PlazaAccessibilityItem(frame: headFrame, role: .staticText, label: l.plazaBerryHead))
        plate = (plateFrame, [PlateRow(kind: .head, text: l.plazaBerryHead, frame: headFrame)]
                 + (isResult ? [] : [PlateRow(kind: .bell, text: "", frame: layout.bell)])
                 + rows.enumerated().map { PlateRow(kind: $1.kind, text: $1.piece, frame: rowFrames[$0].offsetBy(dx: plateFrame.minX, dy: plateFrame.minY), magnify: $1.magnify) })
        for (k, row) in rows.enumerated() {
            plateItems.append(PlazaAccessibilityItem(frame: rowFrames[k].offsetBy(dx: plateFrame.minX, dy: plateFrame.minY), role: .staticText, label: row.text))
        }

        // The bell: the picture or the word "종", rocking during a ring, dimmed with ✕ after a wrong bell.
        var bellItem: PlazaAccessibilityItem?
        if !isResult {
            let bellImage = items[PlazaBerry.bellItem]
            let rock: CGFloat = ringT.map { $0 < Self.ringTotal ? CGFloat(sin($0 * 2 * .pi / 0.5)) * 16 * .pi / 180 : 0 } ?? 0
            let rockStep = (rock * 20).rounded() / 20
            let bell = layout.bell
            let b = bell.size
            if let image = picture("bell \(identity(bellImage)) \(rockStep) \(board.wrong) \(b) \(scale)", size: bell.size, scale: scale, graphics: graphics, { canvas in
                canvas.translate(x: b.width / 2, y: b.height / 2)
                canvas.rotate(by: -rockStep)
                canvas.translate(x: -b.width / 2, y: -b.height / 2)
                if board.wrong { canvas.setAlpha(0.4) }
                if let bellImage {
                    self.drawFitted(bellImage, in: CGRect(origin: .zero, size: b), on: canvas, scale: scale)
                } else {
                    let word = text.line(l.plazaBerryBellFallback, font: body)
                    canvas.setFillColor(Self.gold)
                    canvas.draw(word, at: CGPoint(x: (b.width - word.width) / 2, y: (b.height - metricsBody.ascender - metricsBody.descender) / 2))
                }
                if board.wrong {
                    canvas.setAlpha(1)
                    let mark = text.line(l.plazaBerryWrongMark, font: body)
                    canvas.saveState()
                    canvas.translate(x: b.width / 2, y: b.height / 2)
                    canvas.scale(x: 2, y: 2)
                    canvas.setShouldAntialias(false)
                    self.drawText(mark, at: CGPoint(x: -mark.width / 2, y: -(metricsBody.ascender + metricsBody.descender) / 2), color: PlazaColor(hex: 0xFF6B5A), outline: true, on: canvas)
                    canvas.restoreState()
                }
            }) { layers.append(.image(image, frame: bell)) }
            bellItem = PlazaAccessibilityItem(frame: bell, role: .button, label: l.plazaBerryBellFallback, action: PlazaPanelHit(action: "bell", index: nil))
            if board.wrong {
                let rest = text.line(l.plazaBerryWrongRest, font: small)
                let w = rest.width + 8, h = lineH + 2
                let fr = CGRect(x: snap(bell.midX - w / 2, scale), y: snap(bell.maxY - h * 0.8, scale), width: ceil(w * scale) / scale, height: ceil(h * scale) / scale)
                if let image = picture("rest \(fr.size) \(scale)", size: fr.size, scale: scale, graphics: graphics, { canvas in
                    canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7))
                    canvas.fillRoundedRect(CGRect(origin: .zero, size: fr.size), radius: 4)
                    canvas.setFillColor(PlazaColor(hex: 0xFF6B5A))
                    canvas.draw(rest, at: CGPoint(x: 4, y: 1 - metricsSmall.descender))
                }) { layers.append(.image(image, frame: fr)) }
            }
        }

        // The seats: sprite, name, score; the ringer hops and shows 🔔.
        placedNames = []
        spritesLoaded = 0
        for (i, seat) in layout.seats.enumerated() {
            let s = board.seats[i]
            let box = seat.box
            let ringer = board.ring.map { $0.seat == i } ?? false
            let hopT = ringer ? ringT.map { $0 / Self.ringHop } : nil
            let hop: CGFloat = hopT.map { $0 < 1 ? snap(1.2 * u * ($0 < 0.4 ? $0 / 0.4 : (1 - $0) / 0.6), scale) : 0 } ?? 0
            let gold = ringer && ringT != nil && (ringT ?? 0) < Self.ringTotal
            let room = ceil(1.3 * u * scale) / scale
            let name = fitName(s.name, width: box.width, text: text, font: small)
            let sprite = pictures.sprite(s.mon)
            if sprite != nil { spritesLoaded += 1 }
            let dot = min(max((box.width / 6.5).rounded(), 3), 8)
            let dotsRow = dot + 2
            let nameRect = CGRect(x: box.minX + (box.width - min(name.line.width, box.width)) / 2, y: box.maxY - dotsRow - lineH,
                                  width: min(name.line.width, box.width), height: lineH)
            placedNames.append((name.text, nameRect))
            let frame = CGRect(x: box.minX, y: box.minY - room, width: box.width, height: box.height + room)
            let key = "seat \(s.name) \(s.nameColor) \(s.score) \(s.isPlaying) \(identity(sprite)) \(box.size) \(hop) \(gold) \(scale)"
            if let image = picture(key, size: frame.size, scale: scale, graphics: graphics, { canvas in
                if !s.isPlaying { canvas.setAlpha(0.45) }
                let side = max(0, min(box.width, box.height - dotsRow - 2))
                let spriteBox = CGRect(x: (box.width - side) / 2, y: dotsRow + 2 + hop, width: side, height: side)
                if let sprite {
                    canvas.saveState()
                    if gold { canvas.setShadow(PlazaShadow(offset: .zero, blur: 0.8 * u * scale, color: Self.gold)) }
                    self.drawFitted(sprite, in: spriteBox, on: canvas, scale: scale)
                    canvas.restoreState()
                } else {
                    canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2))
                    canvas.fillEllipse(in: spriteBox.insetBy(dx: side * 0.15, dy: side * 0.15))
                }
                self.drawText(name.line, at: CGPoint(x: (box.width - name.line.width) / 2, y: dotsRow - metricsSmall.descender), color: gold ? Self.gold : s.nameColor, outline: true, on: canvas)
                let span = 5 * dot + 4 * dot * 0.4
                var x = (box.width - span) / 2
                for k in 0..<5 {
                    let r = CGRect(x: x, y: 1, width: dot, height: dot)
                    if k < s.score {
                        canvas.setFillColor(Self.gold)
                        canvas.fillEllipse(in: r)
                    } else {
                        canvas.setStrokeColor(Self.gold)
                        canvas.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5), lineWidth: 1)
                    }
                    x += dot * 1.4
                }
            }) { layers.append(.image(image, frame: frame)) }
            if gold {
                let size = max(14, (2.4 * u).rounded())
                let mark = text.line(l.plazaBerryBellMark, font: .emoji(size: size))
                let fr = CGRect(x: snap(box.minX + box.width * 0.62, scale), y: snap(box.minY - 0.1 * box.height - hop, scale),
                                width: ceil((mark.width + 2) * scale) / scale, height: ceil((mark.ascent + mark.descent + 2) * scale) / scale)
                if let image = picture("mark \(fr.size) \(scale)", size: fr.size, scale: scale, graphics: graphics, { canvas in
                    canvas.setFillColor(.white)
                    canvas.draw(mark, at: CGPoint(x: 1, y: 1 + mark.descent))
                }) { layers.append(.image(image, frame: fr)) }
            }
            seatItems.append(PlazaAccessibilityItem(frame: box, role: .staticText, label: l.plazaBerrySeatLabel(name: s.name, score: s.score), key: s.id))
        }
        placedFrames = layout.seats.map(\.box)
        var accessibility = seatItems + plateItems
        if let bellItem { accessibility.append(bellItem) }
        return PlazaPanelDrawing(layers: layers, accessibility: accessibility)
    }

    /// How many seats showed their sprite in the last render, and the seat boxes (tests).
    private(set) var spritesLoaded = 0
    private(set) var placedFrames: [CGRect] = []

    // MARK: shapes

    /// The felt and its wood rim, flat concentric ellipses with a shadow (the canvas has no gradients). `felt` is the felt's box in the image.
    private static func drawTable(on canvas: any PlazaCanvas, felt: CGRect, size: CGSize, u: CGFloat, scale: CGFloat) {
        let rim = felt.insetBy(dx: -1.4 * u, dy: -1.4 * u)
        canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -1.5 * u * scale), blur: 3 * u * scale, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)))
        canvas.setFillColor(PlazaColor(hex: 0x4F331D))
        canvas.fillEllipse(in: canvasRect(rim, size))
        canvas.setShadow(nil)
        canvas.setFillColor(PlazaColor(hex: 0x7A5232))
        canvas.fillEllipse(in: canvasRect(felt.insetBy(dx: -1.1 * u, dy: -1.1 * u), size))
        for (k, hex) in [(0.0, 0x1B4A31), (0.22, 0x23603F), (0.55, 0x2F7A55)] as [(CGFloat, UInt32)] {
            canvas.setFillColor(PlazaColor(hex: hex))
            canvas.fillEllipse(in: canvasRect(felt.insetBy(dx: felt.width * k / 2, dy: felt.height * k / 2), size))
        }
    }

    private static func canvasRect(_ r: CGRect, _ size: CGSize) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

    /// A face-up card centred on the origin, unrotated: a white border, the cream face and the berries in dice pips.
    private static func drawFace(_ card: PlazaBerry.Card, size: CGSize, u: CGFloat, rim: Bool, items: [String: PlazaImage], scale: CGFloat, on canvas: any PlazaCanvas) {
        let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let border = max(1, 0.25 * u), radius = 0.8 * u
        canvas.saveState()
        if rim {
            canvas.setShadow(PlazaShadow(offset: .zero, blur: 0.5 * u * scale, color: gold))
            canvas.setFillColor(gold)
            canvas.fillRoundedRect(r.insetBy(dx: -0.35 * u, dy: -0.35 * u), radius: radius + 0.35 * u)
            canvas.setShadow(nil)
        }
        canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -0.25 * u * scale), blur: 0.6 * u * scale, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)))
        canvas.setFillColor(.white)
        canvas.fillRoundedRect(r, radius: radius)
        canvas.setShadow(nil)
        canvas.setFillColor(PlazaColor(hex: 0xFBF8EF))
        canvas.fillRoundedRect(r.insetBy(dx: border, dy: border), radius: max(0, radius - border))
        canvas.setStrokeColor(PlazaColor(hex: 0xD9D2BF))
        canvas.strokeRoundedRect(r.insetBy(dx: border + 0.5, dy: border + 0.5), radius: max(0, radius - border), lineWidth: 1)
        canvas.restoreState()
        let side = size.width / 2
        for p in PlazaBerry.pips[card.count] ?? [] {
            let c = CGPoint(x: r.minX + p.x * r.width, y: r.maxY - p.y * r.height)
            let box = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            if let image = items[card.berry.itemName] {
                let k = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                canvas.saveState()
                if k * scale >= 1 { canvas.setInterpolationNone() }
                canvas.draw(image, in: CGRect(x: c.x - CGFloat(image.width) * k / 2, y: c.y - CGFloat(image.height) * k / 2,
                                              width: CGFloat(image.width) * k, height: CGFloat(image.height) * k))
                canvas.restoreState()
            } else {
                canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
                canvas.fillEllipse(in: box.insetBy(dx: side * 0.2, dy: side * 0.2).offsetBy(dx: 0, dy: -0.5))
                canvas.setFillColor(card.berry.color)
                canvas.fillEllipse(in: box.insetBy(dx: side * 0.2, dy: side * 0.2))
            }
        }
    }

    /// A card lying under the top one: cream, blank.
    private static func drawUnder(size: CGSize, u: CGFloat, scale: CGFloat, on canvas: any PlazaCanvas) {
        let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -0.2 * u * scale), blur: 0.4 * u * scale, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4)))
        canvas.setFillColor(.white)
        canvas.fillRoundedRect(r, radius: 0.8 * u)
        canvas.setShadow(nil)
        canvas.setFillColor(PlazaColor(hex: 0xF1ECDD))
        canvas.fillRoundedRect(r.insetBy(dx: max(1, 0.25 * u), dy: max(1, 0.25 * u)), radius: max(0, 0.55 * u))
    }

    /// Two face-down cards: red stripes in a white border, and the count upright on top.
    private static func drawBack(size: CGSize, u: CGFloat, scale: CGFloat, rotation: CGFloat, label: PlazaTextLine, on canvas: any PlazaCanvas) {
        canvas.rotate(by: -rotation)
        let border = max(1, 0.35 * u), radius = 0.8 * u
        for offset in [CGFloat(0.25 * u), 0] {
            let r = CGRect(x: -size.width / 2 + offset, y: -size.height / 2 - offset, width: size.width, height: size.height)
            canvas.saveState()
            canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -0.25 * u * scale), blur: 0.6 * u * scale, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)))
            canvas.setFillColor(.white)
            canvas.fillRoundedRect(r, radius: radius)
            canvas.restoreState()
            canvas.saveState()
            let inner = r.insetBy(dx: border, dy: border)
            canvas.clip(toRoundedRect: inner, radius: max(0, radius - border))
            canvas.setFillColor(PlazaColor(hex: 0xB8473D))
            canvas.fill(inner)
            canvas.translate(x: r.midX, y: r.midY)
            canvas.rotate(by: .pi / 4)
            canvas.setFillColor(PlazaColor(hex: 0x9E3A31))
            let band = max(1.5, 0.5 * u)
            let reach = (size.width + size.height)
            var x = -reach
            while x < reach {
                canvas.fill(CGRect(x: x, y: -reach, width: band, height: 2 * reach))
                x += 2 * band
            }
            canvas.restoreState()
        }
        canvas.rotate(by: rotation)
        canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7))
        canvas.draw(label, at: CGPoint(x: -label.width / 2 + 1, y: -label.ascent / 2 + 1))
        canvas.setFillColor(.white)
        canvas.draw(label, at: CGPoint(x: -label.width / 2, y: -label.ascent / 2))
    }
}
