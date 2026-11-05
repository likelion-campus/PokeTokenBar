import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// 컨트롤러 수준의 사진 모드: P로 열고, Space로 찍고, Esc로 나가고, 닫으면 모두 되돌린다.
@MainActor
final class PlazaPhotoModeTests: XCTestCase {
    private var suites: [String] = []
    private let pKey: UInt16 = 35, spaceKey: UInt16 = 49, escKey: UInt16 = 53, rightKey: UInt16 = 124

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
    }

    private func controller(writer: @escaping (Data) -> Bool) -> (PlazaWindowController, PlazaPreferences) {
        let name = "plaza.photomode.prefs.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        prefs.zoom = 2
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                      nickname: { "나" }, memberID: { "me" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      photoWriter: writer)
        c.prepareScene()
        setUpScene(c)
        return (c, prefs)
    }

    private func setUpScene(_ c: PlazaWindowController) {
        c.scene?.backingOverride = 2
        c.scene?.size = CGSize(width: 960, height: 640)
        c.scene?.update(0)
    }

    private static func frames() -> PlazaCharacterFrames {
        let ctx = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
        let f = [PlazaFrame(image: ctx.makeImage()!, delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func key(_ scene: PlazaScene, _ code: UInt16, _ chars: String = "") {
        scene.handleKeyDown(keyCode: code, characters: chars, isRepeat: false)
    }

    func testSpaceShootsOnlyInPhotoMode() throws {
        var written: [Data] = []
        let (c, _) = controller { written.append($0); return true }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(Self.frames())
        key(scene, spaceKey)
        XCTAssertTrue(written.isEmpty)
        key(scene, escKey)   // 보드 옆이라 스페이스는 판을 연다. 닫고 시작한다.
        XCTAssertEqual(c.overlayContent, .none)
        key(scene, pKey, "p")
        scene.update(1)   // 틀은 다음 프레임에 잡힌다
        key(scene, spaceKey)
        XCTAssertEqual(written.count, 1)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(written.first)))
        XCTAssertEqual(rep.pixelsWide, 1824)
        XCTAssertEqual(rep.pixelsHigh, 1144)
    }

    func testEscLeavesAndTheHintComesBack() throws {
        var written = 0
        let (c, _) = controller { _ in written += 1; return true }
        let scene = try XCTUnwrap(c.scene)
        scene.refreshInteractionTarget()
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
        key(scene, pKey, "p")
        XCTAssertNil(c.hint)
        key(scene, escKey)
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
        XCTAssertEqual(written, 0)
    }

    func testPhotoModeZoomIsNotSaved() throws {
        let (c, prefs) = controller { _ in true }
        let scene = try XCTUnwrap(c.scene)
        key(scene, pKey, "p")
        key(scene, 27, "-")
        XCTAssertEqual(scene.zoom, 1)
        XCTAssertEqual(prefs.zoom, 2)
        key(scene, escKey)
        XCTAssertEqual(scene.zoom, 2)
        XCTAssertEqual(prefs.zoom, 2)
    }

    func testClosingInPhotoModeResetsEverything() throws {
        let (c, _) = controller { _ in true }
        var scene = try XCTUnwrap(c.scene)
        let start = scene.visibleWorldRect
        key(scene, pKey, "p")
        key(scene, 27, "-")
        key(scene, rightKey)   // keyUp 없이 닫는다
        scene.update(1)
        XCTAssertTrue(c.overlayIsPhotoMode)
        c.handleClose()
        XCTAssertFalse(c.overlayIsPhotoMode)
        c.prepareScene()
        setUpScene(c)
        scene = try XCTUnwrap(c.scene)
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(scene.zoom, 2)
        scene.update(1)
        XCTAssertEqual(scene.visibleWorldRect, start, "내 위치를 중심으로 다시 잡고, 남은 pan 키가 없다")
    }
}
