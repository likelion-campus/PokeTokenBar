#if os(Windows)
import Foundation
import WinSDK

// MARK: Task 20 — Settings' "Representative Pokémon" row (G2; the Mac's `SettingsView` row with a `Menu`)

/// A label and a borderless button that shows the current choice ("Follow current" or "#25 Pikachu ✨") and opens the Mac's two-item
/// menu: "Follow current" (checked while no species is chosen) and "Choose from the Pokédex", which closes Settings and opens the
/// Pokédex on the representative (`onChooseRepresentative`: `PopoverState.openRepresentativeDex`).
@MainActor final class WinRepresentativeRow {
    private(set) var row: WinRow?
    private(set) var button: WinControl?
    private let companion: CompanionStore
    private let choose: () -> Void
    var menu: @MainActor ([TrayMenuModel.Item?], POINT, HWND) -> Int? = { items, point, owner in
        WinPopupMenu.run(items, at: point, owner: owner, below: true)
    }
    private(set) var menus = 0

    /// The Mac's `representativeSelectionText`.
    static func selectionText(_ companion: CompanionStore) -> String {
        guard let species = companion.representativeDexSpecies else { return companion.l.representativeFollowCurrent }
        return "#\(species.id) \(species.name)\(species.isShiny ? " ✨" : "")"
    }

    init(section: WinSectionCard, companion: CompanionStore, choose: @escaping () -> Void) {
        self.companion = companion
        self.choose = choose
        let l = companion.l
        row = section.addRow(l.representativePokemonLabel) { [self] pane, ctx in
            button = WinControls.pillButton(WinPill(style: .borderless, title: Self.selectionText(companion), glyph: "chevron.down", glyphAfter: true,
                                                    secondary: false, textStyle: .body), in: pane, ctx: ctx)
            return button
        }
        button?.onClick = { [weak self] in self?.openMenu() }
    }

    /// The button shows the current choice (called with the page's refresh).
    func update() {
        button?.setPillTitle(Self.selectionText(companion))
    }

    private func openMenu() {
        guard let button else { return }
        let l = companion.l
        let items: [TrayMenuModel.Item?] = [
            TrayMenuModel.Item(title: l.representativeFollowCurrent, enabled: true, checked: companion.representativeSpeciesID == nil, action: .none),
            TrayMenuModel.Item(title: l.representativeChooseFromDex, enabled: true, checked: false, action: .none),
        ]
        var r = RECT()
        _ = GetWindowRect(button.hwnd, &r)
        menus += 1
        guard let chosen = menu(items, POINT(x: r.left, y: r.bottom), GetAncestor(button.hwnd, 2 /* GA_ROOT */) ?? button.hwnd) else { return }
        apply(chosen)
    }

    /// The menu entry at `index`: follow the current Pokémon, or go to the Pokédex.
    func apply(_ index: Int) {
        switch index {
        case 0: _ = companion.setRepresentativeSpeciesID(nil)
        case 1: DispatchQueue.main.async { [choose] in choose() }   // replaces the page: after this message returns
        default: break
        }
        update()
    }
}
#endif
