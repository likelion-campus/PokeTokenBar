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
