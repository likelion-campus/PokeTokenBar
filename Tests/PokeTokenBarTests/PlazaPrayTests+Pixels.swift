// PlazaPrayTests+Pixels: a compare of the prayer bubble art's pixels
import XCTest
@testable import PokeTokenBar

extension PlazaPrayTests {
    /// The prayer bubble has its own picture, not another kind's.
    func testThePrayerBubbleHasItsOwnArt() async {
        func pixels(_ kind: TeamEmoteKind) -> [UInt8] { PlazaEmoteArt.image(kind, scale: 1).pixels.bytes }
        XCTAssertFalse(pixels(.pray).isEmpty)
        for other: TeamEmoteKind in [.heart, .party, .exclaim, .question] {
            XCTAssertNotEqual(pixels(.pray), pixels(other), "\(other)")
        }
    }
}
