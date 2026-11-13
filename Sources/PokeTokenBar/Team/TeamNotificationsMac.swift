import AppKit
import Foundation
import UserNotifications

/// Real posting. Only ever created for a bundled app (`TeamNotifications.livePoster`): `UNUserNotificationCenter`
/// crashes in a process without a bundle. Creating one is safe; the center is touched only inside the methods.
@MainActor
final class LiveTeamNotificationPoster: TeamNotificationPosting {
    nonisolated static let threadIdentifier = "team"

    static func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.threadIdentifier = threadIdentifier
        return content
    }

    func post(id: String, title: String, body: String) {
        let request = UNNotificationRequest(identifier: id, content: Self.content(title: title, body: body), trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}

@MainActor
final class TeamNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let onOpenPlaza: () -> Void

    init(onOpenPlaza: @escaping () -> Void) { self.onOpenPlaza = onOpenPlaza }

    /// Team notices show even while the app is in front; anything else keeps today's behaviour (not shown).
    nonisolated static func presentationOptions(threadIdentifier: String) -> UNNotificationPresentationOptions {
        threadIdentifier == LiveTeamNotificationPoster.threadIdentifier ? [.banner] : []
    }

    func handleResponse(threadIdentifier: String) {
        guard threadIdentifier == LiveTeamNotificationPoster.threadIdentifier else { return }
        onOpenPlaza()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentationOptions(threadIdentifier: notification.request.content.threadIdentifier))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let thread = response.notification.request.content.threadIdentifier
        DispatchQueue.main.async { self.handleResponse(threadIdentifier: thread) }
        completionHandler()
    }
}

/// The only way the app gets the real center, and only for a bundled app.
@MainActor
enum TeamNotifications {
    static func livePoster(isBundledApp: Bool = AppEnv.isBundledApp) -> TeamNotificationPosting? {
        isBundledApp ? LiveTeamNotificationPoster() : nil
    }

    /// The caller must keep the returned delegate alive: the center holds it weakly.
    static func installDelegate(isBundledApp: Bool = AppEnv.isBundledApp,
                                onOpenPlaza: @escaping () -> Void) -> TeamNotificationDelegate? {
        guard isBundledApp else { return nil }
        let delegate = TeamNotificationDelegate(onOpenPlaza: onOpenPlaza)
        UNUserNotificationCenter.current().delegate = delegate
        return delegate
    }
}
