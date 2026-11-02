import XCTest
@testable import PokeTokenBar

final class PlazaRosterTests: XCTestCase {
    private func entry(_ id: String, _ nick: String, presence: PlazaPresence = .online, me: Bool = false) -> PlazaRosterEntry {
        PlazaRosterEntry(id: id, nickname: nick, speciesID: 25, speciesName: "x", gender: nil,
                         isShiny: false, presence: presence, isMe: me)
    }

    func testSortOrderMeOnlineAway() {
        let list = [entry("a", "다람", presence: .away), entry("b", "나무"), entry("c", "가지", presence: .away),
                    entry("d", "하늘"), entry("me", "힘", me: true)]
        XCTAssertEqual(PlazaRoster.sorted(list).map(\.id), ["me", "b", "d", "c", "a"])
    }

    func testMyEntryFollowsRaisedPinnedAndEgg() {
        let raised = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: 4, isShiny: true),
                                         followsRaised: true, raisedName: "파이리", raisedGender: .female,
                                         pinnedName: nil, eggName: "알")
        XCTAssertEqual(raised.speciesID, 4); XCTAssertEqual(raised.speciesName, "파이리")
        XCTAssertEqual(raised.gender, .female); XCTAssertTrue(raised.isShiny)
        XCTAssertTrue(raised.isMe); XCTAssertEqual(raised.presence, .online); XCTAssertEqual(raised.id, "m")

        let pinned = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: 25, isShiny: false),
                                         followsRaised: false, raisedName: "파이리", raisedGender: .female,
                                         pinnedName: "피카츄", eggName: "알")
        XCTAssertEqual(pinned.speciesID, 25); XCTAssertEqual(pinned.speciesName, "피카츄"); XCTAssertNil(pinned.gender)

        let egg = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: nil, isShiny: false),
                                      followsRaised: true, raisedName: "Token Egg", raisedGender: nil,
                                      pinnedName: nil, eggName: "알")
        XCTAssertNil(egg.speciesID); XCTAssertEqual(egg.speciesName, "알"); XCTAssertNil(egg.gender)
    }

    @MainActor func testMyEntryFromEggStoreUsesTeamSettings() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-roster-\(UUID().uuidString).json")
        let companion = CompanionStore(fileURL: url)
        let name = "plaza.roster.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = TeamSettings(defaults: UserDefaults(suiteName: name)!)
        settings.nickname = " 도토리 "
        let entry = PlazaRoster.myEntry(companion: companion, teamSettings: settings)
        XCTAssertEqual(entry.id, settings.memberID)
        XCTAssertEqual(entry.nickname, "도토리")
        XCTAssertNil(entry.speciesID)
        XCTAssertEqual(entry.speciesName, L(.ko).plazaEggName)
        XCTAssertTrue(entry.isMe)
    }

    func testIconURL() {
        XCTAssertEqual(PlazaIconLoader.url(speciesID: 25).absoluteString,
            "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-vii/icons/25.png")
    }

    func testRosterStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.plazaRosterTitle, "팀원"); XCTAssertEqual(l.plazaStatusOnline, "접속")
        XCTAssertEqual(l.plazaStatusAway, "잠"); XCTAssertEqual(l.plazaEggName, "알")
        XCTAssertEqual(l.plazaRosterCount(online: 3, total: 5), "접속 3 / 5")
    }
}

extension PlazaRosterTests {
    func testCharacterForTeamKeepsNameGenderAndDropsEggDetails() {
        let entry = PlazaRosterEntry(id: "m", nickname: "나", speciesID: 4, speciesName: "파이리", gender: .female,
                                     isShiny: true, presence: .online, isMe: true)
        let c = PlazaRoster.character(entry: entry, subject: .init(speciesID: 4, isShiny: true, form: nil))
        XCTAssertEqual(c, TeamMonSummary(speciesID: 4, isShiny: true, form: nil, speciesName: "파이리", gender: .female))
        let egg = PlazaRosterEntry(id: "m", nickname: "나", speciesID: nil, speciesName: "알", gender: nil,
                                   isShiny: false, presence: .online, isMe: true)
        let e = PlazaRoster.character(entry: egg, subject: .init(speciesID: nil, isShiny: false))
        XCTAssertEqual(e, TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil))
    }

    private func member(_ id: String, _ nick: String, inPlaza: Bool, speciesID: Int? = 25, name: String? = "Pikachu") -> TeamMemberState {
        TeamMemberState(memberID: id, nickname: nick,
                        character: TeamMonSummary(speciesID: speciesID, isShiny: true, form: nil, speciesName: name, gender: .female),
                        inPlaza: inPlaza, tile: nil, facing: nil, isWalking: false)
    }

    func testEntriesSortMeOnlineAway() {
        let me = entry("me", "힘", me: true)
        let list = PlazaRoster.entries(me: me, members: [member("a", "다람", inPlaza: false), member("b", "나무", inPlaza: true),
                                                         member("c", "가지", inPlaza: false)])
        XCTAssertEqual(list.map(\.id), ["me", "b", "c", "a"])
        XCTAssertEqual(PlazaRoster.entries(me: nil, members: [member("b", "나무", inPlaza: true)]).map(\.id), ["b"])
    }

    func testAwayEntryHasAwayPresence() {
        let list = PlazaRoster.entries(me: nil, members: [member("a", "다람", inPlaza: false), member("b", "나무", inPlaza: true)])
        XCTAssertEqual(list.first { $0.id == "a" }?.presence, .away)
        XCTAssertEqual(list.first { $0.id == "b" }?.presence, .online)
        let a = list.first { $0.id == "a" }
        XCTAssertEqual(a?.nickname, "다람"); XCTAssertEqual(a?.speciesID, 25); XCTAssertEqual(a?.speciesName, "Pikachu")
        XCTAssertEqual(a?.gender, .female); XCTAssertEqual(a?.isShiny, true); XCTAssertEqual(a?.isMe, false)
        let egg = PlazaRoster.entries(me: nil, members: [member("e", "알", inPlaza: true, speciesID: nil, name: nil)])
        XCTAssertEqual(egg.first?.speciesName, L(.ko).plazaEggName)
    }

    func testCapacityFitsHeight() {
        let m = PlazaRosterMetrics.self
        func panel(_ slots: Int) -> CGFloat {
            2 * m.margin + 2 * m.padding + m.headerHeight + m.listTopPadding
                + CGFloat(slots) * m.slotHeight + CGFloat(slots - 1) * m.slotSpacing
        }
        XCTAssertEqual(PlazaRoster.capacity(forHeight: panel(5)), 5)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: panel(5) - 1), 4, "one point short loses a slot")
        XCTAssertEqual(PlazaRoster.capacity(forHeight: panel(5) + 47), 5)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: panel(5) + 48), 6)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 0), 2, "never fewer than me plus a more row")
    }

    func testOverflowShowsMoreRowAndHidesAwayMembers() {
        let entries = PlazaRoster.sorted([entry("me", "나", me: true)]
            + (0..<5).map { entry("o\($0)", "온\($0)") } + (0..<4).map { entry("a\($0)", "잠\($0)", presence: .away) })
        XCTAssertEqual(entries.count, 10)
        let (shown, hidden) = PlazaRoster.visible(entries, capacity: 5)
        XCTAssertEqual(shown.count, 4); XCTAssertEqual(hidden, 6)
        XCTAssertEqual(shown.first?.id, "me")
        let fits = PlazaRoster.visible(entries, capacity: 10)
        XCTAssertEqual(fits.shown.count, 10); XCTAssertEqual(fits.hidden, 0)
        XCTAssertEqual(L(.ko).plazaRosterMore(6), "외 6명")
        XCTAssertEqual(L(.ko).plazaAwaySuffix, "zZ")
    }
}
