import Foundation
@testable import PokeTokenBar

/// The plaza Ditto is hosted by the controller a test builds (the smallest ready ID hosts, and a lone test controller is
/// that host). Left alone it lands on a random ground tile and wanders on a live 50 ms loop, so a test that opens a menu or
/// picks a target by tile can find the Ditto where it expected a teammate (the Ditto's menu is `[.tackle]` only). Tests
/// that depend on who is targeted pass these to `PlazaWindowController`: the loop sleeps for good, and the seed puts the
/// Ditto on a tile far from every spot the tests use. See docs/reference/defect-log.md.
enum ParkedDitto {
    static let loopSleep: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    /// Lands the Ditto at (43, 18).
    static let seed: UInt64 = 7

    /// A seed whose first random ground tile is `tile`, to force the Ditto onto a chosen spot.
    static func seed(landingOn tile: TilePoint) -> UInt64 {
        let map = PlazaMapData.map
        for seed in UInt64(0)..<5_000_000 {
            var rng = PlazaSplitMix64(seed: seed)
            let p = TilePoint(x: Int(rng.unit() * Double(map.width)), y: Int(rng.unit() * Double(map.height)))
            if p == tile { return seed }
        }
        preconditionFailure("no seed lands on \(tile)")
    }
}
