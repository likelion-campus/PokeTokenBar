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
}
