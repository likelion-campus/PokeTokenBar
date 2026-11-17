#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 19: the Shop and Bag tabs' selftest groups (`popover.shop`, `popover.bag`). Every state is SAMPLE data made here
// (a companion state file with a wallet, an inventory and a made-up evolution line; nothing is read from this PC, nothing is
// bought for real: Buy and Use are recorded). With `--dump-ui <dir>` the pages go to `<dir>/shop/` and `<dir>/bag/` as PNG
// ("Sample-data capture, Windows CI runner"). Sprites: the item sprites come from a fixture source (a PNG made here, or none for
// the emoji fallback) and the egg and Snorlax slots from a stub fetcher, so they show the egg glyph.

extension WindowsSelftest {
    @MainActor static func popoverShopBagChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverShopBag.run(r, app)
    }
}

/// Answers for item sprites from a folder of bytes made here; no network.
private final class ItemFixtureSource: PopoverItemSource, @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var answers: [String: Data]
    private var asked = 0
    init(directory: URL, answers: [String: Data]) {
        self.directory = directory
        self.answers = answers
    }
    func data(itemName: String) async -> Data? { answer(itemName) }
    private func answer(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        asked += 1
        return answers[name]
    }
    var askedCount: Int { lock.lock(); defer { lock.unlock() }; return asked }
}

/// A Pokémon provider with one made-up three-stage line (the candy has a plan to preview once it is loaded).
private struct ShopBagFixturePoke: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        let tree = EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])])
        return EvoLine(baseID: 1, tree: tree, rarity: .common, names: [1: ["en": "P1"], 2: ["en": "P2"], 3: ["en": "P3"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor enum WindowsSelftestPopoverShopBag {
    static let names = ["popover.shop", "popover.bag"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        await shopCheck(r)
        await bagCheck(r)
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    static func dumpDirectory(_ name: String) -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent(name, isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func print(_ hwnd: HWND) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    /// A 30 px square PNG made with the plaza canvas (the item sprite's stand-in).
    private static func fixturePNG() -> Data? {
        let graphics = PlatformPlaza.graphics
        guard let canvas = graphics.makeCanvas(width: 30, height: 30, colorSpace: .sRGB) else { return nil }
        canvas.setFillColor(PlazaColor(srgbRed: 1, green: 0.35, blue: 0.5))
        canvas.fill(CGRect(x: 4, y: 4, width: 22, height: 22))
        return canvas.makeImage().flatMap { graphics.encodePNG($0) }
    }

    private static func companionJSON(used: Int, inventory: [ItemKind: Int] = [:], active: Bool, shiny: Bool = false) -> String {
        let inv = inventory.isEmpty ? "" : ",\"inventory\":{" + inventory.map { "\"\($0.key.rawValue)\":\($0.value)" }.sorted().joined(separator: ",") + "}"
        let mon = active
            ? ",\"active\":{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":1000,\"rarity\":\"common\",\"totalForms\":3,\"isShiny\":\(shiny),\"nature\":\"adamant\"}"
            : ""
        return "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":0,\"lastDate\":\"d\"\(mon),\"dex\":[],\"collectedFinals\":[]\(inv)}"
    }

    /// A tab page over a seeded companion, in a kit window; Buy and Use are recorded. `lineLoaded` waits for the made-up line.
    @MainActor final class Harness {
        let home: HomeHarness
        var shop: WinShopPage? { home.page.tabContent as? WinShopPage }
        var bag: WinBagPage? { home.page.tabContent as? WinBagPage }
        let record: Record
        final class Record {
            var items: [String] = []
            var eggs: [String] = []
            var uses: [String] = []
            var tabs: [PopoverState.Tab] = []
        }

        static func make(tab: PopoverState.Tab, language: AppLanguage, used: Int, inventory: [ItemKind: Int] = [:], active: Bool, shiny: Bool = false,
                         lineLoaded: Bool = false, sprites: Bool = true) async -> Harness? {
            let stores = await HomeStores.make(language: language, companionJSON: WindowsSelftestPopoverShopBag.companionJSON(
                used: used, inventory: inventory, active: active, shiny: shiny), poke: ShopBagFixturePoke())
            if lineLoaded {
                stores.companion.update(todayTokensByProvider: ["fixture": 0], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: true)
                _ = await WindowsSelftest.waitUntil(timeout: 3) { stores.companion.currentLine != nil }
            }
            stores.state.tab = tab
            let record = Record()
            let png = WindowsSelftestPopoverShopBag.fixturePNG()
            let source = ItemFixtureSource(directory: stores.directory, answers: sprites ? ["rare-candy": png ?? Data(), "shiny-charm": png ?? Data()] : [:])
            guard let h = HomeHarness(stores: stores, input: nil, recordActions: true, heightDIP: 640, configure: { page in
                page.tabChanged = { record.tabs.append($0) }
                page.configureTabContent = { content in
                    let stub = { WinSpriteAnimator(fetcher: PlazaStubSpriteFetcher(log: { _ in }), animationsEnabled: { false }) }
                    if let shop = content as? WinShopPage {
                        shop.itemSource = source
                        shop.makeSprites = stub
                        shop.buyItem = { kind, count in record.items.append("\(kind.rawValue)x\(count)"); return true }
                        shop.buyEgg = { tier in record.eggs.append(tier?.rawValue ?? "plain"); return true }
                    }
                    if let bag = content as? WinBagPage {
                        bag.itemSource = source
                        bag.makeSprites = stub
                        bag.performUse = { kind, count in record.uses.append("\(kind.rawValue)x\(count)") }
                    }
                }
            }) else { return nil }
            return Harness(home: h, record: record)
        }

        private init(home: HomeHarness, record: Record) {
            self.home = home
            self.record = record
        }

        func destroy() { home.destroy() }
        var language: L { home.stores.companion.l }

        /// Every window text on the page.
        func texts() -> [String] { KitTree.collect(home.window).nodes.map(\.text) }
        func has(_ text: String) -> Bool { texts().contains(text) }
        func click(_ control: WinControl?) { if let control { WinKit.send(control.hwnd, 0x00F5 /* BM_CLICK */) } }
    }

    // MARK: popover.shop

    private static func shopCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = []
        var notes: [String] = []
        let dir = dumpDirectory("shop")
        let start = KitResources.now()
        let rich = 1_000_000_000_000_000

        // 1. the states, in en and ko: what each shows
        for language in [AppLanguage.en, .ko] {
            let tag = language == .en ? "en" : "ko"
            struct Variant { var name: String; var used: Int; var inventory: [ItemKind: Int]; var active: Bool; var shiny = false; var sprites = true }
            let variants = [Variant(name: "rich", used: rich, inventory: [:], active: true),
                            Variant(name: "poor", used: 0, inventory: [:], active: true),
                            Variant(name: "egg", used: rich, inventory: [:], active: false, sprites: false),
                            Variant(name: "charm-owned", used: rich, inventory: [.shinyCharm: 1, .rareCandy: 4], active: true)]
            for v in variants {
                guard let h = await Harness.make(tab: .shop, language: language, used: v.used, inventory: v.inventory, active: v.active, shiny: v.shiny,
                                                 sprites: v.sprites), let page = h.shop, let model = page.last else {
                    problems.append("\(v.name) \(tag): no window or page"); continue
                }
                defer { h.destroy() }
                h.home.window.fitToContent()
                h.home.window.show(activate: false)
                await wait(0.5)
                let l = h.language
                let texts = h.texts()
                func expect(_ text: String, _ what: String) { if !texts.contains(text) { problems.append("\(v.name) \(tag): no \(what) '\(text)'") } }
                expect(model.wallet.caption, "wallet caption")
                expect(model.wallet.tokens, "wallet total")
                expect(model.wallet.hint, "wallet hint")
                if page.cards.count != model.entries.count || page.cards.contains(where: { $0.rendered == nil }) { problems.append("\(v.name) \(tag): cards \(page.cards.count) of \(model.entries.count)") }
                for entry in model.entries {
                    switch entry {
                    case .item(let m):
                        expect(m.name, "item name"); expect(m.description, "item description")
                        let selected = ShopCardRules.selectedQuantity(quantity: 1, maxQuantity: m.maxQuantity)
                        if m.ownedAlready { expect(l.ownedAlready, "owned mark") }
                        else {
                            expect(ShopCardRules.priceLine(l: l, price: m.price, selectedQuantity: selected), "price line")
                            if !m.canBuy { expect(l.notEnoughTokens, "not-enough text") }
                        }
                        if let owned = m.ownedText { expect(owned, "owned count") }
                    case .egg(let m):
                        expect(m.name, "egg name"); expect(m.description, "egg description")
                        expect(ShopCardRules.eggPriceLine(l: l, price: m.price), "egg price line")
                        if let badge = m.badge { expect(badge, "tier badge") }
                        if let note = m.releaseNote { expect(note, "release note") } else if texts.contains(l.eggReleaseNote) { problems.append("\(v.name) \(tag): a release note with nothing to release") }
                        if !m.hasActive { expect(m.lockedHint, "locked hint") }
                    }
                }
                if v.name == "rich" {
                    let items = model.entries.compactMap { e -> ShopItemCardModel? in if case .item(let m) = e { m } else { nil } }
                    let candy = items.first { $0.kind == .rareCandy }
                    if candy?.showsQuantity != true { problems.append("rich: the candy has no stepper") }
                    let candyIndex = model.entries.firstIndex { if case .item(let m) = $0 { m.kind == .rareCandy } else { false } }
                    if let candyIndex, page.cards[candyIndex].controls["stepper"] == nil { problems.append("rich: the candy card made no stepper") }
                }
                if v.name == "egg" {
                    let disabled = KitTree.collect(h.home.window).nodes.filter { $0.cls == "Button" && $0.text == l.buy && !$0.enabled }.count
                    if disabled != 3 { problems.append("egg \(tag): \(disabled) disabled Buy buttons, wanted 3 (one per egg)") }
                }
                if let dir, let shot = print(h.home.window.hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("\(v.name)-\(tag).png")) }
            }
        }
        notes.append("4 states x en/ko: wallet, every card's texts, price lines, not-enough, owned mark, disabled egg Buy and locked hint, release note only with something to release")

        // 2. the flows: stepper, Buy -> inline confirm -> Buy x n / Cancel; the egg's confirm and the second warning
        if let h = await Harness.make(tab: .shop, language: .en, used: rich, active: true), let page = h.shop, let model = page.last {
            defer { h.destroy() }
            h.home.window.fitToContent()
            h.home.window.show(activate: false)
            await wait(0.5)
            let l = h.language
            let dialogsBefore = KitResources.now().dialogs
            func index(_ kind: ItemKind) -> Int? { model.entries.firstIndex { if case .item(let m) = $0 { m.kind == kind } else { false } } }
            if let i = index(.rareCandy), case .item(let m) = model.entries[i] {
                h.click(page.cards[i].controls["buy"])
                await wait(0.4)
                let confirming = page.itemStates[.rareCandy]?.confirming == true
                let question = h.has(l.buyConfirm(ShopCardRules.quantityName(l: l, kind: .rareCandy, selectedQuantity: 1)))
                if !confirming || !question || page.cards[i].controls["confirm"] == nil { problems.append("candy Buy did not turn into the confirm (confirming=\(confirming) question=\(question))") }
                h.click(page.cards[i].controls["cancel"])
                await wait(0.4)
                let backToBuy = page.itemStates[.rareCandy]?.confirming == false && page.cards[i].controls["buy"] != nil && h.record.items.isEmpty
                if !backToBuy { problems.append("Cancel did not go back to Buy, or bought") }
                // the stepper changes the price line and the confirm's names
                page.cards[i].controls["stepper"]?.onValue?(3)
                await wait(0.4)
                let line = ShopCardRules.priceLine(l: l, price: m.price, selectedQuantity: 3)
                if !h.has(line) { problems.append("stepper to 3: no price line '\(line)'") }
                h.click(page.cards[i].controls["buy"])
                await wait(0.4)
                let title = ShopCardRules.confirmButtonTitle(l: l, selectedQuantity: 3)
                let named = h.has(l.buyConfirm(ShopCardRules.quantityName(l: l, kind: .rareCandy, selectedQuantity: 3)))
                if !KitTree.collect(h.home.window).nodes.contains(where: { $0.text == title }) || !named { problems.append("confirm at 3: no '\(title)' button or question (named=\(named))") }
                h.click(page.cards[i].controls["confirm"])
                await wait(0.4)
                if h.record.items != ["rareCandyx3"] || page.itemStates[.rareCandy]?.quantity != 1 || page.itemStates[.rareCandy]?.confirming != false {
                    problems.append("Buy x3 recorded \(h.record.items), state \(String(describing: page.itemStates[.rareCandy]))")
                }
            } else { problems.append("no candy card") }
            // the plain egg: Buy -> question -> Buy -> bought, then Home
            if let i = model.entries.firstIndex(where: { if case .egg(let m) = $0 { m.tier == nil } else { false } }) {
                h.click(page.cards[i].controls["buy"])
                await wait(0.4)
                h.click(page.cards[i].controls["confirm"])
                await wait(0.4)
                if h.record.eggs != ["plain"] || h.record.tabs != [.home] { problems.append("egg bought \(h.record.eggs), tabs \(h.record.tabs)") }
            } else { problems.append("no plain egg card") }
            if KitResources.now().dialogs != dialogsBefore || WinModalPump.depth != 0 { problems.append("a dialog or nested loop opened during the flows") }
            notes.append("candy: Buy -> inline question with Buy / Cancel (Cancel back, nothing bought); stepper 3 -> price line, 'Buy x3' and the named question; confirm recorded \(h.record.items); plain egg confirm -> \(h.record.eggs) then Home picked \(h.record.tabs); no dialog, pump depth \(WinModalPump.depth)")
        } else { problems.append("no window for the flows") }

        // 3. the second warning for a shiny companion (orange), then Home
        if let h = await Harness.make(tab: .shop, language: .en, used: rich, active: true, shiny: true), let page = h.shop, let model = page.last {
            defer { h.destroy() }
            h.home.window.fitToContent()
            h.home.window.show(activate: false)
            await wait(0.4)
            if let i = model.entries.firstIndex(where: { if case .egg(let m) = $0 { m.tier == nil } else { false } }), case .egg(let m) = model.entries[i] {
                h.click(page.cards[i].controls["buy"])
                await wait(0.4)
                h.click(page.cards[i].controls["confirm"])
                await wait(0.4)
                let warned = h.has(m.warningText) && h.record.eggs.isEmpty && page.eggStages["egg-plain"] == .preciousConfirm
                if !warned { problems.append("shiny: no second warning (stage \(String(describing: page.eggStages["egg-plain"])), bought \(h.record.eggs))") }
                if let dir, let shot = print(h.home.window.hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("egg-precious-en.png")) }
                h.click(page.cards[i].controls["confirm"])
                await wait(0.4)
                if h.record.eggs != ["plain"] || h.record.tabs != [.home] { problems.append("shiny discard: bought \(h.record.eggs), tabs \(h.record.tabs)") }
                notes.append("shiny: Buy -> question -> second warning (\(warned)) -> discard bought \(h.record.eggs), Home \(h.record.tabs)")
            } else { problems.append("shiny: no plain egg card") }
        } else { problems.append("no window for the shiny flow") }

        // 4. the item sprites: a fixture PNG replaces the emoji; no sprite keeps the emoji; open and close leaves nothing
        var cycles: [KitResources] = []
        for _ in 0..<4 {
            guard let h = await Harness.make(tab: .shop, language: .en, used: rich, active: true) else { break }
            h.home.window.fitToContent()
            h.home.window.show(activate: false)
            await wait(0.5)
            h.destroy()
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        if cycles.count == 4, let last = cycles.last {
            let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) }, userSlack: 1)
            if !verdict.ok || last.controls != 0 || last.dialogs != start.dialogs || last.pumpDepth != 0 { problems.append("open/close: \(verdict.summary); \(last)") }
            notes.append("open/close x4: \(verdict.summary); \(last)")
        } else { problems.append("open/close: \(cycles.count) of 4 cycles") }
        r.add("popover.shop", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: popover.bag

    private static func bagCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = []
        var notes: [String] = []
        let dir = dumpDirectory("bag")

        for language in [AppLanguage.en, .ko] {
            let tag = language == .en ? "en" : "ko"
            // the empty bag: Snorlax's slot, the title, the Shop button
            if let h = await Harness.make(tab: .bag, language: language, used: 0, active: true), let page = h.bag {
                defer { h.destroy() }
                h.home.window.show(activate: false)
                await wait(0.5)
                let l = h.language
                if !h.has(l.bagEmptyTitle) || page.shopButton == nil || !h.has(l.shop) { problems.append("empty \(tag): title \(h.has(l.bagEmptyTitle)) shop button \(page.shopButton != nil)") }
                if language == .en {
                    h.click(page.shopButton)
                    await wait(0.3)
                    if h.record.tabs != [.shop] { problems.append("empty: the Shop button picked \(h.record.tabs)") }
                }
                if let dir, let shot = print(h.home.window.hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("empty-\(tag).png")) }
            } else { problems.append("empty \(tag): no window") }
            // items with a loaded line: candy (stepper, preview), mint, the passive charm
            if let h = await Harness.make(tab: .bag, language: language, used: 0, inventory: [.rareCandy: 3, .mint: 2, .shinyCharm: 1], active: true,
                                          lineLoaded: true), let page = h.bag, let snap = page.last {
                defer { h.destroy() }
                h.home.window.fitToContent()
                h.home.window.show(activate: false)
                await wait(0.5)
                let l = h.language
                if let dir, let shot = print(h.home.window.hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("items-\(tag).png")) }  // before the flows below change the page
                for card in snap.model.cards {
                    if !h.has(card.name) || !h.has(card.description) { problems.append("items \(tag): \(card.kind) name or description missing") }
                    // (the candy's stepper reads ×1 too: a passive item's missing count can only be told apart above 1)
                    let countShown = h.has("×\(card.count)")
                    if (!card.isPassive && !countShown) || (card.isPassive && card.count > 1 && countShown) || (card.isPassive && !h.has(card.passiveHint)) {
                        problems.append("items \(tag): \(card.kind) count/effect line")
                    }
                }
                if language == .en {
                    let index = Dictionary(uniqueKeysWithValues: snap.model.cards.enumerated().map { ($1.kind, $0) })
                    if let c = index[.rareCandy] {
                        let candy = snap.model.cards[c]
                        if !candy.canUse || !candy.showsCandyStepper || page.cards[c].controls["stepper"] == nil { problems.append("candy: usable=\(candy.canUse) stepper=\(candy.showsCandyStepper)") }
                        let hint = BagCardRules.effectHint(l: l, kind: .rareCandy, selectedCandyCount: 1)
                        if !h.has(hint) { problems.append("candy: no effect hint '\(hint)'") }
                        page.cards[c].controls["stepper"]?.onValue?(2)
                        await wait(0.4)
                        let hint2 = BagCardRules.effectHint(l: l, kind: .rareCandy, selectedCandyCount: 2)
                        if !h.has(hint2) { problems.append("candy at 2: no '\(hint2)'") }
                        h.click(page.cards[c].controls["use"])
                        await wait(0.4)
                        let title = BagCardRules.confirmButtonTitle(l: l, kind: .rareCandy, selectedCandyCount: 2)
                        if !h.has(candy.confirmText) || !h.has(title) { problems.append("candy confirm: question \(h.has(candy.confirmText)) '\(title)' \(h.has(title))") }
                        h.click(page.cards[c].controls["confirm"])
                        await wait(0.4)
                        if h.record.uses != ["rareCandyx2"] || h.record.tabs != [.home] { problems.append("candy used \(h.record.uses), tabs \(h.record.tabs)") }
                        notes.append("candy: stepper 2 -> hint '\(hint2)', Use -> question + '\(title)' -> used \(h.record.uses), Home \(h.record.tabs)")
                    } else { problems.append("no candy card") }
                    if let m = index[.mint] {
                        h.click(page.cards[m].controls["use"])
                        await wait(0.3)
                        h.click(page.cards[m].controls["cancel"])
                        await wait(0.3)
                        if page.itemStates[.mint]?.confirming != false || h.record.uses.count != 1 { problems.append("mint: Cancel left confirming or used") }
                    } else { problems.append("no mint card") }
                }
            } else { problems.append("items \(tag): no window") }
        }
        // a Pokémon that is not there (an egg): the reason in place of the controls
        if let h = await Harness.make(tab: .bag, language: .en, used: 0, inventory: [.mint: 1], active: false), let page = h.bag, let snap = page.last {
            defer { h.destroy() }
            h.home.window.show(activate: false)
            await wait(0.4)
            if !h.has(h.language.useAfterHatch) || snap.model.cards.first?.canUse == true { problems.append("egg: no reason '\(h.language.useAfterHatch)'") }
            notes.append("states en/ko: empty (title, Shop button -> Shop), items (counts, descriptions, passive effect), egg reason")
        }
        r.add("popover.bag", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }
}
#endif
