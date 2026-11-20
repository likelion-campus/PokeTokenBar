import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// 컨트롤러 수준의 사진 모드: P로 열고, Space로 찍고, Esc로 나가고, 닫으면 모두 되돌린다.
@MainActor
final class PlazaPhotoModeTests: XCTestCase {
    var controllers: [PlazaWindowController] = []
    let pKey: UInt16 = 35, spaceKey: UInt16 = 49, escKey: UInt16 = 53, rightKey: UInt16 = 124

    override func tearDown() async throws {
        for c in controllers { c.handleClose() }
        controllers = []
    }

    func controller(writer: @escaping (Data) -> Bool) -> (PlazaWindowController, PlazaPreferences) {
        let name = "plaza.photomode.prefs.\(UUID())"
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: name))
        prefs.zoom = 2
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                      nickname: { "나" }, memberID: { "me" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      photoWriter: writer,
                                      dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                      shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
        controllers.append(c)
        c.prepareScene()
        setUpScene(c)
        return (c, prefs)
    }

    private func setUpScene(_ c: PlazaWindowController) {
        c.scene?.backingOverride = 2
        c.scene?.size = CGSize(width: 960, height: 640)
        c.scene?.update(0)
    }

    static func frames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: PlazaImage(bitmap: PlazaTestImages.solid(width: 9, height: 8, PlazaRGBA(r: 255, g: 0, b: 0, a: 255))), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    func key(_ scene: PlazaScene, _ code: UInt16, _ chars: String = "") {
        scene.handleKeyDown(keyCode: code, characters: chars, isRepeat: false)
    }

    func testEscLeavesAndTheHintComesBack() async throws {
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

    func testPhotoModeZoomIsNotSaved() async throws {
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

    func testClosingInPhotoModeResetsEverything() async throws {
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

    /// 사진 모드를 나가면 작은 지도의 보이는 영역이 곧바로 따라가기 화면으로 돌아온다(1초 틱을 기다리지 않는다).
    func testTheMinimapFollowsTheSceneRightAfterLeaving() async throws {
        let (c, _) = controller { _ in true }
        let scene = try XCTUnwrap(c.scene)
        let follow = scene.visibleWorldRect
        key(scene, pKey, "p")
        key(scene, rightKey)
        for i in 1...30 { scene.update(Double(i) / 30) }
        c.pickNameColor(PlazaNameColor.hexes[0])   // 틱 대신 지도를 한 번 맞추는 계기: 지도가 사진 모드 영역을 보여 준다
        XCTAssertEqual(c.minimapView, scene.visibleWorldRect)
        XCTAssertNotEqual(c.minimapView, follow)
        key(scene, escKey)
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(scene.visibleWorldRect, follow)
        XCTAssertEqual(c.minimapView, follow)
    }
}
