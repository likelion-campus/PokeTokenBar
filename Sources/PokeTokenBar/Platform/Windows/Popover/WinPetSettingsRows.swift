#if os(Windows)
import Foundation
import WinSDK

/// The Settings rows the floating pet brought (stage 7 Task 22), as the Mac's `SettingsView` has them:
/// - General (G4): "Animation" with its hint and the three presets (`UsageStore.AnimationQuality`), after the refresh
///   interval. On the Mac it sets the menu bar sprite's and the pet's frame rate; the tray icon on Windows does not animate,
///   so here it is the pet's.
/// - The floating pet group (G12), after the tracked providers: show the floating pet (with its hint), back view (the Mac keeps
///   it in this group; it applies to the tray icon and the popover too), and the size slider (48–384 in steps of 8, "96px")
///   while the pet is on, then (Task 23, G12a) the limit-alert bubbles switch and "React to agent activity" with its hint,
///   also only while the pet is on (the Mac's `if store.floatingPetEnabled`).
/// `WinSettingsPage` calls it with one line per place; it observes nothing itself (`touch` adds its settings to the page's).
@MainActor final class WinPetSettingsRows {
    static let qualities: [UsageStore.AnimationQuality] = [.powerSaver, .balanced, .smooth]
    /// The Mac's `Slider(value: $store.floatingPetSize, in: 48...384, step: 8)`.
    static let sizeRange = 48...384
    static let sizeStep = 8

    private let store: UsageStore
    private(set) var animationQualityRow: WinRow?
    private(set) var enableRow: WinRow?
    private(set) var backViewRow: WinRow?
    private(set) var sizeRow: WinRow?
    private(set) var bubbleAlertsRow: WinRow?
    private(set) var agentActivityRow: WinRow?
    private(set) var groupSection: WinSectionCard?

    init(store: UsageStore) { self.store = store }

    static func qualityTitles(_ l: L) -> [String] { [l.animationPowerSaver, l.animationBalanced, l.animationSmooth] }

    /// The Mac's `"\(Int(store.floatingPetSize))px"`.
    static func sizeText(_ value: Int) -> String { "\(value)px" }

    func addAnimationQuality(to general: WinSectionCard, l: L) {
        let store = self.store
        animationQualityRow = general.addRow(l.animationQualityLabel, hint: l.animationQualityHint) { p, c in
            WinControls.combo(Self.qualityTitles(l), selected: Self.qualities.firstIndex(of: store.animationQuality) ?? 0, in: p, ctx: c)
        }
        animationQualityRow?.control?.onSelect = { i in
            if Self.qualities.indices.contains(i) { store.animationQuality = Self.qualities[i] }
        }
    }

    /// The group; returns its back view row (the page keeps it with its other rows).
    @discardableResult
    func addGroup(to stack: WinStack, l: L) -> WinRow? {
        let store = self.store
        let section = stack.addSection(l.floatingPetSectionTitle)
        groupSection = section
        enableRow = section.addToggle(l.floatingPetEnableLabel, hint: l.floatingPetHint, isOn: store.floatingPetEnabled)
        enableRow?.control?.onToggle = { on in store.floatingPetEnabled = on }
        backViewRow = section.addToggle(l.backViewLabel, hint: l.winBackViewHint, isOn: store.alwaysFacesBack)
        backViewRow?.control?.onToggle = { on in store.alwaysFacesBack = on }
        sizeRow = section.addRow(l.floatingPetSizeLabel) { p, c in
            WinControls.trackbar(range: Self.sizeRange, step: Self.sizeStep, value: Int(store.floatingPetSize.rounded()),
                                 format: { Self.sizeText($0) }, in: p, ctx: c)
        }
        sizeRow?.control?.onValue = { v in store.floatingPetSize = Double(v) }
        sizeRow?.isVisible = store.floatingPetEnabled
        // --- stage 7 Task 23 (G12a) (begin) ---
        bubbleAlertsRow = section.addToggle(l.floatingPetBubbleAlertsLabel, isOn: store.floatingPetBubbleAlerts)
        bubbleAlertsRow?.control?.onToggle = { on in store.floatingPetBubbleAlerts = on }
        bubbleAlertsRow?.isVisible = store.floatingPetEnabled
        agentActivityRow = section.addToggle(l.floatingPetAgentActivityLabel, hint: l.floatingPetAgentActivityHint, isOn: store.floatingPetAgentActivity)
        agentActivityRow?.control?.onToggle = { on in store.floatingPetAgentActivity = on }
        agentActivityRow?.isVisible = store.floatingPetEnabled
        // --- stage 7 Task 23 (end) ---
        return backViewRow
    }

    /// Values and visibility from the settings now (the page's `sync`); the back view switch is the page's.
    func apply() {
        if let c = animationQualityRow?.control, let i = Self.qualities.firstIndex(of: store.animationQuality), c.selection != i { c.selection = i }
        if let c = enableRow?.control, c.isOn != store.floatingPetEnabled { c.isOn = store.floatingPetEnabled }
        sizeRow?.isVisible = store.floatingPetEnabled
        let size = Int(store.floatingPetSize.rounded())
        if let c = sizeRow?.control, c.value != size { c.value = size }
        bubbleAlertsRow?.isVisible = store.floatingPetEnabled   // Task 23
        agentActivityRow?.isVisible = store.floatingPetEnabled
        if let c = bubbleAlertsRow?.control, c.isOn != store.floatingPetBubbleAlerts { c.isOn = store.floatingPetBubbleAlerts }
        if let c = agentActivityRow?.control, c.isOn != store.floatingPetAgentActivity { c.isOn = store.floatingPetAgentActivity }
    }

    /// What these rows show from observable settings (inside the page's tracking pass).
    static func touch(_ store: UsageStore) {
        _ = store.animationQuality
        _ = store.floatingPetEnabled
        _ = store.floatingPetSize
        _ = store.floatingPetBubbleAlerts   // Task 23
        _ = store.floatingPetAgentActivity
    }
}
#endif
