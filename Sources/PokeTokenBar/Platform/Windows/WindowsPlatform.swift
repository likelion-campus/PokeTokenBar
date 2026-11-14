#if os(Windows)
/// Windows platform services. Stubs until stage 4 replaces them service by service (Tasks 7–9).
enum WindowsPlatform {
    /// What `PlatformLimits.current` hands out on first use. Stubs until the app sets the real one (launch step 8,
    /// before the stores), so `swift test` never reads the user's credentials file.
    nonisolated(unsafe) static var limitsFactory: any LimitsProviderFactory = StubLimitsProviders(log: { AppLog.write($0) })

    /// What `Platform.current` builds on first use (what `swift test` sees).
    @MainActor static func make() -> Platform { StubPlatform.make() }

    /// What the app installs once its sink window exists (launch step 8). Stubs for now.
    @MainActor static func live(window: WinSinkWindow) -> Platform { StubPlatform.make() }
}
#endif
