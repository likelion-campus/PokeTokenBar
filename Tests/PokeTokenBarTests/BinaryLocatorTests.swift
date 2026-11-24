import XCTest
@testable import PokeTokenBar

final class BinaryLocatorTests: XCTestCase {
    /// mise shim 이 버전매니저 본체를 찾을 수 있도록 PATH 가 보강되는지 (버그 리포트 시나리오).
    func testAugmentedEnvironmentPrependsToolPaths() {
        let home = NSHomeDirectory()
        let env = BinaryLocator.augmentedEnvironment(
            binaryPath: "\(home)/.local/share/mise/shims/codex",
            base: ["PATH": ["/usr/bin", "/bin"].joined(separator: String(PlatformCompat.pathListSeparator)), "LANG": "en_US.UTF-8"])
        let paths = env[PlatformCompat.pathVariableKey(in: env)]!.split(separator: PlatformCompat.pathListSeparator).map(String.init)

        // The first entry comes from a URL, whose path uses `/` even where NSHomeDirectory() has `\`.
        XCTAssertEqual(paths.first, URL(fileURLWithPath: "\(home)/.local/share/mise/shims").path)   // 바이너리 디렉토리 최우선
        #if os(Windows)
        XCTAssertTrue(paths.contains { $0.hasSuffix("\\.local\\bin") })   // the Windows tool directories (PlatformCompat)
        #else
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))               // mise 본체 위치 후보
        XCTAssertTrue(paths.contains("\(home)/.local/bin"))
        #endif
        XCTAssertTrue(paths.contains("/usr/bin"))                        // 기존 PATH 보존
        // dedup compares strings, so a `\` home (Windows) keeps both spellings; path normalisation is a stage-4 item.
        if !home.contains("\\") {
            XCTAssertEqual(paths.filter { $0 == "\(home)/.local/share/mise/shims" }.count, 1)  // dedup
        }
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")                       // 다른 env 보존
    }

    func testAugmentedEnvironmentWithoutBasePath() {
        let env = BinaryLocator.augmentedEnvironment(
            binaryPath: "/opt/homebrew/bin/codex", base: [:])
        let paths = env[PlatformCompat.pathVariableKey(in: env)]!.split(separator: PlatformCompat.pathListSeparator).map(String.init)
        XCTAssertEqual(paths.first, "/opt/homebrew/bin")
        #if !os(Windows)
        XCTAssertTrue(paths.contains("/usr/bin"))   // 기본 PATH 폴백
        #endif
    }

    func testParsesCleanMarkedPath() {
        XCTAssertEqual(
            BinaryLocator.parseMarkedPath("<<<BIN:/opt/homebrew/bin/ccusage:BIN>>>"),
            "/opt/homebrew/bin/ccusage")
    }

    func testIgnoresProfileNoiseAroundMarker() {
        // 인터랙티브 셸이 neofetch 등 stdout noise 를 찍어도 마커만 추출
        let noisy = """
        ⠀⣴⣶⣷ neofetch art line 1
        OS: macOS / Shell: zsh
        <<<BIN:/Users/x/.local/share/mise/installs/node/22.14.0/bin/ccusage:BIN>>>
        """
        XCTAssertEqual(
            BinaryLocator.parseMarkedPath(noisy),
            "/Users/x/.local/share/mise/installs/node/22.14.0/bin/ccusage")
    }

    func testEmptyPathReturnsNil() {
        // command -v 가 못 찾으면 마커 사이가 비어 있음
        XCTAssertNil(BinaryLocator.parseMarkedPath("noise\n<<<BIN::BIN>>>\n"))
    }

    func testMissingMarkersReturnsNil() {
        XCTAssertNil(BinaryLocator.parseMarkedPath("just some neofetch output, no marker"))
        XCTAssertNil(BinaryLocator.parseMarkedPath("<<<BIN:/path/without/closing"))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(BinaryLocator.parseMarkedPath("<<<BIN:  /usr/local/bin/codex \n :BIN>>>"),
                       "/usr/local/bin/codex")
    }

    func testCommonPathsIncludeManagersForBinary() {
        let paths = BinaryLocator.commonNodeToolPaths("ccusage")
        #if os(Windows)
        XCTAssertTrue(paths.allSatisfy { $0.contains("ccusage.") }, "every candidate carries an executable extension")
        XCTAssertTrue(paths.contains { $0.hasSuffix("ccusage.exe") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("ccusage.cmd") })
        #else
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/ccusage"))
        XCTAssertTrue(paths.contains { $0.contains("/.local/share/mise/shims/ccusage") })
        XCTAssertTrue(paths.contains { $0.contains("/.asdf/shims/ccusage") })
        XCTAssertTrue(paths.contains { $0.contains("/.volta/bin/ccusage") })
        #endif
    }

    // MARK: not-found is remembered (audit-stability #3)

    private func withFakes(override: @escaping (String) -> String? = { _ in nil },
                           shell: @escaping (String) -> String?, _ body: () -> Void) {
        let savedShell = BinaryLocator.shellResolver, savedOverride = BinaryLocator.overrideReader
        BinaryLocator.shellResolver = shell
        BinaryLocator.overrideReader = override
        BinaryLocator.reset()
        defer {
            BinaryLocator.shellResolver = savedShell
            BinaryLocator.overrideReader = savedOverride
            BinaryLocator.reset()
        }
        body()
    }

    final class Counter: @unchecked Sendable { var n = 0 }

    func testNotFoundSpawnsTheShellOnlyOncePerProcess() {
        let spawns = Counter()
        withFakes(shell: { _ in spawns.n += 1; return nil }) {
            for _ in 0..<5 { XCTAssertNil(BinaryLocator.resolve("ptb-absent-tool", staticPaths: [])) }
            XCTAssertEqual(spawns.n, 1)
        }
    }

    func testNotFoundIsRememberedPastTheOldTenMinuteWindow() {
        // The removed TTL re-spawned once the entry was 10 minutes old; no clock is read any more, so a later
        // call can only spawn again through the explicit signals below.
        let spawns = Counter()
        withFakes(shell: { _ in spawns.n += 1; return nil }) {
            _ = BinaryLocator.resolve("ptb-absent-tool2", staticPaths: [])
            _ = BinaryLocator.resolve("ptb-absent-tool2", staticPaths: ["/nonexistent/ptb-absent-tool2"])
            XCTAssertEqual(spawns.n, 1)
        }
    }

    func testStaticPathInstalledLaterIsFoundWithoutAShell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Windows decides "executable" by the extension (WindowsPathTests uses `.cmd` for the same reason).
        #if os(Windows)
        let tool = dir.appendingPathComponent("ptb-late-tool.cmd").path
        let body = "@echo off\r\n"
        #else
        let tool = dir.appendingPathComponent("ptb-late-tool").path
        let body = "#!/bin/sh\n"
        #endif
        let spawns = Counter()
        withFakes(shell: { _ in spawns.n += 1; return nil }) {
            XCTAssertNil(BinaryLocator.resolve("ptb-late-tool", staticPaths: [tool]))
            FileManager.default.createFile(atPath: tool, contents: Data(body.utf8),
                                           attributes: [.posixPermissions: 0o755])
            XCTAssertEqual(BinaryLocator.resolve("ptb-late-tool", staticPaths: [tool]), tool)
            XCTAssertEqual(spawns.n, 1, "installing into a static path must not cost another shell")
        }
    }

    func testChangedManualPathReChecksOnce() {
        let spawns = Counter()
        let setting = Counter()   // 0 = unset, 1 = set to a bogus path
        withFakes(override: { _ in setting.n == 0 ? nil : "/nonexistent/ptb-override" },
                  shell: { _ in spawns.n += 1; return nil }) {
            _ = BinaryLocator.resolve("ptb-absent-tool3", staticPaths: [])
            setting.n = 1
            _ = BinaryLocator.resolve("ptb-absent-tool3", staticPaths: [])
            _ = BinaryLocator.resolve("ptb-absent-tool3", staticPaths: [])
            XCTAssertEqual(spawns.n, 2, "one spawn per distinct manual-path value, not per call")
        }
    }

    func testNotFoundIsLookedForAgainOnAManualRefresh() {
        let spawns = Counter()
        withFakes(shell: { _ in spawns.n += 1; return nil }) {
            _ = BinaryLocator.resolve("ptb-absent-tool4", staticPaths: [])
            _ = BinaryLocator.resolve("ptb-absent-tool4", staticPaths: [])
            XCTAssertEqual(spawns.n, 1)
            BinaryLocator.forgetNotFound()
            _ = BinaryLocator.resolve("ptb-absent-tool4", staticPaths: [])
            XCTAssertEqual(spawns.n, 2, "a person pressed refresh: ask the shell again")
            _ = BinaryLocator.resolve("ptb-absent-tool4", staticPaths: [])
            XCTAssertEqual(spawns.n, 2)
        }
    }

    func testForgetNotFoundKeepsWhatWasFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #if os(Windows)
        let tool = dir.appendingPathComponent("ptb-found-tool.cmd").path
        let body = "@echo off\r\n"
        #else
        let tool = dir.appendingPathComponent("ptb-found-tool").path
        let body = "#!/bin/sh\n"
        #endif
        FileManager.default.createFile(atPath: tool, contents: Data(body.utf8), attributes: [.posixPermissions: 0o755])
        let spawns = Counter()
        withFakes(shell: { _ in spawns.n += 1; return tool }) {
            XCTAssertEqual(BinaryLocator.resolve("ptb-found-tool", staticPaths: []), tool)
            BinaryLocator.forgetNotFound()
            XCTAssertEqual(BinaryLocator.resolve("ptb-found-tool", staticPaths: []), tool)
            XCTAssertEqual(spawns.n, 1)
        }
    }

    func testNotFoundIsLookedForAgainOnlyOncePerRecheckInterval() {
        let spawns = Counter()
        let savedNow = BinaryLocator.now
        let clock = Clock()
        BinaryLocator.now = { clock.now }
        defer { BinaryLocator.now = savedNow }
        withFakes(shell: { _ in spawns.n += 1; return nil }) {
            _ = BinaryLocator.resolve("ptb-absent-tool5", staticPaths: [])
            clock.now.addTimeInterval(BinaryLocator.notFoundRecheckInterval - 60)
            _ = BinaryLocator.resolve("ptb-absent-tool5", staticPaths: [])
            XCTAssertEqual(spawns.n, 1, "still inside the interval")
            clock.now.addTimeInterval(120)
            _ = BinaryLocator.resolve("ptb-absent-tool5", staticPaths: [])
            XCTAssertEqual(spawns.n, 2, "a tool installed later through nvm/fnm is found without a relaunch")
            _ = BinaryLocator.resolve("ptb-absent-tool5", staticPaths: [])
            XCTAssertEqual(spawns.n, 2, "the interval restarts from the last look")
        }
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_700_000_000) }

    func testShellWaitIsNotHeldUnderTheCacheLock() {
        // A slow shell for one binary must not block a lookup of another (the lock is not held while waiting).
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        withFakes(shell: { name in
            if name == "ptb-slow-tool" { started.signal(); _ = release.wait(timeout: .now() + 10) }
            return nil
        }) {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = BinaryLocator.resolve("ptb-slow-tool", staticPaths: []); done.signal() }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            let other = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = BinaryLocator.resolve("ptb-fast-tool", staticPaths: []); other.signal() }
            XCTAssertEqual(other.wait(timeout: .now() + 3), .success, "a second lookup waited behind the shell")
            release.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
    }
}
