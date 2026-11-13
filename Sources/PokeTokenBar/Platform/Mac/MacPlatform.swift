import Foundation

/// Placeholders for the Mac side of the `Platform` seam.
/// NOT wired into any call site yet: existing Mac code keeps calling today's APIs directly, so Mac behaviour is
/// unchanged. Later tasks move that code in here and switch the call sites over, one service at a time.
enum MacPlatform {
    @MainActor static func make() -> Platform {
        Platform(notifications: MacNotifications(), secrets: MacSecrets(),
                 events: MacSystemEvents(), idle: MacIdleClock())
    }
}

@MainActor struct MacNotifications: LocalNotifying {
    func requestAuthorization() async -> Bool { false }
    func post(id: String, title: String, body: String, sound: Bool) {}
}

struct MacSecrets: SecretStoring {
    func read(service: String, account: String?) -> Result<Data, SecretError> { .failure(.unavailable) }
}

@MainActor struct MacSystemEvents: SystemEvents {
    func onWake(_ f: @escaping () -> Void) {}
    func onScreensSleep(_ f: @escaping () -> Void) {}
    func onScreensWake(_ f: @escaping () -> Void) {}
    func onDayChange(_ f: @escaping () -> Void) {}
}

struct MacIdleClock: IdleClock {
    func secondsSinceLastInput() -> TimeInterval { 0 }
}
