import XCTest
@testable import PokeTokenBar

/// The private members of the Mac's `ShopItemCard` and `ItemCard` (`UI/ShopView.swift`, `UI/BagView.swift`) copied verbatim, with
/// the card's `@State` as plain properties (stage 7 Task 19). `twins.txt` holds each body to the Mac's, so a Mac change fails the
/// parity scan until the copy has it too; the tests below then drive the copies and the shared models over the same stores.
@MainActor
struct MacShopBagOracle {
    let store: CompanionStore
    let kind: ItemKind
    var quantity = 1
    var candyCount = 1

    var price: Int { store.price(of: kind) ?? 0 }
    var maxQuantity: Int { max(1, store.maxBuyCount(kind)) }
    var selectedQuantity: Int { min(quantity, maxQuantity) }
    var showsQuantity: Bool { !kind.isPassive && store.maxBuyCount(kind) > 1 }

    func quantityName(_ l: L) -> String {
        selectedQuantity > 1 ? "\(l.itemName(kind)) ×\(selectedQuantity)" : l.itemName(kind)
    }

    var selectedCandyCount: Int { min(candyCount, max(1, store.maxRareCandyUseCount)) }

    var canUse: Bool {
        switch kind {
        case .rareCandy: return store.canUseRareCandy
        case .mint:      return store.canUseMint
        case .shinyCharm: return false   // 보유형 — 사용 개념 없음(상시 효과)
        }
    }

    func effectHint(_ l: L) -> String {
        switch kind {
        case .rareCandy: return "+\(TokenFormatter.compact(selectedCandyCount * RareCandy.xp)) XP"
        case .mint:      return l.mintEffectHint
        case .shinyCharm: return l.shinyCharmEffectHint
        }
    }

    func performUse() {
        switch kind {
        case .rareCandy: _ = store.useRareCandy(count: selectedCandyCount)
        case .mint:      _ = store.useMint()
        case .shinyCharm: break   // 보유형 — 사용 동작 없음
        }
    }
}

/// The shared Shop and Bag rules against the Mac's own, over wallets, inventories and companions (stage 7 Task 19).
@MainActor
final class PopoverShopBagEquivalenceTests: XCTestCase {
    private func corpus() -> [CompanionStore] {
        var stores: [CompanionStore] = []
        let candy = RareCandy.price
        for used in [0, candy - 1, candy, candy * 2, candy * 3 + 7, candy * 40, 4_000_000_000_000] {
            for inventory in [[ItemKind: Int](), [.rareCandy: 3], [.mint: 2], [.shinyCharm: 1, .rareCandy: 1, .mint: 1]] {
                for active in [false, true] {
                    stores.append(ShopBagFixtures.store(used: used, spent: used / 3, inventory: inventory, active: active))
                }
            }
        }
        return stores
    }

    func testShopRulesMatchTheMacCard() async {
        var checked = 0
        for store in corpus() {
            for kind in ItemKind.allCases {
                for quantity in [1, 2, 5, 99] {
                    let mac = MacShopBagOracle(store: store, kind: kind, quantity: quantity)
                    XCTAssertEqual(ShopCardRules.price(store: store, kind: kind), mac.price)
                    XCTAssertEqual(ShopCardRules.maxQuantity(store: store, kind: kind), mac.maxQuantity)
                    XCTAssertEqual(ShopCardRules.selectedQuantity(quantity: quantity, maxQuantity: mac.maxQuantity), mac.selectedQuantity)
                    XCTAssertEqual(ShopCardRules.showsQuantity(store: store, kind: kind), mac.showsQuantity)
                    for language in AppLanguage.allCases {
                        let l = L(language)
                        XCTAssertEqual(ShopCardRules.quantityName(l: l, kind: kind, selectedQuantity: mac.selectedQuantity), mac.quantityName(l))
                    }
                    let model = ShopPageModel.item(store: store, kind: kind)
                    XCTAssertEqual(model.price, mac.price)
                    XCTAssertEqual(model.maxQuantity, mac.maxQuantity)
                    XCTAssertEqual(model.showsQuantity, mac.showsQuantity)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 600)
    }

    func testBagRulesMatchTheMacCard() async {
        for store in corpus() {
            for kind in ItemKind.allCases {
                for candyCount in [1, 2, 7, 500] {
                    let mac = MacShopBagOracle(store: store, kind: kind, candyCount: candyCount)
                    XCTAssertEqual(BagCardRules.selectedCandyCount(store: store, candyCount: candyCount), mac.selectedCandyCount)
                    XCTAssertEqual(BagCardRules.canUse(store: store, kind: kind), mac.canUse)
                    for language in AppLanguage.allCases {
                        let l = L(language)
                        XCTAssertEqual(BagCardRules.effectHint(l: l, kind: kind, selectedCandyCount: mac.selectedCandyCount), mac.effectHint(l))
                    }
                }
            }
        }
    }

    /// `performUse` does what the Mac's does: the same stock and the same growth afterwards.
    func testUseDoesWhatTheMacDoes() async {
        for kind in [ItemKind.mint, .rareCandy, .shinyCharm] {
            let a = ShopBagFixtures.store(used: 0, inventory: [kind: 3], active: true)
            let b = ShopBagFixtures.store(used: 0, inventory: [kind: 3], active: true)
            MacShopBagOracle(store: a, kind: kind, candyCount: 2).performUse()
            BagCardRules.performUse(store: b, kind: kind, selectedCandyCount: BagCardRules.selectedCandyCount(store: b, candyCount: 2))
            XCTAssertEqual(a.itemCount(kind), b.itemCount(kind), "\(kind)")
            XCTAssertEqual(a.state.active?.usedAtStage, b.state.active?.usedAtStage, "\(kind)")
        }
    }

    func testBagCardsMatchTheMacOwnedItems() async {
        for store in corpus() {
            let cards = BagPageModel.make(store: store).cards
            XCTAssertEqual(cards.map(\.kind), store.ownedItems.map(\.kind))
            XCTAssertEqual(cards.map(\.count), store.ownedItems.map(\.count))
            for card in cards {
                let mac = MacShopBagOracle(store: store, kind: card.kind)
                XCTAssertEqual(card.canUse, mac.canUse)
                XCTAssertEqual(card.showsCandyStepper, card.kind == .rareCandy && store.canUseRareCandy)
                XCTAssertEqual(card.maxCandyCount, max(1, store.maxRareCandyUseCount))
            }
        }
    }
}
