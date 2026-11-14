import Foundation

/// How usage reaches the companion, for app shells other than the Mac's. A copy of `AppDelegate.updateCompanion`
/// and `onStoreRefreshed` in `PokeTokenBarApp.swift`, which the Mac keeps as they are; `AppWiringDriftScanTests`
/// fails when the two copies pass different arguments.
enum AppWiring {
    /// UsageStore values -> CompanionStore (usage credit and display state). Called on every observed change.
    @MainActor static func updateCompanion(_ companion: CompanionStore, from store: UsageStore) {
        companion.alwaysFacesBack = store.alwaysFacesBack
        companion.update(
            todayTokensByProvider: store.todayTokensByProvider,
            todayDate: LocalUsageReader.todayKey(),
            monthTotal: store.monthTotalTokens,
            burnTier: store.burnTier,
            limitWarning: store.isLimitWarning,
            hasUsageData: store.hasUsageData,
            timeSinceLastUsage: store.timeSinceLastUsage())
    }

    /// After every refresh, when the limits are fresh: the companion update and the candy grant.
    @MainActor static func storeRefreshed(_ companion: CompanionStore, _ store: UsageStore) {
        updateCompanion(companion, from: store)
        companion.grantCandies(from: store.candyEligibleWindows, limitsReady: store.limitsReady)
    }
}
