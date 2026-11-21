import XCTest
@testable import PokeTokenBar

/// 큰 나무가 장면에서 하는 일. 이 파일은 Task 2(그려진 자리의 규칙)부터 채운다.
@MainActor final class PlazaTreeLayerTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: p(20, 22), zoom: 2, nickname: "me")
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        return s
    }

    private func member(_ id: String, _ x: Int, _ y: Int) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: p(x, y), facing: .down, isWalking: false)
    }

    func testAnOldPeerOnTheTrunkIsDrawnThere() async throws {
        let s = scene()
        s.applyMembers([member("a", 17, 10), member("ref", 17, 12)])
        let foot = try XCTUnwrap(s.memberFoot("a"))
        let ref = try XCTUnwrap(s.memberFoot("ref"))
        XCTAssertEqual(foot.x, ref.x, accuracy: 0.001)
        XCTAssertEqual(foot.y, ref.y - 2 * CGFloat(PlazaMap.tileSize), accuracy: 0.001, "drawn on (17,10), not moved to the shelter")
    }

    func testABlockedTileThatIsNotTheTreeStillGoesToTheShelter() async throws {
        let s = scene()
        s.applyMembers([member("a", 15, 4)])   // the bush
        let foot = try XCTUnwrap(s.memberFoot("a"))
        let size = CGFloat(PlazaMap.tileSize)
        let tile = TilePoint(x: Int(foot.x / size), y: Int(foot.y / size))
        XCTAssertTrue(map.shelterTiles.contains(tile), "\(tile)")
    }
}
