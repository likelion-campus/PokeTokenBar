import Foundation

/// The tab strip at the top of the popover (the Mac's `Picker(selection: $nav.tab)` in `PopoverView.mainContent`, stage 7
/// Task 19): Home, Shop, Bag, Collection in that order, the one for `PopoverState.tab` selected. The Windows strip is a push-like
/// radio group over these titles; picking one sets `PopoverState.tab`, and the page for it is built in place.
struct PopoverTabsModel: Equatable, Sendable {
    /// The Mac's order (the order of its `Text(...).tag(PopoverTab.…)` rows).
    static let order: [PopoverState.Tab] = [.home, .shop, .bag, .collection]

    var titles: [String]
    var selected: Int

    init(tab: PopoverState.Tab, l: L) {
        titles = [l.home, l.shop, l.bag, l.collection]
        selected = Self.order.firstIndex(of: tab) ?? 0
    }

    /// The tab at a strip position (nil outside the strip).
    static func tab(at index: Int) -> PopoverState.Tab? {
        order.indices.contains(index) ? order[index] : nil
    }

    /// The position of `tab` in the strip.
    static func index(of tab: PopoverState.Tab) -> Int { order.firstIndex(of: tab) ?? 0 }
}
