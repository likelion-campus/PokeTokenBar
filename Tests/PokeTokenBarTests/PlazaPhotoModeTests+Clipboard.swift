import XCTest
@testable import PokeTokenBar

/// The photo path needs a PNG codec: ImageIO on the Mac, WIC on Windows (`PlatformPlaza.graphics` decodes what the writer got).
extension PlazaPhotoModeTests {
    func testSpaceShootsOnlyInPhotoMode() async throws {
        var written: [Data] = []
        let (c, _) = controller { written.append($0); return true }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(Self.frames())
        key(scene, spaceKey)
        XCTAssertTrue(written.isEmpty)
        key(scene, escKey)   // 보드 옆이라 스페이스는 판을 연다. 닫고 시작한다.
        XCTAssertEqual(c.overlayContent, .none)
        key(scene, pKey, "p")
        key(scene, spaceKey)
        XCTAssertEqual(written.count, 1)
        let photo = try XCTUnwrap(PlatformPlaza.graphics.decodeImage(try XCTUnwrap(written.first)))
        XCTAssertEqual(photo.width, 1824)
        XCTAssertEqual(photo.height, 1144)
    }
}
