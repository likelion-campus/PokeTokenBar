#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The Shop tab (stage 7 Task 19; the Mac's `ShopView`): the wallet card, then one card per `shopEntries` entry (items and the
/// three eggs by price). Nothing here calculates or formats: texts, prices, limits and enable states come from `ShopPageModel` and
/// `ShopCardRules`; this file places them (`WinCardView`) and keeps what the Mac's cards keep in `@State`: the chosen quantity,
/// the confirm flag of an item and the stage of an egg. Confirms are inline (the Buy button becomes the question with Buy and
/// Cancel), as the Mac's: no dialog.
///
/// The page observes `CompanionStore` while it exists (one-shot tracking, re-armed per change); a card is made again only when
/// its model or its state changed, keeping the keyboard on the same control. Input (a stepper, a button) marks the card dirty
/// and the card is made again on the next main-queue turn, never inside the control that was pressed. No timer; the item
/// sprites load once per icon and land only while the page is current.
@MainActor final class WinShopPage: WinTabContent {
    let host: WinTabHost
    /// Where item sprites come from (the selftest hands in a fixture folder).
    var itemSource: any PopoverItemSource = SpriteStore.shared
    var makeSprites: () -> WinSpriteAnimator? = { WinSpriteAnimator() }
    /// What Buy does (the selftest records instead of spending).
    var buyItem: (ItemKind, Int) -> Bool
    var buyEgg: (Rarity?) -> Bool
    /// A fixed model instead of the store's (the selftest's sample states); nothing is observed then.
    var modelOverride: (() -> ShopPageModel)?

    struct ItemState: Equatable { var quantity = 1; var confirming = false }
    enum EggStage: Equatable { case idle, confirm, preciousConfirm }

    final class Card {
        let section: WinSectionCard
        var controls: [String: WinControl] = [:]
        var rendered: ShopEntryModel?
        var renderedState = ""
        init(section: WinSectionCard) { self.section = section }
    }

    private(set) var last: ShopPageModel?
    private(set) var itemStates: [ItemKind: ItemState] = [:]
    private(set) var eggStages: [String: EggStage] = [:]
    private(set) var cards: [Card] = []
    private var wallet: WinSectionCard?
    private var walletRendered: ShopWalletModel?
    private var epoch = 0
    private var dirty: Set<Int> = []
    private var flushScheduled = false
    private(set) var isDestroyed = false
    /// How often each part was made (the selftest's evidence that an unrelated change re-renders nothing else).
    private(set) var renders = 0, walletRenders = 0

    init(host: WinTabHost) {
        self.host = host
        let companion = host.companion
        buyItem = { companion.buy($0, count: $1) }
        buyEgg = { companion.buyEgg($0) }
    }

    // MARK: WinTabContent

    func build() {
        isDestroyed = false
        epoch += 1
        host.stack.useMetrics(.shopScroll)  // `VStack(spacing: 10)` with the page's 14 pt sides
        wallet = host.stack.addSection(nil, card: false)
        observe()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        cards = []
        wallet = nil
        last = nil
    }

    // MARK: observing

    func observe() {
        guard !isDestroyed else { return }
        if let modelOverride {
            apply(modelOverride())
            return
        }
        let mine = epoch
        let companion = host.companion
        let model = withObservationTracking {
            ShopPageModel.make(store: companion)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine else { return }
                self.observe()
            }
        }
        apply(model)
    }

    private static func id(_ entry: ShopEntryModel) -> String {
        switch entry {
        case .item(let m): "item-\(m.kind.rawValue)"
        case .egg(let m): "egg-\(m.tier?.rawValue ?? "plain")"
        }
    }

    /// The state a card is drawn with, as text (a card is made again when this or its model changed).
    private func stateKey(_ entry: ShopEntryModel) -> String {
        switch entry {
        case .item(let m):
            let s = itemStates[m.kind] ?? ItemState()
            return "q\(ShopCardRules.selectedQuantity(quantity: s.quantity, maxQuantity: m.maxQuantity)) c\(s.confirming)"
        case .egg(let m):
            return "\(eggStages[Self.id(.egg(m))] ?? .idle)"
        }
    }

    func apply(_ m: ShopPageModel) {
        guard !isDestroyed, let wallet else { return }
        if walletRendered != m.wallet { renderWallet(m.wallet, wallet) }
        while cards.count < m.entries.count { cards.append(Card(section: host.stack.addSection(nil, card: false))) }
        // a quantity above the new limit is clamped (the Mac's `.onChange(of: store.maxBuyCount(kind))`)
        for case .item(let item) in m.entries {
            if var s = itemStates[item.kind] {
                let clamped = ShopCardRules.selectedQuantity(quantity: s.quantity, maxQuantity: item.maxQuantity)
                if clamped != s.quantity { s.quantity = clamped; itemStates[item.kind] = s }
            }
        }
        for (i, card) in cards.enumerated() {
            guard i < m.entries.count else {
                if card.rendered != nil { card.section.removeRows(); card.section.isVisible = false; card.rendered = nil }
                continue
            }
            let entry = m.entries[i]
            let key = stateKey(entry)
            if card.rendered != entry || card.renderedState != key { renderCard(i, entry) }
        }
        last = m
    }

    /// The model as it is now, without arming the observation again (an input changed a card's state).
    private func refresh() {
        guard !isDestroyed else { return }
        if let modelOverride { apply(modelOverride()) } else { apply(ShopPageModel.make(store: host.companion)) }
    }

    private func schedule() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                if self.host.isCurrent { self.refresh() }
            }
        }
    }

    // MARK: wallet

    /// `ShopView.walletHeader`: caption, 24 pt bold total, hint, 2 pt apart on a 10 pt card.
    private func renderWallet(_ w: ShopWalletModel, _ section: WinSectionCard) {
        section.removeRows()
        section.addStyledRow(label: nil, style: .full) { pane, ctx in
            WinCardView(parent: pane, ctx: ctx) { child, ctx, _ in
                var lines: [WinCardView.Line] = []
                if let c = WinCardKit.label(w.caption, .caption, role: .secondary, wraps: true, in: child, ctx: ctx) { lines.append(.init(flexible: c)) }
                if let c = WinCardKit.bigNumber(w.tokens, in: child, ctx: ctx) { lines.append(.init(leading: [c], top: 2)) }
                if let c = WinCardKit.label(w.hint, .caption2, role: .tertiary, wraps: true, in: child, ctx: ctx) { lines.append(.init(flexible: c, top: 2)) }
                return (nil, lines)
            }?.control
        }
        walletRendered = w
        walletRenders += 1
        host.stack.layoutIfNeeded()  // placed now, not on the next turn: nothing shows at the top left meanwhile
    }

    // MARK: cards

    private func renderCard(_ i: Int, _ entry: ShopEntryModel) {
        let card = cards[i]
        let kept = WinCardKit.focusedName(card.controls)
        card.section.removeRows()
        card.controls = [:]
        card.section.isVisible = true
        switch entry {
        case .item(let m): renderItem(card, m)
        case .egg(let m): renderEgg(card, m)
        }
        card.rendered = entry
        card.renderedState = stateKey(entry)
        renders += 1
        host.stack.layoutIfNeeded()  // placed now, not on the next turn: nothing shows at the top left meanwhile
        WinCardKit.restoreFocus(kept, card.controls)
    }

    /// `ShopItemCard.body`: the icon beside the name, the owned count and the quantity stepper over the description, then the buy line.
    private func renderItem(_ card: Card, _ m: ShopItemCardModel) {
        let l = host.l
        let state = itemStates[m.kind] ?? ItemState()
        let selected = ShopCardRules.selectedQuantity(quantity: state.quantity, maxQuantity: m.maxQuantity)
        card.section.addStyledRow(label: nil, style: .full) { pane, ctx in
            WinCardView(parent: pane, ctx: ctx) { child, ctx, _ in
                let icon = WinCardKit.itemIcon(m.kind, host: self.host, source: self.itemSource, in: child, ctx: ctx)
                var title = WinCardView.Line(top: 0, indent: true, gap: 6)
                if let name = WinCardKit.label(m.name, .callout, weight: 600, in: child, ctx: ctx) { title.leading.append(name) }
                if let owned = m.ownedText, let c = WinCardKit.label(owned, .caption2, weight: 700, role: .secondary, in: child, ctx: ctx) { title.leading.append(c) }
                if m.showsQuantity {
                    // the stepper's accessible name is the static before it: the item's name (`.accessibilityLabel(l.itemName(kind))`)
                    if let name = WinControls.label(m.name, wraps: false, in: child, ctx: ctx) { title.unseen.append(name) }
                    let stepper = WinControls.stepper(range: 1...m.maxQuantity, step: 1, value: selected, format: { "×\($0)" }, in: child, ctx: ctx)
                    stepper?.onValue = { [weak self] v in
                        guard let self else { return }
                        var s = self.itemStates[m.kind] ?? ItemState()
                        s.quantity = v
                        self.itemStates[m.kind] = s
                        self.schedule()
                    }
                    if let stepper { title.trailing.append(stepper); card.controls["stepper"] = stepper }
                }
                var description = WinCardView.Line(top: 2, indent: true)
                description.flexible = WinCardKit.label(m.description, .caption, role: .secondary, wraps: true, in: child, ctx: ctx)
                return (icon, [title, description, self.buyLine(card, m, state: state, selected: selected, l: l, in: child, ctx: ctx)])
            }?.control
        }
    }

    /// `ShopItemCard.buyControls`.
    private func buyLine(_ card: Card, _ m: ShopItemCardModel, state: ItemState, selected: Int, l: L, in child: HWND, ctx: WinUIContext) -> WinCardView.Line {
        var line = WinCardView.Line(top: 8)
        if m.ownedAlready {
            // a passive item you own: "owned", no buy button
            line.glyph = ("checkmark.seal.fill", WinCardKit.colorRef(.systemGreen, ctx: ctx))
            if let c = WinCardKit.label(l.ownedAlready, .caption2, weight: 600, color: .systemGreen, in: child, ctx: ctx) { line.leading.append(c) }
        } else if state.confirming {
            let question = l.buyConfirm(ShopCardRules.quantityName(l: l, kind: m.kind, selectedQuantity: selected))
            if let c = WinCardKit.label(question, .caption2, role: .secondary, in: child, ctx: ctx) { line.leading.append(c) }
            let buy = WinCardKit.pill(ShopCardRules.confirmButtonTitle(l: l, selectedQuantity: selected), .prominent, in: child, ctx: ctx) { [weak self] in
                self?.buyNow(m.kind, quantity: selected)
            }
            let cancel = WinCardKit.pill(l.cancel, .borderless, in: child, ctx: ctx) { [weak self] in
                self?.setConfirming(m.kind, false)
            }
            for (name, c) in [("confirm", buy), ("cancel", cancel)] { if let c { line.trailing.append(c); card.controls[name] = c } }
        } else {
            // the total for the chosen quantity, before the confirm
            if let c = WinCardKit.label(ShopCardRules.priceLine(l: l, price: m.price, selectedQuantity: selected), .caption2, role: .tertiary,
                                        in: child, ctx: ctx) { line.leading.append(c) }
            if m.canBuy {
                if let b = WinCardKit.bordered(l.buy, in: child, ctx: ctx, { [weak self] in self?.setConfirming(m.kind, true) }) {
                    line.trailing.append(b)
                    card.controls["buy"] = b
                }
            } else if let c = WinCardKit.label(l.notEnoughTokens, .caption2, role: .tertiary, in: child, ctx: ctx) {
                line.trailing.append(c)
            }
        }
        return line
    }

    func setConfirming(_ kind: ItemKind, _ on: Bool) {
        var s = itemStates[kind] ?? ItemState()
        s.confirming = on
        itemStates[kind] = s
        schedule()
    }

    /// `ShopItemCard.buyNow`.
    func buyNow(_ kind: ItemKind, quantity: Int) {
        var s = itemStates[kind] ?? ItemState()
        s.confirming = false
        itemStates[kind] = s
        if buyItem(kind, quantity) { s.quantity = 1; itemStates[kind] = s }
        schedule()
    }

    /// `EggCard.body`: the egg (26 pt in a 30 pt frame), the name and tier badge, the description and the release note, then
    /// the controls of the stage.
    private func renderEgg(_ card: Card, _ m: ShopEggCardModel) {
        let l = host.l
        let key = Self.id(.egg(m))
        let stage = eggStages[key] ?? .idle
        card.section.addStyledRow(label: nil, style: .full) { pane, ctx in
            WinCardView(parent: pane, ctx: ctx) { child, ctx, _ in
                let icon = WinCardKit.spriteBox(SpriteBoxPart(speciesID: nil, sprite: 26, box: 30), sprites: self.makeSprites(), in: child, ctx: ctx)
                var title = WinCardView.Line(top: 0, indent: true, gap: 6)
                if let name = WinCardKit.label(m.name, .callout, weight: 600, in: child, ctx: ctx) { title.leading.append(name) }
                if let text = m.badge, let tier = m.tier,
                   let badge = WinCardKit.badge(.init(text: text, tint: .rarity(tier)), in: child, ctx: ctx) { title.leading.append(badge) }
                var description = WinCardView.Line(top: 2, indent: true)
                description.flexible = WinCardKit.label(m.description, .caption, role: .secondary, wraps: true, in: child, ctx: ctx)
                var lines = [title, description]
                if let note = m.releaseNote {
                    var line = WinCardView.Line(top: 2, indent: true)
                    line.flexible = WinCardKit.label(note, .caption2, role: .tertiary, wraps: true, in: child, ctx: ctx)
                    lines.append(line)
                }
                lines.append(contentsOf: self.eggLines(card, m, key: key, stage: stage, l: l, in: child, ctx: ctx))
                return (icon, lines)
            }?.control
        }
    }

    /// `EggCard.controls`.
    private func eggLines(_ card: Card, _ m: ShopEggCardModel, key: String, stage: EggStage, l: L, in child: HWND, ctx: WinUIContext) -> [WinCardView.Line] {
        switch stage {
        case .idle:
            var price = WinCardView.Line(top: 8)
            if let c = WinCardKit.label(ShopCardRules.eggPriceLine(l: l, price: m.price), .caption2, role: .tertiary, in: child, ctx: ctx) { price.leading.append(c) }
            if !m.hasActive {
                // an egg: nothing to release, so only Buy is blocked (disabled), and the reason is under it
                if let b = WinCardKit.bordered(l.buy, in: child, ctx: ctx, {}) { b.isEnabled = false; price.trailing.append(b) }
            } else if m.canBuy {
                if let b = WinCardKit.bordered(l.buy, in: child, ctx: ctx, { [weak self] in self?.setStage(key, .confirm) }) {
                    price.trailing.append(b)
                    card.controls["buy"] = b
                }
            } else if let c = WinCardKit.label(l.notEnoughTokens, .caption2, role: .tertiary, in: child, ctx: ctx) {
                price.trailing.append(c)
            }
            var lines = [price]
            if !m.hasActive {
                var hint = WinCardView.Line(top: 4)
                hint.flexible = WinCardKit.label(m.lockedHint, .caption2, role: .tertiary, wraps: true, in: child, ctx: ctx)
                lines.append(hint)
            }
            return lines
        case .confirm:
            var line = WinCardView.Line(top: 8)
            line.flexible = nil
            if let c = WinCardKit.label(m.confirmText, .caption2, role: .secondary, wraps: true, maxLines: 2, in: child, ctx: ctx) { line.leading.append(c) }
            let buy = WinCardKit.pill(l.buy, .prominent, in: child, ctx: ctx) { [weak self] in
                guard let self else { return }
                if m.isHighValue { self.setStage(key, .preciousConfirm) } else { self.commitEgg(m.tier, key: key) }
            }
            let cancel = WinCardKit.pill(l.cancel, .borderless, in: child, ctx: ctx) { [weak self] in self?.setStage(key, .idle) }
            for (name, c) in [("confirm", buy), ("cancel", cancel)] { if let c { line.trailing.append(c); card.controls[name] = c } }
            return [line]
        case .preciousConfirm:
            var line = WinCardView.Line(top: 8)
            if let c = WinCardKit.label(m.warningText, .caption2, weight: 600, role: .warning, wraps: true, maxLines: 2, in: child, ctx: ctx) { line.leading.append(c) }
            let discard = WinCardKit.pill(m.discardTitle, .prominent, in: child, ctx: ctx) { [weak self] in self?.commitEgg(m.tier, key: key) }
            let cancel = WinCardKit.pill(l.cancel, .borderless, in: child, ctx: ctx) { [weak self] in self?.setStage(key, .idle) }
            for (name, c) in [("confirm", discard), ("cancel", cancel)] { if let c { line.trailing.append(c); card.controls[name] = c } }
            return [line]
        }
    }

    func setStage(_ key: String, _ stage: EggStage) {
        eggStages[key] = stage
        schedule()
    }

    /// `EggCard.commit`: the new egg, then Home to see it.
    func commitEgg(_ tier: Rarity?, key: String) {
        eggStages[key] = .idle
        if buyEgg(tier) { host.open(.home) } else { schedule() }
    }
}
#endif
