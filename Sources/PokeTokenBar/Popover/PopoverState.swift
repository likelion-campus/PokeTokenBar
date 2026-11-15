import Foundation
import Observation

/// The Windows popover's navigation state: a shared twin of the Mac's `PopoverNavigation` (`UI/PopoverView.swift`,
/// upstream-owned and Mac-only), stage 7 D8. The class body is the Mac's, line for line, with `PopoverTab` renamed to
/// `Tab`: `PopoverParityScanTests` compares the two bodies (twins.txt) and `PopoverTwinEquivalenceTests+Mac` drives both
/// with the same random actions. Change the Mac first, then copy the change here.
///
/// The rules it carries: opening the popover resets to Home (provider and Claude-account tabs are kept); Settings and
/// the recap replace the content; the Pokédex detail page lasts only while the collection content is on screen.
@MainActor
@Observable
final class PopoverState {
    var showSettings = false { didSet { if showSettings { dexDetailCollectionID = nil } } }
    var tab: Tab = .home { didSet { if tab != .collection { dexDetailCollectionID = nil } } }
    var showingCollectionLog = false {
        didSet { if showingCollectionLog != oldValue { dexDetailCollectionID = nil } }
    }
    var showingRecap = false { didSet { if showingRecap { dexDetailCollectionID = nil } } }
    var dexDetailCollectionID: String?
    var providerID: String?
    var claudeAccountID: String?
    var expandAdvancedOnOpen = false
    var onOpenPlaza: (() -> Void)?

    func reset() {
        showSettings = false
        expandAdvancedOnOpen = false
        showingRecap = false
        tab = .home
    }

    func openSessionKeySettings() {
        showSettings = true
        expandAdvancedOnOpen = true
    }

    func openDexEntry(collectionID: String) {
        showSettings = false
        tab = .collection
        dexDetailCollectionID = collectionID   // last: the didSets above clear it
    }

    func openRepresentativeDex() {
        showSettings = false
        showingCollectionLog = false
        tab = .collection
    }
}

extension PopoverState {
    /// The Mac's `PopoverTab`.
    enum Tab: Equatable { case home, shop, bag, collection }
}
