import XCTest

/// Source scans for Foundation behaviour that differs silently on Windows. See the Windows-Foundation entry in
/// `docs/reference/defect-log.md`.
final class WindowsSeamScanTests: XCTestCase {
    private static let timerRegex = try! NSRegularExpression(pattern: #"\bTimer(?:\.init)?\(\s*timeInterval\s*:"#)

    /// `Timer(timeInterval:` is `init(fire: Date(), ...)` in corelibs: its first tick comes at once on Windows (F14).
    static func timerViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            let ls = try SharedSources.lines(of: url)
            for (i, line) in ls.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                // a call split over two lines: `Timer(` then `timeInterval:` on the next
                let joined = code + " " + (i + 1 < ls.count ? ls[i + 1] : "")
                if timerRegex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                    || (code.trimmingCharacters(in: .whitespaces).hasSuffix("Timer(")
                        && timerRegex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) != nil) {
                    out.append("\(rel):\(i + 1) uses Timer(timeInterval:), which fires at once on Windows; use Timer(fire: Date(timeIntervalSinceNow: i), interval: i, …)")
                }
            }
        }
        return out
    }

    func testNoTimerIntervalInitializerInSharedOrWindowsCode() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(try Self.timerViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheTimerScanCatchesTheImmediateFireInitializer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-timer-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func scan(_ text: String) throws -> Int {
            let f = dir.appendingPathComponent("Injected.swift")
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.timerViolations(in: [f], root: dir).count
        }
        for bad in ["let t = Timer(timeInterval: 1, repeats: true) { _ in }", "let t = Timer.init(timeInterval: 1, repeats: true) { _ in }",
                    "let t = Timer( timeInterval: 1, repeats: true) { _ in }", "let t = Timer(\n    timeInterval: 1, repeats: true) { _ in }"] {
            XCTAssertEqual(try scan(bad + "\n"), 1, bad)
        }
        XCTAssertEqual(try scan("let t = Timer(fire: Date(timeIntervalSinceNow: 1), interval: 1, repeats: true) { _ in }\n// Timer(timeInterval: 1)\n"), 0)
        XCTAssertEqual(try scan("Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }\n"), 0)
    }

    /// macOS Foundation re-exports Observation; corelibs Foundation does not. A shared file that uses it without
    /// `import Observation` builds on the Mac, even in `shared-check.sh`, and fails only on Windows (Track A Task 12).
    static func observationImportViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let code = try SharedSources.lines(of: url).map { $0.components(separatedBy: "//").first ?? $0 }
            guard let i = code.firstIndex(where: { l in ["withObservationTracking", "@Observable", "@ObservationIgnored"].contains { l.contains($0) } }),
                  !code.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "import Observation" }) else { continue }
            out.append("\(SharedSources.relativePath(url, root: root)):\(i + 1) uses Observation without `import Observation`, which only the Mac's Foundation re-exports")
        }
        return out
    }

    func testSharedFilesThatObserveImportObservation() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(try Self.observationImportViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheObservationScanCatchesAMissingImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-observation-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func scan(_ text: String) throws -> Int {
            let f = dir.appendingPathComponent("Injected.swift")
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.observationImportViolations(in: [f], root: dir).count
        }
        XCTAssertEqual(try scan("import Foundation\nlet v = withObservationTracking { 1 } onChange: {}\n"), 1)
        XCTAssertEqual(try scan("import Foundation\n@Observable final class M {}\n"), 1)
        XCTAssertEqual(try scan("import Foundation\nimport Observation\n@Observable final class M {}\n"), 0)
        XCTAssertEqual(try scan("import Foundation\n// withObservationTracking in a comment\n"), 0)
    }

    /// `.libraryDirectory` is not mapped on Windows: `urls(for:)` is empty and `[0]` traps (F1).
    static func libraryDirectoryViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            if rel.hasPrefix("Platform/") { continue }
            for (i, line) in try SharedSources.lines(of: url).enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains(".libraryDirectory") {
                    out.append("\(rel):\(i + 1) asks for .libraryDirectory, which Windows does not map; use PlatformCompat.logsDirectory()")
                }
            }
        }
        return out
    }

    func testSharedFilesDoNotAskForTheLibraryDirectory() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(try Self.libraryDirectoryViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheLibraryDirectoryScanCatchesAUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-lib-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Injected.swift")
        try "let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.libraryDirectoryViolations(in: [f], root: dir).count, 1)
        try "let d = 1 // .libraryDirectory\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.libraryDirectoryViolations(in: [f], root: dir).count, 0)
    }
}
