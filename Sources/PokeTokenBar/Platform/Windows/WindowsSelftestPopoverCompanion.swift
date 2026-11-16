#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 9: the companion header's selftest group (`companion.*`). Each check prints one PASS/FAIL line with what it
// measured. Pages are the real Home page in a kit window, fed FIXTURE companions: sample states made here (public species
// numbers and names), and sprites from the FIXTURE folder `PTB_SELFTEST_SPRITES` (public PokeAPI files the workflow fetched:
// scripts/windows/fetch-fixture-sprites.ps1). The section's own loads ask no network here; a sample store of a species with
// forms (Shellos) asks PokéAPI once for its form's name when its line loads (`CompanionStore.loadCurrentLine` in a bundled app,
// as on the Mac), and the capture shows the name it got ("[East Sea]", or the identifier "[East]" offline). With `--dump-ui <dir>` every state goes to
// `<dir>/companion/` as a PNG and a control-tree JSON ("Sample-data capture, Windows CI runner").

extension WindowsSelftest {
    /// Before any popover opens in the selftest: sprites come from the fixture folder (no network in the selftest).
    @MainActor static func popoverCompanionPrepare() { WindowsSelftestPopoverCompanion.prepare() }

    @MainActor static func popoverCompanionChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverCompanion.run(r, app)
    }
}

/// Sprite files from one folder by the sprite store's cache names, and nothing else (no network): the fixture sprites, or an
/// empty folder for "offline".
struct WinFixtureSpriteSource: PlazaSpriteSource {
    let directory: URL
    /// Seconds each read waits first ("still loading").
    var delay: TimeInterval = 0

    func data(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm?, back: Bool) async -> Data? {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let key = SpriteStore.cacheKey(speciesID: speciesID, animated: animated, shiny: shiny, form: form, back: back)
        return try? Data(contentsOf: directory.appendingPathComponent("\(key).\(animated ? "gif" : "png")"))
    }

    func eggData() async -> Data? {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try? Data(contentsOf: directory.appendingPathComponent("egg.png"))
    }
}

@MainActor private final class SelftestConsumer: CompanionFeedbackConsuming {
    var count = 0
    func consumeCelebration() { count += 1 }
    func consumeCandyFeedback() { count += 1 }
    func consumeMintFeedback() { count += 1 }
}

/// The Home page in a kit window with its companion section set up before it starts (a fixed input or a real store, the
/// animation switch), over fixture Home data.
@MainActor final class CompanionHarness {
    let page: WinHomePage
    private(set) var window: KitWindow!
    let stores: HomeStores
    var section: WinCompanionSection? { page.companionSection }

    init?(stores: HomeStores, companion input: CompanionHeaderInput? = nil, animations: Bool = true, dpi: UINT? = nil, textScale: Double? = nil,
          names: PokemonNameDisplayStore? = nil, home: ((AppLanguage, Date) -> HomeInput)? = nil) {
        self.stores = stores
        let facts = PopoverPlatformFacts.current
        let made = WinHomePage(store: stores.store, companion: stores.companion, updater: nil, team: stores.team, feed: nil, state: stores.state,
                               facts: facts, openPlaza: {}, perform: { _ in })
        let language = stores.companion.language
        let homeInput = home ?? { lang, now in HomeFixtures.empty(lang, now: now) }
        made.modelOverride = { now in HomeModel.make(input: homeInput(language, now), facts: facts, now: now) }
        made.configureCompanion = { section in
            section.animationsEnabled = { animations }
            section.loadsFormNames = false   // PokéAPI: no network in the selftest
            if let names {
                section.names = names
                section.nameProvider = CompanionSampleNames()
            }
            if let input {
                section.inputOverride = { input }
                section.consumer = SelftestConsumer()
            }
        }
        page = made
        guard let w = KitWindow(heightDIP: 600, dpi: dpi, textScale: textScale, register: true, origin: POINT(x: 0, y: 0), build: { _, stack in
            made.attach(stack: stack)
        }) else { return nil }
        window = w
    }

    func destroy() {
        page.destroy()
        window.destroy()
        stores.remove()
    }
}

@MainActor enum WindowsSelftestPopoverCompanion {
    static let names = ["companion.capture", "companion.celebrate", "companion.consumedOnce", "companion.liveUpdate", "companion.colourEgg",
                        "companion.openClose3"]

    static var spriteDirectory: URL? {
        ProcessInfo.processInfo.environment["PTB_SELFTEST_SPRITES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private static let emptyDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-no-sprites-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func fixtureFetcher(delay: TimeInterval = 0, offline: Bool = false) -> any PlazaSpriteFetching {
        PlazaStoreSpriteFetcher(source: WinFixtureSpriteSource(directory: offline ? emptyDirectory : (spriteDirectory ?? emptyDirectory), delay: delay))
    }

    static func prepare() {
        WinCompanionSection.spriteFetcherOverride = fixtureFetcher()
        AppLog.write("selftest: companion sprites from \(spriteDirectory?.path ?? "nowhere (no PTB_SELFTEST_SPRITES): the 🥚 shows")")
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        prepare()
        let start = KitResources.now()
        await captureChecks(r)
        await celebrateCheck(r)
        await consumedOnceCheck(r)
        await liveUpdateCheck(r)
        await colourEggCheck(r)
        await evoLineScrollCheck(r)
        await barHoverCheck(r)
        await openCloseCheck(r, start: start)
        WinCompanionSection.spriteFetcherOverride = fixtureFetcher()
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("companion", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    // MARK: fixture inputs (sample states, the shapes CompanionHeaderInput(store:) captures)

    static func egg(_ language: AppLanguage, banked: Double, tier: Rarity? = nil, delayed: Bool = false) -> CompanionHeaderInput {
        var i = CompanionHeaderInput()
        i.language = language
        i.eggHatchThreshold = 50_000
        i.eggUsage = Int(banked * 50_000)
        i.eggProgress = banked
        i.eggTokensToHatch = 50_000 - i.eggUsage
        i.eggStarted = i.eggUsage > 0
        i.eggGuarantee = tier
        i.isHatchRetryDelayed = delayed
        i.displayName = "Token Egg"
        return i
    }

    static func mon(_ language: AppLanguage, id: Int, path: [Int], stage: Int, name: String, rarity: Rarity = .common, progress: Double,
                    shiny: Bool = false, back: Bool = false, form: PokemonForm? = nil, types: [String]? = ["grass", "poison"],
                    final: Bool = false, boost: Bool = false, state: CompanionStateKind = .working, evolvedTo: String? = nil,
                    nodes: [EvoLineItem]? = nil) -> CompanionHeaderInput {
        var i = CompanionHeaderInput()
        let l = L(language)
        i.language = language
        i.hasActive = true
        i.isEgg = false
        i.currentSpeciesID = id
        i.currentIsShiny = shiny
        i.facesBack = back
        i.currentForm = form
        i.displayName = name
        i.rarity = rarity
        i.types = types
        let typeNames: [String: [String: String]] = ["grass": ["ko": "풀", "en": "Grass", "ja": "くさ"], "poison": ["ko": "독", "en": "Poison", "ja": "どく"],
                                                     "fire": ["ko": "불꽃", "en": "Fire", "ja": "ほのお"], "water": ["ko": "물", "en": "Water", "ja": "みず"],
                                                     "normal": ["ko": "노말", "en": "Normal", "ja": "ノーマル"]]
        for t in types ?? [] { i.typeNames[PokemonNameResource(kind: .type, name: t)] = typeNames[t] }
        i.stageText = final ? l.finalForm : l.stage(stage + 1, 3)
        i.currentNature = .modest
        i.growthMultiplier = boost ? PokemonBalance.repeatGrowthMultiplier : nil
        i.threshold = 60_000
        i.usedAtStage = Int(progress * 60_000)
        i.progress = progress
        i.tokensToNext = 60_000 - i.usedAtStage
        i.isFinalStage = final
        i.displayState = state
        i.justEvolvedTo = evolvedTo
        i.lineNodes = nodes ?? path.enumerated().map { k, s in EvoLineItem(.species(s), k < stage ? .done : (k == stage ? .current : .future)) }
        return i
    }

    struct Variant {
        var name: String
        var language: AppLanguage = .en
        var sample: CompanionHeaderSample
        var dpi: UINT? = nil
        var textScale: Double? = nil
        var fetcher: (any PlazaSpriteFetching)? = nil
        /// Animation on for this capture (the wiggle); off elsewhere, so a capture is one fixed picture.
        var animations = false
        /// A celebration frame to draw (seconds after its start): the celebration, a candy amount.
        var effect: (CompanionStore.Celebration?, Int?, TimeInterval)? = nil
        /// The Mac's nine-node corpus instead of the store's line (synthetic: a Home line hides its branches behind one "?").
        var longLine = false
        var scrollForward = false
        /// The growth bar as a hover leaves it: grown, the readout shown.
        var barOpen = false
    }

    static let eeveeLine = [EvoLineItem(.species(133), .current)] + [134, 135, 136, 196, 197, 470, 471, 700].map { EvoLineItem(.species($0), .future) }

    static func variants() -> [Variant] {
        var out: [Variant] = []
        for lang in [AppLanguage.en, .ko] {
            let s = lang.rawValue
            out += [
                Variant(name: "egg-first-run-\(s)", language: lang, sample: .eggFirstRun),
                Variant(name: "egg-incubating-\(s)", language: lang, sample: .eggIncubating),
                Variant(name: "egg-imminent-guarantee-\(s)", language: lang, sample: .eggImminent, animations: true),
                Variant(name: "hatched-\(s)", language: lang, sample: .hatched),
                Variant(name: "mid-level-\(s)", language: lang, sample: .midLevel),
                Variant(name: "about-to-evolve-\(s)", language: lang, sample: .aboutToEvolve),
                Variant(name: "final-\(s)", language: lang, sample: .finalStage),
                Variant(name: "shiny-\(s)", language: lang, sample: .shiny),
                Variant(name: "form-\(s)", language: lang, sample: .form),
                Variant(name: "back-\(s)", language: lang, sample: .back),
                Variant(name: "graduated-\(s)", language: lang, sample: .graduated),
                Variant(name: "eevee-\(s)", language: lang, sample: .eevee),
                Variant(name: "offline-\(s)", language: lang, sample: .midLevel, fetcher: fixtureFetcher(offline: true)),
                Variant(name: "evolving-flash-\(s)", language: lang, sample: .midLevel, effect: (.evolve, nil, 0.12)),
                Variant(name: "shiny-hatch-burst-\(s)", language: lang, sample: .shiny, effect: (.hatch(shiny: true), nil, 1.0)),
                Variant(name: "eevee-long-line-\(s)", language: lang, sample: .eevee, longLine: true),
                Variant(name: "eevee-long-line-scrolled-\(s)", language: lang, sample: .eevee, longLine: true, scrollForward: true),
                Variant(name: "mid-level-bar-hover-\(s)", language: lang, sample: .midLevel, barOpen: true),
            ]
        }
        out += [
            Variant(name: "candy-xp-en", sample: .midLevel, effect: (nil, 12_000, 0.6)),
            Variant(name: "loading-en", sample: .midLevel, fetcher: fixtureFetcher(delay: 30)),
            Variant(name: "long-name-de", language: .de, sample: .longName),
            Variant(name: "mid-level-ja", language: .ja, sample: .midLevel),
            Variant(name: "mid-level-text150-en", sample: .midLevel, textScale: 1.5),
            Variant(name: "mid-level-150-en", sample: .midLevel, dpi: 144),
            Variant(name: "egg-imminent-text150-ko", language: .ko, sample: .eggImminent, textScale: 1.5),
        ]
        return out
    }

    /// The shown types' names, as PokéAPI would give them (a display store of its own, filled once).
    static let sampleNames = PokemonNameDisplayStore()
    private static var sampleNamesLoaded = false
    static func loadSampleNames() async {
        guard !sampleNamesLoaded else { return }
        sampleNamesLoaded = true
        await CompanionHeaderSamples.loadTypeNames(into: sampleNames)
    }

    private static func capture(_ hwnd: HWND) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    /// The texts a header must show (its model's lines).
    static func expectedTexts(_ m: CompanionHeaderModel) -> [String] {
        var out: [String] = []
        for line in m.lines {
            switch line {
            case .title(let s, _, let r): out.append(s); if let r { out.append(r.text) }
            case .types(let b): out += b.map(\.text)
            case .note(let s), .status(let s), .caption(let s, _): out.append(s)
            case .stage(let s, let b): out.append(s); if let b { out.append(b.text) }
            case .egg(let s, _, let g): out.append(s); if let g { out.append(g.text) }
            case .bar(_, let d): out.append(d)
            }
        }
        if let g = m.graduated { out.append(g) }
        return out
    }

    // MARK: companion.capture: every state, the tree checks, the texts

    private static func captureChecks(_ r: WindowsSelftest.Recorder) async {
        let dir = dumpDirectory()
        var lines: [String] = []
        var allOK = true
        await loadSampleNames()
        for v in variants() {
            WinCompanionSection.spriteFetcherOverride = v.fetcher ?? fixtureFetcher()
            let base = await HomeStores.make(language: v.language)
            let store = await CompanionHeaderSamples.store(v.sample, language: v.language, defaults: sharedDefaults,
                                                           directory: base.directory.appendingPathComponent("sample"))
            let stores = HomeStores(store: base.store, companion: store, team: base.team, state: base.state, directory: base.directory)
            var fixed: CompanionHeaderInput?
            if v.longLine {
                var i = CompanionHeaderInput(store: store, names: sampleNames)
                i.lineNodes = eeveeLine
                fixed = i
            }
            guard let h = CompanionHarness(stores: stores, companion: fixed, animations: v.animations, dpi: v.dpi, textScale: v.textScale, names: sampleNames),
                  let section = h.section, let header = section.header else {
                lines.append("\(v.name): no window or no header")
                allOK = false
                base.remove()
                continue
            }
            let w = h.window!
            w.fitToContent()
            w.show(activate: false)
            // the sprites load off the main thread: wait for the header's picture (or the offline / loading 🥚)
            let animator = header.view.sprites
            _ = await WindowsSelftest.waitUntil(timeout: 3) { v.fetcher != nil || animator?.playback.models.first?.current != nil }
            await wait(0.25)
            if let effect = v.effect {
                let (kind, candy, at) = effect
                var input = CompanionHeaderInput(store: store, names: sampleNames)
                if let kind { input.celebration = kind; input.celebrationSeq = 1 }
                if let candy { input.candyFeedbackAmount = candy; input.candyFeedbackSeq = 1 }
                let t0 = Date()
                let d = CompanionCelebrationDriver()
                d.poll(input, consumer: SelftestConsumer(), now: t0)
                header.part.setEffects(d.effects(at: t0.addingTimeInterval(at)))
                header.view.show(header.part.renderEffectFrame(scale: w.ctx.scale, graphics: PlatformPlaza.graphics))
            }
            if v.scrollForward, let line = section.line { line.part.press(PlazaPanelHit(action: EvoLinePart.forwardAction, index: nil)) }
            if v.barOpen {
                header.part.setBarLook(.open)
                header.view.show(header.part.renderBarFrame(scale: w.ctx.scale, graphics: PlatformPlaza.graphics))
            }
            _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
            await wait(0.15)
            let tree = KitTree.collect(w)
            let checks = tree.check(w)
            let shown = Set(tree.nodes.filter(\.visible).map(\.text))
            let model = section.last ?? CompanionHeaderModel.make(input: CompanionHeaderInput(store: store, names: sampleNames))
            let missing = expectedTexts(model).filter { !$0.isEmpty && !shown.contains($0) }
            let models = animator?.playback.models ?? []
            let picture = models.first.map { $0.current != nil ? ($0.isAnimating ? "GIF \($0.frames.count) frames" : "still") : "🥚" } ?? "none"
            let lineSlots = section.line?.view.spriteSlots.count ?? 0
            var wrote = "no --dump-ui"
            var ok = checks.ok && missing.isEmpty
            if let dir, let shot = capture(w.hwnd) {
                let png = WinUIDump.write(shot, to: dir.appendingPathComponent("companion-\(v.name).png"))
                let json = tree.write(to: dir.appendingPathComponent("companion-tree-\(v.name).json"))
                wrote = "png=\(png == 0 ? "companion-\(v.name).png" : "FAILED \(png)") tree=\(json)"
                if png != 0 { ok = false }
            }
            allOK = allOK && ok
            lines.append("\(v.name) (dpi \(w.ctx.dpi), text x\(w.ctx.textScale), \(v.language)): \(model.spriteLabel), header \(header.view.pixelSize.cx)x\(header.view.pixelSize.cy) px, "
                         + "picture \(picture), evolution line \(section.line?.row.isVisible == true ? "\(lineSlots) sprites" : "hidden"), missing texts \(missing); "
                         + "\(checks.summary); \(wrote)")
            h.destroy()
        }
        WinCompanionSection.spriteFetcherOverride = fixtureFetcher()
        r.add("companion.capture", allOK, "sample-data states, Windows CI runner, sprites from \(spriteDirectory == nil ? "nowhere" : "the fixture folder"): "
              + lines.joined(separator: " | "))
    }

    // MARK: companion.celebrate: a fixture hatch plays at up to 60 frames a second, then only the sprite clock runs

    /// One defaults object for every fixture companion (a new synced one per store would keep its own watchers).
    private static let sharedDefaults = WinDefaultsSync.makeAppDefaults()

    static func fixtureCompanion(language: AppLanguage = .en, eggUsage: Int) -> (CompanionStore, URL) {
        var state = CompanionState()
        state.eggUsage = eggUsage
        state.language = language
        state.installBaselineSet = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-companion-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("companion-state.json")
        try? JSONEncoder().encode(state).write(to: url)
        let store = CompanionStore(provider: CompanionSamplePoke(), fileURL: url, dittoDisguiseRollingEnabled: false, defaults: sharedDefaults)
        return (store, dir)
    }

    /// A page over a real store (so the section observes it and consumes on it).
    private static func realHarness(_ companion: CompanionStore, animations: Bool = true) async -> CompanionHarness? {
        let base = await HomeStores.make(language: companion.language)
        let stores = HomeStores(store: base.store, companion: companion, team: base.team, state: base.state, directory: base.directory)
        return CompanionHarness(stores: stores, animations: animations)
    }

    private static func celebrateCheck(_ r: WindowsSelftest.Recorder) async {
        let (store, dir) = fixtureCompanion(eggUsage: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let h = await realHarness(store), let section = h.section else {
            r.add("companion.celebrate", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.5)
        let framesBefore = section.stats.effectFrames
        let firesBefore = section.effectClock.fireCount
        await store.hatch(baseID: 1)
        let hatched = Date()
        _ = await WindowsSelftest.waitUntil(timeout: 1) { section.driver.plays > 0 }
        let kind = section.driver.celebration?.kind
        // the effect runs: watch until the effect clock goes quiet; the frame rate is bounded by the clock's fires
        var lastActive = hatched
        for _ in 0..<400 {
            await wait(0.01)
            if section.effectClock.isArmed || section.driver.isCelebrating {
                lastActive = Date()
            } else if Date().timeIntervalSince(hatched) > 1 { break }
        }
        let maxRate = section.stats.minFireGap.isFinite ? 1 / section.stats.minFireGap : 0
        let duration = lastActive.timeIntervalSince(hatched)
        let frames = section.stats.effectFrames - framesBefore
        let fires = section.effectClock.fireCount - firesBefore
        // after it: the sprite clock alone (the GIF's frames, or the bob), the effect clock unarmed
        let animator = section.header?.view.sprites
        let ticks0 = animator?.playback.ticks ?? 0
        await wait(1.0)
        let ticksAfter = (animator?.playback.ticks ?? 0) - ticks0
        let model = animator?.playback.models.first
        let gifFrames = model?.frames.count ?? 0
        let gifRate = gifFrames > 1 ? Double(gifFrames) / (model?.frames.reduce(0) { $0 + $1.delay } ?? 1) : 0
        let quiet = !section.effectClock.isArmed && !section.driver.isCelebrating
        let ok = kind != nil && store.celebration == nil && frames >= 20 && frames <= 160 && maxRate <= 64 && duration <= 2.6 && quiet && ticksAfter > 0
        r.add("companion.celebrate", ok,
              "fixture hatch (Bulbasaur, plain): celebration \(kind.map { "\($0)" } ?? "none") consumed=\(store.celebration == nil); effect frames \(frames) "
              + "(clock fires \(fires)) over \(String(format: "%.2f", duration)) s (budget 2.6 s), fastest fire-to-fire \(String(format: "%.1f", maxRate)) /s "
              + "(budget 60 with 1 ms of timer jitter = 64: the shortest gap between two fires of the effect clock); afterwards effect clock armed=\(section.effectClock.isArmed), sprite clock ticks in 1 s=\(ticksAfter) "
              + "(the GIF: \(gifFrames) frames, \(String(format: "%.1f", gifRate)) /s)")
    }

    // MARK: companion.consumedOnce: one play however often the popover opens

    private static func consumedOnceCheck(_ r: WindowsSelftest.Recorder) async {
        let (store, dir) = fixtureCompanion(eggUsage: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.hatch(baseID: 1)   // while the popover is closed
        let fired = store.celebration != nil
        var plays: [Int] = []
        for _ in 0..<2 {
            guard let h = await realHarness(store), let section = h.section else { break }
            h.window.show(activate: false)
            await wait(0.3)
            plays.append(section.driver.plays)
            h.destroy()
        }
        store.applyUsage(store.threshold)   // an evolution, still closed
        let evolved = store.celebration == .evolve
        var evolvePlays: [Int] = []
        for _ in 0..<2 {
            guard let h = await realHarness(store), let section = h.section else { break }
            h.window.show(activate: false)
            await wait(0.3)
            evolvePlays.append(section.driver.plays)
            h.destroy()
        }
        let ok = fired && plays == [1, 0] && evolved && evolvePlays == [1, 0] && store.celebration == nil
        r.add("companion.consumedOnce", ok, "hatch fired while closed=\(fired); plays per open \(plays) (expected [1, 0]); evolve fired=\(evolved), plays per open "
              + "\(evolvePlays) (expected [1, 0]); left in the store=\(store.celebration.map { "\($0)" } ?? "none")")
    }

    // MARK: companion.liveUpdate: a hatch and an evolution while open change the header in place

    private static func liveUpdateCheck(_ r: WindowsSelftest.Recorder) async {
        let (store, dir) = fixtureCompanion(eggUsage: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let h = await realHarness(store, animations: false), let section = h.section, let header = section.header else {
            r.add("companion.liveUpdate", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.show(activate: false)
        await wait(0.4)
        let hwnd = header.view.hwnd
        let rows = section.section.rows.count
        let updates0 = section.stats.headerUpdates
        await store.hatch(baseID: 1)
        await wait(0.5)
        let hatchedSame = section.header?.view.hwnd == hwnd && section.header?.part === header.part && section.section.rows.count == rows
        let shows1 = section.header?.part.model.sprite.speciesID
        store.applyUsage(store.threshold)
        await wait(0.5)
        let evolvedSame = section.header?.view.hwnd == hwnd && section.section.rows.count == rows
        let shows2 = section.header?.part.model.sprite.speciesID
        let lineShown = section.line?.row.isVisible == true
        let visibleThroughout = IsWindowVisible(hwnd)
        let ok = hatchedSame && evolvedSame && shows1 == 1 && shows2 == 2 && lineShown && visibleThroughout
            && section.stats.headerUpdates - updates0 >= 2 && section.driver.plays == 2
        r.add("companion.liveUpdate", ok, "egg -> hatch -> evolve while open: the same header window and part=\(hatchedSame)/\(evolvedSame), rows \(rows) kept, "
              + "sprite species \(shows1.map(String.init) ?? "-") then \(shows2.map(String.init) ?? "-"), evolution line shown=\(lineShown), header updates "
              + "+\(section.stats.headerUpdates - updates0), celebrations played \(section.driver.plays) (animation off: consumed, not drawn)")
    }

    // MARK: companion.colourEgg: the offline 🥚 is drawn in colour (DirectWrite), not GDI's one colour

    private static func colourEggCheck(_ r: WindowsSelftest.Recorder) async {
        WinCompanionSection.spriteFetcherOverride = fixtureFetcher(offline: true)
        defer { WinCompanionSection.spriteFetcherOverride = fixtureFetcher() }
        let stores = await HomeStores.make(language: .en)
        guard let h = CompanionHarness(stores: stores, companion: egg(.en, banked: 0.3), animations: false), let header = h.section?.header else {
            r.add("companion.colourEgg", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.6)
        guard let shot = capture(header.view.hwnd) else {
            r.add("companion.colourEgg", false, "no capture of the header")
            return
        }
        // the sprite box's pixels: how many are coloured (channels apart), how many dark
        let s = header.view.ctx.scale
        let box = CGRect(x: 0, y: (CGFloat(header.view.pixelSize.cy) / s - 76) / 2, width: 76, height: 76)
        var coloured = 0, inked = 0
        for y in Int(box.minY * s)..<min(shot.height, Int(box.maxY * s)) {
            for x in 0..<min(shot.width, Int(box.maxX * s)) {
                let i = (y * shot.width + x) * 4
                let b = Int(shot.bgra[i]), g = Int(shot.bgra[i + 1]), rr = Int(shot.bgra[i + 2])
                if max(b, g, rr) - min(b, g, rr) > 24 { coloured += 1 }   // a hue (GDI's one-colour glyph and the grey backdrop have none)
                if b + g + rr < 600 { inked += 1 }
            }
        }
        let glyphs = header.view.sprites?.stats.glyphs ?? 0
        r.add("companion.colourEgg", glyphs > 0 && coloured > 50,
              "no sprite file (offline): 🥚 drawn \(glyphs) times; in the 76 pt box \(inked) inked pixels, \(coloured) coloured (GDI's one-colour glyph has 0)")
    }

    // MARK: companion.evoLineScroll: the wheel and a touchpad move the line; a chevron press moves it over 0.25 s

    private static func wheelParam(_ delta: Int, keys: Int = 0) -> Int { Int(UInt32(UInt16(bitPattern: Int16(delta))) << 16) | keys }

    private static func evoLineScrollCheck(_ r: WindowsSelftest.Recorder) async {
        await loadSampleNames()
        let base = await HomeStores.make(language: .en)
        let store = await CompanionHeaderSamples.store(.eevee, language: .en, defaults: sharedDefaults, directory: base.directory.appendingPathComponent("sample"))
        let stores = HomeStores(store: base.store, companion: store, team: base.team, state: base.state, directory: base.directory)
        var input = CompanionHeaderInput(store: store, names: sampleNames)
        input.lineNodes = eeveeLine
        guard let h = CompanionHarness(stores: stores, companion: input, animations: true, names: sampleNames),
              let section = h.section, let line = section.line else {
            r.add("companion.evoLineScroll", false, "no window or no line")
            base.remove()
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.3)
        let hwnd = line.view.hwnd
        var chars: UINT = 3
        _ = SystemParametersInfoW(0x006C /* SPI_GETWHEELSCROLLCHARS */, 0, &chars, 0)
        let s = h.window.ctx.scale
        let notch = (CGFloat(chars) * 10 * s).rounded(.towardZero) / s   // DIP a notch, in whole device pixels
        func x() -> CGFloat { line.part.layout.scrollX }
        _ = WinKit.send(hwnd, 0x020A, wheelParam(-120))                  // a plain wheel: the page's, not the line's
        let plain = x()
        _ = WinKit.send(hwnd, 0x020E, wheelParam(120))                   // a touchpad's swipe / tilt to the right
        let right = x()
        _ = WinKit.send(hwnd, 0x020A, wheelParam(120, keys: 0x0004))     // Shift + wheel away from the user: back
        let back = x()
        for _ in 0..<8 { _ = WinKit.send(hwnd, 0x020E, wheelParam(15)) } // a precision touchpad's small steps add up
        let fine = x()
        for _ in 0..<40 { _ = WinKit.send(hwnd, 0x020E, wheelParam(120)) }
        let end = x(), maxX = line.part.layout.maxScrollX
        await wait(0.1)
        let wheelOK = plain == 0 && abs(right - notch) < 0.01 && back == 0 && abs(fine - notch) < 0.01 && end == maxX && !section.lineClock.isArmed
        // a chevron press back from the end: eased over 0.25 s at up to 60 frames a second, then the clock stops
        let frames0 = section.stats.lineFrames, fires0 = section.lineClock.fireCount
        let target = line.part.layout.scrolled(forward: false)
        let pressed = Date()
        line.view.onHit?(PlazaPanelHit(action: EvoLinePart.backAction, index: nil))
        let movedAtOnce = x() != end
        var lastArmed = pressed
        for _ in 0..<100 {
            await wait(0.01)
            if section.lineClock.isArmed { lastArmed = Date() } else if Date().timeIntervalSince(pressed) > 0.5 { break }
        }
        let frames = section.stats.lineFrames - frames0, fires = section.lineClock.fireCount - fires0
        let span = lastArmed.timeIntervalSince(pressed)
        let pressOK = !movedAtOnce && x() == target && frames >= 8 && frames <= 20 && span <= 0.4 && !section.lineClock.isArmed
        r.add("companion.evoLineScroll", wheelOK && pressOK,
              "nine-node line, \(chars) chars a notch (\(notch) DIP): plain wheel moved it to \(plain) (expected 0, the page's); WM_MOUSEHWHEEL +120 → \(right) "
              + "(expected \(notch)); Shift + wheel +120 → \(back) (expected 0); 8 × +15 → \(fine) (expected \(notch)); 40 notches → \(end) (end \(maxX)); "
              + "chevron back from the end: moved at once=\(movedAtOnce) (expected false), \(frames) frames on \(fires) clock fires over "
              + "\(String(format: "%.2f", span)) s (the Mac's 0.25 s ease: 15 frames), landed at \(x()) (target \(target)), clock armed after=\(section.lineClock.isArmed)")
    }

    // MARK: companion.barHover: 300 ms over the growth bar grows it with the readout; leaving shrinks it

    private static func barHoverCheck(_ r: WindowsSelftest.Recorder) async {
        await loadSampleNames()
        var lines: [String] = []
        var allOK = true
        for animations in [true, false] {
            let base = await HomeStores.make(language: .en)
            let store = await CompanionHeaderSamples.store(.midLevel, language: .en, defaults: sharedDefaults, directory: base.directory.appendingPathComponent("sample"))
            let stores = HomeStores(store: base.store, companion: store, team: base.team, state: base.state, directory: base.directory)
            guard let h = CompanionHarness(stores: stores, animations: animations, names: sampleNames), let section = h.section,
                  let header = section.header, let bar = header.part.barFrame else {
                lines.append("animations \(animations): no window, header or bar")
                allOK = false
                base.remove()
                continue
            }
            h.window.fitToContent()
            h.window.show(activate: false)
            // CI only: the real cursor parked off the window, so no real move or leave lands in the timeline below
            if WindowsSelftest.onCI {
                var wr = RECT()
                _ = GetWindowRect(h.window.hwnd, &wr)
                _ = SetCursorPos(wr.right + 40, wr.bottom + 40)
            }
            await wait(0.3)
            // the view's own path: a pointer move over the bar reaches the section (WM_MOUSEMOVE → onPointer)
            let hovers0 = section.stats.barHovers
            let s = h.window.ctx.scale
            let lParam = Int(UInt32(UInt16(truncatingIfNeeded: Int((bar.midX * s).rounded())))) | Int(UInt32(UInt16(truncatingIfNeeded: Int((bar.midY * s).rounded()))) << 16)
            _ = WinKit.send(header.view.hwnd, 0x0200, 0, lParam)
            let delivered = section.stats.barHovers > hovers0
            // the timeline (driven directly: a synthetic move's leave tracking depends on where the real cursor is)
            section.hovered(nil)
            await wait(0.15)
            let frames0 = section.stats.barFrames
            let came = Date()
            section.hovered(CGPoint(x: bar.midX, y: bar.midY))
            await wait(0.2)
            let early = header.part.barLook
            await wait(0.8)
            let open = header.part.barLook
            let grown = section.stats.barFrames - frames0
            let quietOpen = !section.barClock.isArmed
            section.hovered(CGPoint(x: bar.midX, y: bar.maxY + 20))   // off the bar, still on the header
            await wait(0.4)
            let closed = header.part.barLook
            let quietClosed = !section.barClock.isArmed
            let total = section.stats.barFrames - frames0
            let framesOK = animations ? (grown >= 20 && grown <= 40) : grown == 1
            let ok = delivered && early == .rest && open == .open && closed == .rest && framesOK && quietOpen && quietClosed
            allOK = allOK && ok
            lines.append("animations \(animations): WM_MOUSEMOVE delivered=\(delivered); 0.2 s after coming \(early == .rest ? "still thin" : "\(early)") "
                         + "(the Mac's 300 ms wait); 1 s after: \(open == .open ? "grown with the readout" : "\(open)"), \(grown) frames "
                         + "(\(animations ? "the spring settles in 0.48 s: about 29" : "a jump: 1"), clock armed after=\(!quietOpen); 0.4 s after leaving: "
                         + "\(closed == .rest ? "thin again" : "\(closed)"), \(total - grown) frames, clock armed after=\(!quietClosed); "
                         + "since \(String(format: "%.2f", Date().timeIntervalSince(came))) s")
            h.destroy()
        }
        r.add("companion.barHover", allOK, lines.joined(separator: " | "))
    }

    // MARK: companion.openClose3: nothing left behind

    private static func openCloseCheck(_ r: WindowsSelftest.Recorder, start: KitResources) async {
        var cycles: [KitResources] = []
        var armedAfter = false
        for i in 0..<4 {
            let stores = await HomeStores.make(language: .en)
            let input = i % 2 == 0 ? mon(.en, id: 1, path: [1, 2, 3], stage: 0, name: "Bulbasaur", progress: 0.5) : egg(.en, banked: 0.95)
            guard let h = CompanionHarness(stores: stores, companion: input) else { break }
            h.window.fitToContent()
            h.window.show(activate: false)
            await wait(0.4)
            let clocks = [h.section?.effectClock, h.section?.lineClock, h.section?.barClock, h.section?.header?.view.sprites?.playback.clock]
            h.destroy()
            armedAfter = armedAfter || clocks.contains { $0?.isArmed == true }
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        guard cycles.count == 4, let last = cycles.last else {
            r.add("companion.openClose3", false, "only \(cycles.count) of 4 cycles")
            return
        }
        // the shared open/close rule (#240): GDI and USER never above the warm-up, handles fail only when they rise every cycle
        let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) })
        let ok = verdict.ok && last.controls == 0 && last.dialogs == start.dialogs && !armedAfter
        r.add("companion.openClose3", ok, "before the group: \(start); \(verdict.summary); a clock (effects, line, bar, sprites) armed after a close=\(armedAfter); "
              + "kit controls and dialog registrations back to the start (last: \(last))")
    }

    // MARK: --popover-companion-idle-probe still|bob|wiggle|animated (the idle gate)

    static var idleProbe: CompanionHarness?

    /// Home with the companion header open and left alone (CI only): `still` = Windows' own animation setting (off on the
    /// runner: the first picture, no timer), `bob` = the egg with animation on (the bob: one wake per pixel step), `wiggle` =
    /// the imminent egg with animation on (the bob and the wiggle), `animated` = Bulbasaur's GIF with animation on. Nothing
    /// relative on the page.
    static func startIdleProbe(mode: String) {
        guard WindowsSelftest.onCI else {
            AppLog.write("popover companion idle probe: CI not set; nothing opened")
            return
        }
        prepare()
        Task { @MainActor in
            await wait(3)
            let stores = await HomeStores.make(language: .en)
            let input = mode == "bob" ? egg(.en, banked: 0.4)
                : mode == "wiggle" ? egg(.en, banked: 0.95) : mon(.en, id: 1, path: [1, 2, 3], stage: 0, name: "Bulbasaur", progress: 0.5)
            let animations = mode == "still" ? WinSpriteAnimator.systemAnimationsEnabled() : true
            guard let h = CompanionHarness(stores: stores, companion: input, animations: animations, home: { lang, now in
                var i = HomeFixtures.claudeLimits(lang, now: now)
                i.lastUpdated = nil
                i.limits = nil
                i.claudeAccounts = []
                i.claudeLimitsMissing = false
                return i
            }) else {
                AppLog.write("popover companion idle probe: no window")
                return
            }
            h.window.fitToContent()
            h.window.show(activate: false)
            idleProbe = h
            await wait(2)
            let model = h.section?.header?.view.sprites?.playback.models.first
            AppLog.write("popover companion idle probe: mode=\(mode) animations=\(animations) picture=\(model?.current == nil ? "none" : "loaded") "
                         + "gif frames=\(model?.frames.count ?? 0) sprite clock armed=\(h.section?.header?.view.sprites?.playback.clock.isArmed == true) "
                         + "effect clock armed=\(h.section?.effectClock.isArmed == true) \(KitResources.now())")
        }
    }
}
#endif
