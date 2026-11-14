#if os(Windows)
/// Windows platform services. Stubs until stage 4 replaces them service by service (Tasks 7–9).
enum WindowsPlatform {
    /// Read by `PlatformLimits.current` (a `static let`, built on first access): the app sets the live value in
    /// `live(window:)`, before any store exists. Stub until Task 9.
    nonisolated(unsafe) static var limitsFactory: any LimitsProviderFactory = StubLimitsProviders(log: { AppLog.write($0) })
    /// Read by `PlatformNetwork.current`, same rule. `live(window:)` sets the real monitor factory.
    nonisolated(unsafe) static var networkWatching: any NetworkWatching = StubNetworkWatching(log: { AppLog.write($0) })

    /// What `Platform.current` builds on first use (what `swift test` sees).
    @MainActor static func make() -> Platform { StubPlatform.make() }

    /// What the app installs once its sink window exists (launch step 8). System events, idle clock and network
    /// are real; the rest are stubs until their tasks land.
    @MainActor static func live(window: WinSinkWindow, notifications: LocalNotifying? = nil) -> Platform {
        let stubs = StubPlatform.make()
        networkWatching = WindowsNetworkWatching()
        return Platform(notifications: notifications ?? stubs.notifications,
                        secrets: stubs.secrets,
                        events: WindowsSystemEvents(window: window),
                        idle: WindowsIdleClock())
    }
}
#endif
