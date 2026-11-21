import XCTest
@testable import PokeTokenBar

/// Sweep A of the hot-spring plan: every direct `.pond` tile check in the plaza sources is classified here.
/// Mac-only because `SharedSources` is.
final class PlazaPondSweepTests: XCTestCase {
    /// (file relative to `Sources/PokeTokenBar/Team/Plaza`, trimmed line). Water rules ask `isWater`; only the lines below name the pond tile.
    static let allowed: Set<String> = [
        "PlazaIce.swift|let isPond = { (q: TilePoint) in map.tile(at: q) == .pond }   // 온천(.hotSpring)은 연못이 아니다",
        "PlazaTileArt.swift|for (i, c) in lilyPair.enumerated() where map.tile(at: TilePoint(x: pair.x + i, y: pair.y)) == .pond {",
        "PlazaTileArt.swift|for single in lilySingleTiles where map.tile(at: single) == .pond {",
        "PlazaMap.swift|case .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree: false",
        "PlazaMap.swift|func isWater(_ p: TilePoint) -> Bool { tile(at: p) == .pond || tile(at: p) == .hotSpring }",
        "PlazaSnow.swift|case .tallGrass, .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree: false",
    ]

    func testEveryDirectPondCheckIsClassified() throws {
        let root = SharedSources.sourcesRoot.appendingPathComponent("Team/Plaza")
        let regex = try NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_)\]?!])\.pond\b"#)
        var hits = Set<String>()
        for url in SharedSources.allSwiftFiles(root: root) {
            let rel = SharedSources.relativePath(url, root: root)
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    hits.insert("\(rel)|\(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, Self.allowed,
                       "classify it as water (use isWater) or pond-only and list it here. new: \(hits.subtracting(Self.allowed).sorted()) gone: \(Self.allowed.subtracting(hits).sorted())")
    }

    /// Sweep A of the big-tree plan: every direct `.tree`/`.bigTree` tile check in the plaza sources is classified here.
    static let allowedTree: Set<String> = [
        "PlazaMap.swift|case .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree: false",
        "PlazaMap.swift|guard p.x >= 0, p.y >= 0, p.x < width, p.y < height else { return .tree }",
        "PlazaMap.swift|func isBigTree(_ p: TilePoint) -> Bool { tile(at: p) == .bigTree }",
        "PlazaSnow.swift|case .tallGrass, .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree: false",
        "PlazaTileArt.swift|if map.tile(at: TilePoint(x: x, y: y)) == .tree { covers = true } else { allTrees = false }",
    ]

    func testEveryDirectTreeTileCheckIsClassified() throws {
        let root = SharedSources.sourcesRoot.appendingPathComponent("Team/Plaza")
        let regex = try NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_)\]?!])\.(tree|bigTree)\b"#)
        var hits = Set<String>()
        for url in SharedSources.allSwiftFiles(root: root) {
            let rel = SharedSources.relativePath(url, root: root)
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    hits.insert("\(rel)|\(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, Self.allowedTree,
                       "a blocked tile is asked through isWalkable/blocksBall; the tree through PlazaMap.isBigTree; list a real exception here. new: \(hits.subtracting(Self.allowedTree).sorted()) gone: \(Self.allowedTree.subtracting(hits).sorted())")
    }
}
