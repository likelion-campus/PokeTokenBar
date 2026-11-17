import Foundation

/// The Shop tab as plain values (stage 7 Task 19; the Mac's `ShopView`, `ShopItemCard` and `EggCard` in `UI/ShopView.swift`,
/// upstream-owned SwiftUI). One function per Mac member reads the same `CompanionStore` members the Mac view reads; what a card
/// holds in `@State` (the quantity and the confirm stage) stays the page's, and the rules that turn that state into texts are the
/// statics of `ShopCardRules`, written as the Mac's private members and driven against verbatim copies of them by
/// `PopoverShopBagEquivalenceTests+Mac` (twins.txt holds the Mac bodies to those copies).

/// `ShopView.walletHeader`: the caption, the spendable tokens (24 pt bold) and the hint.
struct ShopWalletModel: Equatable, Sendable {
    var caption: String
    var tokens: String
    var hint: String
}

/// `ShopItemCard`: one item for sale (the quantity stepper and the confirm stage are the page's state).
struct ShopItemCardModel: Equatable, Sendable {
    var kind: ItemKind
    var name: String
    var description: String
    /// The owned count next to the name (a consumable you own); nil for passive items and for none owned.
    var ownedText: String?
    var isPassive: Bool
    /// A passive item you own (the Mac shows "owned" in place of the buy controls).
    var ownedAlready: Bool
    var price: Int
    var maxQuantity: Int
    var showsQuantity: Bool
    var canBuy: Bool
}

/// `EggCard`: one egg for sale. `tier` is the guarantee floor (nil = the plain egg).
struct ShopEggCardModel: Equatable, Sendable {
    var tier: Rarity?
    var name: String
    var description: String
    /// The tier badge (`Badge(l.rarityLabel(tier).uppercased(), tint: .rarity(tier))`).
    var badge: String?
    /// The line under the description, only with something to release.
    var releaseNote: String?
    var price: Int
    var hasActive: Bool
    var canBuy: Bool
    var lockedHint: String
    /// Stage `.confirm`: "Release X for a new egg?".
    var confirmText: String
    var isHighValue: Bool
    /// Stage `.preciousConfirm`: the orange warning and the button that discards.
    var warningText: String
    var discardTitle: String
}

enum ShopEntryModel: Equatable, Sendable {
    case item(ShopItemCardModel)
    case egg(ShopEggCardModel)
}

struct ShopPageModel: Equatable, Sendable {
    var wallet: ShopWalletModel
    var entries: [ShopEntryModel]

    @MainActor
    static func make(store: CompanionStore) -> ShopPageModel {
        let l = store.l
        let wallet = ShopWalletModel(caption: l.spendableTokens, tokens: TokenFormatter.compact(store.availableTokens), hint: l.shopHint)
        let entries = store.shopEntries.map { entry -> ShopEntryModel in
            switch entry {
            case .item(let kind): .item(item(store: store, kind: kind))
            case .egg(let tier): .egg(egg(store: store, tier: tier))
            }
        }
        return ShopPageModel(wallet: wallet, entries: entries)
    }

    @MainActor
    static func item(store: CompanionStore, kind: ItemKind) -> ShopItemCardModel {
        let l = store.l
        let owned = store.itemCount(kind)
        return ShopItemCardModel(
            kind: kind, name: l.itemName(kind), description: l.itemDescription(kind),
            ownedText: owned > 0 && !kind.isPassive ? l.ownedCount(owned) : nil,
            isPassive: kind.isPassive, ownedAlready: kind.isPassive && owned > 0,
            price: ShopCardRules.price(store: store, kind: kind), maxQuantity: ShopCardRules.maxQuantity(store: store, kind: kind),
            showsQuantity: ShopCardRules.showsQuantity(store: store, kind: kind), canBuy: store.canBuy(kind))
    }

    @MainActor
    static func egg(store: CompanionStore, tier: Rarity?) -> ShopEggCardModel {
        let l = store.l
        return ShopEggCardModel(
            tier: tier, name: l.eggName(tier), description: l.eggDescription(tier),
            badge: tier.map { l.rarityLabel($0).uppercased() },
            releaseNote: store.hasActive ? l.eggReleaseNote : nil,
            price: store.price(of: .egg(tier)), hasActive: store.hasActive, canBuy: store.canBuyEgg(tier),
            lockedHint: l.eggShopLockedHint, confirmText: l.eggConfirm(store.displayName, l.eggName(tier)),
            isHighValue: store.isHighValueCompanion,
            warningText: store.rarity == .legendary ? l.freshEggLegendaryWarning : l.freshEggShinyWarning,
            discardTitle: store.currentIsShiny && store.rarity != .legendary ? l.freshEggDiscardShiny : l.freshEggDiscardValuable)
    }
}

/// The rules the Mac's cards derive from their `@State` (verbatim bodies of the private members they twin).
enum ShopCardRules {
    /// `ShopItemCard.price`.
    @MainActor static func price(store: CompanionStore, kind: ItemKind) -> Int { store.price(of: kind) ?? 0 }
    /// `ShopItemCard.maxQuantity`.
    @MainActor static func maxQuantity(store: CompanionStore, kind: ItemKind) -> Int { max(1, store.maxBuyCount(kind)) }
    /// `ShopItemCard.selectedQuantity`: the chosen count never exceeds the limit (the balance may have dropped).
    static func selectedQuantity(quantity: Int, maxQuantity: Int) -> Int { min(quantity, maxQuantity) }
    /// `ShopItemCard.showsQuantity`: only a consumable you can afford twice shows the stepper.
    @MainActor static func showsQuantity(store: CompanionStore, kind: ItemKind) -> Bool { !kind.isPassive && store.maxBuyCount(kind) > 1 }
    /// `ShopItemCard.quantityName`.
    static func quantityName(l: L, kind: ItemKind, selectedQuantity: Int) -> String {
        selectedQuantity > 1 ? "\(l.itemName(kind)) ×\(selectedQuantity)" : l.itemName(kind)
    }
    /// The Buy button in the confirm row (`ShopItemCard.buyControls`).
    static func confirmButtonTitle(l: L, selectedQuantity: Int) -> String {
        selectedQuantity > 1 ? "\(l.buy) ×\(selectedQuantity)" : l.buy
    }
    /// The price line before the confirm (`ShopItemCard.buyControls`): the total for the chosen quantity.
    static func priceLine(l: L, price: Int, selectedQuantity: Int) -> String {
        "\(l.shopPriceLabel) \(TokenFormatter.compact(price * selectedQuantity))"
    }
    /// The egg's price line (`EggCard.controls`).
    static func eggPriceLine(l: L, price: Int) -> String { "\(l.shopPriceLabel) \(TokenFormatter.compact(price))" }
}
