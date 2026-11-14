import XCTest
import AppKit
@testable import PokeTokenBar

private func event(_ id: String = "e1", author: String = "a", nick: String = "민수", kind: TeamEventKind = .hatch,
                   species: String = "깨봉이", from: String? = nil, shiny: Bool = false,
                   day: String = "2026-10-30", at: Date? = nil) -> TeamEvent {
    TeamEvent(id: id, authorID: author, authorNickname: nick, kind: kind, speciesID: 25, fromSpeciesID: from == nil ? nil : 24,
              speciesName: species, fromSpeciesName: from, form: nil, isShiny: shiny, nature: nil, rarity: .common,
              day: day, occurredAt: at)
}

@MainActor
final class PlazaBoardRowTests: XCTestCase {
    private var dirs: [URL] = []
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func feed() -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardRowTests-\(UUID())")
        dirs.append(dir)
        return TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me",
                             clock: { Date(timeIntervalSince1970: 1_793_400_000) }, calendar: calendar)
    }

    private func reaction(_ id: String, by nick: String, _ kind: TeamReactionKind, on e: String = "e1", author: String? = nil) -> TeamReaction {
        TeamReaction(id: id, eventID: e, authorID: author ?? nick, authorNickname: nick, kind: kind,
                     text: kind == .comment ? "hi" : nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100))
    }

    func testRowsFollowFeedOrderNewestFirst() {
        let f = feed()
        f.insert(event("old", day: "2026-10-28"))
        f.insert(event("new", day: "2026-10-30"))
        XCTAssertEqual(PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar).map(\.id), ["new", "old"])
    }

    func testDateShowsTimeOnlyWhenKnown() {
        let f = feed()
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 5))!
        f.insert(event("timed", at: at))
        f.insert(event("dated", day: "2026-10-29"))
        let rows = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)
        let l = L(.ko)
        XCTAssertEqual(rows.first { $0.id == "timed" }?.date, l.teamBoardDate(month: 10, day: 30, time: "14:05"))
        XCTAssertEqual(rows.first { $0.id == "dated" }?.date, l.teamBoardDate(month: 10, day: 29, time: nil))
        XCTAssertNotEqual(rows.first { $0.id == "timed" }?.date, rows.first { $0.id == "dated" }?.date)
    }

    func testRowFlagsBigAndShiny() {
        let f = feed()
        f.insert(event("big", kind: .graduate, shiny: true))
        f.insert(event("small", kind: .evolve, from: "깨봉이", day: "2026-10-29"))
        let rows = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)
        XCTAssertEqual(rows.first { $0.id == "big" }.map { ($0.isBig, $0.isShiny) }.map { [$0.0, $0.1] }, [true, true])
        XCTAssertEqual(rows.first { $0.id == "small" }.map { ($0.isBig, $0.isShiny) }.map { [$0.0, $0.1] }, [false, false])
    }

    func testReactionsGroupedByKindWithNicknamesAndCommentsHidden() {
        let f = feed()
        f.insert(event())
        f.insert(reaction("r1", by: "영희", .cute))
        f.insert(reaction("r2", by: "철수", .cute))
        f.insert(reaction("r3", by: "영희", .congrats))
        f.insert(reaction("r4", by: "철수", .comment))
        let row = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)[0]
        XCTAssertEqual(row.reactions.map(\.kind), [.cute, .congrats])
        XCTAssertEqual(row.reactions.map(\.nicknames), [["영희", "철수"], ["영희"]])
    }

    func testMyReactionIsMarkedSoItsButtonCanBeDisabled() {
        let f = feed()
        f.insert(event())
        f.insert(reaction("r1", by: "나", .lol, author: "me"))
        let row = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)[0]
        XCTAssertEqual(row.mine, [.lol])
        XCTAssertEqual(PlazaBoardRow.buttonKinds, [.cute, .lol, .congrats])
    }
}
