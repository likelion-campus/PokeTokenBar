#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The companion header on the Home page (stage 7 Task 9; the Mac's `CompanionHeader`, first in Home's scroll area): three
/// drawn rows in one section — the header block (`CompanionHeaderPart`: sprite box, name, badges, growth bar, captions,
/// status), the evolution line (`EvoLinePart`) and the graduation line (`CompanionNotePart`). Every text and number comes
/// from `CompanionHeaderModel`; this file places the rows, feeds the sprites to Task 8's animator, loads what the Mac's
/// `.task`s load, and plays the celebrations.
///
/// Data flow: the section reads the store inside its own `withObservationTracking` (the header does not ride on the Home
/// model); a change re-applies once per main-queue turn. The parts and their views live as long as the page: a new model is
/// `update(_:)` on the same part, so a level-up or a hatch while the popover is open changes the picture in place (no row is
/// made again, the sprite keeps its loaded frames until the new subject's arrive, as the Mac's `SpriteSubject` does).
///
/// Loads (C13, C4): the subject's details (`loadPokemonDetails`, the type badges), the form names (`loadActiveFormNames`)
/// and the type names (`PokemonNameDisplayStore`), when the subject, form or types change and once per page build (the
/// Mac's `.task(id:)` on appear).
///
/// Timers: the sprites have Task 8's clock (one one-shot timer for a GIF's next frame or the bob). Celebrations have one
/// more one-shot `PopoverAnimationClock`: armed for the effect's next frame (1/60 s while something moves, the next timed
/// step otherwise) or the imminent egg's next wiggle pose (0.35 s); nil when nothing plays; not armed while the header is
/// not on screen (another page, scrolled out: a later paint starts it again), while the displays sleep, when Windows'
/// "show animations" is off, and gone on `destroy()`.
@MainActor final class WinCompanionSection {
    struct Stats: Equatable {
        var observes = 0, applies = 0, headerUpdates = 0, lineUpdates = 0, effectFrames = 0, effectStarts = 0
        var detailLoads = 0, formLoads = 0, typeNameLoads = 0
    }

    /// The selftest's sprite source (no network in the selftest); nil = the app's sprite store.
    static var spriteFetcherOverride: (any PlazaSpriteFetching)?

    let companion: CompanionStore
    let section: WinSectionCard
    private weak var page: WinHomePage?
    /// A fixed input instead of the store's (the selftest's sample states); nothing is observed or loaded then.
    var inputOverride: (() -> CompanionHeaderInput)?
    /// Who consumes the one-shot effects (the store; the selftest's fixtures record instead).
    var consumer: (any CompanionFeedbackConsuming)?
    var names = PokemonNameDisplayStore.shared
    var nameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var animationsEnabled: @MainActor () -> Bool = { WinSpriteAnimator.systemAnimationsEnabled() }
    /// The form names come from PokéAPI through the shared name client (the selftest turns this off: no network there).
    var loadsFormNames = true
    var now: () -> Date = { Date() }

    private(set) var header: (view: WinDrawnView, part: CompanionHeaderPart, row: WinRow)?
    private(set) var line: (view: WinDrawnView, part: EvoLinePart, row: WinRow)?
    private(set) var note: (view: WinDrawnView, part: CompanionNotePart, row: WinRow)?
    let driver = CompanionCelebrationDriver()
    let effectClock = PopoverAnimationClock()
    private var raster: WinGlyphRaster?
    private(set) var last: CompanionHeaderModel?
    private(set) var stats = Stats()
    private(set) var isDestroyed = false
    private var epoch = 0
    private var failedTypeNames = Set<PokemonNameResource>()
    private var tasks: [Task<Void, Never>] = []
    private var loadedDetails: Int?
    private var loadedForm: PokemonForm??
    private var loadedTypes: [String]?

    init(companion: CompanionStore, section: WinSectionCard, page: WinHomePage) {
        self.companion = companion
        self.section = section
        self.page = page
        consumer = companion
        effectClock.onTick = { [weak self] in self?.tickEffects() }
    }

    static func fetcher() -> any PlazaSpriteFetching { spriteFetcherOverride ?? PlatformPlaza.spriteFetcher() }

    /// Starts observing (or shows the fixed input).
    func start() {
        guard !isDestroyed else { return }
        observe()
    }

    /// Shows `input` again now (the selftest, after changing its fixture).
    func reload() { apply(currentInput()) }

    private func currentInput() -> CompanionHeaderInput {
        inputOverride?() ?? CompanionHeaderInput(store: companion, names: names, failedTypeNames: failedTypeNames)
    }

    private func observe() {
        guard !isDestroyed else { return }
        stats.observes += 1
        if inputOverride != nil {
            apply(currentInput())
            return
        }
        let mine = epoch
        let input = withObservationTracking { currentInput() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine, !self.isDestroyed else { return }
                self.observe()
            }
        }
        apply(input)
    }

    func apply(_ input: CompanionHeaderInput) {
        guard !isDestroyed else { return }
        stats.applies += 1
        let model = CompanionHeaderModel.make(input: input)
        if model != last { show(model) }
        last = model
        if inputOverride == nil { load(input) }
        let animates = animationsEnabled()
        if let consumer, driver.poll(input, consumer: consumer, now: now(), animates: animates) { stats.effectStarts += 1 }
        if !animates { driver.stopAll() }
        tickEffects()
    }

    // MARK: rows

    private var widthDIP: CGFloat {
        guard let page, let ctx = page.ctx else { return PopoverWindowMetrics.scrollContentWidth }
        return CGFloat(page.innerWidth) / ctx.scale
    }

    private static func plaza(_ c: COLORREF) -> PlazaColor {
        PlazaColor(srgbRed: Double(c & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double((c >> 16) & 0xFF) / 255)
    }

    private func show(_ m: CompanionHeaderModel) {
        guard let ctx = page?.ctx else { return }
        let width = widthDIP
        if header == nil {
            raster = WinGlyphRaster(fonts: ctx.fonts)
            var made: (WinDrawnView, CompanionHeaderPart)?
            let row = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
                guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
                view.sprites = WinSpriteAnimator(fetcher: Self.fetcher(), animationsEnabled: self.animationsEnabled)
                let part = CompanionHeaderPart(m, textScale: CGFloat(ctx.textScale))
                view.host(part, width: width)
                made = (view, part)
                return view.control
            }
            if let made {
                let (view, part) = made
                header = (view, part, row)
                // A paint after the header was off screen (scrolled back, shown again) starts the effects' clock again.
                let sprites = view.paintOverlay
                view.paintOverlay = { [weak self] dc in
                    sprites?(dc)
                    self?.headerPainted()
                }
            }
            var lineMade: (WinDrawnView, EvoLinePart)?
            let lineRow = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
                guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
                view.sprites = WinSpriteAnimator(fetcher: Self.fetcher(), animationsEnabled: self.animationsEnabled)
                let part = EvoLinePart(m.evoLine ?? Self.emptyLine, background: Self.plaza(ctx.colors.palette.window),
                                       accent: Self.plaza(ctx.colors.palette.accent), glyphs: raster)
                view.host(part, width: width)
                view.onHit = { [weak part] hit in _ = part?.press(hit) }
                lineMade = (view, part)
                return view.control
            }
            if let lineMade { line = (lineMade.0, lineMade.1, lineRow) }
            lineRow.isVisible = m.evoLine != nil
            var noteMade: (WinDrawnView, CompanionNotePart)?
            let noteRow = section.addStyledRow(label: nil, style: .full) { pane, ctx in
                guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
                let part = CompanionNotePart(m.graduated ?? "", color: .systemOrange, textScale: CGFloat(ctx.textScale))
                view.host(part, width: width)
                noteMade = (view, part)
                return view.control
            }
            if let noteMade { note = (noteMade.0, noteMade.1, noteRow) }
            noteRow.isVisible = m.graduated != nil
            stats.headerUpdates += 1
            return
        }
        if header?.part.model != m {
            header?.part.update(m)
            stats.headerUpdates += 1
        }
        if let evo = m.evoLine, line?.part.model != evo {
            line?.part.update(evo)
            stats.lineUpdates += 1
        }
        if line?.row.isVisible != (m.evoLine != nil) { line?.row.isVisible = m.evoLine != nil }
        if let g = m.graduated { note?.part.update(g) }
        if note?.row.isVisible != (m.graduated != nil) { note?.row.isVisible = m.graduated != nil }
    }

    static let emptyLine = EvoLineModel(nodes: [], shiny: false, form: nil, mysteryLabel: "", previousLabel: "", nextLabel: "")

    // MARK: loads (the Mac's .task(id:)s)

    private func load(_ input: CompanionHeaderInput) {
        if input.hasActive, let id = input.currentSpeciesID, loadedDetails != id {
            loadedDetails = id
            stats.detailLoads += 1
            let store = companion
            tasks.append(Task { @MainActor in await store.loadPokemonDetails(speciesID: id) })
        }
        if loadsFormNames, loadedForm == nil || loadedForm! != input.currentForm {
            loadedForm = .some(input.currentForm)
            stats.formLoads += 1
            let store = companion
            tasks.append(Task { @MainActor in await store.loadActiveFormNames() })
        }
        if let types = input.types, types != loadedTypes {
            loadedTypes = types
            loadTypeNames(types)
        }
    }

    /// `PokemonNameLabel`'s `.task`: each type's names through the display store; one that fails shows its identifier.
    func loadTypeNames(_ types: [String]) {
        let resources = types.map { PokemonNameResource(kind: .type, name: $0) }
        failedTypeNames.subtract(resources)
        stats.typeNameLoads += 1
        let store = names, provider = nameProvider
        tasks.append(Task { @MainActor [weak self] in
            for resource in Set(resources) {
                let loaded = await store.load(resource, provider: provider)
                guard !Task.isCancelled, let self, !self.isDestroyed else { return }
                if !loaded {
                    self.failedTypeNames.insert(resource)
                    self.reload()
                }
            }
        })
    }

    // MARK: celebrations

    private var headerIsShown: Bool {
        guard let header else { return false }
        return WinSpriteAnimator.isShown(header.view.hwnd) && !Platform.current.events.displaysAreAsleep
    }

    private func headerPainted() {
        guard !isDestroyed, !effectClock.isArmed, driver.nextDue(after: now()) != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.tickEffects() }   // not inside the paint
    }

    /// Draws the effects' look now (only the sprite box is repainted) and arms the clock for the next change.
    func tickEffects() {
        guard !isDestroyed, let header, let ctx = page?.ctx else { effectClock.setDue(nil); return }
        let t = now()
        let e = driver.effects(at: t)
        if e != header.part.effects {
            header.part.setEffects(e)
            header.view.show(header.part.renderEffectFrame(scale: ctx.scale, graphics: PlatformPlaza.graphics))
            stats.effectFrames += 1
        }
        // never armed at or before now (a due in the past would fire at once, again and again)
        let next = driver.nextDue(after: t).map { max($0, t.addingTimeInterval(0.001)) }
        effectClock.setDue(headerIsShown && animationsEnabled() ? next : nil)
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        effectClock.setDue(nil)
        effectClock.onTick = nil
        driver.stopAll()
        for t in tasks { t.cancel() }
        tasks = []
        header = nil
        line = nil
        note = nil
        raster?.release()
        raster = nil
    }
}

/// An SF Symbol's Windows glyph (`PopoverGlyphTable`: Segoe Fluent Icons, else Segoe MDL2 Assets) drawn by GDI into a
/// picture for a drawn part: white grey-scale coverage on black becomes the alpha of the asked colour (no ClearType: the
/// picture is blended later over any background). Cached per symbol, size, weight, colour and scale while the page lives.
@MainActor final class WinGlyphRaster: PopoverGlyphRaster {
    let face: String
    let fluent: Bool
    private var cache: [String: PlazaImage] = [:]
    private(set) var made = 0

    init(fonts: WinFonts) {
        face = fonts.iconFace
        fluent = fonts.iconIsFluent
    }

    func image(symbol: String, pointSize: CGFloat, bold: Bool, color: PlazaColor, scale: CGFloat) -> PlazaImage? {
        let key = "\(symbol)|\(pointSize)|\(bold)|\(color.red),\(color.green),\(color.blue),\(color.alpha)|\(scale)"
        if let kept = cache[key] { return kept }
        guard let glyph = WinGlyphs.text(symbol: symbol, fluent: fluent) else { return nil }
        let px = max(1, Int32((pointSize * scale).rounded()))
        let font = WinStr.w(face).withUnsafeBufferPointer {
            CreateFontW(-px, 0, 0, 0, bold ? 700 : 400, 0, 0, 0, 1 /* DEFAULT_CHARSET */, 0, 0, 4 /* ANTIALIASED_QUALITY */, 0, $0.baseAddress)
        }
        guard let font, let dc = CreateCompatibleDC(nil) else { return nil }
        defer { _ = DeleteDC(dc); _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        let oldFont = SelectObject(dc, UnsafeMutableRawPointer(font))
        defer { _ = SelectObject(dc, oldFont) }
        let chars = Array(glyph.utf16)
        var size = SIZE()
        _ = GetTextExtentPoint32W(dc, chars, Int32(chars.count), &size)
        let w = Int(max(1, size.cx)), h = Int(max(1, size.cy))
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(w)
        info.bmiHeader.biHeight = -Int32(h)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0
        var bits: UnsafeMutableRawPointer?
        guard let bitmap = CreateDIBSection(dc, &info, 0, &bits, nil, 0), let bits else { return nil }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        let oldBitmap = SelectObject(dc, UnsafeMutableRawPointer(bitmap))
        defer { _ = SelectObject(dc, oldBitmap) }
        memset(bits, 0, w * h * 4)
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        _ = SetTextColor(dc, 0x00FF_FFFF)
        _ = TextOutW(dc, 0, 0, chars, Int32(chars.count))
        _ = GdiFlush()
        var bitmapOut = PlazaBitmap(width: w, height: h)
        let src = bits.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) {
            let cover = Double(max(src[i * 4], src[i * 4 + 1], src[i * 4 + 2])) / 255 * color.alpha
            bitmapOut.bytes[i * 4] = UInt8((color.red * cover * 255).rounded())
            bitmapOut.bytes[i * 4 + 1] = UInt8((color.green * cover * 255).rounded())
            bitmapOut.bytes[i * 4 + 2] = UInt8((color.blue * cover * 255).rounded())
            bitmapOut.bytes[i * 4 + 3] = UInt8((cover * 255).rounded())
        }
        let image = PlazaImage(bitmap: bitmapOut)
        cache[key] = image
        made += 1
        return image
    }

    func release() { cache = [:] }
}
#endif
