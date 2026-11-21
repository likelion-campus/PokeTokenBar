import Foundation
@testable import PokeTokenBar

// Verbatim copies of the one-tile rules at b93f25e2 (before PR 2), renamed. The class-1 oracle. Shared, so the Windows
// test job compares too. Do not edit.

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

enum LegacyPlazaTackle {
    /// Today's `showTackle` guard: `PlazaPathfinder.isAdjacent(from, to) || from == to`.
    static func pushes(from: TilePoint, to: TilePoint) -> Bool {
        abs(from.x - to.x) + abs(from.y - to.y) == 1 || from == to
    }

    /// Today's `showTackle` direction expression (`:1120-1121`).
    static func direction(from: TilePoint, to: TilePoint, fallback: PlazaDirection) -> PlazaDirection {
        if abs(from.x - to.x) + abs(from.y - to.y) == 1 {
            if to.x > from.x { return .right }
            if to.x < from.x { return .left }
            return to.y > from.y ? .down : .up
        }
        return fallback
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
        hitTile(thrower: thrower, target: PlazaBody(foot: target, size: 1), direction: direction) != nil
    }
}
