#if os(Windows)
/// Windows platform services. Stubs until stage 4 replaces them service by service (Tasks 7–9).
enum WindowsPlatform {
    /// What `Platform.current` builds on first use (what `swift test` sees).
    @MainActor static func make() -> Platform { StubPlatform.make() }

    /// What the app installs once its sink window exists (launch step 8). Stubs for now.
    @MainActor static func live(window: WinSinkWindow) -> Platform { StubPlatform.make() }
}
#endif
