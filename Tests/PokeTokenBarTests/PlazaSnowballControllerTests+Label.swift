// PlazaSnowballControllerTests+Label: what the shortcut guide's V line names
import XCTest
@testable import PokeTokenBar

extension PlazaSnowballControllerTests {
    func testVThrowsOnAnyDate() async {
        now = Self.day(7, 23, 59, 59)
        let w = await world(me: p(10, 12), b: p(14, 12))
        XCTAssertEqual(w.c.shortcutThrowLabel, "눈뭉치")
        press(w.scene, vKey)
        await settle()
        XCTAssertEqual(snowballs(w.b).count, 1)
        now = Self.day(20, 0, 0, 0)
        run(w.scene, 0.1)
        XCTAssertEqual(w.c.shortcutThrowLabel, "눈뭉치")
    }
}
