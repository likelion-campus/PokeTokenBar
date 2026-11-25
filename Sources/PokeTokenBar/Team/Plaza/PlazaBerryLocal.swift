import Foundation

/// What one machine remembers about a berry five game and never sends: when it first saw each part (on its own clocks),
/// which berries have shown five on its screen, and its own last bell. A pure value: no stamp from another machine is in it.
struct PlazaBerryLocal: Equatable, Sendable {
    var game: String
    /// Wall-clock seconds on this machine (the dealer's intervals).
    var lockSeen: Double?
    var flips = 0
    var flipSeen: Double?
    var clears = 0
    var clearSeen: Double?
    /// When the dealer first saw a valid right bell for the current clear.
    var windowSeen: Double?
    /// Since when the host has been out of `playing` in my view, and since when fewer than two have been playing.
    var hostAbsentSince: Double?
    var lackSince: Double?
    /// Who was playing at the last tick.
    var playing: Set<String> = []
    /// Who dealt at the last tick, as this machine saw it.
    var dealer: String?

    /// Monotonic seconds on this machine (reaction times): the uptime each berry at exactly five on the current table first showed on my screen.
    var shown: [PlazaBerry.Berry: Double] = [:]
    /// My last `berrySeen` was not nil: the plaza is on screen.
    var visible = false
    var lockedUntil: Double = -.infinity
    var bell: PlazaBerryBell?
    var serial = 0

    init(game: String) { self.game = game }

    /// Stamps the first sight of the lock, of a new flip and of a new clear (a clear closes the judging window).
    mutating func observe(flips newFlips: Int, clears newClears: Int, at t: Double) {
        if lockSeen == nil { lockSeen = t }
        if newFlips != flips { flips = newFlips; flipSeen = t }
        if newClears != clears { clears = newClears; clearSeen = t; windowSeen = nil }
    }
}
