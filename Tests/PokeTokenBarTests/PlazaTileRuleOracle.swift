import Foundation
@testable import PokeTokenBar

// The one-tile rules at b93f25e2 (before PR 2). The class-1 oracle. Shared, so the Windows test job compares too. Do not edit.
// Copies, line for line (checked against 2dd83d05 by script; only the type names and the `PlazaSnowball.` qualifier on
// `blocksBall`/`range`/`reach` differ): `LegacyPlazaTargeting`, `LegacyPlazaInteraction.target`, `LegacyPlazaSnowball.aim`
// and `.hits`, and `LegacyPlazaPathfinder.isAdjacent`/`.direction`.
// Not copied: `LegacyPlazaTackle.pushes`/`.direction` compose the pathfinder copies in the same expressions the controller
// used (`isAdjacent(from, to) || from == to` and `isAdjacent(from, to) ? direction(from:to:) : fallback`, showTackle at 2dd83d05).

enum LegacyPlazaTargeting {
    static func facingTile(from: TilePoint, facing: PlazaDirection) -> TilePoint {
        PlazaWalker.offset(from, facing)
    }

    static func otherSides(_ facing: PlazaDirection) -> [PlazaDirection] {
        [PlazaDirection.up, .down, .left, .right].filter { $0 != facing }
    }

    static func member(from: TilePoint, facing: PlazaDirection, members: [String: TilePoint]) -> String? {
        let tiles = [facingTile(from: from, facing: facing), from] + otherSides(facing).map { PlazaWalker.offset(from, $0) }
        for tile in tiles {
            if let id = member(on: tile, members: members) { return id }
        }
        return nil
    }

    static func member(on tile: TilePoint, members: [String: TilePoint]) -> String? {
        members.filter { $0.value == tile }.keys.min()
    }
}

enum LegacyPlazaInteraction {
    static func target(from: TilePoint, facing: PlazaDirection, map: PlazaMap,
                       members: [String: TilePoint]) -> PlazaInteractionHit? {
        let ahead = LegacyPlazaTargeting.facingTile(from: from, facing: facing)
        if map.tile(at: ahead) == .board { return .init(target: .board, facing: facing) }
        if map.tile(at: ahead) == .campfire { return .init(target: .campfire, facing: facing) }
        for tile in [ahead, from] {
            if let id = LegacyPlazaTargeting.member(on: tile, members: members) { return .init(target: .member(id), facing: facing) }
        }
        let sides = LegacyPlazaTargeting.otherSides(facing)
        if let d = sides.first(where: { map.tile(at: PlazaWalker.offset(from, $0)) == .board }) {
            return .init(target: .board, facing: d)
        }
        if let d = sides.first(where: { map.tile(at: PlazaWalker.offset(from, $0)) == .campfire }) {
            return .init(target: .campfire, facing: d)
        }
        for d in sides {
            if let id = LegacyPlazaTargeting.member(on: PlazaWalker.offset(from, d), members: members) {
                return .init(target: .member(id), facing: d)
            }
        }
        return nil
    }
}

enum LegacyPlazaPathfinder {
    static func isAdjacent(_ a: TilePoint, _ b: TilePoint) -> Bool {
        abs(a.x - b.x) + abs(a.y - b.y) == 1
    }

    static func direction(from a: TilePoint, to b: TilePoint) -> PlazaDirection {
        if b.x > a.x { return .right }
        if b.x < a.x { return .left }
        return b.y > a.y ? .down : .up
    }
}

enum LegacyPlazaTackle {
    /// Today's `showTackle` guard.
    static func pushes(from: TilePoint, to: TilePoint) -> Bool {
        LegacyPlazaPathfinder.isAdjacent(from, to) || from == to
    }

    /// Today's `showTackle` direction expression.
    static func direction(from: TilePoint, to: TilePoint, fallback: PlazaDirection) -> PlazaDirection {
        LegacyPlazaPathfinder.isAdjacent(from, to) ? LegacyPlazaPathfinder.direction(from: from, to: to) : fallback
    }
}

// MARK: - Class-1 shorthands for the tile-era tests

extension PlazaBody {
    static func ones(_ tiles: [String: TilePoint]) -> [String: PlazaBody] {
        tiles.mapValues { PlazaBody(foot: $0, size: 1) }
    }
}

extension PlazaTargeting {
    static func member(from: TilePoint, facing: PlazaDirection, members: [String: TilePoint]) -> String? {
        member(me: PlazaBody(foot: from, size: 1), facing: facing, members: PlazaBody.ones(members))
    }
}

extension PlazaInteraction {
    static func target(from: TilePoint, facing: PlazaDirection, map: PlazaMap,
                       members: [String: TilePoint]) -> PlazaInteractionHit? {
        target(me: PlazaBody(foot: from, size: 1), facing: facing, map: map, members: PlazaBody.ones(members))
    }
}

// MARK: - Snowball (verbatim at b93f25e2)

enum LegacyPlazaSnowball {
    static func aim(from: TilePoint, facing: PlazaDirection, targets: [String: TilePoint], map: PlazaMap) -> PlazaSnowballShot? {
        var tile = from
        var last: TilePoint?
        for _ in 1...PlazaSnowball.range {
            tile = PlazaWalker.offset(tile, facing)
            if PlazaSnowball.blocksBall(tile, in: map) { break }
            if let id = targets.filter({ $0.value == tile }).keys.min() {
                return PlazaSnowballShot(from: from, direction: facing, end: .actor(id: id, tile: tile))
            }
            last = tile
        }
        guard let last else { return nil }
        return PlazaSnowballShot(from: from, direction: facing, end: .ground(last))
    }

    static func hits(thrower: TilePoint, target: TilePoint, direction: PlazaDirection) -> Bool {
        let dx = target.x - thrower.x, dy = target.y - thrower.y
        let along: Int, across: Int
        switch direction {
        case .right: (along, across) = (dx, dy)
        case .left: (along, across) = (-dx, dy)
        case .down: (along, across) = (dy, dx)
        case .up: (along, across) = (-dy, dx)
        }
        return across == 0 && (1...PlazaSnowball.reach).contains(along)
    }
}

extension PlazaSnowball {
    static func aim(from: TilePoint, facing: PlazaDirection, targets: [String: TilePoint], map: PlazaMap) -> PlazaSnowballShot? {
        aim(from: from, facing: facing, bodies: PlazaBody.ones(targets), map: map)
    }

    static func hits(thrower: TilePoint, target: TilePoint, direction: PlazaDirection) -> Bool {
        hitTile(thrower: thrower, target: PlazaBody(foot: target, size: 1), direction: direction, map: openGround) != nil
    }

    /// 64x64 open ground (board (0,0), shelter (1,0)): the old receiver knew no blocking tiles, and the oracle's random tiles stay on it.
    static let openGround = try! PlazaMap(rows: ["NS" + String(repeating: ".", count: 62)] + Array(repeating: String(repeating: ".", count: 64), count: 63))
}
