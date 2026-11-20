import XCTest
@testable import PokeTokenBar

private struct OfflinePokeProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// Stage 7 Task 20: the Collection tab's shared rules and drawn parts (state, paging, the grid and log models, the parts' hits,
/// keys, items and sprite slots). Headless: the parts render through `PlatformPlaza.graphics`, no window.
@MainActor
final class DexBrowserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `count` species (ids 1…count), rarities cycling, species 5 shiny; one entry each.
    private func makeStore(count: Int = 20, language: AppLanguage = .en) throws -> CompanionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-browser-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = language
        let rarities: [Rarity] = [.common, .uncommon, .rare, .legendary]
        state.dex = (1...max(1, count)).map { id in
            DexEntry(id: "entry-\(id)", baseID: id, finalID: id, chainOrder: [id], rarity: rarities[id % 4],
                     caughtAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(id) * 3600), isShiny: id == 5,
                     names: [id: ["en": "Mon\(id)", "ko": "몬\(id)"]])
        }
        if count == 0 { state.dex = [] }
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: OfflinePokeProvider(), clock: { self.now }, fileURL: file, rng: SeededRNG(seed: 7))
    }

    // MARK: state

    func testAFilterOrSortOrSearchChangeStartsOnPageOneAndClearsTheSelection() async {
        var s = DexBrowserState()
        for change in [{ s.setSearch("mon") }, { s.toggleShinyOnly() }, { s.setDexSort(.nameAsc) }, { s.setLogSort(.oldestFirst) },
                       { s.toggleRarity(.rare) }, { s.toggleRegion(.kanto) }] {
            s.page = 3
            s.selectedID = "7"
            change()
            XCTAssertEqual(s.page, 0)
            XCTAssertNil(s.selectedID)
        }
        // the same value again changes nothing (the Mac's onChange does not fire)
        s.page = 3
        s.selectedID = "7"
        s.setSearch("mon")
        s.setDexSort(.nameAsc)
        XCTAssertEqual(s.page, 3)
        XCTAssertEqual(s.selectedID, "7")
    }

    func testTheSameChipAgainClearsItAndResetFiltersClearsEverything() async {
        var s = DexBrowserState()
        s.toggleRarity(.rare)
        XCTAssertEqual(s.selectedRarity, .rare)
        s.toggleRarity(.rare)
        XCTAssertNil(s.selectedRarity)
        s.toggleRegion(.johto)
        s.setSearch("x")
        s.setLogSort(.nameDesc)
        s.resetFilters()
        XCTAssertEqual(s, DexBrowserState(page: 0))
        XCTAssertFalse(s.isCustomSortActive(showingLog: false) || s.isCustomSortActive(showingLog: true))
        s.setDexSort(.rarityDesc)
        XCTAssertTrue(s.isCustomSortActive(showingLog: false))
        XCTAssertFalse(s.isCustomSortActive(showingLog: true))
    }

    // MARK: paging

    func testPagingRules() async {
        XCTAssertEqual(DexPaging.pageAfterScroll(current: 0, pageCount: 3, step: -1), 0)
        XCTAssertEqual(DexPaging.pageAfterScroll(current: 2, pageCount: 3, step: 1), 2)
        XCTAssertEqual(DexPaging.pageAfterScroll(current: 1, pageCount: 3, step: 1), 2)
        let ids = (1...40).map(String.init)
        XCTAssertEqual(DexPaging.page(containing: "17", in: ids, pageSize: 16), 1)
        XCTAssertEqual(DexPaging.page(containing: "99", in: ids, pageSize: 16), 0)
        XCTAssertEqual(DexPaging.page(containing: nil, in: ids, pageSize: 16), 0)
        XCTAssertEqual(DexPaging.currentPage(nil, anchor: "33", ids: ids, pageCount: 3), 2)
        XCTAssertEqual(DexPaging.currentPage(9, anchor: nil, ids: ids, pageCount: 3), 2)   // clamped to the pages there are
    }

    func testTheWheelPagerTurnsOnePagePerNotchAndAccumulatesATouchpad() async {
        var w = DexWheelPager()
        XCTAssertEqual(w.step(deltaY: -40, precise: false), 1)
        XCTAssertEqual(w.step(deltaY: 40, precise: false), -1)
        XCTAssertEqual(w.step(deltaY: -10, precise: true), 0)
        XCTAssertEqual(w.step(deltaY: -10, precise: true), 0)
        XCTAssertEqual(w.step(deltaY: -10, precise: true), 1)       // 30 points ≥ 24: one page, the sum starts again
        XCTAssertEqual(w.step(deltaY: -10, precise: true), 0)
        XCTAssertEqual(w.step(deltaY: 30, precise: true), 0)        // +20 after -10: the direction change cancels
    }

    // MARK: the grid model

    func testTheGridModelHasSixteenCellsPerPageAndTheFooterSaysWhichPage() async throws {
        let store = try makeStore(count: 20)
        var s = DexBrowserState()
        let m = DexBodyModel.make(store: store, state: s)
        XCTAssertEqual(m.cells.count, 16)
        XCTAssertEqual(m.footer.pageText, "1 / 2")
        XCTAssertEqual(m.footer.pageCount, 2)
        XCTAssertEqual(m.total, store.l.dexSpeciesTotal(20))
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.cells[4].number, 5)
        XCTAssertTrue(m.cells[4].isShiny && m.cells[4].spriteShiny)
        XCTAssertTrue(m.cells[4].tooltip.contains(store.l.dexShinyLabel), m.cells[4].tooltip)
        s.page = 1
        XCTAssertEqual(DexBodyModel.make(store: store, state: s).cells.map(\.number), [17, 18, 19, 20])
        // Back from a detail page opens on the page of the species, selecting nothing
        s = DexBrowserState(returnAnchor: "18")
        let back = DexBodyModel.make(store: store, state: s)
        XCTAssertEqual(back.footer.current, 1)
        XCTAssertNil(back.footer.selection)
    }

    func testTheSelectedCellShowsItsRarityAndTheRepresentativeButton() async throws {
        let store = try makeStore(count: 20)
        var s = DexBrowserState()
        s.selectedID = "3"
        let m = DexBodyModel.make(store: store, state: s)
        let sel = try XCTUnwrap(m.footer.selection)
        XCTAssertEqual(sel.text, "#3 Mon3 · \(store.l.rarityLabel(.legendary))")
        XCTAssertEqual(sel.representativeTitle, store.l.representativeSet)
        XCTAssertTrue(store.setRepresentativeSpeciesID(3))
        let after = DexBodyModel.make(store: store, state: s)
        XCTAssertEqual(after.footer.selection?.representativeTitle, store.l.representativeFollowCurrent)
        XCTAssertTrue(after.cells[2].isRepresentative)
        XCTAssertTrue(after.cells[2].tooltip.hasSuffix(store.l.representativeBadge), after.cells[2].tooltip)
        XCTAssertFalse(after.cells[3].isRepresentative)
    }

    func testFiltersNarrowTheGridAndNothingLeftIsTheNoResultsState() async throws {
        let store = try makeStore(count: 20)
        var s = DexBrowserState()
        s.toggleRarity(.rare)
        let rare = DexBodyModel.make(store: store, state: s)
        XCTAssertEqual(rare.cells.count, 5)
        XCTAssertTrue(rare.rarities.first { $0.rarity == .rare }?.isSelected == true)
        s.resetFilters()
        s.setSearch("zzz")
        let none = DexBodyModel.make(store: store, state: s)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.noResults, store.l.noSearchResults)
        s.resetFilters()
        s.toggleShinyOnly()
        XCTAssertEqual(DexBodyModel.make(store: store, state: s).cells.map(\.number), [5])
        s.resetFilters()
        s.toggleRegion(.johto)   // nothing of Johto is owned: the chip is disabled but its filter shows nothing
        XCTAssertTrue(DexBodyModel.make(store: store, state: s).isEmpty)
        let kanto = DexBodyModel.make(store: store, state: DexBrowserState()).regions.first { $0.region == .kanto }
        XCTAssertEqual(kanto?.owned, 20)
        XCTAssertTrue(kanto?.isEnabled == true)
        XCTAssertEqual(DexBodyModel.make(store: store, state: DexBrowserState()).regions.first { $0.region == .johto }?.isEnabled, false)
    }

    // MARK: the grid part

    private func part(_ store: CompanionStore, _ state: DexBrowserState = DexBrowserState()) -> (DexBodyPart, PlazaGraphics) {
        let graphics = PlatformPlaza.graphics
        let p = DexBodyPart(DexBodyModel.make(store: store, state: state), height: 456)
        _ = p.size(width: 332, scale: 1, text: graphics.text)
        return (p, graphics)
    }

    func testTheGridPartHasOneButtonItemPerCellAndAStillSlotPerSprite() async throws {
        let store = try makeStore(count: 20)
        let (p, graphics) = part(store)
        let d = p.render(scale: 1, graphics: graphics)
        let cellItems = d.drawing.accessibility.filter { $0.action?.action == DexBodyPart.cellAction }
        XCTAssertEqual(cellItems.count, 16)
        XCTAssertEqual(d.spriteSlots.count, 16)
        XCTAssertTrue(d.spriteSlots.allSatisfy { $0.frame.width == 56 && $0.animated == false && $0.bob == false })
        XCTAssertEqual(d.spriteSlots[4].subject?.speciesID, 5)
        XCTAssertEqual(d.spriteSlots[4].subject?.shiny, true)
        XCTAssertFalse(d.drawing.layers.isEmpty)
        // each cell's hit is its own item's action, at its centre
        for (i, item) in cellItems.enumerated() {
            let hit = p.hit(CGPoint(x: item.frame.midX, y: item.frame.midY))
            XCTAssertEqual(hit?.action, DexBodyPart.cellAction)
            XCTAssertEqual(hit?.index, i)
        }
        // the page arrows: next is enabled on page 1, previous is not
        XCTAssertEqual(d.drawing.accessibility.first { $0.action?.action == DexBodyPart.nextAction }?.isEnabled, true)
        XCTAssertEqual(d.drawing.accessibility.first { $0.action?.action == DexBodyPart.prevAction }?.isEnabled, false)
        // every cell has its tooltip
        XCTAssertGreaterThanOrEqual(d.drawing.tooltips.count, 16)
    }

    func testTheGridKeysMoveWithinThePageAndTurnIt() async throws {
        let store = try makeStore(count: 20)
        let (p, _) = part(store)
        XCTAssertEqual(p.key(0x27, from: 0), .focusCell(1))     // right
        XCTAssertNil(p.key(0x27, from: 3))                      // the row's last cell
        XCTAssertNil(p.key(0x25, from: 0))
        XCTAssertEqual(p.key(0x28, from: 1), .focusCell(5))     // down
        XCTAssertNil(p.key(0x26, from: 2))
        XCTAssertEqual(p.key(0x24, from: 9), .focusCell(0))     // home
        XCTAssertEqual(p.key(0x23, from: 0), .focusCell(15))    // end
        XCTAssertEqual(p.key(0x22, from: 0), .page(1))          // page down
        XCTAssertNil(p.key(0x21, from: 0))                      // no page before the first
        XCTAssertNil(p.key(0x41, from: 0))
        // a short last page: right and down stop at the last cell
        var s = DexBrowserState()
        s.page = 1
        let (q, _) = part(store, s)
        XCTAssertNil(q.key(0x27, from: 3))
        XCTAssertNil(q.key(0x28, from: 0))
        XCTAssertEqual(q.key(0x21, from: 0), .page(-1))
    }

    func testHoverLiftsOneCellAndRepaintsOnlyThatRegion() async throws {
        let store = try makeStore(count: 20)
        let (p, graphics) = part(store)
        _ = p.render(scale: 1, graphics: graphics)
        let cell = try XCTUnwrap(p.laid?.cells[6])
        var changes = 0
        p.onChange = { changes += 1 }
        p.setPointer(CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertEqual(p.hoverCell, 6)
        XCTAssertEqual(changes, 1)
        p.setPointer(CGPoint(x: cell.midX + 1, y: cell.midY))   // still over it: nothing
        XCTAssertEqual(changes, 1)
        let d = p.render(scale: 1, graphics: graphics)
        XCTAssertNotNil(d.dirty)
        XCTAssertTrue(d.dirty?.contains(cell) == true)
        XCTAssertLessThan(d.dirty?.height ?? 999, 200)
        // the lifted sprite is 4 % larger
        XCTAssertEqual(d.spriteSlots[6].frame.width, 56 * 1.04, accuracy: 0.01)
        p.setPointer(nil)
        XCTAssertNil(p.hoverCell)
    }

    func testTheChipRowsScrollSidewaysAndKeepEveryChipReachable() async throws {
        let store = try makeStore(count: 20)
        let (p, graphics) = part(store)
        _ = p.render(scale: 1, graphics: graphics)
        let lay = try XCTUnwrap(p.laid)
        XCTAssertGreaterThan(lay.regions.contentWidth, 0)
        let rarityPoint = CGPoint(x: 5, y: lay.rarities.viewport.midY)
        // five regions at 11 pt do not fit 332 pt next to each other with their counts: the strip scrolls when it overflows
        let moved = p.scrollChips(at: CGPoint(x: 5, y: lay.regions.viewport.midY), by: 40)
        XCTAssertEqual(moved, lay.regions.maxScroll > 0)
        XCTAssertFalse(p.scrollChips(at: CGPoint(x: 5, y: 2000), by: 40))   // not over a strip
        _ = rarityPoint
        let d = p.render(scale: 1, graphics: graphics)
        let region = d.drawing.accessibility.filter { $0.action?.action == DexBodyPart.regionAction }
        XCTAssertFalse(region.isEmpty)
        XCTAssertTrue(region.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 332.01 })
    }

    func testNothingFoundShowsTheMessageAndAClearButton() async throws {
        let store = try makeStore(count: 20)
        var s = DexBrowserState()
        s.setSearch("zzz")
        let (p, graphics) = part(store, s)
        let d = p.render(scale: 1, graphics: graphics)
        XCTAssertTrue(d.spriteSlots.isEmpty)
        let clear = try XCTUnwrap(d.drawing.accessibility.first { $0.action?.action == DexBodyPart.clearAction })
        XCTAssertEqual(clear.label, store.l.clearFilters)
        XCTAssertEqual(p.hit(CGPoint(x: clear.frame.midX, y: clear.frame.midY))?.action, DexBodyPart.clearAction)
        XCTAssertNil(p.hit(CGPoint(x: 1, y: 400)))
    }

    // MARK: the log

    func testTheLogDrawsOnlyTheRowsInView() async throws {
        let store = try makeStore(count: 300)
        let model = DexLogModel.make(store: store, state: DexBrowserState())
        XCTAssertEqual(model.rows.count, 300)
        let graphics = PlatformPlaza.graphics
        let p = DexLogPart(model, height: 456, language: .en)
        _ = p.size(width: 332, scale: 1, text: graphics.text)
        let d = p.render(scale: 1, graphics: graphics)
        XCTAssertGreaterThan(d.spriteSlots.count, 0)
        XCTAssertLessThan(d.spriteSlots.count, 12, "only the rows in view have sprite slots")
        let nodes = d.drawing.accessibility.filter { $0.action?.action == DexLogPart.nodeAction }
        XCTAssertEqual(nodes.count, d.spriteSlots.count)
        XCTAssertTrue(nodes.allSatisfy { $0.action?.target != nil })
        // scrolling to the end shows the last entries, still few slots
        XCTAssertTrue(p.scroll(by: .greatestFiniteMagnitude))
        let end = p.render(scale: 1, graphics: graphics)
        XCTAssertLessThan(end.spriteSlots.count, 12)
        XCTAssertEqual(end.spriteSlots.last?.subject?.speciesID, model.rows.last?.nodes.first?.speciesID)
        XCTAssertFalse(p.scroll(by: 10))   // at the end
        p.scrollToTop()
        XCTAssertEqual(p.scrollY, 0)
    }

    func testTheLogThumbDragsTheList() async throws {
        let store = try makeStore(count: 60)
        let model = DexLogModel.make(store: store, state: DexBrowserState())
        let graphics = PlatformPlaza.graphics
        let p = DexLogPart(model, height: 456, language: .en)
        _ = p.size(width: 332, scale: 1, text: graphics.text)
        _ = p.render(scale: 1, graphics: graphics)
        let thumb = try XCTUnwrap(p.thumbRect(try XCTUnwrap(p.laid)))
        let down = CGPoint(x: thumb.midX, y: thumb.midY)
        XCTAssertEqual(p.hit(down)?.action, DexLogPart.thumbAction)
        p.setPointer(CGPoint(x: down.x, y: down.y + 60))
        XCTAssertGreaterThan(p.scrollY, 0)
        p.endDrag()
        let before = p.scrollY
        p.setPointer(CGPoint(x: down.x, y: down.y + 200))   // no drag any more: only hover
        XCTAssertEqual(p.scrollY, before)
    }

    func testTheLogModelFollowsTheFiltersAndLinksOnlySpeciesInTheDex() async throws {
        let store = try makeStore(count: 8)
        var s = DexBrowserState()
        s.toggleRarity(.uncommon)
        let m = DexLogModel.make(store: store, state: s)
        XCTAssertEqual(m.rows.count, 2)       // ids 1 and 5
        XCTAssertTrue(m.rows.allSatisfy { $0.rarity == .uncommon })
        XCTAssertTrue(m.rows.flatMap(\.nodes).allSatisfy { $0.link != nil })
        XCTAssertEqual(m.total, store.l.dexTotal(8))
        XCTAssertEqual(m.rows.first?.rarityText, store.l.rarityLabel(.uncommon).uppercased())
        XCTAssertEqual(m.rows.first?.nodes.first?.name, "Mon1")
    }

    func testTheEmptyPartCentresTheTextAndAnimatesPikachu() async {
        let graphics = PlatformPlaza.graphics
        let p = DexEmptyPart(title: "No Pokémon caught yet!", hint: "Spend tokens to hatch your first Pokémon.")
        let size = p.size(width: 332, scale: 1, text: graphics.text)
        XCTAssertGreaterThan(size.height, 28 + 96 + 28)
        let d = p.render(scale: 1, graphics: graphics)
        XCTAssertEqual(d.spriteSlots.count, 1)
        XCTAssertEqual(d.spriteSlots[0].subject?.speciesID, 25)
        XCTAssertTrue(d.spriteSlots[0].animated)
        XCTAssertEqual(d.spriteSlots[0].frame.width, 96)
        XCTAssertEqual(d.spriteSlots[0].frame.midX, 166, accuracy: 0.01)
    }
}
