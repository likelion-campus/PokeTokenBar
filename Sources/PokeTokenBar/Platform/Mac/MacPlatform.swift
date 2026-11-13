import CoreGraphics
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
    /// 마지막 입력 뒤 지난 시간. 권한 없이 읽을 수 있고 어떤 앱을 쓰는지는 알 수 없다.
    func secondsSinceLastInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                    .leftMouseDragged, .otherMouseDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
