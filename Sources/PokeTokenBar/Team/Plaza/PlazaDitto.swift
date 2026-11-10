import Foundation

/// 광장 메타몽 규칙: 누가 호스트인지, 누구를 따라 할 수 있는지, 받은 상태가 믿을 만한지.
enum PlazaDitto {
    static let sceneKey = "plaza-ditto"
    static let speciesID = PokemonOdds.dittoSpeciesID
    static let restDuration: TimeInterval = 180
    static let decoyLimit: TimeInterval = 900
    static let fleeDistance = 8
    static let nameHex: UInt32 = 0xC9A6FF
    static let clockSkew: TimeInterval = 600

    /// Land the Ditto may stand on: walkable, not water, not shelter.
    static func isGround(_ t: TilePoint, in map: PlazaMap) -> Bool {
        map.isWalkable(t) && !map.isWater(t) && map.tile(at: t) != .shelter
    }

    /// Smallest member ID among the ready ones (me included when `meReady`). nil when nobody is ready.
    static func host(me: String, meReady: Bool, others: [String: Bool]) -> String? {
        var ready = others.filter { $0.value }.map { $0.key }
        if meReady { ready.append(me) }
        return ready.min()
    }

    static func canBeCopied(inPlaza: Bool, ready: Bool, isIdle: Bool, isFocusing: Bool, isEgg: Bool) -> Bool {
        inPlaza && ready && !isIdle && !isFocusing && !isEgg
    }

    /// How long the host holds a dancing Ditto still: one round and the wait for the next round's news, exactly as long as a
    /// received dance lasts, so the host's Ditto never hops or walks off mid-dance.
    static let danceHold: TimeInterval = PlazaDance.round + PlazaDance.remoteGrace

    /// A dancer in the eight tiles around the Ditto (or on its tile) makes it dance the same dance, in either form.
    static func dancesAlong(ditto: TilePoint, dancer: TilePoint) -> Bool {
        max(abs(ditto.x - dancer.x), abs(ditto.y - dancer.y)) <= 1
    }

    /// The member to copy: one of `copyable` on a tile next to `ditto`. Smallest ID when several.
    static func copyTarget(ditto: TilePoint, copyable: [String: TilePoint]) -> String? {
        copyable.filter { PlazaPathfinder.isAdjacent(ditto, $0.value) }.keys.min()
    }

    static func change(from old: PlazaDittoState?, to new: PlazaDittoState?) -> PlazaDittoChange {
        guard let old, let new else { return .none }
        if new.isDecoy && (!old.isDecoy || old.decoyOf != new.decoyOf) { return .transformed(new.tile) }
        if !new.isDecoy && old.isDecoy { return .turnedBack(new.tile) }
        return .none
    }
}

struct PlazaDittoState: Codable, Equatable, Sendable {
    var tile: TilePoint
    var facing: PlazaDirection
    var isWalking: Bool?
    var isRunning: Bool?
    var decoyOf: String?
    var since: Date
    var restUntil: Date?
    var isDecoy: Bool { decoyOf != nil }

    func copying(_ memberID: String, now: Date) -> PlazaDittoState {
        var s = self
        s.decoyOf = memberID
        s.since = now
        s.restUntil = nil
        return s
    }

    func turnedBack(now: Date) -> PlazaDittoState {
        var s = self
        s.decoyOf = nil
        s.since = now
        s.restUntil = now.addingTimeInterval(PlazaDitto.restDuration)
        s.isWalking = nil
        s.isRunning = nil
        return s
    }

    /// Receipt check without a map.
    static func accepted(_ s: PlazaDittoState?, now: Date) -> PlazaDittoState? {
        guard let s else { return nil }
        let skew = PlazaDitto.clockSkew
        if let id = s.decoyOf, id.utf8.count > TeamWire.maxFieldBytes { return nil }
        if s.since > now.addingTimeInterval(skew) { return nil }
        if s.isDecoy, s.since < now.addingTimeInterval(-(PlazaDitto.decoyLimit + skew)) { return nil }
        if let r = s.restUntil, r > now.addingTimeInterval(PlazaDitto.restDuration + skew) { return nil }
        return s
    }
}

enum PlazaDittoChange: Equatable { case none, transformed(TilePoint), turnedBack(TilePoint) }
