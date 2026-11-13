import CoreGraphics
import Foundation

enum MacPlatform {
    @MainActor static func make() -> Platform {
        Platform(notifications: MacNotifications(), secrets: MacSecrets(),
                 events: MacSystemEvents(), idle: MacIdleClock())
    }
}

/// PLACEHOLDER: the Keychain providers still call `KeychainReader` directly (see the task 6 report).
struct MacSecrets: SecretStoring {
    func read(service: String, account: String?) -> Result<Data, SecretError> { .failure(.unavailable) }
}

struct MacIdleClock: IdleClock {
    /// 마지막 입력 뒤 지난 시간. 권한 없이 읽을 수 있고 어떤 앱을 쓰는지는 알 수 없다.
    func secondsSinceLastInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                    .leftMouseDragged, .otherMouseDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
