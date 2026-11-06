import XCTest
import UserNotifications
@testable import PokeTokenBar

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func notice(_ nick: String, _ text: String = "t") -> TeamNotice { TeamNotice(fromNickname: nick, text: text) }

@MainActor
private final class FakePoster: TeamNotificationPosting {
    private(set) var posts: [(id: String, title: String, body: String)] = []
    private(set) var authorizationRequests = 0
    func post(id: String, title: String, body: String) { posts.append((id, title, body)) }
    func requestAuthorization() { authorizationRequests += 1 }
}

private func bigEvent(_ id: String = "e1", author: String = "other", nick: String = "민수",
                      kind: TeamEventKind = .hatch) -> TeamEvent {
    TeamEvent(id: id, authorID: author, authorNickname: nick, kind: kind, speciesID: 25, fromSpeciesID: nil,
              speciesName: "피카츄", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common,
              day: "2026-10-30", occurredAt: t0)
}

private func reaction(_ nick: String = "민수") -> TeamReaction {
    TeamReaction(id: UUID().uuidString, eventID: "e1", authorID: "x", authorNickname: nick, kind: .cute, text: nil, createdAt: t0)
}

private func memberState(_ nick: String) -> TeamMemberState {
    TeamMemberState(memberID: "m", nickname: nick,
                    character: TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil),
                    inPlaza: false, tile: nil, facing: nil, isWalking: false)
}

final class TeamNotificationBatcherTests: XCTestCase {
    func testFirstNoticePostsImmediately() {
        var b = TeamNotificationBatcher()
        XCTAssertEqual(b.offer(notice("민수"), now: t0), notice("민수"))
    }

    func testNoticesInWindowAreBatched() {
        var b = TeamNotificationBatcher()
        XCTAssertNotNil(b.offer(notice("민수"), now: t0))
        XCTAssertNil(b.offer(notice("지영"), now: t0.addingTimeInterval(5)))
        XCTAssertNil(b.offer(notice("철수"), now: t0.addingTimeInterval(10)))
        XCTAssertEqual(b.flush(now: t0.addingTimeInterval(29)), [], "window not over yet")
        XCTAssertEqual(b.flush(now: t0.addingTimeInterval(30)), [notice("지영"), notice("철수")])
        XCTAssertEqual(b.flush(now: t0.addingTimeInterval(31)), [], "flush empties the batch")
    }

    func testBatchFlushWithNothingPendingPostsNothing() {
        var b = TeamNotificationBatcher()
        XCTAssertNotNil(b.offer(notice("민수"), now: t0))
        XCTAssertEqual(b.flush(now: t0.addingTimeInterval(60)), [])
        XCTAssertNotNil(b.offer(notice("지영"), now: t0.addingTimeInterval(61)), "window closed, next one is immediate")
    }

    func testFlushOpensANewWindow() {
        var b = TeamNotificationBatcher()
        _ = b.offer(notice("a"), now: t0)
        _ = b.offer(notice("b"), now: t0.addingTimeInterval(1))
        XCTAssertEqual(b.flush(now: t0.addingTimeInterval(31)).count, 1)
        XCTAssertNil(b.offer(notice("c"), now: t0.addingTimeInterval(32)), "the flushed post counts as the window's first")
    }
}

@MainActor
final class TeamNotificationsTests: XCTestCase {
    private var now = t0
    private var frontmost = false
    private var inPlaza: [String] = []
    private let poster = FakePoster()
    private var settings: TeamSettings!
    private var notifier: TeamNotifier!
    private let suite = "ptb.test.team.notifications.\(UUID().uuidString)"

    override func setUp() async throws {
        settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        notifier = TeamNotifier(settings: settings, poster: poster, isPlazaFrontmost: { [unowned self] in frontmost },
                                showInPlaza: { [unowned self] in inPlaza.append($0) }, clock: { [unowned self] in now })
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func testMegaphoneNotifiesOutsideThePlazaAndBannersInside() {
        notifier.megaphone(from: memberState("민수"), text: "점심!")
        XCTAssertEqual(poster.posts.map(\.body), [L(.ko).teamMegaphoneNotice(nickname: "민수", text: "점심!")])
        frontmost = true
        now = now.addingTimeInterval(TeamNotifier.megaphoneInterval)
        notifier.megaphone(from: memberState("민수"), text: "다시")
        XCTAssertEqual(inPlaza, [L(.ko).teamMegaphoneNotice(nickname: "민수", text: "다시")])
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testMegaphoneIsLimitedPerMemberAndFollowsTheSwitch() {
        notifier.megaphone(from: memberState("민수"), text: "하나")
        now = now.addingTimeInterval(TeamNotifier.megaphoneInterval - 1)
        notifier.megaphone(from: memberState("민수"), text: "둘")
        XCTAssertEqual(poster.posts.count, 1, "a second megaphone within a minute is dropped")
        settings.notificationsEnabled = false
        now = now.addingTimeInterval(120)
        notifier.megaphone(from: memberState("민수"), text: "셋")
        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertTrue(inPlaza.isEmpty)
    }

    func testOthersBigEventPosts() {
        notifier.bigEvent(bigEvent())
        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertEqual(poster.posts.first?.body, L(.ko).teamEventText(bigEvent()))
        XCTAssertTrue(inPlaza.isEmpty)
    }

    func testMyBigEventDoesNotPost() {
        notifier.bigEvent(bigEvent(author: settings.memberID))
        XCTAssertTrue(poster.posts.isEmpty)
    }

    func testNotificationsOffPostsNothing() {
        settings.notificationsEnabled = false
        notifier.bigEvent(bigEvent())
        notifier.reactionToMine(reaction(), bigEvent())
        notifier.emoteToMe(from: memberState("민수"), kind: .heart)
        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertTrue(inPlaza.isEmpty)
    }

    func testFrontmostPlazaShowsInsideInstead() {
        frontmost = true
        notifier.reactionToMine(reaction("민수"), bigEvent())
        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertEqual(inPlaza, [L(.ko).teamReactionNotice(nickname: "민수")])
    }

    func testFrontmostPlazaDoesNotRepeatWhatTheSceneAlreadyShows() {
        frontmost = true
        notifier.bigEvent(bigEvent())
        notifier.emoteToMe(from: memberState("민수"), kind: .heart)
        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertTrue(inPlaza.isEmpty)
    }

    func testEmoteToMePosts() {
        notifier.emoteToMe(from: memberState("민수"), kind: .heart)
        XCTAssertEqual(poster.posts.map(\.body), ["민수가 내 포켓몬에게 ♥"])
    }

    func testNoticeIDsAreUUIDsAndDoNotRepeatAcrossNotifiers() {
        let other = TeamNotifier(settings: settings, poster: poster, isPlazaFrontmost: { false }, showInPlaza: { _ in })
        notifier.emoteToMe(from: memberState("민수"), kind: .heart)
        other.emoteToMe(from: memberState("민수"), kind: .heart)
        let ids = poster.posts.map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: $0) != nil })
    }

    func testEmoteNoticeNamesEachKind() {
        let l = L(.ko)
        let expected: [TeamEmoteKind: String] = [
            .heart: "민수가 내 포켓몬에게 ♥", .lol: "민수가 내 포켓몬에게 ㅋㅋ", .party: "민수가 내 포켓몬에게 🎉",
            .exclaim: "민수가 내 포켓몬에게 !", .question: "민수가 내 포켓몬에게 ?", .tackle: "민수가 내 포켓몬에게 💥",
            .jump: "민수가 내 포켓몬에게 점프", .groupPhoto: "민수가 내 포켓몬에게 단체 사진",
            .pickup: "민수가 내 포켓몬에게 아이템", .firework: "민수가 내 포켓몬에게 불꽃놀이"]
        XCTAssertEqual(Set(expected.keys), Set(TeamEmoteKind.allCases))
        for (kind, text) in expected { XCTAssertEqual(l.teamEmoteNotice(nickname: "민수", kind: kind), text) }
    }

    func testBatchedNoticesBecomeOneSummary() {
        notifier.reactionToMine(reaction("민수"), bigEvent())
        notifier.reactionToMine(reaction("지영"), bigEvent())
        notifier.reactionToMine(reaction("철수"), bigEvent())
        XCTAssertEqual(poster.posts.count, 1)
        notifier.flush()
        XCTAssertEqual(poster.posts.count, 1, "window still open")
        now = t0.addingTimeInterval(30)
        notifier.flush()
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertEqual(poster.posts.last?.body, L(.ko).teamNoticeSummary(first: "지영", others: 1))
    }

    func testSameNicknameTwiceUsesSinglePersonWording() {
        notifier.reactionToMine(reaction("민수"), bigEvent())
        notifier.reactionToMine(reaction("민수"), bigEvent())
        notifier.reactionToMine(reaction("민수"), bigEvent())
        now = t0.addingTimeInterval(30)
        notifier.flush()
        XCTAssertEqual(poster.posts.last?.body, L(.ko).teamNoticeSummary(first: "민수", others: 0))
        XCTAssertFalse(poster.posts.last?.body.contains("외") ?? true)
    }

    func testFlushAfterNotificationsTurnedOffPostsNothing() {
        notifier.reactionToMine(reaction("민수"), bigEvent())
        notifier.reactionToMine(reaction("지영"), bigEvent())
        settings.notificationsEnabled = false
        now = t0.addingTimeInterval(30)
        notifier.flush()
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testBigEventDuringReactionWindowPostsItsOwnText() {
        notifier.reactionToMine(reaction("지영"), bigEvent())
        notifier.reactionToMine(reaction("철수"), bigEvent())
        notifier.reactionToMine(reaction("영희"), bigEvent())
        notifier.bigEvent(bigEvent(nick: "민수"))
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertEqual(poster.posts.last?.body, L(.ko).teamEventText(bigEvent(nick: "민수")))
        now = t0.addingTimeInterval(30)
        notifier.flush()
        XCTAssertEqual(poster.posts.count, 3)
        XCTAssertEqual(poster.posts.last?.body, L(.ko).teamNoticeSummary(first: "철수", others: 1))
    }

    func testTwoBigEventsInARowPostTwoNotices() {
        notifier.bigEvent(bigEvent("e1", nick: "민수"))
        notifier.bigEvent(bigEvent("e2", nick: "지영", kind: .graduate))
        XCTAssertEqual(poster.posts.map(\.body),
                       [L(.ko).teamEventText(bigEvent("e1", nick: "민수")),
                        L(.ko).teamEventText(bigEvent("e2", nick: "지영", kind: .graduate))])
    }

    /// Big news skips the batch, so a modified app could post one banner per frame. The board keeps them all.
    func testAFloodOfBigNewsStopsAtTheLimit() {
        for _ in 0..<50 { notifier.bigEvent(bigEvent(author: "bob")) }
        XCTAssertEqual(poster.posts.count, TeamNotifier.bigNoticeBurst)
        now = now.addingTimeInterval(TeamNotifier.bigNoticeInterval)
        notifier.bigEvent(bigEvent(author: "bob"))
        XCTAssertEqual(poster.posts.count, TeamNotifier.bigNoticeBurst + 1, "it comes back with time")
    }

    func testBigNewsHeldDuringFocusDoesNotSpendTheLimit() {
        notifier.isFocusing = { true }
        for _ in 0..<50 { notifier.bigEvent(bigEvent(author: "bob")) }
        XCTAssertEqual(notifier.heldTally.news, 50)
        notifier.isFocusing = { false }
        notifier.bigEvent(bigEvent(author: "bob"))
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testBigEventDoesNotOpenAWindow() {
        notifier.bigEvent(bigEvent())
        notifier.reactionToMine(reaction("지영"), bigEvent())
        XCTAssertEqual(poster.posts.count, 2)
    }

    func testSummaryWording() {
        XCTAssertEqual(L(.ko).teamNoticeSummary(first: "민수", others: 2), "민수 외 2명이 반응했어요")
        XCTAssertEqual(L(.ko).teamNoticeSummary(first: "민수", others: 0), "민수가 반응했어요")
    }

    func testNoticeTextHasNoUsageNumbers() {
        notifier.bigEvent(bigEvent())
        notifier.reactionToMine(reaction(), bigEvent())
        notifier.emoteToMe(from: memberState("민수"), kind: .party)
        now = t0.addingTimeInterval(30)
        notifier.flush()
        for p in poster.posts {
            let text = p.title + p.body
            XCTAssertNil(text.range(of: #"\d"#, options: .regularExpression), text)
        }
    }

    func testAuthorizationRequestedOnceAndOnlyWhenOn() {
        settings.notificationsEnabled = false
        notifier.requestAuthorizationIfNeeded()
        XCTAssertEqual(poster.authorizationRequests, 0)
        settings.notificationsEnabled = true
        notifier.requestAuthorizationIfNeeded()
        notifier.requestAuthorizationIfNeeded()
        XCTAssertEqual(poster.authorizationRequests, 1)
    }

    // MARK: - bundle guard and delegate

    func testNoLivePosterWithoutABundle() {
        XCTAssertNil(TeamNotifications.livePoster(isBundledApp: false))
        XCTAssertNil(TeamNotifications.installDelegate(isBundledApp: false, onOpenPlaza: {}))
    }

    func testTestProcessIsNotABundle() {
        XCTAssertFalse(AppEnv.isBundledApp)
    }

    func testPresentationOnlyForTeamNotifications() {
        XCTAssertEqual(TeamNotificationDelegate.presentationOptions(threadIdentifier: "team"), [.banner])
        XCTAssertEqual(TeamNotificationDelegate.presentationOptions(threadIdentifier: ""), [])
        XCTAssertEqual(TeamNotificationDelegate.presentationOptions(threadIdentifier: "other"), [])
    }

    func testOnlyTeamNotificationOpensThePlaza() {
        var opened = 0
        let delegate = TeamNotificationDelegate(onOpenPlaza: { opened += 1 })
        delegate.handleResponse(threadIdentifier: "other")
        XCTAssertEqual(opened, 0)
        delegate.handleResponse(threadIdentifier: "team")
        XCTAssertEqual(opened, 1)
    }

    func testPosterContentHasNoSoundAndTeamThread() {
        let content = LiveTeamNotificationPoster.content(title: "a", body: "b")
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.threadIdentifier, "team")
    }
}

@MainActor
final class TeamNotifierFocusTests: XCTestCase {
    private var frontmost = false
    private var focusing = true
    private var inPlaza: [String] = []
    private let poster = FakePoster()
    private var settings: TeamSettings!
    private var notifier: TeamNotifier!
    private let suite = "ptb.test.team.notifier.focus.\(UUID().uuidString)"

    override func setUp() async throws {
        settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        notifier = TeamNotifier(settings: settings, poster: poster, isPlazaFrontmost: { [unowned self] in frontmost },
                                showInPlaza: { [unowned self] in inPlaza.append($0) }, clock: { t0 })
        notifier.isFocusing = { [unowned self] in focusing }
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    private func holdSome() {
        let m = memberState("민수")
        notifier.emoteToMe(from: m, kind: .heart)
        notifier.emoteToMe(from: m, kind: .heart)
        notifier.emoteToMe(from: m, kind: .lol)
        notifier.emoteToMe(from: m, kind: .exclaim)
        for _ in 0..<3 { notifier.reactionToMine(reaction(), bigEvent()) }
        notifier.bigEvent(bigEvent())
    }

    func testFocusHoldsEmotesReactionsAndNewsButNotTheMegaphone() {
        holdSome()
        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertEqual(notifier.heldTally, TeamFocusTally(hearts: 2, lols: 1, parties: 0, reactions: 3, news: 1))
        notifier.emoteToMe(from: memberState("민수"), kind: .party)
        XCTAssertEqual(notifier.heldTally.parties, 1)
        notifier.megaphone(from: memberState("지영"), text: "점심!")
        XCTAssertEqual(poster.posts.count, 1)
    }

    func testFocusDoesNotHoldWhatThePlazaShows() {
        frontmost = true
        notifier.reactionToMine(reaction(), bigEvent())
        notifier.emoteToMe(from: memberState("민수"), kind: .heart)
        notifier.bigEvent(bigEvent())
        XCTAssertEqual(inPlaza.count, 1)
        XCTAssertEqual(notifier.heldTally, TeamFocusTally())
    }

    func testFocusEndPostsOneSummaryAndResets() {
        holdSome()
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertEqual(poster.posts.map(\.body), ["🔥 25분 집중 끝!\n그동안 ♥ 2 · ㅋㅋ 1 · 반응 3 · 소식 1"])
        XCTAssertEqual(notifier.heldTally, TeamFocusTally())
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertEqual(poster.posts.last?.body, "🔥 25분 집중 끝!")
        holdSome()
        frontmost = true
        notifier.focusEnded(PlazaFocusEnd(minutes: 50, elapsedMinutes: 50, completed: true))
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertEqual(inPlaza, ["🔥 50분 집중 끝!\n그동안 ♥ 2 · ㅋㅋ 1 · 반응 3 · 소식 1"])
    }

    func testFocusEndRespectsTheNotificationSwitch() {
        settings.notificationsEnabled = false
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertTrue(poster.posts.isEmpty)
        frontmost = true
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertEqual(inPlaza, ["🔥 25분 집중 끝!"])
    }

    func testEarlyStandUpLine() {
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 12, completed: false))
        XCTAssertEqual(poster.posts.map(\.body), ["집중을 마쳤어요 · 12분"])
    }

    func testResetDropsWhatWasHeldSoItNeverReachesTheNextFocus() {
        holdSome()
        notifier.reset()
        XCTAssertEqual(notifier.heldTally, TeamFocusTally())
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertEqual(poster.posts.map(\.body), ["🔥 25분 집중 끝!"])
    }

    func testSummaryPutsPartiesBetweenLolAndReactions() {
        let m = memberState("민수")
        notifier.emoteToMe(from: m, kind: .lol)
        notifier.emoteToMe(from: m, kind: .party)
        notifier.reactionToMine(reaction(), bigEvent())
        notifier.focusEnded(PlazaFocusEnd(minutes: 25, elapsedMinutes: 25, completed: true))
        XCTAssertEqual(poster.posts.map(\.body), ["🔥 25분 집중 끝!\n그동안 ㅋㅋ 1 · 🎉 1 · 반응 1"])
    }
}
