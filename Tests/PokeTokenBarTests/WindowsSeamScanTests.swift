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
        // CompanionStore.update -> autoSnapshotIfNeeded (main actor, at most every 12 h) -> createManualSnapshot
        ("Core/SaveSnapshots.swift", nil),
    ]

    static func directAtomicWrites(_ text: String, allowed: String?) -> [String] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, line in
            let code = Self.code(line)
            guard code.contains("options: .atomic") else { return nil }
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

    // MARK: the session key's file (stage 7 Task 14, D14)

    /// The two upstream lines of `SessionKeyStore` that route its file through the secret seams (DPAPI on Windows). An upstream
    /// merge that puts the plain calls back would leave Windows writing the key unencrypted: this fails then.
    static func secretSeamFindings(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").map(Self.code)
        var out: [String] = []
        let reads = lines.filter { $0.contains("PlatformCompat.readSecret(at: fileURL)") }.count
        let writes = lines.filter { $0.contains("PlatformCompat.writeSecret(data, to: fileURL)") }.count
        if reads != 1 { out.append("SessionKeyStore.load reads through PlatformCompat.readSecret \(reads) times (expected 1)") }
        if writes != 1 { out.append("SessionKeyStore.save writes through PlatformCompat.writeSecret \(writes) times (expected 1)") }
        for (i, line) in lines.enumerated() where line.contains("Data(contentsOf: fileURL)") || line.contains("write(to: fileURL") {
            out.append("line \(i + 1) reads or writes the key file without the seam: \(line.trimmingCharacters(in: .whitespaces))")
        }
        return out
    }

    func testTheSessionKeyFileGoesThroughTheSecretSeams() throws {
        let text = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent("Core/SessionKeyLimitsProvider.swift"), encoding: .utf8)
        XCTAssertEqual(Self.secretSeamFindings(text), [])
    }

    /// The four upstream lines of Task 14's path fix (P19): each routes its standardization through a `PlatformCompat` seam
    /// whose Mac branch is the old expression (`PlatformPathFormsTests.testTheMacPathSeamsAreTheOldExpressions`). An upstream
    /// merge that restores the plain call would bring back the UNC defect on Windows: this fails then.
    static let pathSeamSites: [(file: String, line: String)] = [
        ("Core/LocalUsageReader.swift", "let path = PlatformCompat.resolvedFileURL(root).path"),
        ("Core/CustomScanRoots.swift", "PlatformCompat.resolvedPath(url).lowercased()"),
        ("Core/LocalAsideUsageReader.swift", "let db = PlatformCompat.resolvedFileURL(directory.appendingPathComponent(\"state.db\"))"),
        ("Core/ClaudeAccountRoots.swift", "let url = PlatformCompat.standardizedDirectoryURL(expanded)"),
    ]

    func testTheUserPathsGoThroughThePathSeams() throws {
        for (file, line) in Self.pathSeamSites {
            let text = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: line).count - 1, 1, "\(file): \(line)")
            XCTAssertFalse(text.components(separatedBy: "\n").map(Self.code).contains { $0.contains("resolvingSymlinksInPath()") }, "\(file) resolves links without the seam")
        }
    }

    /// Every URL-based folder walk or listing in Core goes through `PlatformCompat.enumerator` / `contentsOfDirectory` (review
    /// of Task 14): swift-foundation's URL-based listing finds nothing under a share on Windows, so a bare call there leaves
    /// a custom scan folder on a share unscanned while Settings counts it. An upstream merge or a new reader that calls
    /// `FileManager` directly fails here. (The String-based `contentsOfDirectory(atPath:)` lists shares and stays allowed.)
    static func bareListingFindings(file: String, _ text: String) -> [String] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, raw in
            let line = code(raw)
            let lists = (line.contains(".enumerator(") && !line.contains("enumerator(atPath:")) || line.contains("contentsOfDirectory(at:")
            return lists && !line.contains("PlatformCompat.") ? "\(file):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    func testCoreListsFoldersThroughTheListingSeams() throws {
        let core = SharedSources.sourcesRoot.appendingPathComponent("Core")
        let files = try FileManager.default.contentsOfDirectory(atPath: core.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20)
        var findings: [String] = [], seamed = 0
        for file in files {
            let text = try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
            findings += Self.bareListingFindings(file: file, text)
            seamed += text.components(separatedBy: "PlatformCompat.enumerator(").count - 1 + text.components(separatedBy: "PlatformCompat.contentsOfDirectory(").count - 1
        }
        XCTAssertEqual(findings, [])
        XCTAssertEqual(seamed, 8, "the eight call sites of the review round")
        XCTAssertEqual(Self.bareListingFindings(file: "x", "guard let en = fm.enumerator(\n at: root"), ["x:1: guard let en = fm.enumerator("], "the scan sees a bare call")
        XCTAssertEqual(Self.bareListingFindings(file: "x", "let n = try fm.contentsOfDirectory(atPath: p) // enumerator( note"), [])
    }

    /// The Mac branches of the secret seams are the calls the two lines made before (an atomic write cannot be told from a
    /// plain one by its bytes, so the text is held here; `SecretSeamTests` holds what they do).
    func testTheMacBranchesOfTheSecretSeamsAreTheOldCalls() throws {
        let text = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent("Platform/PlatformCompat.swift"), encoding: .utf8)
        func body(_ name: String) -> String {
            guard let start = text.range(of: "static func \(name)(") else { return "" }
            let rest = text[start.upperBound...]
            guard let end = rest.range(of: "\n    }\n") else { return "" }
            return String(rest[..<end.lowerBound])
        }
        let write = body("writeSecret"), read = body("readSecret")
        XCTAssertTrue(write.contains("#else\n        try data.write(to: url, options: .atomic)\n        #endif"), write)
        XCTAssertTrue(read.contains("#else\n        return try? Data(contentsOf: url)\n        #endif"), read)
    }

    func testTheSecretSeamScanCatchesThePlainCalls() {
        let routed = "guard let data = PlatformCompat.readSecret(at: fileURL),\n        try PlatformCompat.writeSecret(data, to: fileURL)\n"
        XCTAssertEqual(Self.secretSeamFindings(routed), [])
        XCTAssertEqual(Self.secretSeamFindings("guard let data = try? Data(contentsOf: fileURL),\n        try PlatformCompat.writeSecret(data, to: fileURL)\n").count, 2)
        XCTAssertEqual(Self.secretSeamFindings("guard let data = PlatformCompat.readSecret(at: fileURL),\n        try data.write(to: fileURL, options: .atomic)\n").count, 2)
    }

    // MARK: URLSession on Windows keeps two dispatch threads awake for a whole transfer (defect log, "윈도우 URLSession")

    private static let directRequest = try! NSRegularExpression(
        pattern: #"\.(data|bytes|upload|download)\((for|from):|(data|download|upload|webSocket|stream)Task\("#)

    /// The only files that run on Windows and send a request themselves: the seam (its Mac branch and the Windows fallback)
    /// and the two diagnostics helpers, which measure URLSession on purpose.
    static let directRequestFiles: Set<String> = [
        "Platform/PlatformCompat.swift",
        "Platform/Windows/WindowsSelftestWakers.swift",
        "Platform/Windows/WindowsSelftestNetBurst.swift",
    ]

    /// Every routed call site, by file, with how many calls it makes through the seam (one upstream line each).
    static let routedSites: [String: Int] = [
        "Core/ProviderStatusChecker.swift": 1,        // provider status pages, each refresh
        "Core/ClaudeOAuthLimitsProvider.swift": 2,    // Claude usage + profile, each refresh with credentials
        "Core/SessionKeyLimitsProvider.swift": 1,     // Claude limits by session key, each refresh when set
        "Core/CursorAuthentication.swift": 1,         // Cursor token refresh (own session)
        "Core/CursorUsageAPI.swift": 1,               // Cursor usage pages (own session)
        "Core/CursorRateLimitsProvider.swift": 1,     // Cursor limits (own session)
        "Core/GrokRateLimitsProvider.swift": 1,       // Grok credits (own session)
        "Core/OpenCodeGoRateLimitsProvider.swift": 1, // OpenCode Go usage (own session)
        "Core/PokeAPIClient.swift": 2,                // species REST + base index GraphQL POST
        "Core/PokemonNameLocalization.swift": 1,      // name tables, once
        "Core/UpdateChecker.swift": 1,                // release feed (the Mac's path)
        "Core/SpriteStore.swift": 3,                  // sprites, items, egg
        "Platform/InstallerReleaseFeed.swift": 1,     // release feed on Windows
        "Team/Plaza/PlazaIconStore.swift": 1,         // plaza icons
    ]

    static func directRequestFiles(in files: [URL], root: URL) throws -> Set<String> {
        var out: Set<String> = []
        for url in files {
            for line in try SharedSources.lines(of: url) {
                let c = code(line)
                if directRequest.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) != nil {
                    out.insert(SharedSources.relativePath(url, root: root))
                    break
                }
            }
        }
        return out
    }

    func testNoRequestOutsideTheSeamInCodeThatRunsOnWindows() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        let found = try Self.directRequestFiles(in: files, root: SharedSources.sourcesRoot)
        XCTAssertEqual(found.subtracting(Self.directRequestFiles).sorted(), [],
                       "a request sent straight through URLSession in code that runs on Windows: there every new connection keeps two "
                       + "dispatch threads waking each other until the transfer ends. Send it through PlatformCompat.oneShotData.")
        XCTAssertEqual(Self.directRequestFiles.subtracting(found).sorted(), [], "a listed file no longer sends a request: drop it")
    }

    func testEveryRoutedSiteStaysOnTheSeam() throws {
        for (file, expected) in Self.routedSites.sorted(by: { $0.key < $1.key }) {
            let url = SharedSources.sourcesRoot.appendingPathComponent(file)
            let text = try SharedSources.lines(of: url).map(Self.code).joined(separator: "\n")
            XCTAssertEqual(text.components(separatedBy: "PlatformCompat.oneShotData(").count - 1, expected, "\(file): calls through the seam")
            XCTAssertEqual(try Self.directRequestFiles(in: [url], root: SharedSources.sourcesRoot), [], "\(file) sends a request itself")
        }
    }

    // MARK: WinHTTP keeps Windows' certificate checks (review of fix/windows-fetches-through-winhttp, item 4)

    /// `WINHTTP_OPTION_SECURITY_FLAGS` (31) relaxes certificate checks (`SECURITY_FLAG_IGNORE_*`): the seam never sets it.
    /// Comments may name it; code may not.
    static func certificateRelaxations(_ lines: [String]) -> [String] {
        lines.enumerated().compactMap { i, line in
            let c = code(line)
            let hit = c.contains("SECURITY_FLAG")
                || c.range(of: #"\boption\w*\s*:\s*UInt32\s*=\s*31\b"#, options: .regularExpression) != nil
                || c.range(of: #"setOption\([^,]+,\s*31\s*,"#, options: .regularExpression) != nil
            return hit ? "line \(i + 1): \(line.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    func testWinHTTPRelaxesNoCertificateCheck() throws {
        let url = SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows/WinHTTPFetch.swift")
        XCTAssertEqual(Self.certificateRelaxations(try SharedSources.lines(of: url)), [])
    }

    func testTheCertificateScanCatchesARelaxation() {
        for line in ["    private static let optionSecurityFlags: UInt32 = 31", "_ = api.setOption(handle, 31, &flags, 4)",
                     "var flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA"] {
            XCTAssertEqual(Self.certificateRelaxations([line]).count, 1, line)
        }
        XCTAssertEqual(Self.certificateRelaxations(["/// `WINHTTP_OPTION_SECURITY_FLAGS` is never set"]), [])
    }

    func testTheRequestScanCatchesEachForm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-request-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Injected.swift")
        for text in ["let (d, _) = try await URLSession.shared.data(for: r)\n", "let (d, _) = try await session.data(from: u)\n",
                     "let t = session.dataTask(with: r)\n", "for try await b in session.bytes(for: r).0 {}\n"] {
            try text.write(to: f, atomically: true, encoding: .utf8)
            XCTAssertEqual(try Self.directRequestFiles(in: [f], root: dir), ["Injected.swift"], text)
        }
        try "let (d, _) = try await PlatformCompat.oneShotData(for: r) // URLSession.shared.data(for: r)\n"
            .write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.directRequestFiles(in: [f], root: dir), [])
    }
}

// MARK: - the plaza window (stage 6 Task 5)

extension WindowsSeamScanTests {
    /// Calls that can bring a window forward or take the foreground.
    static let activationCalls = ["SetForegroundWindow(", "ShowWindow(", "SetActiveWindow(", "BringWindowToTop(",
                                  "SwitchToThisWindow(", "AllowSetForegroundWindow("]

    /// Only `WinPlazaWindow.bringToFront` activates (stage 6 Global Constraints, "Focus"): it runs only for the user's
    /// action (the tray, a team balloon, `--open-plaza`). Anywhere else under `Platform/Windows/Plaza/` an activation call
    /// fails, and every `SetWindowPos` there passes `SWP_NOACTIVATE` (without it, a resize or a DPI move activates).
    static func plazaActivationViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/Plaza/") else { continue }
            let lines = try SharedSources.lines(of: url)
            let allowed = bodyLines(of: "func bringToFront(", in: lines)
            for (i, line) in lines.enumerated() {
                let c = code(line)
                for call in activationCalls where c.contains(call) && !allowed.contains(i) {
                    out.append("\(rel):\(i + 1) calls \(call.dropLast()) outside bringToFront: the plaza may come forward without the user")
                }
                if c.contains("SetWindowPos("), !c.contains("SWP_NOACTIVATE") {
                    out.append("\(rel):\(i + 1) SetWindowPos without SWP_NOACTIVATE")
                }
            }
        }
        return out
    }

    func testOnlyBringToFrontActivatesThePlaza() throws {
        let files = SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot)
        XCTAssertTrue(files.contains { SharedSources.relativePath($0, root: SharedSources.sourcesRoot) == "Platform/Windows/Plaza/WinPlazaWindow.swift" })
        XCTAssertEqual(try Self.plazaActivationViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheActivationScanCatchesACallOutsideBringToFront() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-focus-scan-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("Platform/Windows/Plaza")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ text: String) throws -> Int {
            let f = dir.appendingPathComponent("Injected.swift")
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.plazaActivationViolations(in: [f], root: root).count
        }
        XCTAssertEqual(try scan("func bringToFront() {\n    _ = ShowWindow(h, SW_SHOWNORMAL)\n    _ = SetForegroundWindow(h)\n}\n"), 0)
        XCTAssertEqual(try scan("func showBanner() {\n    _ = SetForegroundWindow(h)\n}\n"), 1)
        XCTAssertEqual(try scan("func tick() {\n    _ = ShowWindow(h, SW_RESTORE)\n}\n"), 1)
        XCTAssertEqual(try scan("func dpi() {\n    _ = SetWindowPos(h, nil, 0, 0, 1, 1, UINT(SWP_NOZORDER))\n}\n"), 1)
        XCTAssertEqual(try scan("func dpi() {\n    _ = SetWindowPos(h, nil, 0, 0, 1, 1, UINT(SWP_NOZORDER | SWP_NOACTIVATE))\n}\n"), 0)
        XCTAssertEqual(try scan("func f() {\n    // SetForegroundWindow( is only for bringToFront\n}\n"), 0)
    }

    // MARK: - who may take the foreground (stage 7 Task 4, D4)

    /// The places in Windows code that may bring a window forward, each for a user's action: the popover's `present` (a tray
    /// click or key, the tray menu, a second launch), the tray menu's foreground dance, the second instance handing its
    /// right to the running one, the plaza's `bringToFront` (its own scan above), and `--ime-check` (a diagnostic a person
    /// starts), and the in-app update's progress window (stage 8 Task 6: opened only by the user's "Update", through
    /// `UpdateChecker.applyUpdate`). The selftest (`WindowsSelftest*.swift`, the runner only) is outside the rule. Anything
    /// else fails: a teammate, a timer, a balloon or a refresh must never pull a window of ours to the front. The menu
    /// runner's second call (stage 7 Task 22) gives the foreground back after a menu of the floating pet, to the window
    /// that had it before the menu, never to one of ours it was not taken from (its own test below).
    static let activationSites: [(file: String, function: String?)] = [
        ("Platform/Windows/Popover/WinPopover.swift", "func present("),
        ("Platform/Windows/WinUpdateProgress.swift", "private func open("),
        ("Platform/Windows/WinTray.swift", "static func run("),
        ("Platform/Windows/WinSingleInstance.swift", "static func acquire("),
        ("Platform/Windows/Plaza/WinPlazaWindow.swift", "func bringToFront("),
        ("Platform/Windows/WinImeCheck.swift", nil),
    ]

    static func windowsActivationViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        for url in files {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/"), !(rel.components(separatedBy: "/").last ?? "").hasPrefix("WindowsSelftest") else { continue }
            let lines = try SharedSources.lines(of: url)
            var allowed = Set<Int>()
            for site in activationSites where site.file == rel {
                if let function = site.function { allowed.formUnion(bodyLines(of: function, in: lines)) } else { allowed.formUnion(lines.indices) }
            }
            for (i, line) in lines.enumerated() {
                let c = code(line)
                // One finding a line (`AllowSetForegroundWindow(` contains `SetForegroundWindow(`).
                if !allowed.contains(i), let call = activationCalls.first(where: { c.contains($0) }) {
                    out.append("\(rel):\(i + 1) calls \(call.dropLast()) outside the allowed sites (\(activationSites.map(\.file).joined(separator: ", "))): a window of ours may come forward without the user")
                }
                if rel.hasPrefix("Platform/Windows/Popover/"), c.contains("SetWindowPos("), !Self.call(from: i, in: lines).contains("SWP_NOACTIVATE") {
                    out.append("\(rel):\(i + 1) SetWindowPos without SWP_NOACTIVATE in the popover")
                }
            }
        }
        return out
    }

    /// The call that starts on line `i`, to its closing parenthesis (a call wrapped over lines keeps its flags on a later one).
    static func call(from i: Int, in lines: [String]) -> String {
        var text = "", depth = 0, opened = false
        for line in lines[i...].prefix(8) {
            let c = code(line)
            text += c + " "
            for ch in c { if ch == "(" { depth += 1; opened = true } else if ch == ")" { depth -= 1 } }
            if opened && depth <= 0 { break }
        }
        return text
    }

    func testOnlyTheAllowedSitesActivateWindowsOfOurs() throws {
        let files = SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot)
        for site in Self.activationSites {
            XCTAssertTrue(files.contains { SharedSources.relativePath($0, root: SharedSources.sourcesRoot) == site.file }, "\(site.file) is gone: update the list")
        }
        XCTAssertEqual(try Self.windowsActivationViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    // --- stage 7 Task 22: the menu runner's two activations (begin) ---
    /// `WinPopupMenu.run` activates exactly twice: its owner for the menu (the foreground dance), and, for a caller that opts
    /// in (the floating pet, which never takes the foreground), the window that had the foreground before the menu, read
    /// in `run` itself from `GetForegroundWindow()` before the owner took it. No other target, and no other call there.
    func testTheMenuRunnerActivatesItsOwnerAndGivesBackOnlyToTheWindowItTookItFrom() throws {
        let lines = try SharedSources.lines(of: SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows/WinTray.swift"))
        let body = Self.bodyLines(of: "static func run(", in: lines).sorted().map { Self.code(lines[$0]) }
        XCTAssertFalse(body.isEmpty, "WinPopupMenu.run is gone: update this test")
        let activations = body.filter { line in Self.activationCalls.contains { line.contains($0) } }
        XCTAssertEqual(activations.map { $0.trimmingCharacters(in: .whitespaces) },
                       ["_ = SetForegroundWindow(owner)", "gaveBack = SetForegroundWindow(previous)"],
                       "the owner for the menu, then only the window that had the foreground")
        XCTAssertEqual(body.filter { $0.contains("let previous = ") }.map { $0.trimmingCharacters(in: .whitespaces) },
                       ["let previous = giveBack == nil ? nil : GetForegroundWindow()"],
                       "previous is the foreground window read before the owner takes it, and nothing else")
        let ownerAt = body.firstIndex { $0.contains("SetForegroundWindow(owner)") } ?? -1
        let previousAt = body.firstIndex { $0.contains("let previous = ") } ?? Int.max
        XCTAssertLessThan(previousAt, ownerAt, "read before the owner takes the foreground")
        let backAt = body.firstIndex { $0.contains("SetForegroundWindow(previous)") } ?? -1
        let guardText = body[max(0, backAt - 3)..<max(0, backAt)].joined(separator: " ")
        for condition in ["previous != owner", "GetForegroundWindow() == owner", "IsWindow(previous)", "IsWindowVisible(previous)", "giveBack(chosen, previous)"] {
            XCTAssertTrue(guardText.contains(condition), "the give-back is guarded by \(condition)")
        }
    }
    // --- stage 7 Task 22 (end) ---

    func testTheWindowsActivationScanCatchesACallOutsideTheSites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-activation-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ rel: String, _ text: String) throws -> Int {
            let f = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: f, atomically: true, encoding: .utf8)
            return try Self.windowsActivationViolations(in: [f], root: root).count
        }
        let present = "func present(_ opener: Opener) {\n    _ = SetForegroundWindow(h)\n    _ = ShowWindow(h, SW_SHOW)\n}\n"
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinPopover.swift", present), 0)
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinPopover.swift", present + "func rebuild() {\n    _ = SetForegroundWindow(h)\n}\n"), 1)
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinHomePage.swift", "func onChange() {\n    _ = ShowWindow(h, SW_SHOW)\n}\n"), 1)
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinHomePage.swift", "func f() {\n    _ = SetWindowPos(h, nil, 0, 0, 1, 1, UINT(SWP_NOZORDER))\n}\n"), 1)
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinHomePage.swift",
                                "func f() {\n    _ = SetWindowPos(h, nil, 0, 0, 1, 1,\n                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))\n}\n"), 0, "flags on the next line")
        XCTAssertEqual(try scan("Platform/Windows/Popover/WinHomePage.swift",
                                "func f() {\n    _ = SetWindowPos(h, nil, 0, 0, 1, 1,\n                     UINT(SWP_NOZORDER))\n    g(SWP_NOACTIVATE)\n}\n"), 1,
                       "a later statement's flag does not count")
        XCTAssertEqual(try scan("Platform/Windows/WinTrayHost.swift", "func refresh() {\n    _ = BringWindowToTop(h)\n}\n"), 1)
        XCTAssertEqual(try scan("Platform/Windows/WinSingleInstance.swift", "static func acquire(name: String) {\n    _ = AllowSetForegroundWindow(pid)\n}\n"), 0)
        XCTAssertEqual(try scan("Platform/Windows/WinSingleInstance.swift", "static func other() {\n    _ = AllowSetForegroundWindow(pid)\n}\n"), 1)
        XCTAssertEqual(try scan("Platform/Windows/WindowsSelftestPopoverWindow.swift", "func grant() {\n    _ = SetForegroundWindow(h)\n}\n"), 0)
        XCTAssertEqual(try scan("Platform/Windows/WinTrayHost.swift", "func f() {\n    // SetForegroundWindow( only in present\n}\n"), 0)
        XCTAssertEqual(try scan("Team/Plaza/Elsewhere.swift", "func f() {\n    _ = SetForegroundWindow(h)\n}\n"), 0, "shared code cannot call Win32 (other scans)")
    }

    /// The frame clock's thread must not touch the main actor (it only waits and posts, D4).
    static func clockThreadViolations(_ text: String) -> [String] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, line in
            let c = code(line)
            guard c.contains("assumeIsolated") || c.contains("DispatchQueue.main") else { return nil }
            return "line \(i + 1): \(line.trimmingCharacters(in: .whitespaces))"
        }
    }

    func testTheFrameClockTouchesNoMainActorState() throws {
        let text = try String(contentsOf: SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows/Plaza/WinFrameClock.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("ptb_clock_create("), "WinFrameClock.swift no longer wraps the clock thread")
        XCTAssertEqual(Self.clockThreadViolations(text), [])
    }

    func testTheClockScanCatchesAMainActorHop() {
        XCTAssertEqual(Self.clockThreadViolations("func fire() {\n    MainActor.assumeIsolated { tick() }\n}\n").count, 1)
        XCTAssertEqual(Self.clockThreadViolations("func fire() {\n    DispatchQueue.main.async { tick() }\n}\n").count, 1)
        XCTAssertEqual(Self.clockThreadViolations("func fire() {\n    // no DispatchQueue.main here\n    post()\n}\n").count, 0)
    }
}

// MARK: - the in-app update's download and its CI hooks (stage 8 Task 6)

extension WindowsSeamScanTests {
    /// Calls of `needle` per file (code only, `//` comments stripped), the `declaration` form not counted.
    static func calls(of needle: String, notCounting declaration: String? = nil, in files: [URL], root: URL) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for url in files {
            let text = try SharedSources.lines(of: url).map(code).joined(separator: "\n")
            var n = text.components(separatedBy: needle).count - 1
            if let declaration { n -= text.components(separatedBy: declaration).count - 1 }
            if n > 0 { out[SharedSources.relativePath(url, root: root)] = n }
        }
        return out
    }

    /// The text of each call of `needle` up to its closing parenthesis.
    static func callTexts(of needle: String, in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let r = rest.range(of: needle) {
            var depth = 1
            var i = r.upperBound
            while i < rest.endIndex, depth > 0 {
                if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }
                i = rest.index(after: i)
            }
            out.append(String(rest[r.lowerBound..<i]))
            rest = rest[i...]
        }
        return out
    }

    static let installerFile = "Platform/Windows/WindowsUpdateInstaller.swift"
    static let selftestUpdateFile = "Platform/Windows/WindowsSelftestUpdate.swift"
    static let shellFile = "Platform/Windows/WindowsShell.swift"
    /// The hooks only the tests and the CI selftest pass to `WindowsUpdateInstaller.install`.
    static let installHooks = ["fetch:", "launch:", "flush:", "onLaunched:", "setupRunning:", "folder:", "logs:"]

    /// One download site, the installer's, with its own cap and deadline (the seam has no default cap: defect log, "기본 상한은
    /// 그 값을 정한 호출부의 크기다"); the relaxations the CI loopback needs are reachable from one place each; the app's own call
    /// of the install passes none of the test hooks.
    static func updateSeamViolations(in files: [URL], root: URL) throws -> [String] {
        var out: [String] = []
        func expect(_ needle: String, _ declaration: String? = nil, _ sites: [String: Int], _ why: String) throws {
            let found = try calls(of: needle, notCounting: declaration, in: files, root: root)
            if found != sites { out.append("\(needle) is called in \(found.sorted { $0.key < $1.key }), expected \(sites.sorted { $0.key < $1.key }): \(why)") }
        }
        try expect("PlatformCompat.oneShotDownload(", nil, [installerFile: 1], "the update installer is the one download")
        try expect("fetch(request, installer.size, downloadDeadline,", nil, [installerFile: 1], "the cap is the installer's own size")
        try expect("useLoopbackFeed(", "func useLoopbackFeed(", [selftestUpdateFile: 1], "only the CI selftest flag sets the loopback feed")
        try expect("LoopbackFeed(feed:", nil, [selftestUpdateFile: 2], "the loopback feed is made only by the CI selftest")
        try expect("allowHTTP: true", nil, [installerFile: 1], "plain HTTP only for the loopback feed's download")
        try expect("WindowsUpdateInstaller.install(", nil, [shellFile: 1, selftestUpdateFile: 1], "the app's install and the CI checks")
        for url in files where SharedSources.relativePath(url, root: root) == shellFile {
            let text = try SharedSources.lines(of: url).map(code).joined(separator: "\n")
            for call in callTexts(of: "WindowsUpdateInstaller.install(", in: text) {
                for hook in installHooks where call.contains(hook) { out.append("\(shellFile): the app's install passes the test hook \(hook)") }
            }
        }
        for url in files where SharedSources.relativePath(url, root: root) == "Platform/PlatformCompat.swift" {
            let text = try SharedSources.lines(of: url).map(code).joined(separator: "\n")
            for call in callTexts(of: "static func oneShotDownload(", in: text) where call.contains("maxBytes: Int =") || call.contains("deadline: TimeInterval =") {
                out.append("Platform/PlatformCompat.swift: oneShotDownload has a default cap or deadline: \(call)")
            }
        }
        return out
    }

    func testTheUpdateDownloadAndItsCIHooksStayWhereTheyAre() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        XCTAssertEqual(try Self.updateSeamViolations(in: files, root: SharedSources.sourcesRoot), [])
    }

    func testTheUpdateSeamScanCatchesEachBreak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-update-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = SharedSources.sourcesRoot
        let names = [Self.installerFile, Self.selftestUpdateFile, Self.shellFile, "Platform/PlatformCompat.swift"]
        func scan(_ edit: (inout [String: String]) -> Void) throws -> [String] {
            try? FileManager.default.removeItem(at: root)
            var texts: [String: String] = [:]
            for name in names { texts[name] = try String(contentsOf: real.appendingPathComponent(name), encoding: .utf8) }
            edit(&texts)
            var urls: [URL] = []
            for (name, text) in texts {
                let url = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
            return try Self.updateSeamViolations(in: urls, root: root)
        }
        XCTAssertEqual(try scan { _ in }, [], "the copies of the real files pass")
        XCTAssertEqual(try scan { $0[Self.shellFile]! += "\nfunc f() async { _ = try? await PlatformCompat.oneShotDownload(for: r, maxBytes: 1, deadline: 1) }\n" }.count, 1)
        XCTAssertEqual(try scan { $0[Self.installerFile] = $0[Self.installerFile]!.replacingOccurrences(of: "fetch(request, installer.size, downloadDeadline,",
                                                                                                        with: "fetch(request, 32 << 20, downloadDeadline,") }.count, 1)
        XCTAssertEqual(try scan { $0[Self.shellFile]! += "\nfunc g() { WindowsUpdates.useLoopbackFeed(x) }\n" }.count, 1)
        XCTAssertEqual(try scan { $0[Self.shellFile]! += "\nlet h = UpdateDownloadCheck.refusal(status: 1, finalURL: nil, body: d, for: i, allowHTTP: true)\n" }.count, 1)
        XCTAssertEqual(try scan { $0[Self.shellFile] = $0[Self.shellFile]!.replacingOccurrences(of: "progress: window)", with: "progress: window, launch: { _, _, _ in true })") }.count, 1)
        XCTAssertEqual(try scan { $0["Platform/PlatformCompat.swift"] = $0["Platform/PlatformCompat.swift"]!.replacingOccurrences(of: "maxBytes: Int, deadline: TimeInterval,", with: "maxBytes: Int = 1 << 25, deadline: TimeInterval,") }.count, 1)
    }
}
