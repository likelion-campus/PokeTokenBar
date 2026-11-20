import Foundation
import XCTest
@testable import PokeTokenBar

/// The photo path on an OS without graphics or a clipboard yet (Windows until stage 6): honest "unavailable", no crash.
final class PlazaPhotoStubTests: XCTestCase {
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testStubClipboardIsUnavailable() {
        let log = LogBox()
        let stub = StubImageClipboard(log: { log.add($0) })
        XCTAssertFalse(stub.writePNG(Data([1, 2, 3])))
        XCTAssertFalse(stub.writePNG(Data()))
        XCTAssertEqual(log.lines.count, 1, "logs once, not on every photo")
    }

    private func input(_ ppw: Int = 2) -> PlazaPhotoInput {
        var map = PlazaBitmap(width: 6, height: 4)
        map[1, 1] = PlazaRGBA(r: 9, g: 8, b: 7, a: 255)
        return PlazaPhotoInput(mapImage: PlazaImage(bitmap: map), visibleRect: CGRect(x: 0, y: 0, width: 6, height: 4), pixelsPerWorld: ppw, actors: [])
    }

    func testThePhotoOnTheStubIsATransparentCanvasWithoutPNG() throws {
        let log = LogBox()
        let stub = PlazaStubGraphics(log: { log.add($0) })
        let image = try XCTUnwrap(PlazaPhotoRenderer.render(input(), graphics: stub))
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)
        XCTAssertNil(PlazaPhotoRenderer.pngData(for: input(), graphics: stub), "no codec: no PNG, so nothing reaches the clipboard")
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertNil(PlazaPhotoRenderer.render(input(0), graphics: stub))
    }
}
