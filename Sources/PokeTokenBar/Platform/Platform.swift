import Foundation

/// Small protocols for the OS services shared code needs. Method lists grow only when a real call site needs them.
@MainActor protocol LocalNotifying {
    func requestAuthorization() async -> Bool
    func post(id: String, title: String, body: String, sound: Bool)
}

enum SecretError: Error, Equatable { case notFound, denied, unavailable }

protocol SecretStoring: Sendable {
    func read(service: String, account: String?) -> Result<Data, SecretError>
}

@MainActor protocol SystemEvents {
    func onWake(_ f: @escaping () -> Void)
    func onScreensSleep(_ f: @escaping () -> Void)
    func onScreensWake(_ f: @escaping () -> Void)
    func onDayChange(_ f: @escaping () -> Void)
}

protocol IdleClock: Sendable {
    func secondsSinceLastInput() -> TimeInterval
}

struct Platform {
    let notifications: LocalNotifying
    let secrets: SecretStoring
    let events: SystemEvents
    let idle: IdleClock

    /// Lazily built on first use; a test may assign its own.
    @MainActor static var current: Platform = {
        #if os(Windows)
        WindowsPlatform.make()
        #elseif PTB_SHARED_ONLY
        StubPlatform.make()  // the Mac checking the shared set as Windows sees it (no Mac/ files)
        #else
        MacPlatform.make()
        #endif
    }()
}
