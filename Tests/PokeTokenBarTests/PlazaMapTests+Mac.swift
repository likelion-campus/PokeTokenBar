import XCTest
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension PlazaMapTests {
    /// An older-version teammate can report the pit as its tile; the scene treats it like any unwalkable tile.
    @MainActor
    func testATeammateReportedOnThePitIsDrawnInTheShelter() {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        scene.size = CGSize(width: 800, height: 600)
        scene.applyMembers([PlazaSceneMember(memberID: "m", nickname: "m", isAway: false, tile: TilePoint(x: 23, y: 15),
                                             facing: .down, isWalking: false)])
        XCTAssertTrue(map.shelterTiles.contains(scene.memberTiles["m"]!))
    }
}
