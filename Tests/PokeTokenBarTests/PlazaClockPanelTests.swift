import XCTest
@testable import PokeTokenBar

/// The clock on the minimap as a panel (Track A Task 14). Stub text: a 12-point character is 7.2 wide, a line 12 tall
/// (ascender 9.6). Runs on Windows.
@MainActor final class PlazaClockPanelTests: XCTestCase {
    private let stub = PlazaStubGraphics(log: { _ in })

    func testClockRendersOnlyWhenItsTextChanges() async {
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        let hud = PlazaHUD(panels: [clock], graphics: stub)
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        XCTAssertEqual(hud.renderCount, 0, "no text yet: nothing to show")
        XCTAssertFalse(clock.isVisible)
        clock.update("밤 21:34")
        XCTAssertEqual(hud.renderCounts, [.clock: 1])
        for _ in 0..<59 { clock.update("밤 21:34") }   // the 1 s tick within the minute
        XCTAssertEqual(hud.renderCounts, [.clock: 1])
        clock.update("밤 21:35")
        XCTAssertEqual(hud.renderCounts, [.clock: 2])
        let shown = host.take().compactMap { call -> PlazaPanelID? in
            if case .show(let id, _, _) = call { return id }
            return nil
        }
        XCTAssertEqual(shown, [.clock, .clock])
    }

    /// One line in Galmuri 12 with 8 and 5 points of padding, a 6-point corner and a 1.5 stroke centred on the edge.
    func testClockDrawsOnePill() async throws {
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        // 7 × 7.2 = 50.4, whole pixels: 51 at 1x; + 16 = 67 by 12 + 10 = 22, and 1 point of room around.
        XCTAssertEqual(clock.size(in: CGSize(width: 960, height: 640), scale: 1, text: stub.text), CGSize(width: 69, height: 24))
        XCTAssertEqual(clock.size(in: CGSize(width: 960, height: 640), scale: 2, text: stub.text), CGSize(width: 68.5, height: 24))
        let graphics = CanvasKeepingGraphics()
        XCTAssertNotNil(clock.render(scale: 1, viewport: CGSize(width: 960, height: 640), graphics: graphics))
        let calls = try XCTUnwrap(graphics.canvases.first).calls
        XCTAssertTrue(calls.contains("fillColor (\(29.0 / 255), \(79.0 / 255), \(92.0 / 255), 0.9)"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("fillRoundedRect (1.0, 1.0, 67.0, 22.0)") && $0.hasSuffix(" 6.0") }, "\(calls)")
        let ascender = stub.text.metrics(.plaza(.small)).ascender   // 9.6
        XCTAssertTrue(calls.contains("line \"밤 21:34\" at 9.0 \(Double(24 - (1 + (5 + ascender))))"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("strokeRoundedRect (1.0, 1.0, 67.0, 22.0)") && $0.hasSuffix(" 6.0 1.5") }, "\(calls)")
        XCTAssertNil(clock.hit(CGPoint(x: 10, y: 10)), "nothing to click")
    }

    /// The controller's tick hands the clock the minute's text, with the team's core time (`PlazaDaylight.clockText`).
    func testTheClockShowsTheControllersTime() async throws {
        let shell = RecordingPlazaShell()
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 14, 21, 34)
        let date = try XCTUnwrap(Calendar.current.date(from: c))
        let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let controller = PlazaWindowController(
            preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.clock.\(UUID())")),
            loader: PlazaCharacterLoader(fetcher: ClockTestNoSprites()),
            nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
            clock: { date }, bannerSleep: park, renderCheckSleep: park, focusTickSleep: park, dittoLoopSleep: park,
            dittoSeed: { 7 }, shell: shell, chatInput: PlazaStubChatInput())
        controller.show()
        let clock = try XCTUnwrap(controller.hud.panels.first { $0.id == .clock } as? PlazaClockPanel)
        XCTAssertEqual(clock.text, PlazaDaylight.clockText(date, core: .standard))
        controller.handleClose()
    }
}

private struct ClockTestNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}
