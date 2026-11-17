import Foundation

// MARK: Task 20 — the Collection tab's rules as values (the Mac's `CollectionView`, `DexGridView`, `DexSpeciesCell`,
// `DexEntryRow`, `DexSummaryHeader`, `RarityTally`, `RegionTally`, `DexScrollPager`; UI/CompanionView.swift)
//
// Every rule, text and number below is the Mac's: the filtering and sorting are the store's (`filteredDexSpecies`,
// `filteredDexEntries`), the texts are `L`'s. What a SwiftUI view body holds (which page, which cell is selected, what
// the footer says) is rebuilt here as values, once for both systems, so the Windows page only draws and routes input.

/// The Collection page's local state and the rules that move it: the `@State` of `CollectionView` and `DexGridView` with
/// their `onChange` handlers (a changed filter, sort or search starts on page 1 and clears the selected cell).
struct DexBrowserState: Equatable {
    var searchText = ""
    var shinyOnly = false
    var dexSort: CompanionStore.DexSortOption = .numberAsc
    var logSort: CompanionStore.CatchLogSortOption = .recentFirst
    var selectedRarity: Rarity?
    var selectedRegion: PokedexRegion?
    /// nil = the page that shows `returnAnchor` (Back from a detail page). Paging or filtering sets it.
    var page: Int?
    /// The species whose detail page was just closed. Only picks the page; nothing is selected.
    var returnAnchor: String?
    /// The selected cell: the footer shows its rarity.
    var selectedID: String?

    /// `onChange(of: …) { page = 0; selectedID = nil }`.
    private mutating func restart() {
        page = 0
        selectedID = nil
    }

    mutating func setSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        restart()
    }

    mutating func toggleShinyOnly() {
        shinyOnly.toggle()
        restart()
    }

    mutating func setDexSort(_ sort: CompanionStore.DexSortOption) {
        guard sort != dexSort else { return }
        dexSort = sort
        restart()
    }

    /// The log does not page, so its sort only matters to what it shows.
    mutating func setLogSort(_ sort: CompanionStore.CatchLogSortOption) {
        guard sort != logSort else { return }
        logSort = sort
        restart()
    }

    /// A rarity chip: the same rarity again clears the filter.
    mutating func toggleRarity(_ rarity: Rarity) {
        selectedRarity = (selectedRarity == rarity) ? nil : rarity
        restart()
    }

    mutating func toggleRegion(_ region: PokedexRegion) {
        selectedRegion = (selectedRegion == region) ? nil : region
        restart()
    }

    /// `CollectionView.resetFilters()`.
    mutating func resetFilters() {
        let before = self
        searchText = ""
        shinyOnly = false
        selectedRarity = nil
        selectedRegion = nil
        dexSort = .numberAsc
        logSort = .recentFirst
        if self != before { restart() }
    }

    /// The Mac's `isCustomSortActive` for the segment on screen.
    func isCustomSortActive(showingLog: Bool) -> Bool {
        showingLog ? logSort != .recentFirst : dexSort != .numberAsc
    }

    /// What starts the log over at its top (`.onChange` of the rarity, search, shiny-only and log sort).
    var logScrollKey: [String] {
        [selectedRarity?.rawValue ?? "", searchText, shinyOnly ? "1" : "0", logSort.rawValue]
    }
}

/// The Dex grid's page rules: the shared twin of `DexScrollPager`'s statics (twins.txt) and its wheel stepping on Windows
/// wheel deltas. The Mac's `step` reads an `NSEvent` phase; a Windows wheel message carries none, so the phase-less
/// branch of the Mac's rule is what runs here (`WinDexWheel` feeds it).
enum DexPaging {
    static let columns = 4
    static let rows = 4
    static let pageSize = columns * rows      // 16
    static let spacing: CGFloat = 4

    /// Accumulated touchpad distance before a gesture flips the page (the Mac's `preciseThreshold`).
    static let preciseThreshold: CGFloat = 24

    static func pageAfterScroll(current: Int, pageCount: Int, step: Int) -> Int {
        min(max(0, current + step), max(0, pageCount - 1))
    }

    /// The page that shows `id` — where Back from a detail page lands. 0 when `id` is nil or
    /// filtered out, the same page a fresh grid opens on.
    static func page(containing id: String?, in ids: [String], pageSize: Int) -> Int {
        guard let id, let index = ids.firstIndex(of: id) else { return 0 }
        return index / pageSize
    }

    static func direction(_ deltaY: CGFloat) -> Int {
        deltaY < 0 ? 1 : (deltaY > 0 ? -1 : 0)
    }

    /// `current` clamped to the pages there are, `nil` meaning the page of `returnAnchor`.
    static func currentPage(_ page: Int?, anchor: String?, ids: [String], pageCount: Int) -> Int {
        min(page ?? Self.page(containing: anchor, in: ids, pageSize: pageSize), pageCount - 1)
    }
}

/// A wheel gesture as single page steps (the phase-less branch of `DexScrollPager.step`): a notch is one page; a touchpad's
/// small deltas add up to `preciseThreshold` points and then flip once.
struct DexWheelPager: Equatable {
    private var accumulated: CGFloat = 0

    /// +1 = next page, -1 = previous page, 0 = no change. `deltaY` is in points, negative = move the content up (what
    /// comes next), as `scrollingDeltaY`.
    mutating func step(deltaY: CGFloat, precise: Bool) -> Int {
        guard precise else { return DexPaging.direction(deltaY) }
        accumulated += deltaY
        guard abs(accumulated) >= DexPaging.preciseThreshold else { return 0 }
        let result = DexPaging.direction(accumulated)
        accumulated = 0
        return result
    }

    mutating func reset() { accumulated = 0 }
}

// MARK: the Pokédex grid

/// One cell of the grid (`DexSpeciesCell`).
struct DexCellModel: Equatable {
    var collectionID: String
    var number: Int
    var name: String
    /// The line under the sprite: the name, with the collected forms of a species that has some ("Unown 3/28").
    var label: String
    var rarity: Rarity
    var isShiny: Bool
    var isRaising: Bool
    var isRepresentative: Bool
    var isSelected: Bool
    /// Collected forms, nil for species with a single appearance.
    var formCount: Int?
    var formTotal: Int
    /// The sprite is the shiny one (species without forms that were caught shiny).
    var spriteShiny: Bool
    /// The tooltip and the accessible name: the same sentence.
    var tooltip: String
}

struct DexMedalModel: Equatable {
    var emoji: String
    var help: String
}

struct DexRegionChipModel: Equatable {
    var region: PokedexRegion
    var label: String
    var owned: Int
    var total: Int
    var isComplete: Bool
    var isShinyComplete: Bool
    var isSelected: Bool
    /// "Kanto 87/151" tooltip; the chip is disabled while nothing is owned.
    var help: String
    var isEnabled: Bool { owned > 0 }
}

struct DexRarityChipModel: Equatable {
    var rarity: Rarity
    var label: String
    var count: Int
    var isSelected: Bool
    var help: String
    var isEnabled: Bool { count > 0 }
}

struct DexFooterModel: Equatable {
    /// "#25 Pikachu · Common" for the selected cell, with the representative button for a species without forms.
    struct Selection: Equatable {
        var text: String
        var collectionID: String
        var speciesID: Int
        /// nil: a species with forms (the representative is picked on its detail page).
        var representativeTitle: String?
        var isRepresentative: Bool
    }
    var selection: Selection?
    /// "n / m" (only with more than one page).
    var pageText: String?
    var pageLabel: String?
    var current: Int
    var pageCount: Int
    var previousLabel: String
    var nextLabel: String
}

struct DexBodyModel: Equatable {
    var title: String
    var total: String
    var medals: [DexMedalModel]
    var regions: [DexRegionChipModel]
    var rarities: [DexRarityChipModel]
    var cells: [DexCellModel]
    /// Nothing passes the filters: the grid is replaced by the no-results state.
    var isEmpty: Bool
    var noResults: String
    var clearFilters: String
    var footer: DexFooterModel
    /// The collection IDs of every visible species, in order (the page of an anchor, the keyboard's reach).
    var visibleIDs: [String]

    @MainActor static func make(store: CompanionStore, state: DexBrowserState) -> DexBodyModel {
        let l = store.l
        let all = store.dexSpecies
        let visible = store.filteredDexSpecies(query: state.searchText, rarity: state.selectedRarity, shinyOnly: state.shinyOnly,
                                               region: state.selectedRegion, sort: state.dexSort)
        let pageCount = max(1, (visible.count + DexPaging.pageSize - 1) / DexPaging.pageSize)
        let ids = visible.map(\.collectionID)
        let current = DexPaging.currentPage(state.page, anchor: state.returnAnchor, ids: ids, pageCount: pageCount)
        let slice = Array(visible.dropFirst(current * DexPaging.pageSize).prefix(DexPaging.pageSize))
        let formCounts = Dictionary(uniqueKeysWithValues: slice.lazy
            .filter { PokemonForm.hasForms(speciesID: $0.id) }
            .map { ($0.id, store.state.collectedForms(speciesID: $0.id).count) })
        let cells = slice.map { sp -> DexCellModel in
            let formCount = formCounts[sp.id]
            let formTotal = PokemonForm.forms(speciesID: sp.id).count
            let isRepresentative = store.isRepresentative(sp)
            return DexCellModel(collectionID: sp.collectionID, number: sp.id, name: sp.name,
                                label: formCount.map { "\(sp.name) \($0)/\(formTotal)" } ?? sp.name,
                                rarity: sp.rarity, isShiny: sp.isShiny, isRaising: sp.isRaising,
                                isRepresentative: isRepresentative, isSelected: state.selectedID == sp.collectionID,
                                formCount: formCount, formTotal: formTotal, spriteShiny: formCount == nil && sp.isShiny,
                                tooltip: Self.tooltip(species: sp, formCount: formCount, formTotal: formTotal,
                                                      isRepresentative: isRepresentative, store: store))
        }
        let badges = store.earnedDexBadges.filter {
            switch $0 { case .region, .regionShiny: return false; default: return true }
        }
        var selection: DexFooterModel.Selection?
        if let sel = slice.first(where: { $0.collectionID == state.selectedID }) {
            let isRepresentative = store.isRepresentative(sel)
            let hasForms = PokemonForm.hasForms(speciesID: sel.id)
            selection = .init(text: "#\(sel.id) \(sel.name) · \(l.rarityLabel(sel.rarity))", collectionID: sel.collectionID, speciesID: sel.id,
                              representativeTitle: hasForms ? nil : (isRepresentative ? l.representativeFollowCurrent : l.representativeSet),
                              isRepresentative: isRepresentative)
        }
        return DexBodyModel(
            title: l.dexTitle, total: l.dexSpeciesTotal(all.count),
            medals: badges.map { DexMedalModel(emoji: Self.medalEmoji($0), help: l.dexBadgeLabel($0)) },
            regions: store.dexCompletions.map { c in
                DexRegionChipModel(region: c.region, label: l.regionName(c.region), owned: c.owned, total: c.total, isComplete: c.isComplete,
                                   isShinyComplete: c.isShinyComplete, isSelected: state.selectedRegion == c.region,
                                   help: l.dexRegionProgressLabel(c.region, owned: c.owned, total: c.total))
            },
            rarities: Self.rarityOrder.map { r in
                DexRarityChipModel(rarity: r, label: l.rarityLabel(r), count: all.lazy.filter { $0.rarity == r }.count,
                                   isSelected: state.selectedRarity == r, help: l.dexFilterHint)
            },
            cells: cells, isEmpty: visible.isEmpty, noResults: l.noSearchResults, clearFilters: l.clearFilters,
            footer: DexFooterModel(selection: selection, pageText: pageCount > 1 ? "\(current + 1) / \(pageCount)" : nil,
                                   pageLabel: pageCount > 1 ? l.dexPageLabel(current + 1, pageCount) : nil, current: current,
                                   pageCount: pageCount, previousLabel: l.dexPagePrev, nextLabel: l.dexPageNext),
            visibleIDs: ids)
    }

    /// The chips' order: the Mac's file-level `rarityDisplayOrder` (DexBrowserTests holds the two together).
    static let rarityOrder: [Rarity] = [.legendary, .rare, .uncommon, .common]

    /// 전국·안농 등 획득한 완성 메달의 이모지. Twin of `DexGridView.medalEmoji` (twins.txt).
    static func medalEmoji(_ badge: DexBadge) -> String {
        switch badge {
        case .region: return "🏅"
        case .regionShiny: return "✨"
        case .unown: return "🔤"
        case .national: return "🌍"
        case .nationalShiny: return "✨"
        }
    }

    /// 툴팁과 접근성 라벨이 같은 문장을 쓴다. Twin of `DexSpeciesCell.tooltip` (twins.txt).
    @MainActor static func tooltip(species: CompanionStore.DexSpecies, formCount: Int?, formTotal: Int, isRepresentative: Bool,
                        store: CompanionStore) -> String {
        var parts = ["#\(species.id) \(species.name)", store.l.rarityLabel(species.rarity)]
        if let formCount { parts.append(store.l.formsCollected(formCount, of: formTotal)) }
        if species.isShiny { parts.append(store.l.dexShinyLabel) }
        if species.isRaising { parts.append(store.l.dexRaising) }
        if isRepresentative { parts.append(store.l.representativeBadge) }
        return parts.joined(separator: " · ")
    }
}

// MARK: the catch log

/// One row of the log (`DexEntryRow`).
struct DexLogRowModel: Equatable {
    struct Node: Equatable {
        var speciesID: Int
        /// The name under the sprite (the stored one, "…" while a pre-names save is resolved).
        var name: String
        /// The dex cell it opens (`dexLinkTargets`); nil: not in the dex, not a link.
        var link: String?
    }
    var id: String
    var rarity: Rarity
    var rarityText: String
    var isRaising: Bool
    var isReleased: Bool
    var raisingText: String
    var releasedText: String
    var isShiny: Bool
    var shinyLabel: String
    var nature: String?
    var nodes: [Node]
    var form: PokemonForm?
    var caughtAt: Date?
    var openHint: String
}

struct DexLogModel: Equatable {
    var title: String
    var total: String
    var rarities: [DexRarityChipModel]
    var rows: [DexLogRowModel]
    var noResults: String
    var clearFilters: String

    /// `resolved` holds the names of entries whose save has none stored (filled in asynchronously, as the Mac's `.task`).
    @MainActor static func make(store: CompanionStore, state: DexBrowserState, resolved: [String: [Int: String]] = [:]) -> DexLogModel {
        let l = store.l
        let links = store.dexLinkTargets
        let entries = store.filteredDexEntries(query: state.searchText, rarity: state.selectedRarity, shinyOnly: state.shinyOnly, sort: state.logSort)
        let rows = entries.map { entry -> DexLogRowModel in
            let names = store.dexStoredChainNames(entry) ?? resolved[entry.id]
            return DexLogRowModel(
                id: entry.id, rarity: entry.rarity, rarityText: l.rarityLabel(entry.rarity).uppercased(),
                isRaising: store.isActiveDexEntry(entry), isReleased: entry.isReleased,
                raisingText: l.dexRaising.uppercased(), releasedText: l.dexReleased.uppercased(),
                isShiny: entry.isShiny, shinyLabel: l.dexShinyLabel, nature: entry.nature?.name(store.language),
                nodes: entry.chainOrder.map { id in
                    .init(speciesID: id,
                          name: PokemonForm.displayName(names?[id] ?? "…", speciesID: id, form: entry.form, label: nil),
                          link: links[id])
                },
                form: entry.form, caughtAt: entry.caughtAt, openHint: l.dexOpenEntryHint)
        }
        return DexLogModel(
            title: l.catchLogTitle, total: l.dexTotal(store.dexEntries.count),
            rarities: DexBodyModel.rarityOrder.map { r in
                DexRarityChipModel(rarity: r, label: l.rarityLabel(r), count: store.dexCount(r), isSelected: state.selectedRarity == r,
                                   help: l.dexFilterHint)
            },
            rows: rows, noResults: l.noSearchResults, clearFilters: l.clearFilters)
    }
}
// MARK: end Task 20

extension PopoverStackMetrics {
    /// The Collection page: the content column is the Mac's `VStack(alignment: .leading, spacing: 6)` at the scroller's edge.
    static let collection = PopoverStackMetrics(pagePadding: 14, sectionSpacing: 6, plainSpacing: 6, padTop: 0, padBottom: 0)
}
