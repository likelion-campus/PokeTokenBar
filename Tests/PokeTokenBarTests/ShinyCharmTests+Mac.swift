import XCTest
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension ShinyCharmTests {
    func testShinyFlipReloadsSpriteForSameSpecies() {
        // 도감 토글의 두 방향 — 이 두 줄이 회귀의 본체다.
        XCTAssertTrue(SpriteView.needsReload(loadedID: 1, loadedShiny: false, id: 1, shiny: true),
                      "일반 → 이로치 토글이 갱신을 트리거해야 한다")
        XCTAssertTrue(SpriteView.needsReload(loadedID: 1, loadedShiny: true, id: 1, shiny: false),
                      "이로치 → 일반 토글도 마찬가지")
    }

    func testUnchangedSpriteSkipsReload() {
        // 같은 종·같은 이로치 여부면 재요청하지 않는다(재렌더 플래시 방지 가드 유지).
        XCTAssertFalse(SpriteView.needsReload(loadedID: 1, loadedShiny: false, id: 1, shiny: false))
        XCTAssertFalse(SpriteView.needsReload(loadedID: 1, loadedShiny: true, id: 1, shiny: true))
    }

    func testSpeciesChangeReloadsRegardlessOfShiny() {
        XCTAssertTrue(SpriteView.needsReload(loadedID: 1, loadedShiny: false, id: 2, shiny: false))
        XCTAssertTrue(SpriteView.needsReload(loadedID: nil, loadedShiny: false, id: 1, shiny: false),
                      "미로드(캐시 미스) 상태에서는 항상 불러온다")
    }
}
