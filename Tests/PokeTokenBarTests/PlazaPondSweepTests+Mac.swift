import XCTest
@testable import PokeTokenBar

/// Sweep A of the hot-spring plan: every place in all of `Sources` that decides by the pond or hot-spring tile kind is classified here, so a
/// new one cannot slip in. Mac-only because `SharedSources` is.
///
/// Caught spellings: the tile literal `.pond` (alone or as `PlazaTile.pond`; a property like `iceBreak.pond` is not one), any use of
/// `.hotSpring` (`== .hotSpring`, `!= .hotSpring`, a `case`), `PlazaTile(rawValue:)` (a tile read from a character), and a `default:` in a
/// file that works with tiles (it would send a new tile kind to an old answer). Water rules ask `isWater`; hot-spring rules ask `isHotSpring`.
final class PlazaPondSweepTests: XCTestCase {
    /// "file relative to Sources/PokeTokenBar|trimmed line" -> why this line may name the tile kind.
    static let allowed: [String: String] = [
        "Team/Plaza/PlazaIce.swift|let isPond = { (q: TilePoint) in map.tile(at: q) == .pond }   // 온천(.hotSpring)은 연못이 아니다":
            "only ponds freeze: the spring is water but never ice",
        "Team/Plaza/PlazaTileArt.swift|for (i, c) in lilyPair.enumerated() where map.tile(at: TilePoint(x: pair.x + i, y: pair.y)) == .pond {":
            "lily pads float on ponds only, not on the spring",
        "Team/Plaza/PlazaTileArt.swift|for single in lilySingleTiles where map.tile(at: single) == .pond {":
            "lily pads float on ponds only, not on the spring",
        "Team/Plaza/PlazaMap.swift|case .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree, .stall: false":
            "isWalkable's exhaustive switch (no default): the compiler forces every new tile kind to answer",
        "Team/Plaza/PlazaMap.swift|func isWater(_ p: TilePoint) -> Bool { tile(at: p) == .pond || tile(at: p) == .hotSpring }":
            "the one water rule",
        "Team/Plaza/PlazaMap.swift|func isHotSpring(_ p: TilePoint) -> Bool { tile(at: p) == .hotSpring }":
            "the one hot-spring rule (art, steam, flush)",
        "Team/Plaza/PlazaMap.swift|guard let tile = PlazaTile(rawValue: ch) else { throw .unknown(ch) }":
            "parses the map rows",
        "Team/Plaza/PlazaSnow.swift|case .tallGrass, .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree, .stall: false":
            "isSnowGround's exhaustive switch (no default): water takes no snow prints",
        "Team/Plaza/PlazaHotSpring.swift|for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .hotSpring { out.append(TilePoint(x: x, y: y)) }":
            "lists the spring's tiles",
        "Team/Plaza/PlazaTileArt.swift|default: break":
            "tile art after the water cells were drawn through isWater: only flowers and bushes add art, nothing else is decided here",
        "Team/Plaza/PlazaWindowController.swift|default: break":
            "overlay and panel dispatch (menu content, panel hits), not a tile kind",
        "Team/Plaza/PlazaTileArt.swift|default: y - 16":
            "a tree-cell row offset, not a tile kind",
    ]

    /// The regexes, by the spelling they catch (the injection test checks each one on its own).
    static let spellings: [(name: String, pattern: String, needsTileFile: Bool)] = [
        ("the .pond tile literal", #"(^|[^A-Za-z0-9_)\]?!]|\bPlazaTile)\.pond\b"#, false),
        ("any .hotSpring", #"\.hotSpring\b"#, false),
        ("PlazaTile(rawValue:)", #"\bPlazaTile\(rawValue:"#, false),
        ("default: in a file that works with tiles", #"^\s*default:"#, true),
    ]

    /// "relative path|trimmed line" for every hit in `text` (one file's contents).
    static func hits(in text: String, rel: String) throws -> Set<String> {
        let touchesTiles = text.contains("PlazaTile") || text.contains(".tile(at")
        var out = Set<String>()
        for spelling in spellings where !spelling.needsTileFile || touchesTiles {
            let regex = try NSRegularExpression(pattern: spelling.pattern)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") || s.trimmingCharacters(in: .whitespaces).hasPrefix("///") { continue }
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    out.insert("\(rel)|\(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return out
    }

    func testEveryPondOrHotSpringTileDecisionIsClassified() throws {
        let root = SharedSources.sourcesRoot
        var found = Set<String>()
        for url in SharedSources.allSwiftFiles(root: root) {
            found.formUnion(try Self.hits(in: String(contentsOf: url, encoding: .utf8), rel: SharedSources.relativePath(url, root: root)))
        }
        let allowed = Set(Self.allowed.keys)
        XCTAssertEqual(found, allowed,
                       "classify it as water (use isWater), spring (isHotSpring) or pond-only and list it with a reason. new: \(found.subtracting(allowed).sorted()) gone: \(allowed.subtracting(found).sorted())")
    }

    /// Each spelling is caught on its own, in a file outside Team/Plaza too (the scan reads all of Sources).
    func testEverySpellingIsCaught() throws {
        let samples: [(String, String)] = [
            ("the .pond tile literal", "if map.tile(at: p) == .pond { return }"),
            ("the .pond tile literal", "let t = PlazaTile.pond"),
            ("any .hotSpring", "if map.tile(at: p) != .hotSpring { return }"),
            ("any .hotSpring", "case .hotSpring: break"),
            ("PlazaTile(rawValue:)", "let t = PlazaTile(rawValue: \"w\")"),
            ("default: in a file that works with tiles", "default: break"),
        ]
        for (name, line) in samples {
            let spelling = try XCTUnwrap(Self.spellings.first { $0.name == name })
            let text = "let m = PlazaTile.grass\n\(line)\n"
            let hits = try Self.hits(in: text, rel: "Platform/Windows/Elsewhere.swift")
            XCTAssertTrue(hits.contains("Platform/Windows/Elsewhere.swift|\(line)"), "\(name): \(line)")
            _ = spelling
        }
        XCTAssertTrue(try Self.hits(in: "let b = iceBreak.pond\nvar x = PlazaIceBreak(at: 0, pond: p).pond\n", rel: "x.swift").isEmpty,
                      "a property named pond on an ice break is not the tile")
        XCTAssertTrue(try Self.hits(in: "default: break\n", rel: "x.swift").isEmpty, "a default: in a file with no tiles is not a tile decision")
    }

    /// Sweep A of the big-tree plan: every direct `.tree`/`.bigTree` tile check in the plaza sources is classified here.
    static let allowedTree: Set<String> = [
        "PlazaMap.swift|case .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree, .stall: false",
        "PlazaMap.swift|guard p.x >= 0, p.y >= 0, p.x < width, p.y < height else { return .tree }",
        "PlazaMap.swift|func isBigTree(_ p: TilePoint) -> Bool { tile(at: p) == .bigTree }",
        "PlazaSnow.swift|case .tallGrass, .tree, .bush, .board, .campfire, .pond, .hotSpring, .bigTree, .stall: false",
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
