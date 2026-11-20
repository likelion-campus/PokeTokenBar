// PlazaItemsTests+Pixels: the photo render
import XCTest
@testable import PokeTokenBar

extension PlazaItemsTests {
    /// The photo shows the item where it lies.
    func testThePhotoShowsTheItem() async throws {
        let (from, _) = try XCTUnwrap(beside(spawn.tile))
        let s = scene(on: from)   // the camera follows me, so stand next to it
        s.update(0)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.items.count, 1)
        let withItem = try XCTUnwrap(PlazaPhotoRenderer.renderBitmap(input))
        var bare = input
        bare.items = []
        let without = try XCTUnwrap(PlazaPhotoRenderer.renderBitmap(bare))
        XCTAssertNotEqual(withItem.bytes, without.bytes)
    }
}
