import Foundation

/// Small protocols for the OS services shared code needs. Method lists grow only when a real call site needs them.
@MainActor protocol LocalNotifying {
    /// False where posting must not be attempted (the Mac: outside an app bundle, `UNUserNotificationCenter` crashes).
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    func post(id: String, title: String, body: String, sound: Bool)
}

enum SecretError: Error, Equatable { case notFound, denied, unavailable }

protocol SecretStoring: Sendable {
    func read(service: String, account: String?) -> Result<Data, SecretError>
}

@MainActor protocol SystemEvents {
    func onWake(_ f: @escaping @Sendable () -> Void)
    func onScreensSleep(_ f: @escaping @Sendable () -> Void)
    func onScreensWake(_ f: @escaping @Sendable () -> Void)
    func onDayChange(_ f: @escaping @Sendable () -> Void)
    /// Whether the main display is asleep (the Mac: `CGDisplayIsAsleep(CGMainDisplayID())`).
    var displaysAreAsleep: Bool { get }
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
