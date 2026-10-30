import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamFeedStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("team-feed.json") }
    private var now = Date(timeIntervalSince1970: 1_793_242_800) // 2026-10-29 12:00 KST

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamFeedStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> TeamFeedStore {
        TeamFeedStore(fileURL: url, myMemberID: "me", clock: { [now] in now }, calendar: calendar)
    }

    private func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func event(_ id: String, author: String = "bob", at: Date? = nil, day: String? = nil) -> TeamEvent {
        TeamEvent(id: id, authorID: author, authorNickname: author, kind: .hatch,
                  speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
                  form: nil, isShiny: false, nature: nil, rarity: .common,
                  day: day ?? dayString(at ?? now), occurredAt: at)
    }

    private func reaction(_ id: String, event: String = "e1", author: String = "bob",
                          kind: TeamReactionKind = .cute, text: String? = nil, at: Date? = nil) -> TeamReaction {
        TeamReaction(id: id, eventID: event, authorID: author, authorNickname: author,
                     kind: kind, text: text, createdAt: at ?? now)
    }

    func testDuplicateEventIsIgnored() {
        let store = makeStore()
        let e1 = event("e1", at: now)
        XCTAssertTrue(store.insert(e1))
        XCTAssertFalse(store.insert(e1))
        XCTAssertEqual(store.events.count, 1)
    }

    func testPresetReactionOncePerAuthorButCommentsMany() {
        let store = makeStore()
        store.insert(event("e1", at: now))
        XCTAssertTrue(store.insert(reaction("r1", kind: .cute)))
        XCTAssertFalse(store.insert(reaction("r2", kind: .cute)))
        XCTAssertTrue(store.insert(reaction("r3", kind: .lol)))
        XCTAssertTrue(store.insert(reaction("r4", kind: .comment, text: "hi")))
        XCTAssertTrue(store.insert(reaction("r5", kind: .comment, text: "yo")))
        XCTAssertFalse(store.insert(reaction("r1", kind: .congrats)))
        XCTAssertEqual(store.reactions(for: "e1").count, 4)
    }

    func testCommentLengthLimit() {
        let store = makeStore()
        store.insert(event("e1", at: now))
        XCTAssertFalse(store.insert(reaction("r1", kind: .comment, text: String(repeating: "a", count: 41))))
        XCTAssertFalse(store.insert(reaction("r2", kind: .comment, text: "  \n ")))
        XCTAssertFalse(store.insert(reaction("r3", kind: .comment, text: nil)))
        XCTAssertTrue(store.insert(reaction("r4", kind: .comment, text: String(repeating: "가", count: 40))))
        XCTAssertTrue(store.insert(reaction("r5", kind: .comment, text: "  trimmed \n")))
        XCTAssertEqual(store.reactions(for: "e1").last?.text, "trimmed")
    }

    func testOrderingPutsDayOnlyAtStartOfItsDay() {
        let store = makeStore()
        let todayStart = calendar.startOfDay(for: now)
        let yesterday23 = todayStart.addingTimeInterval(-3600)
        let today9 = todayStart.addingTimeInterval(9 * 3600)
        store.insert(event("a", at: yesterday23))
        store.insert(event("b", at: nil, day: dayString(now)))
        store.insert(event("c", at: today9))
        XCTAssertEqual(store.events.map(\.id), ["c", "b", "a"])
    }

    func testUnreadCountsOnlyOthersAfterMarkRead() {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        XCTAssertEqual(store.unreadCount, 0)
        store.insert(event("e1", at: now))
        XCTAssertEqual(store.unreadCount, 1)
        now = now.addingTimeInterval(10)
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        // clock captured at make time, so build a later store to simulate new arrival
        let later = TeamFeedStore(fileURL: url, myMemberID: "me", clock: { [now] in now.addingTimeInterval(60) }, calendar: calendar)
        XCTAssertEqual(later.unreadCount, 0)
        later.insert(event("e2", at: now))
        XCTAssertEqual(later.unreadCount, 1)
    }

    private final class ClockBox { var now: Date; init(_ n: Date) { now = n } }

    func testInsertOfAlreadyExpiredEventReturnsFalse() {
        let store = makeStore()
        let old = event("old", at: now.addingTimeInterval(-8 * 86400))
        XCTAssertFalse(store.insert(old))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.eventIDs.isEmpty)
    }

    func testPruneDropsAgedEventAndItsOldReactions() {
        let box = ClockBox(now)
        let store = TeamFeedStore(fileURL: url, myMemberID: "me", clock: { box.now }, calendar: calendar)
        XCTAssertTrue(store.insert(event("e1", at: now)))
        XCTAssertTrue(store.insert(reaction("r1", event: "e1", at: now)))
        box.now = now.addingTimeInterval(9 * 86400)
        store.prune()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.reactionIDs.contains("r1"))
    }

    func testPruneKeepsRecentReactionOfDroppedEvent() {
        let box = ClockBox(now)
        let store = TeamFeedStore(fileURL: url, myMemberID: "me", clock: { box.now }, calendar: calendar)
        XCTAssertTrue(store.insert(event("e1", at: now)))
        box.now = now.addingTimeInterval(9 * 86400)
        // Reaction created recently (relative to the advanced clock) survives its event's pruning.
        XCTAssertTrue(store.insert(reaction("r1", event: "e1", at: box.now)))
        store.prune()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.reactionIDs.contains("r1"))
    }

    func testPruneKeepsFreshOrphanReactionAndCapsEvents() {
        let store = makeStore()
        XCTAssertTrue(store.insert(reaction("orphan", event: "later")))
        store.prune()
        XCTAssertTrue(store.reactionIDs.contains("orphan"))
        for i in 0..<(TeamFeedStore.maxEvents + 5) {
            store.insert(event("e\(i)", at: now.addingTimeInterval(Double(-i))))
        }
        XCTAssertEqual(store.events.count, TeamFeedStore.maxEvents)
        XCTAssertEqual(store.events.first?.id, "e0")
    }

    func testPersistsAcrossInstances() {
        let store = makeStore()
        store.insert(event("e1", at: now))
        store.insert(reaction("r1"))
        let again = makeStore()
        XCTAssertEqual(again.events.map(\.id), ["e1"])
        XCTAssertEqual(again.reactions(for: "e1").map(\.id), ["r1"])
        XCTAssertEqual(again.unreadCount, 1)
        XCTAssertEqual(again.eventIDs, ["e1"])
        XCTAssertEqual(again.events(notIn: ["e1"]).count, 0)
        XCTAssertEqual(again.reactions(notIn: []).count, 1)
    }

    private func makeBoxedStore(_ box: ClockBox) -> TeamFeedStore {
        TeamFeedStore(fileURL: url, myMemberID: "me", clock: { box.now }, calendar: calendar)
    }

    func testReactionOnMyEventCountsAsUnread() {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        XCTAssertEqual(store.unreadCount, 0)
        store.insert(reaction("r1", event: "mine", author: "bob"))
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testReactionOnOthersEventDoesNotCount() {
        let box = ClockBox(now)
        let store = makeBoxedStore(box)
        store.insert(event("e1", author: "bob", at: now))
        box.now = now.addingTimeInterval(10)
        store.markAllRead()
        box.now = now.addingTimeInterval(20)
        store.insert(reaction("r1", event: "e1", author: "carol"))
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testMyOwnReactionDoesNotCount() {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        store.insert(reaction("r1", event: "mine", author: "me"))
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testMarkAllReadClearsEventsAndReactions() {
        let box = ClockBox(now)
        let store = makeBoxedStore(box)
        store.insert(event("mine", author: "me", at: now))
        store.insert(event("e1", author: "bob", at: now))
        store.insert(reaction("r1", event: "mine", author: "bob"))
        XCTAssertEqual(store.unreadCount, 2)
        box.now = now.addingTimeInterval(10)
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        box.now = now.addingTimeInterval(20)
        store.insert(reaction("r2", event: "mine", author: "carol"))
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testUnreadReactionSurvivesReload() {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        store.insert(reaction("r1", event: "mine", author: "bob"))
        XCTAssertEqual(makeStore().unreadCount, 1)
    }

    func testResetClearsEverythingAndPersists() {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        store.insert(reaction("r1", event: "mine", author: "bob"))
        store.markAllRead()
        store.reset()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.reactionIDs.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
        let again = makeStore()
        XCTAssertTrue(again.events.isEmpty)
        XCTAssertTrue(again.reactionIDs.isEmpty)
        // The read marker is gone too: a fresh event at the same instant is unread.
        again.insert(event("e2", author: "bob", at: now))
        XCTAssertEqual(again.unreadCount, 1)
    }

    func testCorruptFileStartsEmptyAndKeepsBackup() throws {
        try Data("{not json".utf8).write(to: url)
        let s = makeStore()
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }
}
