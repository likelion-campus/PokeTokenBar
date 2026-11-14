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

    // MARK: The Windows app's main thread and its single exit (F2, F16)

    private static func code(_ line: String) -> String { line.components(separatedBy: "//").first ?? line }

    private static let asyncRegex = try! NSRegularExpression(pattern: #"\b(?:await|async)\b"#)

    /// `main.swift` stays synchronous: after the first `await` of an async main, main-actor code runs on a pool
    /// thread and the windows made before it are destroyed (F16).
    static func mainAsyncViolations(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).enumerated().compactMap { i, line in
            let c = code(line)
            return asyncRegex.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) == nil ? nil
                : "main.swift:\(i + 1) \(line.trimmingCharacters(in: .whitespaces)) (main.swift must stay synchronous)"
        }
    }

    func testWindowsMainIsSynchronous() throws {
        let url = SharedSources.repoRoot.appendingPathComponent("Sources/PokeTokenBarWin/main.swift")
        XCTAssertEqual(Self.mainAsyncViolations(try String(contentsOf: url, encoding: .utf8)), [])
    }

    func testTheMainScanCatchesAnAsyncMain() {
        XCTAssertEqual(Self.mainAsyncViolations("import PokeTokenBar\nawait WindowsApp.run()\n").count, 1)
        XCTAssertEqual(Self.mainAsyncViolations("@main enum M { static func main() async {} }\n").count, 1)
        XCTAssertEqual(Self.mainAsyncViolations("// an async main loses the thread\nWindowsApp.main()\n").count, 0)
    }

    private static let processExitPatterns = [
        #"(?<![\w.])(?<!func )exit\s*\("#,
        #"\b(?:Foundation|ucrt|CRT|WinSDK)\s*\.\s*exit\s*\("#,
        #"\b_exit\s*\("#,
        #"\bExitProcess\s*\("#,
        #"\bTerminateProcess\s*\(\s*GetCurrentProcess\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let crtExitCall = try! NSRegularExpression(pattern: #"(?<!func )\bcrtExit\s*\("#)

    /// Lines of the body of every declaration whose line contains `signature`, the declaration line included.
    static func bodyLines(of signature: String, in lines: [String]) -> Set<Int> {
        var out = Set<Int>()
        for (start, line) in lines.enumerated() where code(line).contains(signature) {
            var depth = 0
            var opened = false
            var i = start
            while i < lines.count {
                for ch in code(lines[i]) {
                    if ch == "{" { depth += 1; opened = true } else if ch == "}" { depth -= 1 }
                }
                out.insert(i)
                if opened && depth <= 0 { break }
                i += 1
            }
        }
        return out
    }

    /// Windows code leaves the process only through `WindowsApp.exit`, which saves the settings first: on Windows
    /// they reach the disk only on `synchronize()`, not on `exit(0)` or a kill (F2). The C `exit` lives in
    /// `crtExit` (WindowsApp.swift), which only `WindowsApp.exit` and the selftest's F2 control call.
    static func exitViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/") else { continue }
            let lines = try SharedSources.lines(of: url)
            let isApp = rel == "Platform/Windows/WindowsApp.swift"
            let rawAllowed = isApp ? bodyLines(of: "func crtExit(", in: lines) : []
            let callAllowed = isApp ? bodyLines(of: "static func exit(", in: lines)
                .union(bodyLines(of: "static func exitWithoutSyncForF2Control(", in: lines)) : []
            for (i, line) in lines.enumerated() {
                let c = code(line)
                let range = NSRange(c.startIndex..., in: c)
                if !rawAllowed.contains(i), processExitPatterns.contains(where: { $0.firstMatch(in: c, range: range) != nil }) {
                    out.append("\(rel):\(i + 1) ends the process outside WindowsApp.exit, so settings are not saved (F2)")
                }
                if !callAllowed.contains(i), crtExitCall.firstMatch(in: c, range: range) != nil {
                    out.append("\(rel):\(i + 1) calls crtExit outside WindowsApp.exit")
                }
            }
        }
        return out
    }

    func testWindowsCodeExitsOnlyThroughWindowsAppExit() throws {
        let files = SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot)
        XCTAssertTrue(files.contains { SharedSources.relativePath($0, root: SharedSources.sourcesRoot) == "Platform/Windows/WindowsApp.swift" })
        XCTAssertEqual(try Self.exitViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheExitScanCatchesEveryOtherExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-exit-scan-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("Platform/Windows")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ name: String, _ text: String) throws -> Int {
            let f = dir.appendingPathComponent(name)
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.exitViolations(in: [f], root: root).count
        }
        for bad in ["exit(1)", "Foundation.exit(1)", "_exit(1)", "ExitProcess(1)", "TerminateProcess(GetCurrentProcess(), 1)", "crtExit(1)"] {
            XCTAssertEqual(try scan("Other.swift", "func f() {\n    \(bad)\n}\n"), 1, bad)
        }
        XCTAssertEqual(try scan("Other.swift", "func f() {\n    WindowsApp.exit(0, .menu)\n    // exit(1)\n"
            + "    TerminateProcess(handle, 1)\n    _ = child.exitCode\n}\n"), 0)
        let app = "enum WindowsApp {\n    static func exit(_ code: Int32) -> Never {\n        crtExit(code)\n    }\n"
            + "    static func other() {\n        crtExit(1)\n    }\n}\nprivate func crtExit(_ code: Int32) -> Never {\n"
            + "    exit(code)\n}\n"
        XCTAssertEqual(try scan("WindowsApp.swift", app), 1, "only the call in other()")
    }

    /// Pool-thread callbacks (DNS-SD, the socket loop, the connectivity hint) must not enter the main actor with
    /// `assumeIsolated`: it traps off the main thread (F16). They hop with `DispatchQueue.main.async`; inside such a
    /// block `assumeIsolated` is on the main thread and allowed.
    static func assumeIsolatedViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/Team/") || rel == "Platform/Windows/WindowsReachability.swift" else { continue }
            var mainQueueBlocks: [Bool] = []
            var header = ""
            for (i, line) in try SharedSources.lines(of: url).enumerated() {
                for ch in code(line) {
                    switch ch {
                    case "{": mainQueueBlocks.append(header.contains("DispatchQueue.main.")); header = ""
                    case "}": _ = mainQueueBlocks.popLast(); header = ""
                    case ";": header = ""
                    default:
                        header.append(ch)
                        if header.hasSuffix("MainActor.assumeIsolated"), !mainQueueBlocks.contains(true) {
                            out.append("\(rel):\(i + 1) uses MainActor.assumeIsolated outside a DispatchQueue.main block "
                                + "(callbacks here run on pool threads, F16)")
                        }
                    }
                }
                let trimmed = code(line).trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("(") || trimmed.hasSuffix(",") { header.append(" ") } else { header = "" }
            }
        }
        return out
    }

    func testNoAssumeIsolatedInPoolThreadCallbacks() throws {
        let files = SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot)
        XCTAssertEqual(try Self.assumeIsolatedViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheAssumeIsolatedScanAllowsOnlyMainQueueBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-isolation-scan-\(UUID().uuidString)")
        let team = root.appendingPathComponent("Platform/Windows/Team")
        try FileManager.default.createDirectory(at: team, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ text: String, in dir: URL? = nil) throws -> Int {
            let f = (dir ?? team).appendingPathComponent("Injected.swift")
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.assumeIsolatedViolations(in: [f], root: root).count
        }
        XCTAssertEqual(try scan("func callback() {\n    MainActor.assumeIsolated { f() }\n}\n"), 1)
        XCTAssertEqual(try scan("DispatchQueue.global().async {\n    MainActor.assumeIsolated { f() }\n}\n"), 1)
        XCTAssertEqual(try scan("DispatchQueue.main.async { MainActor.assumeIsolated { f() } }\n"), 0)
        XCTAssertEqual(try scan("DispatchQueue.main.async {\n    for e in es {\n        guard ok else { return }\n"
            + "        MainActor.assumeIsolated { d(e) }\n    }\n}\n"), 0)
        XCTAssertEqual(try scan("DispatchQueue.main.asyncAfter(deadline: .now() + 1) {\n    MainActor.assumeIsolated { f() }\n}\n"), 0)
        XCTAssertEqual(try scan("func wndProc() {\n    MainActor.assumeIsolated { f() }\n}\n",
                                in: team.deletingLastPathComponent()), 0, "WndProcs (outside Team/) run on the main thread")
    }

    // MARK: - main-actor atomic writes (defect log: Windows flushes in .atomic)

    /// Files whose `.atomic` writes run on the main actor. Windows' `.atomic` flushes to disk (100-230 ms), so they go
    /// through `PlatformCompat.atomicWrite`. `allowed` is the rare, user-initiated write left alone on purpose.
    static let mainActorWriters: [(file: String, allowed: String?)] = [
        ("Core/CompanionStore.swift", "data.write(to: backup, options: .atomic)"),
        ("Core/UsageStore.swift", nil),
        ("Team/TeamFeedStore.swift", nil),
    ]

    static func directAtomicWrites(_ text: String, allowed: String?) -> [String] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, line in
            let code = Self.code(line)
            guard code.contains(".atomic") else { return nil }
            if let allowed, code.contains(allowed) { return nil }
            return "line \(i + 1): \(line.trimmingCharacters(in: .whitespaces))"
        }
    }

    func testMainActorStoresWriteThroughPlatformCompat() throws {
        for (file, allowed) in Self.mainActorWriters {
            let text = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(Self.directAtomicWrites(text, allowed: allowed), [], file)
            XCTAssertTrue(text.contains("PlatformCompat.atomicWrite("), "\(file) lost its routed write")
        }
    }

    func testTheAtomicWriteScanCatchesADirectCall() {
        XCTAssertEqual(Self.directAtomicWrites("try? data.write(to: u, options: .atomic)\n", allowed: nil).count, 1)
        XCTAssertEqual(Self.directAtomicWrites("try? PlatformCompat.atomicWrite(data, to: u) // .atomic\n", allowed: nil).count, 0)
    }
}
