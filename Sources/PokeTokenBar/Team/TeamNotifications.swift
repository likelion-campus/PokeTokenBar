import Foundation

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
    /// True while the user sits at the campfire. Set by the runtime.
    var isFocusing: () -> Bool = { false }
    private(set) var heldTally = TeamFocusTally()
    private var didRequestAuthorization = false
    /// The last megaphone notice per member. A modified app could send them back to back.
    private var lastMegaphone: [String: Date] = [:]
    static let megaphoneInterval: TimeInterval = 60
    /// Big news skips the batch, so a modified app could post one banner per frame. The board keeps what this drops.
    static let bigNoticeBurst = 3
    static let bigNoticeInterval: TimeInterval = 20
    private var bigNotices = TeamTokenBucket(capacity: Double(bigNoticeBurst), perSecond: 1 / bigNoticeInterval)

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
        if isFocusing() { heldTally.news += 1; return }
        // Big news is rare and says something different from "reacted", so it never joins the reaction batch.
        guard bigNotices.take(now: clock()) else { return }
        post(L(.ko).teamEventText(e))
    }

    func reactionToMine(_ r: TeamReaction, _ e: TeamEvent) {
        guard settings.notificationsEnabled else { return }
        let text = L(.ko).teamReactionNotice(nickname: r.authorNickname)
        if isPlazaFrontmost() {
            showInPlaza(text)
        } else if isFocusing() {
            heldTally.reactions += 1
        } else {
            deliver(TeamNotice(fromNickname: r.authorNickname, text: text))
        }
    }

    func emoteToMe(from member: TeamMemberState, kind: TeamEmoteKind) {
        guard settings.notificationsEnabled, !isPlazaFrontmost() else { return }
        if isFocusing() {
            switch kind {
            case .heart: heldTally.hearts += 1
            case .lol: heldTally.lols += 1
            case .party: heldTally.parties += 1
            default: break
            }
            return
        }
        deliver(TeamNotice(fromNickname: member.nickname, text: L(.ko).teamEmoteNotice(nickname: member.nickname, kind: kind)))
    }

    /// A megaphone line reaches everyone: a banner with the plaza in front, a notification otherwise.
    func megaphone(from member: TeamMemberState, text: String) {
        guard settings.notificationsEnabled else { return }
        let now = clock()
        if let last = lastMegaphone[member.memberID], now.timeIntervalSince(last) < Self.megaphoneInterval { return }
        lastMegaphone[member.memberID] = now
        show(L(.ko).teamMegaphoneNotice(nickname: member.nickname, text: text))
    }

    /// The focus is over: one line with what was held. Bypasses the batcher.
    func focusEnded(_ end: PlazaFocusEnd) {
        let l = L(.ko)
        let first = end.completed ? l.plazaFocusDoneLine(minutes: end.minutes) : l.plazaFocusEarlyLine(minutes: end.elapsedMinutes)
        let body = [first, l.plazaFocusSummary(heldTally)].compactMap { $0 }.joined(separator: "\n")
        heldTally = TeamFocusTally()
        if isPlazaFrontmost() {
            showInPlaza(body)
        } else if settings.notificationsEnabled {
            post(body)
        }
    }

    /// Drops notices still waiting for the batch window, and the ones held during a focus.
    func reset() {
        batcher = TeamNotificationBatcher()
        heldTally = TeamFocusTally()
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
        // A fresh id each time, so a restarted app never replaces a notice still in Notification Center.
        poster.post(id: UUID().uuidString, title: L(.ko).teamNoticeTitle, body: text)
    }
}
