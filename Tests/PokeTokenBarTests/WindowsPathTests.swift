import XCTest
@testable import PokeTokenBar

/// Path and line-ending behaviour that differs between the Mac and Windows. Runs on both.
final class WindowsPathTests: XCTestCase {
    func testAugmentedPathUsesThePlatformSeparator() {
        let sep = PlatformCompat.pathListSeparator
        let base = ["/base/one", "/base/two"].joined(separator: String(sep))
        let env = BinaryLocator.augmentedEnvironment(binaryPath: "/tools/bin/codex", base: ["PATH": base])
        let entries = env["PATH"]!.split(separator: sep).map(String.init)
        XCTAssertTrue(entries.contains("/base/one"))
        XCTAssertTrue(entries.contains("/base/two"))
        XCTAssertEqual(entries.count, Set(entries).count)
        #if !os(Windows)
        XCTAssertEqual(sep, ":")
        #endif
    }

    func testHomeRelativeRootsResolveUnderTheUserProfile() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let projects = LocalUsageReader.claudeProjectsDir.standardizedFileURL.path
        XCTAssertTrue(projects.hasPrefix(home), "\(projects) is not under \(home)")
        XCTAssertTrue(projects.hasSuffix("projects"))
        let roots = LocalUsageReader.computeClaudeProjectRoots(
            configDirValue: nil, customRootsValue: nil, accountRoots: [],
            home: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(roots.contains { $0.standardizedFileURL.path == projects })
    }

    private func claudeLine(_ id: String) -> String {
        #"{"type":"assistant","requestId":"R\#(id)","timestamp":"2026-06-30T10:00:00.000Z","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":1000}}}"#
    }

    private func codexLine(_ ts: String, total: Int, last: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":\#(total + 10)},"last_token_usage":{"input_tokens":\#(last),"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":\#(last + 10)}}}}"#
    }

    private func fields(_ e: LocalUsageReader.Entry) -> [String] {
        [e.model, e.localDay, "\(e.input)", "\(e.output)", "\(e.cacheWrite)", "\(e.cacheRead)", "\(e.date.timeIntervalSince1970)"]
    }

    func testJSONLWithCRLFParsesTheSameAsLF() throws {
        let fmt = LocalUsageReader.localDayFormatter()
        let claude = [claudeLine("A"), claudeLine("B")]
        func parseClaude(_ eol: String) -> [[String]] {
            let data = Data((claude.joined(separator: eol) + eol).utf8)
            let r = LocalUsageReader.parseClaudeData(data, fmt: fmt)
            return r.entries.sorted { $0.id < $1.id }.map(fields)
        }
        let lf = parseClaude("\n")
        XCTAssertEqual(lf.count, 2)
        XCTAssertEqual(parseClaude("\r\n"), lf)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-crlf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = [codexLine("2026-06-30T11:00:00.000Z", total: 100, last: 100),
                     codexLine("2026-06-30T11:00:01.000Z", total: 300, last: 200)]
        func parseCodex(_ eol: String) throws -> [[String]] {
            let file = dir.appendingPathComponent("rollout-\(eol.count).jsonl")
            try Data((codex.joined(separator: eol) + eol).utf8).write(to: file)
            return LocalUsageReader.parseCodexRollout(file, fmt: fmt).events.map { fields($0.entry) }
        }
        let codexLF = try parseCodex("\n")
        XCTAssertEqual(codexLF.count, 2)
        XCTAssertEqual(try parseCodex("\r\n"), codexLF)
    }

    // MARK: Tool directories and log roots (Task 4)

    /// Trigger: the real Windows process environment names the key `Path`, not `PATH` (stage 1 injected `PATH`).
    func testAugmentedEnvironmentKeepsOnePathKey() {
        let sep = PlatformCompat.pathListSeparator
        #if os(Windows)
        let env = BinaryLocator.augmentedEnvironment(binaryPath: "C:\\tools\\codex.cmd", base: ["Path": "C:\\a;C:\\b"])
        let keys = env.keys.filter { $0.caseInsensitiveCompare("PATH") == .orderedSame }
        XCTAssertEqual(keys, ["Path"])
        let entries = env["Path"]!.split(separator: sep).map(String.init)
        XCTAssertTrue(entries.contains("C:\\a"))
        XCTAssertTrue(entries.contains("C:\\b"))
        if let appData = ProcessInfo.processInfo.environment["APPDATA"] {
            XCTAssertTrue(entries.contains(appData + "\\npm"), "tool dirs missing from \(entries)")
        }
        #else
        let env = BinaryLocator.augmentedEnvironment(binaryPath: "/x/bin/codex", base: ["PATH": "/a:/b"])
        let expected = (["/x/bin"] + BinaryLocator.commonToolDirectories() + ["/a", "/b"])
        var seen = Set<String>()
        XCTAssertEqual(env["PATH"], expected.filter { seen.insert($0).inserted }.joined(separator: ":"))
        XCTAssertEqual(env.count, 1)
        #endif
    }

    func testPathVariableKeyMatchesTheCaseOfTheExistingKey() {
        #if os(Windows)
        XCTAssertEqual(PlatformCompat.pathVariableKey(in: ["Path": "x"]), "Path")
        XCTAssertEqual(PlatformCompat.pathVariableKey(in: ["PATH": "x"]), "PATH")
        XCTAssertEqual(PlatformCompat.pathVariableKey(in: [:]), "Path")
        #else
        XCTAssertEqual(PlatformCompat.pathVariableKey(in: ["Path": "x"]), "PATH")
        XCTAssertEqual(PlatformCompat.pathVariableKey(in: [:]), "PATH")
        #endif
    }

    func testCommonNodeToolPathsOnTheMacAreUnchanged() {
        #if !os(Windows)
        let home = NSHomeDirectory()
        XCTAssertEqual(BinaryLocator.commonNodeToolPaths("codex"), [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.local/share/mise/shims/codex", "\(home)/.asdf/shims/codex", "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex", "\(home)/.npm-global/bin/codex", "\(home)/.local/bin/codex", "/usr/bin/codex",
        ])
        #endif
    }

    func testCursorRootsOnTheMacAreUnchanged() throws {
        #if !os(Windows)
        if ProcessInfo.processInfo.environment["CURSOR_DATA_DIR"] != nil { throw XCTSkip("CURSOR_DATA_DIR is set") }
        let home = URL(fileURLWithPath: "/h")
        let expected = ["/h/Library/Application Support/Cursor/User/globalStorage",
                        "/h/Library/Application Support/Cursor Nightly/User/globalStorage"]
        XCTAssertEqual(LocalAdditionalUsageReader.cursorRoots(home: home).map(\.path), expected)
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(LocalAdditionalUsageReader.defaultCursorRoots.map(\.path), expected.map { $0.replacingOccurrences(of: "/h/", with: real + "/") })
        #endif
    }

    func testCursorRootsAreUnderRoamingAppData() throws {
        #if os(Windows)
        if ProcessInfo.processInfo.environment["CURSOR_DATA_DIR"] != nil { throw XCTSkip("CURSOR_DATA_DIR is set") }
        let home = URL(fileURLWithPath: "C:/Users/x")
        let paths = LocalAdditionalUsageReader.cursorRoots(home: home).map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("AppData/Roaming/Cursor/User/globalStorage") || $0.hasSuffix("AppData\\Roaming\\Cursor\\User\\globalStorage") }, "\(paths)")
        XCTAssertTrue(paths.contains { $0.contains("Cursor Nightly") })
        #endif
    }

    /// The desktop root is found only if the folder sits where the OS keeps application data.
    func testClaudeDesktopRootMatchesThePlatformApplicationFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #if os(Windows)
        let app = home.appendingPathComponent("AppData/Roaming/Claude")
        #else
        let app = home.appendingPathComponent("Library/Application Support/Claude")
        #endif
        let projects = app.appendingPathComponent("local-agent-mode-sessions/s1/.claude/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let roots = LocalUsageReader.computeClaudeProjectRoots(configDirValue: nil, customRootsValue: nil, accountRoots: [], home: home)
        let found = roots.contains { $0.standardizedFileURL.path == projects.standardizedFileURL.path }
        #if os(Windows)
        XCTAssertFalse(found, "Windows has no verified Claude Desktop session layout, so no root is read")
        #else
        XCTAssertTrue(found, "\(roots.map(\.path))")
        #endif
    }

    func testClaudeDesktopRootOnTheMacIsUnchanged() {
        #if !os(Windows)
        XCTAssertEqual(PlatformCompat.userApplicationSupport(home: URL(fileURLWithPath: "/h")).path, "/h/Library/Application Support")
        #endif
    }

    func testExecutableCandidatesPreferExe() {
        #if os(Windows)
        XCTAssertEqual(PlatformCompat.executableCandidates("C:\\t\\codex", pathExt: nil),
                       ["C:\\t\\codex.exe", "C:\\t\\codex.cmd", "C:\\t\\codex.bat", "C:\\t\\codex.com"])
        XCTAssertEqual(PlatformCompat.executableCandidates("c", pathExt: ".COM;.EXE;.BAT;.CMD;.VBS"),
                       ["c.exe", "c.com", "c.bat", "c.cmd"])
        #else
        XCTAssertEqual(PlatformCompat.executableCandidates("/t/codex", pathExt: nil), ["/t/codex"])
        XCTAssertNil(PlatformCompat.searchProcessPath("codex", environment: ["PATH": "/usr/bin"]))
        #endif
    }

    func testSearchProcessPathFindsACmdShim() throws {
        #if os(Windows)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "@echo off\r\n".write(to: dir.appendingPathComponent("codex.cmd"), atomically: true, encoding: .utf8)
        let dirPath = dir.path.replacingOccurrences(of: "/", with: "\\")
        let found = PlatformCompat.searchProcessPath("codex", environment: ["Path": "C:\\nowhere;" + dirPath])
        XCTAssertEqual(found.map { $0.lowercased() }, (dirPath + "\\codex.cmd").lowercased())
        XCTAssertNil(PlatformCompat.searchProcessPath("nothere", environment: ["Path": dirPath]))
        #endif
    }

    func testWindowsToolDirectoriesComeFromTheEnvironment() {
        #if os(Windows)
        let dirs = PlatformCompat.toolDirectories(posix: ["/never"], environment: [
            "APPDATA": "C:\\R", "LOCALAPPDATA": "C:\\L", "USERPROFILE": "C:\\U", "NVM_SYMLINK": "C:\\nodejs", "PNPM_HOME": "C:\\P"])
        XCTAssertEqual(dirs, ["C:\\R\\npm", "C:\\P", "C:\\L\\Microsoft\\WinGet\\Links", "C:\\U\\scoop\\shims",
                              "C:\\U\\.bun\\bin", "C:\\L\\Volta\\bin", "C:\\L\\mise\\shims", "C:\\nodejs", "C:\\U\\.local\\bin"])
        XCTAssertEqual(PlatformCompat.toolDirectories(posix: [], environment: [:]), [])
        #else
        XCTAssertEqual(PlatformCompat.toolDirectories(posix: ["/a", "/b"], environment: ["APPDATA": "x"]), ["/a", "/b"])
        #endif
    }

    /// Mac pin: `terminate` is `process.terminate()` (a plain POSIX fixture, no tool is launched).
    func testTerminateOnTheMacEndsTheProcess() throws {
        #if !os(Windows)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        PlatformCompat.terminate(p)
        p.waitUntilExit()
        XCTAssertFalse(p.isRunning)
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        #endif
    }

    /// Trigger: Windows `FileManager.isExecutableFile` is true for a missing `.cmd`/`.exe`, so a static path list
    /// (now carrying extension candidates) used to "resolve" to a file that does not exist.
    func testAMissingExecutableIsNeverFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nothere.cmd").path
        XCTAssertFalse(PlatformCompat.isExecutableFile(atPath: missing))
        #if os(Windows)
        XCTAssertFalse(PlatformCompat.isExecutableFile(atPath: dir.path), "a folder is not an executable")
        #endif
        #if os(Windows)
        let name = "ptb-no-such-tool-\(UUID().uuidString)"
        XCTAssertNil(BinaryLocator.resolve(name, staticPaths: [missing, dir.appendingPathComponent(name + ".exe").path]))
        #endif
        let present = dir.appendingPathComponent("tool.cmd")
        try "@echo off\r\n".write(to: present, atomically: true, encoding: .utf8)
        #if os(Windows)
        XCTAssertTrue(PlatformCompat.isExecutableFile(atPath: present.path))
        #endif
    }
}
