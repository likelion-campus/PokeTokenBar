#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The Bag tab (stage 7 Task 19; the Mac's `BagView`): an empty bag shows the animated Snorlax, the title and a Shop button; else
/// one card per owned item (icon, name, count, the rare candy's stepper, description, the candy preview, then Use with its inline
/// confirm, the passive item's effect, or the reason it cannot be used). Texts, counts, limits and enable states come from
/// `BagPageModel` and `BagCardRules`; this file places them and keeps what the Mac's `ItemCard` keeps in `@State`: the candy count
/// and the confirm flag. Using an item goes to Home to see it (the Mac's `nav.tab = .home`).
///
/// Observation, input and sprites work as the Shop page's (`WinShopPage`): a card is made again only when its model or state
/// changed, input is applied on the next main-queue turn, no timer.
@MainActor final class WinBagPage: WinTabContent {
    let host: WinTabHost
    var itemSource: any PopoverItemSource = SpriteStore.shared
    var makeSprites: () -> WinSpriteAnimator? = { WinSpriteAnimator() }
    /// What Use does (the selftest records instead of using).
    var performUse: (ItemKind, Int) -> Void
    /// A fixed model instead of the store's (the selftest's sample states); nothing is observed then.
    var modelOverride: (() -> Snapshot)?

    struct ItemState: Equatable { var candyCount = 1; var confirming = false }

    /// What the page shows: the model, the candy count in force and its preview (read inside the observation).
    struct Snapshot: Equatable {
        var model: BagPageModel
        var selectedCandy: Int
        var preview: BagCandyPreview?
    }

    final class Card {
        let section: WinSectionCard
        var controls: [String: WinControl] = [:]
        var rendered: BagCardModel?
        var renderedState = ""
        var renderedPreview: BagCandyPreview?
        init(section: WinSectionCard) { self.section = section }
    }

    private(set) var last: Snapshot?
    private(set) var itemStates: [ItemKind: ItemState] = [:]
    private(set) var cards: [Card] = []
    private var emptySection: WinSectionCard?
    private var emptyShown = false
    private var epoch = 0
    private var flushScheduled = false
    private(set) var isDestroyed = false
    private(set) var renders = 0, emptyRenders = 0
    /// The empty state's Shop button, for the selftest.
    private(set) var shopButton: WinControl?

    init(host: WinTabHost) {
        self.host = host
        let companion = host.companion
        performUse = { BagCardRules.performUse(store: companion, kind: $0, selectedCandyCount: $1) }
    }

    // MARK: WinTabContent

    func build() {
        isDestroyed = false
        epoch += 1
        host.stack.useMetrics(.bagScroll)  // `VStack(spacing: 8)` with the page's 14 pt sides
        emptySection = host.stack.addSection(nil, card: false)
        observe()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        cards = []
        emptySection = nil
        shopButton = nil
        last = nil
    }

    // MARK: observing

    private var candyCount: Int { itemStates[.rareCandy]?.candyCount ?? 1 }

    /// The page's snapshot of `store` (the observation's closure).
    static func snapshot(store: CompanionStore, candyCount: Int) -> Snapshot {
        let selected = BagCardRules.selectedCandyCount(store: store, candyCount: candyCount)
        return Snapshot(model: BagPageModel.make(store: store), selectedCandy: selected,
                        preview: BagPageModel.candyPreview(store: store, kind: .rareCandy, selectedCount: selected))
    }

    func observe() {
        guard !isDestroyed else { return }
        if let modelOverride {
            apply(modelOverride())
            return
        }
        let mine = epoch
        let companion = host.companion
        let count = candyCount
        let snapshot = withObservationTracking {
            Self.snapshot(store: companion, candyCount: count)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine else { return }
                self.observe()
            }
        }
        apply(snapshot)
    }

    private func stateKey(_ m: BagCardModel, selected: Int) -> String {
        let s = itemStates[m.kind] ?? ItemState()
        return "n\(m.kind == .rareCandy ? selected : 0) c\(s.confirming)"
    }

    func apply(_ snap: Snapshot) {
        guard !isDestroyed, let emptySection else { return }
        let m = snap.model
        // a candy count above the new limit is clamped (the Mac's `.onChange(of: store.maxRareCandyUseCount)`)
        if var s = itemStates[.rareCandy], s.candyCount != snap.selectedCandy, s.candyCount > snap.selectedCandy {
            s.candyCount = snap.selectedCandy
            itemStates[.rareCandy] = s
        }
        if m.isEmpty {
            if !emptyShown { renderEmpty(m, emptySection) }
            emptyShown = true
            emptySection.isVisible = true
            for card in cards where card.rendered != nil { card.section.removeRows(); card.section.isVisible = false; card.rendered = nil }
        } else {
            if emptyShown { emptySection.removeRows(); shopButton = nil; emptyShown = false }
            emptySection.isVisible = false
            while cards.count < m.cards.count { cards.append(Card(section: host.stack.addSection(nil, card: false))) }
            for (i, card) in cards.enumerated() {
                guard i < m.cards.count else {
                    if card.rendered != nil { card.section.removeRows(); card.section.isVisible = false; card.rendered = nil }
                    continue
                }
                let item = m.cards[i]
                let key = stateKey(item, selected: snap.selectedCandy)
                let preview = item.kind == .rareCandy ? snap.preview : nil
                if card.rendered != item || card.renderedState != key || card.renderedPreview != preview {
                    renderCard(card, item, selected: snap.selectedCandy, preview: preview, key: key)
                }
            }
        }
        last = snap
    }

    /// The snapshot as it is now, without arming the observation again (an input changed a card's state).
    private func refresh() {
        guard !isDestroyed else { return }
        if let modelOverride { apply(modelOverride()) } else { apply(Self.snapshot(store: host.companion, candyCount: candyCount)) }
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

    // MARK: the empty bag

    /// `BagView.emptyState`: Snorlax (96 pt, animated), the title, the Shop button; 10 pt apart, 28 pt above and below.
    private func renderEmpty(_ m: BagPageModel, _ section: WinSectionCard) {
        section.removeRows()
        section.addStyledRow(label: nil, style: .full) { pane, ctx in
            WinCardView(parent: pane, ctx: ctx, tinted: false, padding: 0, verticalPadding: 28) { child, ctx, _ in
                var lines: [WinCardView.Line] = []
                if let sprite = WinCardKit.spriteBox(SpriteBoxPart(speciesID: 143, sprite: 96, animated: true), sprites: self.makeSprites(), in: child, ctx: ctx) {
                    lines.append(.init(center: [sprite]))
                }
                if let title = WinCardKit.label(m.emptyTitle, .callout, weight: 600, in: child, ctx: ctx) { lines.append(.init(center: [title], top: 10)) }
                if let shop = WinCardKit.bordered(m.shopTitle, in: child, ctx: ctx, { [weak self] in self?.host.open(.shop) }) {
                    self.shopButton = shop
                    lines.append(.init(center: [shop], top: 10))
                }
                return (nil, lines)
            }?.control
        }
        emptyRenders += 1
    }

    // MARK: cards

    private func renderCard(_ card: Card, _ m: BagCardModel, selected: Int, preview: BagCandyPreview?, key: String) {
        let kept = WinCardKit.focusedName(card.controls)
        card.section.removeRows()
        card.controls = [:]
        card.section.isVisible = true
        let l = host.l
        let state = itemStates[m.kind] ?? ItemState()
        let candy = m.kind == .rareCandy ? selected : 1
        card.section.addStyledRow(label: nil, style: .full) { pane, ctx in
            WinCardView(parent: pane, ctx: ctx) { child, ctx, _ in
                let icon = WinCardKit.itemIcon(m.kind, host: self.host, source: self.itemSource, in: child, ctx: ctx)
                var title = WinCardView.Line(top: 0, indent: true, gap: 6)
                if let name = WinCardKit.label(m.name, .callout, weight: 600, in: child, ctx: ctx) { title.leading.append(name) }
                if !m.isPassive, let count = WinCardKit.label("×\(m.count)", .caption, weight: 700, role: .secondary, in: child, ctx: ctx) { title.leading.append(count) }
                if m.showsCandyStepper {
                    if let name = WinControls.label(m.name, wraps: false, in: child, ctx: ctx) { title.unseen.append(name) }
                    let stepper = WinControls.stepper(range: 1...m.maxCandyCount, step: 1, value: candy, format: { "×\($0)" }, in: child, ctx: ctx)
                    stepper?.onValue = { [weak self] v in
                        guard let self else { return }
                        var s = self.itemStates[.rareCandy] ?? ItemState()
                        s.candyCount = v
                        self.itemStates[.rareCandy] = s
                        self.schedule()
                    }
                    if let stepper { title.trailing.append(stepper); card.controls["stepper"] = stepper }
                }
                var description = WinCardView.Line(top: 2, indent: true)
                description.flexible = WinCardKit.label(m.description, .caption, role: .secondary, wraps: true, in: child, ctx: ctx)
                var lines = [title, description]
                for line in preview?.lines ?? [] {
                    var row = WinCardView.Line(top: 8)
                    switch line {
                    case .graduates(let t): row.flexible = WinCardKit.label(t, .caption2, role: .secondary, wraps: true, in: child, ctx: ctx)
                    case .discarded(let t): row.flexible = WinCardKit.label(t, .caption2, role: .warning, wraps: true, in: child, ctx: ctx)
                    case .carryover(let t): row.flexible = WinCardKit.label(t, .caption2, role: .secondary, wraps: true, in: child, ctx: ctx)
                    }
                    lines.append(row)
                }
                lines.append(self.useLine(card, m, state: state, candy: candy, l: l, in: child, ctx: ctx))
                return (icon, lines)
            }?.control
        }
        card.rendered = m
        card.renderedState = key
        card.renderedPreview = preview
        renders += 1
        WinCardKit.restoreFocus(kept, card.controls)
    }

    /// `ItemCard.useControls`.
    private func useLine(_ card: Card, _ m: BagCardModel, state: ItemState, candy: Int, l: L, in child: HWND, ctx: WinUIContext) -> WinCardView.Line {
        var line = WinCardView.Line(top: 8)
        if m.isPassive {
            line.gap = 6
            line.glyph = ("checkmark.seal.fill", WinCardKit.colorRef(.systemGreen))
            if let c = WinCardKit.label(m.passiveHint, .caption2, weight: 600, color: .systemGreen, in: child, ctx: ctx) { line.leading.append(c) }
        } else if m.canUse {
            if state.confirming {
                if let c = WinCardKit.label(m.confirmText, .caption2, role: .secondary, in: child, ctx: ctx) { line.leading.append(c) }
                let use = WinCardKit.pill(BagCardRules.confirmButtonTitle(l: l, kind: m.kind, selectedCandyCount: candy), .prominent, in: child, ctx: ctx) { [weak self] in
                    self?.useNow(m.kind, candy: candy)
                }
                let cancel = WinCardKit.pill(l.cancel, .borderless, in: child, ctx: ctx) { [weak self] in self?.setConfirming(m.kind, false) }
                for (name, c) in [("confirm", use), ("cancel", cancel)] { if let c { line.trailing.append(c); card.controls[name] = c } }
            } else {
                if let c = WinCardKit.label(BagCardRules.effectHint(l: l, kind: m.kind, selectedCandyCount: candy), .caption2, role: .tertiary, in: child, ctx: ctx) {
                    line.leading.append(c)
                }
                if let b = WinCardKit.bordered(l.useItem, in: child, ctx: ctx, { [weak self] in self?.setConfirming(m.kind, true) }) {
                    line.trailing.append(b)
                    card.controls["use"] = b
                }
            }
        } else {
            // an egg, no Pokémon, or (the candy only) no evolution line yet: the reason, in place of the controls
            line.flexible = WinCardKit.label(m.unusableReason, .caption2, role: .tertiary, wraps: true, in: child, ctx: ctx)
        }
        return line
    }

    func setConfirming(_ kind: ItemKind, _ on: Bool) {
        var s = itemStates[kind] ?? ItemState()
        s.confirming = on
        itemStates[kind] = s
        schedule()
    }

    /// `ItemCard.useNow`: the item is used, then Home shows what happened.
    func useNow(_ kind: ItemKind, candy: Int) {
        var s = itemStates[kind] ?? ItemState()
        s.confirming = false
        itemStates[kind] = s
        performUse(kind, candy)
        host.open(.home)
    }
}
#endif
