import Foundation

/// The Bag tab as plain values (stage 7 Task 19; the Mac's `BagView` and `ItemCard` in `UI/BagView.swift`, upstream-owned
/// SwiftUI). As the Shop's model: the page keeps the candy stepper and the confirm flag, `BagCardRules` holds the rules the Mac
/// derives from them (verbatim bodies, driven against copies of the Mac's by `PopoverShopBagEquivalenceTests+Mac`).

/// What the candy preview says for a chosen count: up to two lines under the title (`ItemCard.body`).
struct BagCandyPreview: Equatable, Sendable {
    enum Line: Equatable, Sendable {
        /// `l.candyGraduates` (secondary).
        case graduates(String)
        /// `l.candyDiscardedXP` (orange).
        case discarded(String)
        /// `l.candyCarryoverXP` (secondary).
        case carryover(String)
    }
    var lines: [Line]
}

/// `ItemCard`: one owned item (the candy stepper and the confirm flag are the page's state).
struct BagCardModel: Equatable, Sendable {
    var kind: ItemKind
    var name: String
    var description: String
    var count: Int
    var isPassive: Bool
    /// The stepper beside the name (`kind == .rareCandy && store.canUseRareCandy`).
    var showsCandyStepper: Bool
    var maxCandyCount: Int
    var canUse: Bool
    /// The effect line of a passive item (`l.shinyCharmEffectHint`).
    var passiveHint: String
    /// Why it cannot be used now (`l.useAfterHatch` for an egg, else `l.useNeedsPokemon`).
    var unusableReason: String
    /// "Use X on <current>?".
    var confirmText: String
}

struct BagPageModel: Equatable, Sendable {
    var emptyTitle: String
    var shopTitle: String
    var cards: [BagCardModel]
    var isEmpty: Bool { cards.isEmpty }

    @MainActor
    static func make(store: CompanionStore) -> BagPageModel {
        let l = store.l
        let cards = store.ownedItems.map { item -> BagCardModel in
            let kind = item.kind
            return BagCardModel(
                kind: kind, name: l.itemName(kind), description: l.itemDescription(kind), count: item.count, isPassive: kind.isPassive,
                showsCandyStepper: kind == .rareCandy && store.canUseRareCandy, maxCandyCount: max(1, store.maxRareCandyUseCount),
                canUse: BagCardRules.canUse(store: store, kind: kind), passiveHint: l.shinyCharmEffectHint,
                unusableReason: store.isEgg ? l.useAfterHatch : l.useNeedsPokemon, confirmText: l.useOnCurrent(store.displayName))
        }
        return BagPageModel(emptyTitle: l.bagEmptyTitle, shopTitle: l.shop, cards: cards)
    }

    /// The candy preview for `selectedCount` candies (`ItemCard.body`: only for the rare candy, only with a plan).
    @MainActor
    static func candyPreview(store: CompanionStore, kind: ItemKind, selectedCount: Int) -> BagCandyPreview? {
        let l = store.l
        guard kind == .rareCandy, let preview = store.planRareCandyUse(count: selectedCount) else { return nil }
        var lines: [BagCandyPreview.Line] = []
        if preview.graduates { lines.append(.graduates(l.candyGraduates)) }
        if preview.discardedXP > 0 {
            lines.append(.discarded(l.candyDiscardedXP(TokenFormatter.compact(preview.discardedXP))))
        } else if preview.evolves && !preview.graduates {
            lines.append(.carryover(l.candyCarryoverXP(TokenFormatter.compact(preview.carryoverXP))))
        }
        return BagCandyPreview(lines: lines)
    }
}

enum BagCardRules {
    /// `ItemCard.selectedCandyCount`.
    @MainActor static func selectedCandyCount(store: CompanionStore, candyCount: Int) -> Int { min(candyCount, max(1, store.maxRareCandyUseCount)) }
    /// `ItemCard.canUse`.
    @MainActor static func canUse(store: CompanionStore, kind: ItemKind) -> Bool {
        switch kind {
        case .rareCandy: return store.canUseRareCandy
        case .mint:      return store.canUseMint
        case .shinyCharm: return false   // a passive item has no use
        }
    }
    /// `ItemCard.effectHint`.
    static func effectHint(l: L, kind: ItemKind, selectedCandyCount: Int) -> String {
        switch kind {
        case .rareCandy: return "+\(TokenFormatter.compact(selectedCandyCount * RareCandy.xp)) XP"
        case .mint:      return l.mintEffectHint
        case .shinyCharm: return l.shinyCharmEffectHint
        }
    }
    /// The Use button in the confirm row (`ItemCard.useControls`).
    static func confirmButtonTitle(l: L, kind: ItemKind, selectedCandyCount: Int) -> String {
        kind == .rareCandy ? "\(l.use) ×\(selectedCandyCount)" : l.use
    }
    /// `ItemCard.performUse`.
    @MainActor static func performUse(store: CompanionStore, kind: ItemKind, selectedCandyCount: Int) {
        switch kind {
        case .rareCandy: _ = store.useRareCandy(count: selectedCandyCount)
        case .mint:      _ = store.useMint()
        case .shinyCharm: break   // a passive item has no use
        }
    }
}
