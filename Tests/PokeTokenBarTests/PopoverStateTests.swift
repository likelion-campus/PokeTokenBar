import XCTest
@testable import PokeTokenBar

/// The Mac's `PopoverNavigationTests` cases, run on its shared twin `PopoverState` on both systems (stage 7, Task 1).
/// `PopoverTwinEquivalenceTests+Mac` checks the two against each other.
@MainActor
final class PopoverStateTests: XCTestCase {
    func testDefaultsToHome() async {
        let nav = PopoverState()
        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .home)
        XCTAssertFalse(nav.showingCollectionLog)
        XCTAssertFalse(nav.showingRecap)
        XCTAssertFalse(nav.expandAdvancedOnOpen)
        XCTAssertNil(nav.dexDetailCollectionID)
    }

    func testResetReturnsToHomeFromSettings() async {
        let nav = PopoverState()
        nav.showSettings = true
        nav.tab = .collection
        nav.showingCollectionLog = true
        nav.reset()
        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .home)
        XCTAssertTrue(nav.showingCollectionLog, "an ordinary reopen keeps the collection segment")
    }

    /// Opening keeps the provider and Claude-account tabs (the Mac's `reset` leaves them).
    func testResetKeepsTheProviderAndAccountTabs() async {
        let nav = PopoverState()
        nav.providerID = "codex"
        nav.claudeAccountID = "work"
        nav.showingRecap = true
        nav.expandAdvancedOnOpen = true
        nav.reset()
        XCTAssertEqual(nav.providerID, "codex")
        XCTAssertEqual(nav.claudeAccountID, "work")
        XCTAssertFalse(nav.showingRecap)
        XCTAssertFalse(nav.expandAdvancedOnOpen)
    }

    func testOpenSessionKeySettingsOpensAdvanced() async {
        let nav = PopoverState()
        nav.openSessionKeySettings()
        XCTAssertTrue(nav.showSettings)
        XCTAssertTrue(nav.expandAdvancedOnOpen)
    }

    func testOpenRepresentativeDexLeavesSettingsForCollection() async {
        let nav = PopoverState()
        nav.showSettings = true
        nav.showingCollectionLog = true
        nav.openRepresentativeDex()
        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .collection)
        XCTAssertFalse(nav.showingCollectionLog, "choosing a representative always opens the Pokédex")
    }

    func testOpenDexEntryShowsDetailInCollection() async {
        let nav = PopoverState()
        nav.showSettings = true
        nav.showingCollectionLog = true
        nav.openDexEntry(collectionID: "25")
        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .collection)
        XCTAssertEqual(nav.dexDetailCollectionID, "25", "set after the tab/settings changes that clear it")
        XCTAssertTrue(nav.showingCollectionLog, "segment is left as it was")
    }

    func testDexDetailDroppedWhenCollectionContentLeavesScreen() async {
        let triggers: [(String, (PopoverState) -> Void)] = [
            ("other tab", { $0.tab = .home }),
            ("settings", { $0.showSettings = true }),
            ("recap", { $0.showingRecap = true }),
            ("segment switch", { $0.showingCollectionLog.toggle() }),
            ("popover reopen", { $0.reset() }),
        ]
        for (name, trigger) in triggers {
            let nav = PopoverState()
            nav.openDexEntry(collectionID: "25")
            trigger(nav)
            XCTAssertNil(nav.dexDetailCollectionID, name)
        }
    }

    func testDexDetailKeptWhileCollectionContentStaysOnScreen() async {
        let keepers: [(String, (PopoverState) -> Void)] = [
            ("same tab", { $0.tab = .collection }),
            ("same segment", { $0.showingCollectionLog = $0.showingCollectionLog }),
            ("settings closed", { $0.showSettings = false }),
            ("recap closed", { $0.showingRecap = false }),
        ]
        for (name, keep) in keepers {
            let nav = PopoverState()
            nav.openDexEntry(collectionID: "25")
            keep(nav)
            XCTAssertEqual(nav.dexDetailCollectionID, "25", name)
        }
    }

    func testTheOpenPlazaActionIsTheHostsToSet() async {
        let nav = PopoverState()
        var opened = 0
        nav.onOpenPlaza = { opened += 1 }
        nav.onOpenPlaza?()
        nav.reset()
        nav.onOpenPlaza?()
        XCTAssertEqual(opened, 2, "reset leaves the action in place")
    }
}
