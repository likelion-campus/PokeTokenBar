import Foundation

/// What the Mac popover takes for granted about its platform, made explicit input of the shared models (stage 7, D8).
///
/// - `hasKeychain`: the Mac reads Claude's (and Antigravity's) token from the Keychain on a user refresh and offers a
///   switch to turn that off (`UsageStore.disableKeychainAccess`). Without a Keychain (Windows) there is no switch: a user
///   refresh reads `~/.claude/.credentials.json`, so the popover behaves as the Mac does with the Keychain allowed, and
///   the Keychain help (P15h) has no meaning.
/// - `antigravityLimitsAvailable`: Antigravity's limits have a source (Windows: `WindowsLimitsProviders` reports them
///   unavailable, so the section would offer a refresh that does nothing visible; P25).
/// - `floatingPetAvailable`: the floating pet exists, so the footer's eye button, the pet's Settings group and "Animation
///   quality" mean something (Windows: since stage 7 Task 22, `WinFloatingPet`).
/// - `regionLocale`, `regionCalendar`: number grouping, and the zone and day the clocks read (D11).
///
/// `mac` reproduces the Mac's predicates exactly (`PopoverTwinEquivalenceTests+Mac` holds the limits gate to a copy of
/// `PopoverView.selectedProviderHasLimits` over every flag); `current` is this system's.
struct PopoverPlatformFacts: Equatable, Sendable {
    var hasKeychain: Bool
    var antigravityLimitsAvailable: Bool
    var floatingPetAvailable: Bool
    var regionLocale: Locale
    var regionCalendar: Calendar

    /// The Mac: a Keychain, Antigravity's limits, the floating pet, `Locale.current` and `Calendar.current` (what
    /// `TokenFormatter.grouped`'s default, `Calendar.current.isDateInToday` and a default `DateFormatter` read).
    static var mac: PopoverPlatformFacts {
        PopoverPlatformFacts(hasKeychain: true, antigravityLimitsAvailable: true, floatingPetAvailable: true,
                             regionLocale: .current, regionCalendar: .current)
    }

    /// Windows: no Keychain, no Antigravity limits source; the floating pet (stage 7 Task 22); the region from the OS (D11).
    static func windows(regionLocale: Locale, regionCalendar: Calendar) -> PopoverPlatformFacts {
        PopoverPlatformFacts(hasKeychain: false, antigravityLimitsAvailable: false, floatingPetAvailable: true,
                             regionLocale: regionLocale, regionCalendar: regionCalendar)
    }

    /// This system's facts, read per call (a region change applies to the next build).
    @MainActor static var current: PopoverPlatformFacts { PlatformCompat.popoverFacts }
}
