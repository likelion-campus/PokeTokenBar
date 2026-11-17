// PlazaPullUnderTests+Pond: the splash reads the pond layer (the bundled tile sheet)
import XCTest
@testable import PokeTokenBar

extension PlazaPullUnderTests {
    func testAFarPullSlidesMeThreeTilesAndSplashesBig() async throws {
        let (c, scene, me, other, _) = try await open(me: p(41, 17), teammate: p(38, 17))
        c.showPull(from: other.id, on: me.id)
        run(scene, 0.25)
        XCTAssertFalse(scene.isMeInWater, "still sliding")
        var splashed = 0
        for _ in 0..<30 { run(scene, 0.1); splashed = max(splashed, try XCTUnwrap(scene.pondLayer).dropletCount) }
        XCTAssertEqual(scene.walker.tile, p(38, 17), "the puller's own tile does not stop me")
        XCTAssertTrue(scene.isMeInWater)
        XCTAssertEqual(splashed, PlazaPondLayer.bigDroplets, "a big splash")
        withExtendedLifetime(c) {}
    }
}
