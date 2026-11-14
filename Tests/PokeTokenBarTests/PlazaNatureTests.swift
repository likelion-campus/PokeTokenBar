import XCTest
@testable import PokeTokenBar

/// 이름표 위 성격 줄: 문구, 고르는 개체, 장면과 사진까지.
@MainActor
final class PlazaNatureTests: XCTestCase {
    private let map = PlazaMapData.map

    // MARK: - 문구

    func testEveryNatureReadsBeforeAName() {
        let expected: [PokemonNature: String] = [
            .hardy: "노력하는", .lonely: "외로운", .brave: "용감한", .adamant: "고집스러운", .naughty: "개구쟁이",
            .bold: "대담한", .docile: "온순한", .relaxed: "무사태평한", .impish: "장난꾸러기", .lax: "촐랑대는",
            .timid: "겁쟁이", .hasty: "성급한", .serious: "성실한", .jolly: "명랑한", .naive: "천진난만한",
            .modest: "조심스러운", .mild: "의젓한", .quiet: "냉정한", .bashful: "수줍은", .rash: "덜렁대는",
            .calm: "차분한", .gentle: "얌전한", .sassy: "건방진", .careful: "신중한", .quirky: "변덕스러운",
        ]
        XCTAssertEqual(expected.count, PokemonNature.allCases.count)
        for nature in PokemonNature.allCases {
            XCTAssertEqual(L(.ko).plazaNatureTitle(nature), expected[nature], "\(nature)")
        }
    }

    // MARK: - 어떤 개체의 성격인가

    private func graduate(_ chain: [Int], _ nature: PokemonNature?, day: Double?, form: PokemonForm? = nil) -> DexEntry {
        DexEntry(baseID: chain[0], finalID: chain[chain.count - 1], chainOrder: chain, rarity: .common,
                 caughtAt: day.map { Date(timeIntervalSince1970: $0 * 86_400) }, nature: nature, form: form)
    }

    private func raised(_ path: [Int], stage: Int, _ nature: PokemonNature?, form: PokemonForm? = nil) -> MonState {
        MonState(baseID: path[0], pathIDs: path, stageIndex: stage, usedAtStage: 0, rarity: .common,
                 totalForms: path.count, nature: nature, form: form)
    }

    func testLatestNaturePrefersTheRaisedIndividual() {
        var state = CompanionState()
        state.active = raised([1, 2, 3], stage: 1, .bold)
        state.dex = [graduate([1, 2, 3], .brave, day: 9)]
        XCTAssertEqual(state.latestNature(of: 2), .bold)
        XCTAssertEqual(state.latestNature(of: 1), .bold, "an earlier stage of the raised line")
    }

    func testLatestNatureSkipsAStageTheRaisedIndividualHasNotReached() {
        var state = CompanionState()
        state.active = raised([1, 2, 3], stage: 0, .bold)
        state.dex = [graduate([1, 2, 3], .brave, day: 9)]
        XCTAssertEqual(state.latestNature(of: 3), .brave)
    }

    func testLatestNatureTakesTheNewestGraduate() {
        var state = CompanionState()
        state.dex = [graduate([25], .quiet, day: nil), graduate([25], .calm, day: 2), graduate([25], .sassy, day: 5),
                     graduate([25], .timid, day: 3), graduate([25], .lax, day: nil)]
        XCTAssertEqual(state.latestNature(of: 25), .sassy)
    }

    func testLatestNatureSkipsRecordsWithoutOne() {
        var state = CompanionState()
        state.active = raised([25], stage: 0, nil)
        state.dex = [graduate([25], .calm, day: 2), graduate([25], nil, day: 5)]
        XCTAssertEqual(state.latestNature(of: 25), .calm)
        XCTAssertNil(CompanionState().latestNature(of: 25))
    }

    func testLatestNatureMatchesTheChosenForm() {
        var state = CompanionState()
        state.active = raised([201], stage: 0, .bold, form: .b)
        state.dex = [graduate([201], .calm, day: 2, form: .a), graduate([201], .sassy, day: 1, form: .c)]
        XCTAssertEqual(state.latestNature(of: 201, form: .a), .calm)
        XCTAssertEqual(state.latestNature(of: 201, form: .b), .bold)
        XCTAssertEqual(state.latestNature(of: 201, form: .c), .sassy)
    }

    private func store(nature: String?, dex: [DexEntry] = []) throws -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nature-\(UUID().uuidString).json")
        let field = nature.map { ",\"nature\":\"\($0)\"" } ?? ""
        let active = "{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"common\",\"totalForms\":1,\"isShiny\":false\(field)}"
        let dexJSON = String(decoding: try JSONEncoder().encode(dex), as: UTF8.self)
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":0,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(active),\"dex\":\(dexJSON),\"collectedFinals\":[]}"
        try json.data(using: .utf8)!.write(to: url)
        return CompanionStore(fileURL: url)
    }

    func testRepresentativeNatureFollowsTheRaisedOneUntilASpeciesIsChosen() throws {
        let companion = try store(nature: "adamant", dex: [graduate([25], .calm, day: 2)])
        XCTAssertEqual(companion.representativeNature, .adamant)
        XCTAssertTrue(companion.setRepresentativeSpeciesID(25))
        XCTAssertEqual(companion.representativeNature, .calm)
        XCTAssertTrue(companion.setRepresentativeSpeciesID(nil))
        XCTAssertEqual(companion.representativeNature, .adamant)
    }

    func testRepresentativeNatureFollowsTheChosenForm() throws {
        let companion = try store(nature: "adamant", dex: [graduate([201], .calm, day: 5, form: .a),
                                                           graduate([201], .sassy, day: 1, form: .c)])
        XCTAssertTrue(companion.setRepresentativeSpeciesID(201, form: .c))
        XCTAssertEqual(companion.representativeNature, .sassy)
    }

    func testAnEggHasNoNature() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nature-egg-\(UUID().uuidString).json")
        XCTAssertNil(CompanionStore(fileURL: url).representativeNature)
    }

    // MARK: - 내 칸

    func testMyEntryCarriesTheRepresentativeNature() throws {
        let name = "plaza.nature.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: name))
        let companion = try store(nature: "naive")
        XCTAssertEqual(PlazaRoster.myEntry(companion: companion, teamSettings: settings).nature, .naive)
    }

    func testCharacterCarriesTheNatureButAnEggDoesNot() {
        func entry(species: Int?) -> PlazaRosterEntry {
            PlazaRosterEntry(id: "m", nickname: "나", speciesID: species, speciesName: "x", gender: nil, isShiny: false,
                             presence: .online, isMe: true, nature: .naive)
        }
        let subject = CompanionStore.RepresentativeSubject(speciesID: 25, isShiny: false)
        XCTAssertEqual(PlazaRoster.character(entry: entry(species: 25), subject: subject).nature, .naive)
        XCTAssertNil(PlazaRoster.character(entry: entry(species: nil), subject: subject).nature)
    }

    func testRosterEntriesKeepTheNature() {
        let me = PlazaRosterEntry(id: "me", nickname: "나", speciesID: 25, speciesName: "x", gender: nil, isShiny: false,
                                  presence: .online, isMe: true, nature: .calm)
        let member = TeamMemberState(memberID: "a", nickname: "민지",
                                     character: TeamMonSummary(speciesID: 1, isShiny: false, form: nil, speciesName: "y", gender: nil, nature: .sassy),
                                     inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let entries = PlazaRoster.entries(me: me, members: [member])
        XCTAssertEqual(entries.first { $0.isMe }?.nature, .calm)
        XCTAssertEqual(entries.first { !$0.isMe }?.nature, .sassy)
    }

    // MARK: - 장면

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        return s
    }

    private func member(_ nature: PokemonNature?) -> PlazaSceneMember {
        PlazaSceneMember(memberID: "a", nickname: "민지", isAway: false, tile: TilePoint(x: map.spawn.x + 1, y: map.spawn.y),
                         facing: .down, isWalking: false, nature: nature)
    }

    private func frames() -> PlazaCharacterFrames {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let frame = [PlazaFrame(image: PlazaImage(cgImage: context.makeImage()!), delay: 1)]
        return PlazaCharacterFrames(front: frame, back: frame)
    }

    func testATeammatesPlateGrowsUpwardWithTheNatureAndShrinksWithoutIt() throws {
        let s = scene()
        s.applyMembers([member(nil)])
        s.update(0)
        XCTAssertNil(s.memberTitle("a"))
        let plain = try XCTUnwrap(s.memberNamePlateTop("a"))

        s.applyMembers([member(.naive)])
        s.update(0.1)
        XCTAssertEqual(s.memberTitle("a"), "천진난만한")
        XCTAssertGreaterThan(try XCTUnwrap(s.memberNamePlateTop("a")), plain)

        s.applyMembers([member(nil)])
        s.update(0.2)
        XCTAssertNil(s.memberTitle("a"))
        XCTAssertEqual(try XCTUnwrap(s.memberNamePlateTop("a")), plain, accuracy: 0.001)
    }

    func testANewTeammateArrivesWithTheNature() {
        let s = scene()
        s.applyMembers([member(.calm)])
        XCTAssertEqual(s.memberTitle("a"), "차분한")
    }

    func testMyPlateFollowsMyNature() {
        let s = scene()
        s.update(0)
        let plain = s.myNamePlateTop
        s.setNature(.sassy)
        s.update(0.1)
        XCTAssertEqual(s.myTitle, "건방진")
        XCTAssertGreaterThan(s.myNamePlateTop, plain)
        s.setNature(nil)
        s.update(0.2)
        XCTAssertNil(s.myTitle)
        XCTAssertEqual(s.myNamePlateTop, plain, accuracy: 0.001)
    }

    func testRenamingAndRecolouringKeepTheNature() {
        let s = scene()
        s.setNature(.calm)
        s.setNickname("도토리")
        s.setNameColor(PlazaNameColor.palette[3])
        XCTAssertEqual(s.myTitle, "차분한")
    }

    func testTheBubbleSitsAboveTheNature() throws {
        let s = scene()
        s.applyMembers([member(.naive)])
        s.showEmote(memberID: "a", kind: .heart)
        s.update(0)
        s.update(0.05)
        let frame = try XCTUnwrap(s.emoteFrame(memberID: "a"))
        XCTAssertGreaterThanOrEqual(frame.minY, try XCTUnwrap(s.memberNamePlateTop("a")))
    }

    func testThePhotoPlateCarriesTheNature() throws {
        let s = scene()
        s.setCharacter(frames())
        s.update(0)
        let plain = try XCTUnwrap(s.photoInput()?.actors.first?.plate)
        s.setNature(.naive)
        s.update(0.1)
        let titled = try XCTUnwrap(s.photoInput()?.actors.first?.plate)
        let expected = try XCTUnwrap(PlazaNamePlate.image(text: "나", title: "천진난만한", color: s.nameColor, scale: 2))
        XCTAssertEqual(titled.height, expected.height)
        XCTAssertEqual(titled.width, expected.width)
        XCTAssertGreaterThan(titled.height, plain.height)
    }
}
