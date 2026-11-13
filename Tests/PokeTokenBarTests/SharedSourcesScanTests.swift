import XCTest

/// Windows port guard. `Sources/PokeTokenBar/mac-only.txt` lists what Windows does not build; everything else is the
/// "shared set". The shared set may only grow: a shared file must not import an Apple-only framework and may use
/// `#if os(` / `#if canImport(` only in the three import-guard shapes (body-level conditionals live in `Platform/`).
enum SharedSources {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesRoot = repoRoot.appendingPathComponent("Sources/PokeTokenBar")
    static let sourcesList = sourcesRoot.appendingPathComponent("mac-only.txt")
    static let testsRoot = repoRoot.appendingPathComponent("Tests/PokeTokenBarTests")
    static let testsList = testsRoot.appendingPathComponent("mac-only.txt")

    /// Entries of a list file: one path per line, `#` comments, CRLF tolerated. A trailing `/` marks a directory.
    static func macOnly(listURL: URL) throws -> Set<String> {
        let text = try String(contentsOf: listURL, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    static func isListed(_ relative: String, in entries: Set<String>) -> Bool {
        entries.contains { $0.hasSuffix("/") ? relative.hasPrefix($0) : relative == $0 }
    }

    static func allSwiftFiles(root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return (e.allObjects as! [URL]).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    static func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    static func sharedFiles(root: URL, listURL: URL) throws -> [URL] {
        let entries = try macOnly(listURL: listURL)
        return allSwiftFiles(root: root).filter { !isListed(relativePath($0, root: root), in: entries) }
    }

    static let appleOnly = SharedSourcesScanTests.appleOnly

    private static let importRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z0-9_]+)"#)
    private static let conditionRegex = try! NSRegularExpression(pattern: #"\b(?:os|canImport|arch|targetEnvironment)\("#)

    static func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    }

    /// Modules imported on one source line, in any form (attributes, `;`-joined statements, trailing comments).
    static func importedModules(in line: String) -> [String] {
        let code = line.components(separatedBy: "//").first ?? line
        return code.components(separatedBy: ";").compactMap { statement in
            guard let m = importRegex.firstMatch(in: statement, range: NSRange(statement.startIndex..., in: statement)),
                  let r = Range(m.range(at: 1), in: statement) else { return nil }
            return String(statement[r])
        }
    }

    /// The one shared file that may import CoreGraphics (guarded by `canImport`); see its header comment.
    static let coreGraphicsShim = "Platform/MacGeometryImport.swift"

    /// One message per Apple-only import in `files`.
    static func importViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files where relativePath(url, root: root) != coreGraphicsShim {
            for line in try lines(of: url) {
                for module in importedModules(in: line) where appleOnly.contains(module) {
                    out.append("\(relativePath(url, root: root)) imports \(module). Add it to mac-only.txt, or route the call through Platform.")
                }
            }
        }
        return out
    }

    /// The only conditionals a shared file may contain: each guard is the opening line followed by these lines.
    static let guardShapes: [[String]] = [
        ["#if canImport(FoundationNetworking)", "import FoundationNetworking", "#endif"],
        ["#if canImport(CryptoKit)", "import CryptoKit", "#else", "import Crypto", "#endif"],
        ["#if canImport(SQLite3)", "import SQLite3", "#else", "import CSQLite", "#endif"],
    ]

    static func guardViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = relativePath(url, root: root)
            if rel.hasPrefix("Platform/") { continue }
            let ls = try lines(of: url).map { $0.trimmingCharacters(in: .whitespaces) }
            var covered = Set<Int>()
            for (i, l) in ls.enumerated() where (l.hasPrefix("#if") || l.hasPrefix("#elseif"))
                && conditionRegex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil {
                if let shape = guardShapes.first(where: { Array(ls[i...].prefix($0.count)) == $0 }) {
                    covered.formUnion(i..<(i + shape.count))
                } else {
                    out.append("\(rel):\(i + 1) has `\(l)`. Only the three import guards are allowed outside Platform/.")
                }
            }
            for (i, l) in ls.enumerated() where !covered.contains(i)
                && !Set(importedModules(in: l)).isDisjoint(with: ["CryptoKit", "SQLite3"]) {
                out.append("\(rel):\(i + 1) has `\(l)` outside its import guard.")
            }
        }
        return out
    }

    static func lineCount(of files: [URL]) throws -> Int {
        try files.reduce(0) { $0 + (try String(contentsOf: $1, encoding: .utf8).split(whereSeparator: \.isNewline).count) }
    }
}

final class SharedSourcesScanTests: XCTestCase {
    static let appleOnly: Set<String> = ["AppKit", "SwiftUI", "SpriteKit", "CoreGraphics", "CoreText", "QuartzCore", "ImageIO",
                                          "UniformTypeIdentifiers", "Network", "Security", "LocalAuthentication", "ServiceManagement",
                                          "UserNotifications", "Darwin", "Metal", "Combine",
                                          "WebKit", "IOKit", "CoreServices", "ApplicationServices", "CoreImage", "AVFoundation",
                                          "OSLog", "os", "Cocoa", "Carbon"]  // not CoreFoundation: Foundation re-exports it on Windows too

    func testEveryListedPathExists() throws {
        for (list, root) in [(SharedSources.sourcesList, SharedSources.sourcesRoot), (SharedSources.testsList, SharedSources.testsRoot)] {
            for entry in try SharedSources.macOnly(listURL: list) {
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(entry).path, isDirectory: &isDir)
                XCTAssertTrue(exists, "\(list.lastPathComponent) lists \(entry), which does not exist")
                if entry.hasSuffix("/") { XCTAssertTrue(isDir.boolValue, "\(entry) ends with / but is not a directory") }
                else { XCTAssertFalse(isDir.boolValue, "\(list.lastPathComponent) lists directory \(entry) without a trailing /") }
            }
        }
    }

    func testSharedFilesImportNothingAppleOnly() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertFalse(files.isEmpty)
        let bad = try SharedSources.importViolations(in: files, root: SharedSources.sourcesRoot)
        XCTAssertEqual(bad, [])
    }

    func testOnlyTheThreeImportGuardsAppearOutsidePlatform() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertFalse(files.isEmpty)
        let bad = try SharedSources.guardViolations(in: files, root: SharedSources.sourcesRoot)
        XCTAssertEqual(bad, [])
    }

    /// Runs both scanners over a temp dir holding one file with `content`.
    private func scan(_ content: String) throws -> (imports: [String], guards: [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Injected.swift")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return (try SharedSources.importViolations(in: [file], root: dir), try SharedSources.guardViolations(in: [file], root: dir))
    }

    func testTheScanCatchesAnInjectedImport() throws {
        let r = try scan("import Foundation\nimport AppKit\n")
        XCTAssertEqual(r.imports, ["Injected.swift imports AppKit. Add it to mac-only.txt, or route the call through Platform."])
        XCTAssertEqual(r.guards, [])
    }

    func testTheScanCatchesImportVariants() throws {
        for line in ["@_spi(X) import AppKit", "@preconcurrency import SwiftUI", "import Foundation; import AppKit",
                     "import AppKit // why", "import struct AppKit.NSColor", "import os", "import WebKit"] {
            XCTAssertEqual(try scan(line + "\n").imports.count, 1, line)
        }
        XCTAssertEqual(try scan("import Foundation\n// import AppKit\n").imports, [])
    }

    func testTheScanCatchesConditionalsOutsideTheThreeGuards() throws {
        for cond in ["#if os(macOS)", "#if !os(Windows)", "#if !canImport(AppKit)", "#if os(macOS) || os(iOS)",
                     "#if arch(arm64)", "#if targetEnvironment(simulator)", "#if DEBUG && os(macOS)", "#if canImport(AppKit)"] {
            XCTAssertEqual(try scan("\(cond)\nlet x = 1\n#endif\n").guards.count, 1, cond)
        }
        XCTAssertEqual(try scan("#if DEBUG\nlet x = 1\n#elseif os(macOS)\nlet y = 1\n#endif\n").guards.count, 1)
        XCTAssertEqual(try scan("#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n").guards, [])
    }

    func testCryptoKitAndSQLite3NeedTheirGuardInAnyImportForm() throws {
        for line in ["import CryptoKit", "@preconcurrency import CryptoKit", "import SQLite3 // x", "import Foundation; import CryptoKit"] {
            XCTAssertEqual(try scan(line + "\n").guards.count, 1, line)
        }
    }

    func testSharedSetDoesNotShrink() throws {
        let floorText = try String(contentsOf: SharedSources.testsRoot.appendingPathComponent("shared-floor.txt"), encoding: .utf8)
        let floor = try XCTUnwrap(Int(floorText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        let count = try SharedSources.lineCount(of: files)
        XCTAssertGreaterThanOrEqual(count, floor, "shared set shrank from \(floor) to \(count) lines; moving files into mac-only.txt needs a reason")
    }
}
