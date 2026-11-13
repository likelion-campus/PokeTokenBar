import XCTest
@testable import PokeTokenBar

final class SpriteBackURLTests: XCTestCase {
    private let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"

    func testBackURLs() {
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: true, shiny: true, back: true).absoluteString,
                       "\(base)/versions/generation-v/black-white/animated/back/shiny/25.gif")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: false, shiny: true, back: true).absoluteString,
                       "\(base)/back/shiny/25.png")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 906, animated: false, shiny: false, back: true).absoluteString,
                       "\(base)/back/906.png")
    }

    func testFrontKeysUnchangedAndBackKeysDistinct() {
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: false), "25-a")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: true), "25-sha")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: false, back: true), "25-back-a")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: false, shiny: true, back: true), "25-back-shs")
    }
}
