import XCTest
@testable import PokeTokenBar

private func tNode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private func tLine(base: Int, tree: EvoNode, rarity: Rarity) -> EvoLine {
    func ids(_ n: EvoNode) -> [Int] { [n.speciesID] + n.children.flatMap(ids) }
    var names: [Int: [String: String]] = [:]
    for id in ids(tree) { names[id] = ["en": "P\(id)", "ko": "포\(id)", "ja": "ポ\(id)"] }
    return EvoLine(baseID: base, tree: tree, rarity: rarity, names: names)
}
private let teamLinear3 = tLine(base: 1, tree: tNode(1, [tNode(2, [tNode(3)])]), rarity: .common)
private let teamDitto = tLine(base: 132, tree: tNode(132), rarity: .rare)
private let teamNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Serves the disguise line for any base except Ditto.
private struct TeamTestProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        baseSpeciesID == PokemonOdds.dittoSpeciesID ? teamDitto : teamLinear3
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: 1, captureRate: 255)] }
}

/// Always 0: shiny roll hits and the Ditto disguise roll hits (0 % 128 == 0).
private struct ZeroRNG: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0 }
}

final class TeamEventFactoryTests: XCTestCase {
    private let sample = CompanionTeamEvent(
        kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
        form: nil, isShiny: true, nature: .adamant, rarity: .rare)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }
    // 2026-10-29 12:00 KST
    private var noonOct29: Date { Date(timeIntervalSince1970: 1_793_242_800) }

    func testFactoryUsesExactTimeOnlyWhenPeersOnline() {
        let e = TeamEventFactory.make(sample, authorID: "m1", nickname: "민수", now: noonOct29,
                                      hasOnlinePeers: true, calendar: calendar)
        XCTAssertEqual(e.occurredAt, noonOct29); XCTAssertEqual(e.day, "2026-10-29")
        let off = TeamEventFactory.make(sample, authorID: "m1", nickname: "민수", now: noonOct29,
                                        hasOnlinePeers: false, calendar: calendar)
        XCTAssertNil(off.occurredAt); XCTAssertEqual(off.day, "2026-10-29")
    }

    func testDayUsesCalendarTimeZone() {
        // 2026-10-29 16:00 UTC is already Oct 30 in Seoul.
        let t = Date(timeIntervalSince1970: 1_793_289_600)
        let e = TeamEventFactory.make(sample, authorID: "m1", nickname: "n", now: t,
                                      hasOnlinePeers: false, calendar: calendar)
        XCTAssertEqual(e.day, "2026-10-30")
    }

    func testEncodedEventCarriesNoUsageNumbers() throws {
        let e = TeamEventFactory.make(sample, authorID: "m1", nickname: "민수", now: noonOct29,
                                      hasOnlinePeers: true, calendar: calendar)
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        for banned in ["token", "Token", "cost", "usage", "limit", "progress", "usedAt"] {
            XCTAssertFalse(json.contains(banned), banned)
        }
    }

    func testBigKinds() {
        XCTAssertFalse(TeamEventKind.evolve.isBig)
        XCTAssertTrue(TeamEventKind.hatch.isBig && TeamEventKind.graduate.isBig && TeamEventKind.dittoReveal.isBig)
    }
}

@MainActor
final class TeamEventHookTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("team-\(UUID().uuidString).json")
    }
    private func store(rng: any RandomNumberGenerator = SeededRNG(seed: 7), disguise: Bool = false,
                       url: URL? = nil) -> CompanionStore {
        CompanionStore(provider: TeamTestProvider(), clock: { teamNow }, fileURL: url ?? tempURL(),
                       rng: rng, dittoDisguiseRollingEnabled: disguise)
    }

    func testHatchHookFiresOnceWithBaseSpecies() async {
        let s = store()
        var events: [CompanionTeamEvent] = []
        s.onTeamEvent = { events.append($0) }
        await s.hatch(baseID: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .hatch)
        XCTAssertEqual(events.first?.speciesID, 1)
        XCTAssertNil(events.first?.fromSpeciesID)
        XCTAssertEqual(events.first?.speciesName, "포1")
        XCTAssertEqual(events.first?.rarity, .common)
        XCTAssertEqual(events.first?.isShiny, s.currentIsShiny)
    }

    func testDisguisedDittoHatchHidesShiny() async {
        let s = store(rng: ZeroRNG(), disguise: true)
        var events: [CompanionTeamEvent] = []
        s.onTeamEvent = { events.append($0) }
        await s.hatch(baseID: 1)
        XCTAssertNotNil(s.state.active?.dittoDisguise, "fixture must produce a disguised Ditto")
        XCTAssertEqual(s.state.active?.isShiny, true, "fixture must be internally shiny")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.isShiny, false)
        XCTAssertEqual(events.first?.speciesID, 1)
    }

    func testEvolveAndGraduateHooksFire() async {
        let s = store()
        await s.hatch(baseID: 1)
        var events: [CompanionTeamEvent] = []
        s.onTeamEvent = { events.append($0) }
        s.applyUsage(100_000_000_000)
        XCTAssertEqual(events.map(\.kind), [.evolve, .evolve, .graduate])
        XCTAssertEqual(events[0].fromSpeciesID, 1); XCTAssertEqual(events[0].speciesID, 2)
        XCTAssertEqual(events[0].fromSpeciesName, "포1"); XCTAssertEqual(events[0].speciesName, "포2")
        XCTAssertEqual(events[1].fromSpeciesID, 2); XCTAssertEqual(events[1].speciesID, 3)
        XCTAssertEqual(events[2].speciesID, 3)
        XCTAssertNil(events[2].fromSpeciesID)
    }

    func testDittoRevealHookReportsDisguise() async {
        let url = tempURL()
        let active = "{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":300000000,"
            + "\"rarity\":\"common\",\"totalForms\":3,\"isShiny\":true,\"hasGrowthBoost\":false,"
            + "\"dittoDisguise\":1,\"dittoRevealed\":false}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d1\",\"active\":\(active),\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = store(url: url)
        var events: [CompanionTeamEvent] = []
        s.onTeamEvent = { events.append($0) }
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d1", monthTotal: 0, burnTier: .idle,
                 limitWarning: false, hasUsageData: true)
        for _ in 0..<200 where !(s.state.active?.dittoRevealed ?? false) { await Task.yield() }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .dittoReveal)
        XCTAssertEqual(events.first?.speciesID, 132)
        XCTAssertEqual(events.first?.fromSpeciesID, 1)
        XCTAssertEqual(events.first?.fromSpeciesName, "포1")
        XCTAssertEqual(events.first?.isShiny, true)
        XCTAssertEqual(events.first?.rarity, .rare)
    }
}
