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
        "PlazaMap.swift|case .tree, .bush, .board, .campfire, .pond, .hotSpring: false",
        "PlazaMap.swift|func isWater(_ p: TilePoint) -> Bool { tile(at: p) == .pond || tile(at: p) == .hotSpring }",
        "PlazaSnow.swift|case .tallGrass, .tree, .bush, .board, .campfire, .pond, .hotSpring: false",
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
}
