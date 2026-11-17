import XCTest
@testable import PokeTokenBar

/// Seeded `CompanionStore`s for the Shop and Bag models: the wallet, the inventory and an optional active Pokémon are written
/// into a state file (the pattern of `ShopTests` and `MintTests`), so no growth path runs and nothing reads the network.
private struct ShopBagNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

enum ShopBagFixtures {
    @MainActor
    static func store(used: Int, spent: Int = 0, inventory: [ItemKind: Int] = [:], active: Bool = false, shiny: Bool = false,
                      rarity: String = "common", language: AppLanguage = .en) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shopbag-\(UUID().uuidString).json")
        let inv = inventory.isEmpty ? "" : ",\"inventory\":{" + inventory.map { "\"\($0.key.rawValue)\":\($0.value)" }.sorted().joined(separator: ",") + "}"
        let mon = active
            ? ",\"active\":{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":1000,\"rarity\":\"\(rarity)\",\"totalForms\":3,\"isShiny\":\(shiny),\"nature\":\"adamant\"}"
            : ""
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":\(spent),\"lastDate\":\"d\"\(mon),\"dex\":[],\"collectedFinals\":[]\(inv)}"
        try? Data(json.utf8).write(to: url)
        let store = CompanionStore(provider: ShopBagNoProvider(), clock: { Date(timeIntervalSince1970: 1_700_000_000) }, fileURL: url, rng: SeededRNG(seed: 3))
        store.setLanguage(language)
        return store
    }
}

/// The Shop's and Bag's models (stage 7 Task 19) over seeded stores; `PopoverShopBagEquivalenceTests+Mac` holds them to the Mac views.
@MainActor
final class PopoverShopBagTests: XCTestCase {
    func testWalletShowsTheSpendableTokensAndTheHint() async {
        let store = ShopBagFixtures.store(used: 1_500_000, spent: 500_000)
        let m = ShopPageModel.make(store: store)
        XCTAssertEqual(m.wallet.tokens, TokenFormatter.compact(1_000_000))
        XCTAssertEqual(m.wallet.caption, store.l.spendableTokens)
        XCTAssertEqual(m.wallet.hint, store.l.shopHint)
    }

    func testEntriesAreTheStoresInItsOrderWithEveryEgg() async {
        let store = ShopBagFixtures.store(used: 10)
        let m = ShopPageModel.make(store: store)
        XCTAssertEqual(m.entries.count, store.shopEntries.count)
        for (entry, model) in zip(store.shopEntries, m.entries) {
            switch (entry, model) {
            case (.item(let kind), .item(let card)): XCTAssertEqual(card.kind, kind)
            case (.egg(let tier), .egg(let card)): XCTAssertEqual(card.tier, tier)
            default: XCTFail("entry and card differ in kind")
            }
        }
        XCTAssertEqual(m.entries.filter { if case .egg = $0 { true } else { false } }.count, 3, "three eggs are always listed")
    }

    func testItemCardAffordabilityAndQuantityLimit() async {
        let price = RareCandy.price
        let poor = ShopPageModel.item(store: ShopBagFixtures.store(used: price - 1), kind: .rareCandy)
        XCTAssertFalse(poor.canBuy)
        XCTAssertEqual(poor.maxQuantity, 1, "at least one even when none is affordable (the Mac's max(1, …))")
        XCTAssertFalse(poor.showsQuantity)
        let exact = ShopPageModel.item(store: ShopBagFixtures.store(used: price), kind: .rareCandy)
        XCTAssertTrue(exact.canBuy)
        XCTAssertFalse(exact.showsQuantity, "the stepper needs room for two")
        let rich = ShopPageModel.item(store: ShopBagFixtures.store(used: price * 3 + 5), kind: .rareCandy)
        XCTAssertEqual(rich.maxQuantity, 3)
        XCTAssertTrue(rich.showsQuantity)
        XCTAssertEqual(rich.price, price)
    }

    func testOwnedCountOnlyForConsumables() async {
        let store = ShopBagFixtures.store(used: 0, inventory: [.rareCandy: 4, .shinyCharm: 1])
        XCTAssertEqual(ShopPageModel.item(store: store, kind: .rareCandy).ownedText, store.l.ownedCount(4))
        let charm = ShopPageModel.item(store: store, kind: .shinyCharm)
        XCTAssertNil(charm.ownedText, "a passive item shows no count")
        XCTAssertTrue(charm.ownedAlready)
        XCTAssertFalse(charm.canBuy, "a passive item is bought once")
        XCTAssertNil(ShopPageModel.item(store: ShopBagFixtures.store(used: 0), kind: .mint).ownedText)
    }

    func testEggCardAsAnEggAndWithAPokemon() async {
        let none = ShopPageModel.egg(store: ShopBagFixtures.store(used: 10_000_000_000), tier: nil)
        XCTAssertFalse(none.hasActive)
        XCTAssertFalse(none.canBuy, "an egg has nothing to release")
        XCTAssertNil(none.releaseNote)
        let mon = ShopBagFixtures.store(used: 10_000_000_000, active: true)
        let plain = ShopPageModel.egg(store: mon, tier: nil)
        XCTAssertTrue(plain.hasActive)
        XCTAssertTrue(plain.canBuy)
        XCTAssertEqual(plain.releaseNote, mon.l.eggReleaseNote)
        XCTAssertNil(plain.badge)
        let tiered = ShopPageModel.egg(store: mon, tier: .rare)
        XCTAssertEqual(tiered.badge, mon.l.rarityLabel(.rare).uppercased())
        XCTAssertEqual(tiered.name, mon.l.eggName(.rare))
        XCTAssertEqual(tiered.price, mon.price(of: .egg(.rare)))
    }

    func testPreciousWarningFollowsTheCompanion() async {
        let shiny = ShopBagFixtures.store(used: 1, active: true, shiny: true)
        let s = ShopPageModel.egg(store: shiny, tier: nil)
        XCTAssertTrue(s.isHighValue)
        XCTAssertEqual(s.warningText, shiny.l.freshEggShinyWarning)
        XCTAssertEqual(s.discardTitle, shiny.l.freshEggDiscardShiny)
        let legend = ShopBagFixtures.store(used: 1, active: true, shiny: true, rarity: "legendary")
        let g = ShopPageModel.egg(store: legend, tier: nil)
        XCTAssertEqual(g.warningText, legend.l.freshEggLegendaryWarning)
        XCTAssertEqual(g.discardTitle, legend.l.freshEggDiscardValuable)
        XCTAssertFalse(ShopPageModel.egg(store: ShopBagFixtures.store(used: 1, active: true), tier: nil).isHighValue)
    }

    func testQuantityRules() async {
        let l = L(.en)
        XCTAssertEqual(ShopCardRules.selectedQuantity(quantity: 5, maxQuantity: 3), 3)
        XCTAssertEqual(ShopCardRules.selectedQuantity(quantity: 2, maxQuantity: 3), 2)
        XCTAssertEqual(ShopCardRules.quantityName(l: l, kind: .rareCandy, selectedQuantity: 1), l.itemName(.rareCandy))
        XCTAssertEqual(ShopCardRules.quantityName(l: l, kind: .rareCandy, selectedQuantity: 3), "\(l.itemName(.rareCandy)) ×3")
        XCTAssertEqual(ShopCardRules.confirmButtonTitle(l: l, selectedQuantity: 1), l.buy)
        XCTAssertEqual(ShopCardRules.confirmButtonTitle(l: l, selectedQuantity: 2), "\(l.buy) ×2")
        XCTAssertEqual(ShopCardRules.priceLine(l: l, price: 1_000_000, selectedQuantity: 3), "\(l.shopPriceLabel) \(TokenFormatter.compact(3_000_000))")
    }

    func testBagIsEmptyWithoutItemsAndListsOwnedInOrder() async {
        let empty = BagPageModel.make(store: ShopBagFixtures.store(used: 0))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.emptyTitle, L(.en).bagEmptyTitle)
        XCTAssertEqual(empty.shopTitle, L(.en).shop)
        let store = ShopBagFixtures.store(used: 0, inventory: [.shinyCharm: 1, .mint: 2, .rareCandy: 3], active: true)
        let m = BagPageModel.make(store: store)
        XCTAssertEqual(m.cards.map(\.kind), ItemKind.allCases.filter { store.itemCount($0) > 0 })
        XCTAssertEqual(m.cards.first { $0.kind == .mint }?.count, 2)
        XCTAssertTrue(m.cards.first { $0.kind == .shinyCharm }?.isPassive == true)
    }

    func testUseRulesPerKindAndReasons() async {
        let egg = ShopBagFixtures.store(used: 0, inventory: [.mint: 1])
        let eggCard = BagPageModel.make(store: egg).cards[0]
        XCTAssertFalse(eggCard.canUse)
        XCTAssertEqual(eggCard.unusableReason, egg.l.useAfterHatch, "an egg (no Pokémon yet)")
        let mon = ShopBagFixtures.store(used: 0, inventory: [.mint: 1, .shinyCharm: 1], active: true)
        let cards = BagPageModel.make(store: mon).cards
        XCTAssertTrue(cards.first { $0.kind == .mint }?.canUse == true)
        XCTAssertFalse(cards.first { $0.kind == .shinyCharm }?.canUse ?? true, "a passive item has no use")
        XCTAssertEqual(BagCardRules.effectHint(l: mon.l, kind: .mint, selectedCandyCount: 1), mon.l.mintEffectHint)
        XCTAssertEqual(BagCardRules.effectHint(l: mon.l, kind: .rareCandy, selectedCandyCount: 3), "+\(TokenFormatter.compact(3 * RareCandy.xp)) XP")
        XCTAssertEqual(BagCardRules.confirmButtonTitle(l: mon.l, kind: .rareCandy, selectedCandyCount: 2), "\(mon.l.use) ×2")
        XCTAssertEqual(BagCardRules.confirmButtonTitle(l: mon.l, kind: .mint, selectedCandyCount: 2), mon.l.use)
    }

    func testCandyPreviewIsOnlyForTheCandyWithAPlan() async {
        let mon = ShopBagFixtures.store(used: 0, inventory: [.rareCandy: 5], active: true)
        XCTAssertNil(BagPageModel.candyPreview(store: mon, kind: .mint, selectedCount: 1), "only the rare candy previews")
        XCTAssertNil(BagPageModel.candyPreview(store: mon, kind: .rareCandy, selectedCount: 1), "no evolution line is loaded: no plan")
    }

    /// Every language gives every card a name and a description (the shop and the bag read the same `L`).
    func testEveryLanguageHasCardTexts() async {
        for language in AppLanguage.allCases {
            let store = ShopBagFixtures.store(used: 1_000_000_000, inventory: [.rareCandy: 1], active: true, language: language)
            for case .item(let card) in ShopPageModel.make(store: store).entries {
                XCTAssertFalse(card.name.isEmpty, "\(language) \(card.kind)")
                XCTAssertFalse(card.description.isEmpty, "\(language) \(card.kind)")
            }
        }
    }
}
