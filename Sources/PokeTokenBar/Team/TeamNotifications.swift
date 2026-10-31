import AppKit
import Foundation
import UserNotifications

struct TeamNotice: Equatable, Sendable {
    let fromNickname: String
    let text: String
}

/// Lets the first notice through and holds the rest until the window ends, so a burst becomes one banner.
struct TeamNotificationBatcher {
    private let window: TimeInterval
    private var windowStart: Date?
    private var pending: [TeamNotice] = []

    init(window: TimeInterval = 30) { self.window = window }

    /// Returns the notice when nothing is waiting and no window is open; otherwise keeps it for `flush`.
    mutating func offer(_ item: TeamNotice, now: Date) -> TeamNotice? {
        if pending.isEmpty, !isWindowOpen(at: now) {
            windowStart = now
            return item
        }
        pending.append(item)
        return nil
    }

    /// Once the window is over, hands back what piled up. Posting it opens the next window.
    mutating func flush(now: Date) -> [TeamNotice] {
        guard let windowStart, now.timeIntervalSince(windowStart) >= window else { return [] }
        let out = pending
        pending = []
        self.windowStart = out.isEmpty ? nil : now
        return out
    }

    private func isWindowOpen(at now: Date) -> Bool {
        guard let windowStart else { return false }
        return now.timeIntervalSince(windowStart) < window
    }
}

@MainActor
protocol TeamNotificationPosting: AnyObject {
    func post(id: String, title: String, body: String)
    func requestAuthorization()
}

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

/// Turns big news, reactions to my news and emotes sent to me into macOS notifications. With the plaza in front
/// only reaction notices are shown, inside the plaza; bubbles and sparkles are already visible there.
@MainActor
final class TeamNotifier {
    private let settings: TeamSettings
    private let poster: TeamNotificationPosting
    private let isPlazaFrontmost: () -> Bool
    private let showInPlaza: (String) -> Void
    private let clock: () -> Date
    private var batcher = TeamNotificationBatcher()
    private var postCount = 0
    private var didRequestAuthorization = false

    init(settings: TeamSettings, poster: TeamNotificationPosting, isPlazaFrontmost: @escaping () -> Bool,
         showInPlaza: @escaping (String) -> Void, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.poster = poster
        self.isPlazaFrontmost = isPlazaFrontmost
        self.showInPlaza = showInPlaza
        self.clock = clock
    }

    /// Asks once, and only while team notices are on. The runtime calls this once the team is ready.
    func requestAuthorizationIfNeeded() {
        guard settings.notificationsEnabled, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        poster.requestAuthorization()
    }

    func bigEvent(_ e: TeamEvent) {
        guard settings.notificationsEnabled, e.authorID != settings.memberID, !isPlazaFrontmost() else { return }
        deliver(TeamNotice(fromNickname: e.authorNickname, text: L(.ko).teamEventText(e)))
    }

    func reactionToMine(_ r: TeamReaction, _ e: TeamEvent) {
        guard settings.notificationsEnabled else { return }
        let text = L(.ko).teamReactionNotice(nickname: r.authorNickname)
        if isPlazaFrontmost() {
            showInPlaza(text)
        } else {
            deliver(TeamNotice(fromNickname: r.authorNickname, text: text))
        }
    }

    func emoteToMe(from member: TeamMemberState, kind: TeamEmoteKind) {
        guard settings.notificationsEnabled, !isPlazaFrontmost() else { return }
        deliver(TeamNotice(fromNickname: member.nickname, text: L(.ko).teamEmoteNotice(nickname: member.nickname)))
    }

    /// Posts what piled up once the batch window is over. Runs on the runtime's tick.
    func flush() {
        let items = batcher.flush(now: clock())
        guard settings.notificationsEnabled, let first = items.first else { return }
        if items.count == 1 {
            show(first.text)
            return
        }
        let others = Set(items.map(\.fromNickname)).subtracting([first.fromNickname]).count
        show(L(.ko).teamNoticeSummary(first: first.fromNickname, others: others))
    }

    private func deliver(_ notice: TeamNotice) {
        guard let now = batcher.offer(notice, now: clock()) else { return }
        post(now.text)
    }

    private func show(_ text: String) {
        if isPlazaFrontmost() { showInPlaza(text) } else { post(text) }
    }

    private func post(_ text: String) {
        postCount += 1
        poster.post(id: "team-\(postCount)", title: L(.ko).teamNoticeTitle, body: text)
    }
}
