import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

private let spaceKey: UInt16 = 49, escKey: UInt16 = 53, wKey: UInt16 = 13, rightKey: UInt16 = 124, heartKey: UInt16 = 18

private let upKey: UInt16 = 126, downKey: UInt16 = 125, leftKey: UInt16 = 123, returnKey: UInt16 = 36

private let zKey: UInt16 = 6, xKey: UInt16 = 7, cKey: UInt16 = 8

private extension PlazaOverlayContent {
    var cardMemberID: String? {
        switch self {
        case .card(.loading(let s)), .card(.loaded(let s, _)), .card(.failed(let s)): s.memberID
        case .none, .board, .memberMenu, .campfireMenu: nil
        }
    }
}

@MainActor
final class PlazaInteractionTests: XCTestCase {

    /// A seated user is never aimed at the pit by Space; if the seats move this fails loudly.
    func testNoSeatEverTargetsTheCampfire() async {
        for seat in PlazaCampfire.seats {
            for d in PlazaDirection.allCases {
                let hit = PlazaInteraction.target(from: seat.tile, facing: d, map: PlazaMapData.map, members: [:])
                XCTAssertNotEqual(hit?.target, .campfire, "\(seat.tile) \(d)")
            }
        }
    }

    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testBoardWinsOverMember() async {
        let board = map.boardTile
        let above = p(board.x, board.y - 1)
        // 소식판 칸에 팀원이 겹쳐 있어도 판이 먼저다.
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: ["a": board])?.target, .board)
        XCTAssertEqual(PlazaInteraction.target(from: above, facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .down))
    }

    func testMemberAheadIsTheTarget() async {
        let from = map.spawn
        let ahead = PlazaTargeting.facingTile(from: from, facing: .down)
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["b": ahead, "a": ahead])?.target, .member("a"))
        XCTAssertNil(PlazaInteraction.target(from: p(10, 10), facing: .down, map: map, members: ["far": p(1, 1)]))
    }

    /// A teammate right beside me can be talked to without facing them first; Space turns me towards them.
    func testMemberBesideMeIsTheTargetAndITurnToThem() async {
        let from = p(10, 10)
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(11, 10)]),
                       PlazaInteractionHit(target: .member("m"), facing: .right))
        XCTAssertEqual(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(10, 9)]),
                       PlazaInteractionHit(target: .member("m"), facing: .up))
        XCTAssertNil(PlazaInteraction.target(from: from, facing: .down, map: map, members: ["m": p(11, 11)]), "diagonal is not beside")
    }

    /// The board is readable from any side, without facing it first.
    func testBoardBesideMeIsTheTarget() async {
        let b = map.boardTile
        let left = p(b.x - 1, b.y + 1)
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .right))
        let below = p(b.x + 1, b.y + 2)
        XCTAssertEqual(PlazaInteraction.target(from: below, facing: .left, map: map, members: [:]),
                       PlazaInteractionHit(target: .board, facing: .up))
    }

    /// Order: the board I face, a teammate I face, a teammate on my tile, the board beside me, a teammate beside me.
    func testFacedTargetsWinOverTargetsBeside() async {
        let b = map.boardTile
        let left = p(b.x - 1, b.y + 1)
        let ahead = p(left.x, left.y + 1)
        XCTAssertTrue(map.isWalkable(ahead) && map.isWalkable(p(left.x - 1, left.y)), "test precondition")
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": ahead]),
                       PlazaInteractionHit(target: .member("m"), facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": left]),
                       PlazaInteractionHit(target: .member("m"), facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .down, map: map, members: ["m": p(left.x - 1, left.y)]),
                       PlazaInteractionHit(target: .board, facing: .right), "the board beside me wins over a teammate beside me")
        XCTAssertEqual(PlazaInteraction.target(from: left, facing: .right, map: map, members: ["m": left]),
                       PlazaInteractionHit(target: .board, facing: .right), "the board I face wins over everyone")
    }

    private func cardState(_ c: TeamMonSummary, dex: [TeamDexSpecies]?) -> PlazaCardState {
        let state = TeamMemberState(memberID: "m", nickname: "민수", character: c, inPlaza: true, tile: nil, facing: nil, isWalking: false)
        guard let dex else { return .loading(state) }
        return .loaded(state, TeamMemberProfile(memberID: "m", nickname: "민수", current: c, dex: dex))
    }

    private func dexEntry(_ id: Int, _ rarity: Rarity) -> TeamDexSpecies {
        TeamDexSpecies(speciesID: id, form: nil, name: "\(id)", rarity: rarity, hasShiny: false, hasNormal: true)
    }

    /// The big partner on the card says whose it is, what it is, and whether it is shiny or above common.
    func testCardNamesTheOwnerAndTheirPartner() async {
        XCTAssertEqual(L(.ko).plazaCardTitle(nickname: "민수"), "민수의 포켓몬")
        let milotic = TeamMonSummary(speciesID: 350, isShiny: false, form: nil, speciesName: "밀로틱", gender: nil)
        XCTAssertEqual(cardState(milotic, dex: nil).characterName, "밀로틱")
        XCTAssertEqual(cardState(milotic, dex: nil).member.nickname, "민수")
        let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertEqual(cardState(egg, dex: []).characterName, L(.ko).plazaEggName)
        let unnamed = TeamMonSummary(speciesID: 350, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertNil(cardState(unnamed, dex: []).characterName, "an unknown name is left out, not shown as an egg")
    }

    func testCardBadgesShowShinyAndRarityAboveCommon() async {
        let shinyMewtwo = TeamMonSummary(speciesID: 150, isShiny: true, form: nil, speciesName: "뮤츠", gender: nil)
        XCTAssertEqual(cardState(shinyMewtwo, dex: nil).characterBadges, [.shiny], "rarity is known only once the dex arrives")
        XCTAssertEqual(cardState(shinyMewtwo, dex: [dexEntry(1, .common), dexEntry(150, .legendary)]).characterBadges,
                       [.shiny, .rarity(.legendary)])
        let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil)
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(25, .common)]).characterBadges, [], "common gets no badge")
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(25, .uncommon)]).characterBadges, [.rarity(.uncommon)])
        XCTAssertEqual(cardState(pikachu, dex: [dexEntry(150, .legendary)]).characterBadges, [], "only its own species counts")
        let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        XCTAssertEqual(cardState(egg, dex: [dexEntry(150, .legendary)]).characterBadges, [])
    }

    func testCardShowsCurrentOnlyWhenItDiffersFromPlazaCharacter() async {
        let pika = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let eevee = TeamMonSummary(speciesID: 133, isShiny: false, form: nil, speciesName: "Eevee", gender: nil)
        let state = TeamMemberState(memberID: "m", nickname: "민수", character: pika, inPlaza: true, tile: nil, facing: nil, isWalking: false)
        func profile(_ c: TeamMonSummary) -> TeamMemberProfile { TeamMemberProfile(memberID: "m", nickname: "민수", current: c, dex: []) }
        XCTAssertNil(PlazaCardState.loaded(state, profile(pika)).differingCurrent)
        XCTAssertEqual(PlazaCardState.loaded(state, profile(eevee)).differingCurrent?.speciesID, 133)
        var shiny = pika; shiny.isShiny = true
        XCTAssertNotNil(PlazaCardState.loaded(state, profile(shiny)).differingCurrent)
        XCTAssertNil(PlazaCardState.loading(state).differingCurrent)
    }
}
