// PlazaPrayTests+Mac: a CGImage compare of the prayer bubble art
import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaPrayTests {
    /// The prayer bubble has its own picture, not another kind's.
    func testThePrayerBubbleHasItsOwnArt() async {
        func pixels(_ kind: TeamEmoteKind) -> Data? { PlazaEmoteArt.image(kind, scale: 1).cgImage.dataProvider?.data as Data? }
        XCTAssertNotNil(pixels(.pray))
        for other: TeamEmoteKind in [.heart, .party, .exclaim, .question] {
            XCTAssertNotEqual(pixels(.pray), pixels(other), "\(other)")
        }
    }
}
