import Foundation
import UserNotifications

/// The system-notification code that `UsageStore` and `CompanionStore` used to hold inline, moved here unchanged.
/// `isAvailable` is the bundle check those sites guarded with: `UNUserNotificationCenter.current()` crashes outside an
/// app bundle (`swift test`, a raw binary), so the hubs ask it before every request or post.
@MainActor struct MacNotifications: LocalNotifying {
    var isAvailable: Bool { AppEnv.isBundledApp }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(id: String, title: String, body: String, sound: Bool) {
        UNUserNotificationCenter.current().add(Self.request(id: id, title: title, body: body, sound: sound))
    }

    /// The request `post` hands to the system. Pure, so a test can check it without a notification center.
    static func request(id: String, title: String, body: String, sound: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }
}
