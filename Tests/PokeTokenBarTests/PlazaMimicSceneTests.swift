import XCTest
@testable import PokeTokenBar

/// My own name plate while my Ditto copies a teammate: their name, colour and title show; mine wait underneath.
@MainActor
final class PlazaMimicSceneTests: XCTestCase {
    private let map = PlazaMapData.map
    private let palette = PlazaNameColor.palette

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        s.setNameColor(palette[2])
        s.setNature(.hardy)
        return s
    }

    private func look(_ name: String, hex: UInt32, nature: PokemonNature?) -> PlazaMimicLook {
        PlazaMimicLook(memberID: "m-\(name)", name: name, nameHex: hex, nature: nature,
                       subject: .init(speciesID: 25, isShiny: false))
    }

    private func pink(_ name: String = "지아") -> CGColor {
        PlazaNameColor.color(forMemberID: "m-\(name)", chosen: 0xFF9ECF)
    }

    func testADisguiseShowsTheirNameColourAndTitle() {
        let s = scene()
        s.setMyDisguise(look("지아", hex: 0xFF9ECF, nature: .timid))
        XCTAssertEqual(s.myShownName, "지아")
        XCTAssertEqual(s.myShownNameColor, pink())
        XCTAssertEqual(s.myTitle, L(.ko).plazaNatureTitle(.timid))
        XCTAssertEqual(s.nickname, "나")
        XCTAssertEqual(s.nameColor, palette[2])
    }

    func testMyOwnChangesWaitUnderTheDisguise() {
        let s = scene()
        s.setMyDisguise(look("지아", hex: 0xFF9ECF, nature: .timid))
        s.setNickname("새이름")
        s.setNameColor(palette[4])
        s.setNature(.bold)
        XCTAssertEqual(s.myShownName, "지아")
        XCTAssertEqual(s.myShownNameColor, pink())
        XCTAssertEqual(s.myTitle, L(.ko).plazaNatureTitle(.timid))
        s.setMyDisguise(nil)
        XCTAssertEqual(s.myShownName, "새이름")
        XCTAssertEqual(s.myShownNameColor, palette[4])
        XCTAssertEqual(s.myTitle, L(.ko).plazaNatureTitle(.bold))
    }

    func testADisguiseWithoutANatureHasNoTitle() {
        let s = scene()
        s.setMyDisguise(look("지아", hex: 0xFF9ECF, nature: nil))
        XCTAssertNil(s.myTitle)
    }
}
