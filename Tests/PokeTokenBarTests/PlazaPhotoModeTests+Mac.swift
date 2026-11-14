import XCTest
import AppKit
@testable import PokeTokenBar

/// The photo path needs a PNG codec (CoreGraphics / ImageIO): the Windows stub graphics write no PNG, so the controller
/// never hands a photo to the clipboard writer there.
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
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(written.first)))
        XCTAssertEqual(rep.pixelsWide, 1824)
        XCTAssertEqual(rep.pixelsHigh, 1144)
    }
}
