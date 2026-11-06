import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamFeedStoreTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
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

    // MARK: - Hostile rows

    /// Every row goes through here, so a String field added later without a limit fails without anyone writing a test.
    private func assertEveryStringIsBounded<T: Codable>(_ row: T, insert: (T, TeamFeedStore) -> Void,
                                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        let keys = object.compactMap { $0.value is String ? $0.key : nil }
        XCTAssertGreaterThan(keys.count, 3, file: file, line: line)
        for key in keys {
            var bad = object
            // Leading zeros keep a date readable, so the size is the only thing wrong with it.
            bad[key] = String(repeating: "0", count: 2000) + (try XCTUnwrap(object[key] as? String))
            let data = try JSONSerialization.data(withJSONObject: bad)
            guard let hostile = try? JSONDecoder().decode(T.self, from: data) else { continue }   // an enum refuses it
            let target = dir.appendingPathComponent("\(UUID().uuidString).json")
            insert(hostile, TeamFeedStore(fileURL: target, myMemberID: "me", clock: { [now] in now }, calendar: calendar))
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
            XCTAssertLessThan(size, 1024, "\(key) reached the disk at full size", file: file, line: line)
        }
    }

    func testEveryStringFieldOfAnEventIsBounded() throws {
        let e = TeamEvent(id: "e", authorID: "bob", authorNickname: "bob", kind: .evolve, speciesID: 25, fromSpeciesID: 172,
                          speciesName: "Pikachu", fromSpeciesName: "Pichu", form: PokemonForm("sandy"), isShiny: false,
                          nature: .hardy, rarity: .common, day: dayString(now), occurredAt: now)
        XCTAssertEqual(makeStore().insert([e]).count, 1, "the row is fine until a field is blown up")
        try assertEveryStringIsBounded(e) { _ = $1.insert([$0]) }
    }

    func testEveryStringFieldOfAReactionIsBounded() throws {
        let r = TeamReaction(id: "r", eventID: "e", authorID: "bob", authorNickname: "bob", kind: .cute, text: "x", createdAt: now)
        XCTAssertEqual(makeStore().insert([r]).count, 1, "the row is fine until a field is blown up")
        try assertEveryStringIsBounded(r) { _ = $1.insert([$0]) }
    }

    /// `validNickname` trims before it measures, so the row keeps what the check never saw.
    func testSpacesDoNotHideANicknamesSize() {
        let padded = "A" + String(repeating: " ", count: 2000)
        let store = makeStore()
        XCTAssertTrue(store.insert([TeamEvent(id: "e", authorID: "bob", authorNickname: padded, kind: .hatch, speciesID: 25,
                                              fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil, form: nil,
                                              isShiny: false, nature: nil, rarity: .common, day: dayString(now),
                                              occurredAt: nil)]).isEmpty)
        XCTAssertTrue(store.insert([TeamReaction(id: "r", eventID: "e", authorID: "bob", authorNickname: padded, kind: .cute,
                                                 text: nil, createdAt: now)]).isEmpty)
    }

    /// One row too big used to stop its whole batch of 100, so honest news never reached a newcomer.
    func testAFullBatchOfTheLargestRowsFitsInAFrame() throws {
        let long = String(repeating: "\"", count: TeamWire.maxFieldBytes)   // a quote costs two bytes in JSON
        let name = String(repeating: "\"", count: 12)
        let events = (0..<TeamSession.batchSize).map { _ in
            TeamEvent(id: long, authorID: long, authorNickname: name, kind: .evolve, speciesID: .max, fromSpeciesID: .max,
                      speciesName: long, fromSpeciesName: long, form: PokemonForm(long), isShiny: true, nature: .hardy,
                      rarity: .legendary, day: long, occurredAt: now)
        }
        XCTAssertNoThrow(try TeamWire.encode(.events(events, live: false)))
        let reactions = (0..<TeamSession.batchSize).map { _ in
            TeamReaction(id: long, eventID: long, authorID: long, authorNickname: name, kind: .congrats, text: nil, createdAt: now)
        }
        XCTAssertNoThrow(try TeamWire.encode(.reactions(reactions, live: false)))
    }

    func testAFrameOfDuplicatesKeepsOneOfEach() {
        let store = makeStore()
        XCTAssertEqual(store.insert([event("a"), event("a"), event("b")]).map(\.id).sorted(), ["a", "b"])
        let r = TeamReaction(id: "r", eventID: "a", authorID: "bob", authorNickname: "bob", kind: .cute, text: nil, createdAt: now)
        let sameSlot = TeamReaction(id: "r2", eventID: "a", authorID: "bob", authorNickname: "bob", kind: .cute, text: nil, createdAt: now)
        let otherKind = TeamReaction(id: "r3", eventID: "a", authorID: "bob", authorNickname: "bob", kind: .lol, text: nil, createdAt: now)
        XCTAssertEqual(store.insert([r, r, sameSlot, otherKind]).map(\.id), ["r", "r3"])
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

    func testGregorianDayIsReadOnANonGregorianMac() {
        let sent = CompanionTeamEvent(kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu",
                                      fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common)
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            var local = Calendar(identifier: identifier)
            local.timeZone = calendar.timeZone
            let file = dir.appendingPathComponent("\(identifier).json")
            let e = TeamEventFactory.make(sent, authorID: "bob", nickname: "bob", now: now,
                                          hasOnlinePeers: false, calendar: local)
            let store = TeamFeedStore(fileURL: file, myMemberID: "me", clock: { [now] in now }, calendar: local)
            XCTAssertTrue(store.insert(e), "today's event is admitted on \(identifier)")
            XCTAssertFalse(store.insert(event("old", day: "2026-01-01")), "the window still applies on \(identifier)")
            let reopened = TeamFeedStore(fileURL: file, myMemberID: "me", clock: { [now] in now }, calendar: local)
            XCTAssertEqual(reopened.events.map(\.id), [e.id], "launch pruning keeps it on \(identifier)")
        }
    }

    func testDuplicateEventIsIgnored() {
        let store = makeStore()
        let e1 = event("e1", at: now)
        XCTAssertTrue(store.insert(e1))
        XCTAssertFalse(store.insert(e1))
        XCTAssertEqual(store.events.count, 1)
    }

    func testPresetReactionOncePerAuthor() {
        let store = makeStore()
        store.insert(event("e1", at: now))
        XCTAssertTrue(store.insert(reaction("r1", kind: .cute)))
        XCTAssertFalse(store.insert(reaction("r2", kind: .cute)))
        XCTAssertTrue(store.insert(reaction("r3", kind: .lol)))
        XCTAssertFalse(store.insert(reaction("r1", kind: .congrats)))
        XCTAssertEqual(store.reactions(for: "e1").count, 2)
    }

    /// R25: no UI draws or sends comments, so one that arrives is dropped (the enum case stays for the wire).
    func testCommentReactionsAreRejected() {
        let store = makeStore()
        store.insert(event("e1", author: "me", at: now))
        XCTAssertFalse(store.insert(reaction("r1", event: "e1", kind: .comment, text: "hi")))
        XCTAssertFalse(store.insert(reaction("r2", event: "e1", kind: .comment, text: nil)))
        XCTAssertTrue(store.reactionIDs.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
    }

    private func longChain() -> String { "👨" + String(repeating: "\u{200D}👨", count: 999) }

    private func eventWith(id: String = "e1", author: String = "bob", nickname: String = "bob", species: String = "Pikachu",
                           from: String? = nil, day: String? = nil, at: Date? = nil) -> TeamEvent {
        TeamEvent(id: id, authorID: author, authorNickname: nickname, kind: .evolve,
                  speciesID: 25, fromSpeciesID: nil, speciesName: species, fromSpeciesName: from,
                  form: nil, isShiny: false, nature: nil, rarity: .common,
                  day: day ?? dayString(at ?? now), occurredAt: at)
    }

    func testEventTextFieldsAreBoundedInBytes() {
        let store = makeStore()
        let max = String(repeating: "a", count: 64), over = String(repeating: "a", count: 65)
        XCTAssertTrue(store.insert(eventWith(id: max)))
        XCTAssertFalse(store.insert(eventWith(id: over)))
        XCTAssertFalse(store.insert(eventWith(id: "x1", author: over)))
        XCTAssertFalse(store.insert(eventWith(id: "x2", species: over)))
        XCTAssertFalse(store.insert(eventWith(id: "x3", from: over)))
        XCTAssertFalse(store.insert(eventWith(id: "x4", nickname: longChain())))
        XCTAssertFalse(store.insert(eventWith(id: "x5", nickname: "")))
        XCTAssertFalse(store.insert(eventWith(id: "x6", species: String(repeating: "가", count: 22))), "66 bytes")
        XCTAssertTrue(store.insert(eventWith(id: "x7", species: String(repeating: "가", count: 21), from: "깨봉이")))
        XCTAssertEqual(store.events.count, 2)
    }

    func testEventDatesMustBeInsideRetentionAndNextDay() throws {
        let store = makeStore()
        XCTAssertFalse(store.insert(eventWith(id: "past", at: now.addingTimeInterval(-8 * 86400))))
        XCTAssertFalse(store.insert(eventWith(id: "future", at: now.addingTimeInterval(2 * 86400))))
        XCTAssertFalse(store.insert(eventWith(id: "futureDay", day: dayString(now.addingTimeInterval(3 * 86400)))))
        XCTAssertFalse(store.insert(eventWith(id: "pastDay", day: dayString(now.addingTimeInterval(-9 * 86400)))))
        XCTAssertFalse(store.insert(eventWith(id: "garbageDay", day: "soon")))
        let ancient = Date(timeIntervalSince1970: -62_200_000_000)   // year 0: cannot be written as ISO 8601
        XCTAssertFalse(store.insert(eventWith(id: "year0", day: dayString(now), at: ancient)))
        XCTAssertTrue(store.insert(eventWith(id: "ok", at: now.addingTimeInterval(3600))))
        XCTAssertEqual(makeStore().events.map(\.id), ["ok"], "the file still decodes on the next launch")
    }

    func testReactionFieldsAndDatesAreValidated() {
        let store = makeStore()
        let over = String(repeating: "a", count: 65)
        func r(_ id: String, event: String = "e1", author: String = "bob", nick: String = "bob", at: Date) -> TeamReaction {
            TeamReaction(id: id, eventID: event, authorID: author, authorNickname: nick, kind: .cute, text: nil, createdAt: at)
        }
        XCTAssertFalse(store.insert(r(over, at: now)))
        XCTAssertFalse(store.insert(r("a", event: over, at: now)))
        XCTAssertFalse(store.insert(r("b", author: over, at: now)))
        XCTAssertFalse(store.insert(r("c", nick: longChain(), at: now)))
        XCTAssertFalse(store.insert(r("d", at: now.addingTimeInterval(2 * 86400))))
        XCTAssertFalse(store.insert(r("e", at: now.addingTimeInterval(-8 * 86400))))
        XCTAssertFalse(store.insert(r("f", at: Date(timeIntervalSince1970: -62_200_000_000))))
        XCTAssertTrue(store.insert(r("ok", at: now)))
        XCTAssertEqual(store.reactionIDs, ["ok"])
    }

    func testReactionsAreCappedOldestFirst() {
        let store = makeStore()
        let total = TeamFeedStore.maxReactions + 5
        let batch = (0..<total).map { i in
            reaction("r\(i)", event: "e1", author: "a\(i)", at: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.insert(batch).count, TeamFeedStore.maxReactions, "the five oldest are not new")
        XCTAssertEqual(store.reactionIDs.count, TeamFeedStore.maxReactions)
        XCTAssertFalse(store.reactionIDs.contains("r0"))
        XCTAssertTrue(store.reactionIDs.contains("r\(total - 1)"))
    }

    func testBatchInsertSavesOncePerFrame() {
        let store = makeStore()
        let before = store.saveCount
        let events = (0..<100).map { eventWith(id: "e\($0)", at: now.addingTimeInterval(Double(-$0))) }
        XCTAssertEqual(store.insert(events).count, 100)
        XCTAssertEqual(store.saveCount, before + 1)
        XCTAssertEqual(store.insert(events).count, 0, "duplicates are not new and cost no save")
        XCTAssertEqual(store.saveCount, before + 1)
        let reactions = (0..<100).map { reaction("r\($0)", event: "e0", author: "a\($0)") }
        XCTAssertEqual(store.insert(reactions).count, 100)
        XCTAssertEqual(store.saveCount, before + 2)
        XCTAssertEqual(makeStore().reactionIDs.count, 100)
    }

    func testCutoffDayEventFromFarEastSenderIsAdmitted() {
        let store = makeStore()
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(-7 * 86_400)
        // The sender's local day is the cutoff day, but in this calendar the instant lies before the cutoff.
        let eastern = event("east", at: cutoff.addingTimeInterval(-10 * 3600), day: dayString(cutoff))
        XCTAssertTrue(store.insert(eastern))
        let tooOld = event("old", at: cutoff.addingTimeInterval(-2 * 86_400), day: dayString(cutoff))
        XCTAssertFalse(store.insert(tooOld), "the extra day below the cutoff is all that is allowed")
        let oldDay = event("oldday", at: nil, day: dayString(cutoff.addingTimeInterval(-86_400)))
        XCTAssertFalse(store.insert(oldDay), "the day string decides the lower bound")
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

    func testFreshStoreWritesNoFile() {
        _ = makeStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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

    /// Unread is ordered by a local counter, not a wall clock: a frozen clock must still tell old from new.
    func testUnreadNeedsNoClock() {
        let store = makeStore()   // the clock never moves
        store.insert(event("e1", at: now))
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        store.insert(event("e2", at: now))
        XCTAssertEqual(store.unreadCount, 1)
        let again = makeStore()
        XCTAssertEqual(again.unreadCount, 1)
        again.markAllRead()
        XCTAssertEqual(makeStore().unreadCount, 0)
    }

    /// R26: nothing on disk says when a reaction was made or received, or when the feed was read.
    func testStoredReactionHoldsNoTimeOfDay() throws {
        let store = makeStore()
        store.insert(event("mine", author: "me", at: now))
        let afternoon = calendar.startOfDay(for: now).addingTimeInterval(15 * 3600 + 123.456)
        store.insert(reaction("r1", event: "mine", at: afternoon))
        store.markAllRead()
        XCTAssertEqual(store.reactions(for: "mine").first?.createdAt, calendar.startOfDay(for: now))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("receivedAt"))
        XCTAssertFalse(text.contains("lastReadAt"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let stored = try XCTUnwrap((json["reactions"] as? [[String: Any]])?.first)
        let reactionJSON = try XCTUnwrap(stored["reaction"] as? [String: Any])
        let created = try XCTUnwrap(reactionJSON["createdAt"] as? String)
        XCTAssertEqual(created, ISO8601DateFormatter().string(from: calendar.startOfDay(for: now)))
        XCTAssertEqual(Set(stored.keys), ["reaction", "seq"])
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        // The read marker is gone too: a fresh event at the same instant is unread.
        again.insert(event("e2", author: "bob", at: now))
        XCTAssertEqual(again.unreadCount, 1)
    }

    /// The backup of an unreadable file is the old team's feed too.
    func testResetDeletesTheCorruptBackup() throws {
        try Data("{not json".utf8).write(to: url)
        let store = makeStore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    func testCorruptFileStartsEmptyAndKeepsBackup() throws {
        try Data("{not json".utf8).write(to: url)
        let s = makeStore()
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }
}
