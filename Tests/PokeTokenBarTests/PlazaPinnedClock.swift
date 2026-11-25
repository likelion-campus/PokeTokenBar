import XCTest
@testable import PokeTokenBar

extension XCTestCase {
    /// Pins a plaza scene's clock to a fixed instant (2026-06-15 12:00 on the fixture's +09:00 clock) so a test does not
    /// depend on when it runs: `PlazaScene.now` defaults to `Date()`, and the slot item, the daylight tint, the season and
    /// the snow day all follow it (see `PlazaSceneClockScanTests`). The process zone is pinned too (restored at teardown),
    /// because the scene reads the hour through `Calendar.current`.
    /// At this instant (03:00 UTC, slot 03:00-03:20) the slot's item has NOT dropped yet (it drops at 03:06), so no item is on the
    /// ground, the daylight is day, the season (`.auto`) is summer and it is no snow day. A test that needs an item or another
    /// season sets `now` itself after this call.
    @MainActor
    func pinPlazaClock(_ scene: PlazaScene, hour: Int = 12) {
        let pin = PlazaFixtureTime.pin()
        addTeardownBlock { pin.restore() }
        scene.now = { PlazaFixtureTime.date(hour: hour) }
    }
}
