import CryptoKit
import XCTest

/// Runs `scripts/team-release.sh` against fakes: every outside command it can reach (gh, git, security, codesign,
/// ditto, lipo, python3 and the repository scripts it calls) is a logging fake on a PATH that holds nothing else
/// but a few plain text tools. Nothing here reaches GitHub, the keychain, /Applications or a build.
/// The copy differs from the real script in one line: the pinned leaf is that of a throwaway certificate.
final class TeamReleaseScriptRunTests: XCTestCase {

    static let head = "abcdef0123456789abcdef0123456789abcdef01"
    static let releaseVersion = "2.5.640"
    static let installerSHA = String(repeating: "0", count: 63) + "7"

    /// Every call's command and arguments, in order.
    struct Run {
        let status: Int32
        let out: String
        let err: String
        let calls: [String]
        var text: String { out + err }
        /// One short name per call ("gh release view", "team_release.py publish", "build-app.sh", …).
        var verbs: [String] { calls.map(Run.verb) }

        static func verb(_ call: String) -> String {
            let t = call.split(separator: " ").map(String.init)
            switch t.first ?? "" {
            case "gh": return t[1] == "api" ? (t.contains("-X") ? "gh api PUT" : "gh api GET") : "gh \(t[1]) \(t[2])"
            case "git": return "git \(t[1])"
            case "python3":
                if t[1] == "-m" { return "python3 unittest" }
                let tool = (t[1] as NSString).lastPathComponent
                return t.count > 2 ? "\(tool) \(t[2])" : tool
            default: return t.first ?? ""
            }
        }
    }

    // MARK: - the sandbox

    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }
    private var state: URL { root.appendingPathComponent("state") }
    private var notes: URL { root.appendingPathComponent("notes.md") }
    /// A throwaway certificate, made once: the fake codesign hands it out as the built app's leaf.
    private static let cert: (der: URL, leaf: String)? = try? makeCertificate()

    private static func makeCertificate() throws -> (der: URL, leaf: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-release-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let der = dir.appendingPathComponent("leaf.der")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appendingPathComponent("k.pem").path,
                       "-out", der.path, "-outform", "der", "-subj", "/CN=ptb-test", "-days", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let leaf = Insecure.SHA1.hash(data: try Data(contentsOf: der)).map { String(format: "%02X", $0) }.joined()
        return (der, leaf)
    }

    private static func throwawayCertificate() throws -> (der: URL, leaf: String) {
        try XCTUnwrap(cert, "/usr/bin/openssl could not make a throwaway certificate")
    }

    private static let realTools = ["/bin/bash", "/usr/bin/dirname", "/usr/bin/grep", "/usr/bin/mktemp", "/bin/rm", "/usr/bin/awk",
                                    "/usr/bin/sed", "/usr/bin/tr", "/usr/bin/perl", "/usr/bin/base64", "/usr/bin/shasum",
                                    "/usr/bin/cut", "/bin/cat", "/bin/mkdir", "/bin/sleep", "/bin/ps", "/bin/cp"]
    private static let fakedTools = ["gh", "git", "security", "codesign", "ditto", "lipo", "python3"]

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("ptb-team-release-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin"), scripts = repo.appendingPathComponent("scripts")
        for dir in [bin, scripts, state] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let cert = try Self.throwawayCertificate()
        let real = try String(contentsOf: Self.realScript, encoding: .utf8)
        let copy = real.replacingOccurrences(of: #"(?m)^TEAM_EXPECTED_LEAF=".*"$"#, with: "TEAM_EXPECTED_LEAF=\"\(cert.leaf)\"",
                                             options: .regularExpression)
        let changed = zip(real.components(separatedBy: "\n"), copy.components(separatedBy: "\n")).filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1, "the copy differs from the script in the leaf line only")
        try write(copy, to: scripts.appendingPathComponent("team-release.sh"))

        try write(Self.fake, to: bin.appendingPathComponent("fake"))
        for tool in Self.fakedTools {
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent(tool).path, withDestinationPath: "fake")
        }
        for tool in Self.realTools {
            XCTAssertTrue(fm.isExecutableFile(atPath: tool), tool)
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent((tool as NSString).lastPathComponent).path,
                                      withDestinationPath: tool)
        }
        for name in ["test-gate.sh", "cfprefsd-guard.sh", "build-app.sh"] {
            let version = name == "build-app.sh" ? "VERSION=\"\(Self.releaseVersion)\"\n" : ""
            try write("#!/bin/bash\n\(version)FAKE_NAME=\(name) exec \"$FAKE_BIN/fake\" \"$@\"\n",
                      to: scripts.appendingPathComponent(name))
        }
        try "## New\n".write(to: notes, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private static let realScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/team-release.sh")

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs the script in its own process group (a fake's Ctrl-C reaches the script and its children, not the tests),
    /// with only the sandbox PATH and the scenario's FAKE_* variables. `state` (the release on GitHub, the cask)
    /// carries over from one run to the next, as it would between a failed release and its re-run.
    @discardableResult
    private func release(_ arguments: [String]? = nil, _ scenario: [String: String] = [:],
                         file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        let log = state.appendingPathComponent("calls.log")
        try Data().write(to: log)
        let outURL = root.appendingPathComponent("stdout"), errURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", #"setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec: $!""#,
                       repo.appendingPathComponent("scripts/team-release.sh").path] + (arguments ?? [notes.path])
        var env = ["HOME": root.path, "PATH": root.appendingPathComponent("bin").path,
                   "FAKE_BIN": root.appendingPathComponent("bin").path, "FAKE_STATE": state.path,
                   "FAKE_CERT": try Self.throwawayCertificate().der.path, "FAKE_LEAF": try Self.throwawayCertificate().leaf,
                   "FAKE_HEAD": Self.head]
        env.merge(scenario) { $1 }
        p.environment = env
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            XCTFail("team-release.sh did not finish within 60 s", file: file, line: line)
        }
        p.waitUntilExit()
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        return Run(status: p.terminationStatus, out: try String(contentsOf: outURL, encoding: .utf8),
                   err: try String(contentsOf: errURL, encoding: .utf8), calls: calls)
    }

    private func setRelease(_ value: String) throws {
        try (value + "\n").write(to: state.appendingPathComponent("release"), atomically: true, encoding: .utf8)
    }

    // MARK: - expected call sequences

    static let checks = ["gh auth status", "git rev-parse", "git status", "git remote", "git fetch", "git rev-parse",
                         "git rev-parse", "git show-ref", "gh release view", "security",
                         "python3 unittest", "team_notes.py check", "team_docs_check.py"]
    static let macHalf = ["test-gate.sh", "cfprefsd-guard.sh", "build-app.sh", "codesign", "ditto", "lipo"]
    static let windowsHalf = ["team_release.py collect", "team_notes.py fill"]
    static let fullRelease = checks + ["team_release.py start"] + macHalf + windowsHalf
        + ["team_release.py publish", "gh api GET", "gh api GET", "gh api PUT", "team_release.py smoke"]
    static let rehearsal = checks + ["team_release.py start"] + windowsHalf

    private func assertNothingPublic(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
        for verb in ["team_release.py publish", "gh api PUT", "gh api GET", "team_release.py smoke"] {
            XCTAssertFalse(run.verbs.contains(verb), "\(verb) must not run: \(run.verbs)", file: file, line: line)
        }
    }

    private func assertStopped(_ run: Run, before verb: String, says: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.status, 1, run.text, file: file, line: line)
        XCTAssertFalse(run.verbs.contains(verb), "stops before \(verb): \(run.verbs)", file: file, line: line)
        for phrase in says {
            XCTAssertTrue(run.err.contains(phrase), "message lacks '\(phrase)':\n\(run.err)", file: file, line: line)
        }
    }

    // MARK: - the happy path and the rehearsal

    func testAReleaseRunsTheStepsOfD3InOrderAndPublishesOnce() throws {
        let run = try release()
        XCTAssertEqual(run.status, 0, run.text)
        XCTAssertEqual(run.verbs, Self.fullRelease)

        let publish = try XCTUnwrap(run.calls.first { Run.verb($0) == "team_release.py publish" })
        let installer = repo.appendingPathComponent("build/windows-release/windows-release/PokeTokenBar-Setup-\(Self.releaseVersion)-win-x64.exe")
        XCTAssertEqual(publish, "python3 scripts/team_release.py publish --sha \(Self.head) --version \(Self.releaseVersion) "
                       + "--zip build/PokeTokenBar.zip --installer \(installer.path) --notes build/release-notes.md")
        XCTAssertTrue(run.calls.contains("python3 scripts/team_release.py start --sha \(Self.head) --version \(Self.releaseVersion) --ref main"))
        XCTAssertTrue(run.calls.contains { $0.hasPrefix("python3 scripts/team_notes.py fill") && $0.contains("--sha256 \(Self.installerSHA)") })

        // The cask moves to this version and this zip.
        let zip = try Data(contentsOf: repo.appendingPathComponent("build/PokeTokenBar.zip"))
        let zipSHA = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let put = try String(contentsOf: state.appendingPathComponent("put-content"), encoding: .utf8)
        let cask = String(decoding: try XCTUnwrap(Data(base64Encoded: put.trimmingCharacters(in: .whitespacesAndNewlines))), as: UTF8.self)
        XCTAssertTrue(cask.contains("  version \"\(Self.releaseVersion)\"\n"), cask)
        XCTAssertTrue(cask.contains("  sha256 \"\(zipSHA)\"\n"), cask)

        // Banners carry D3's step numbers, in order, with the elapsed time.
        var at = run.out.startIndex
        for label in ["[0/10]", "[1/10]", "[2/10]", "[3/10]", "[4/10]", "[5/10]", "[6/10]", "[7-8/10]", "[9/10]", "[10/10]"] {
            let range = try XCTUnwrap(run.out.range(of: "▶ \(label)", range: at..<run.out.endIndex), "banner \(label) in order")
            at = range.upperBound
        }
        XCTAssertEqual(run.out.components(separatedBy: "(경과 ").count - 1, 9, "steps 1–10 print the elapsed time")
        XCTAssertTrue(run.out.contains("완료: v\(Self.releaseVersion)"))
    }

    /// The rehearsal runs only reads, the Windows start and the local notes fill: a write added to its path (a gh call,
    /// the tap, the build, publish, smoke) changes this exact sequence.
    func testTheRehearsalBuildsNothingAndNeverPublishes() throws {
        let run = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "feat/release-flow"])
        XCTAssertEqual(run.status, 0, run.text)
        XCTAssertEqual(run.verbs, Self.rehearsal)
        assertNothingPublic(run)
        for call in run.calls where call.hasPrefix("gh ") {
            XCTAssertTrue(call.hasPrefix("gh auth status") || call.hasPrefix("gh release view"), "a gh read only: \(call)")
        }
        for call in run.calls where call.hasPrefix("git ") {
            XCTAssertTrue(["rev-parse", "status", "remote", "fetch", "show-ref"].contains(Run.verb(call).dropFirst(4)), call)
        }
        XCTAssertTrue(run.calls.contains("python3 scripts/team_release.py start --sha \(Self.head) --version \(Self.releaseVersion) --ref feat/release-flow"))
        XCTAssertTrue(run.calls.contains("git rev-parse --verify --quiet origin/feat/release-flow"))
        for label in ["[3/10] 맥 테스트 게이트: SKIPPED", "[4/10] 맥 빌드", "[7-8/10] GitHub 릴리스", "[9/10] Homebrew 탭: SKIPPED", "[10/10] smoke: SKIPPED"] {
            XCTAssertTrue(run.out.contains(label), label)
        }
        XCTAssertEqual(run.out.components(separatedBy: "SKIPPED (리허설)").count - 1, 5)
        XCTAssertTrue(run.out.contains("    python3 scripts/team_release.py publish --sha \(Self.head) --version \(Self.releaseVersion) --zip build/PokeTokenBar.zip"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("put-content").path))
    }

    /// Task 11 rehearses the merge candidate before any bump: the version is already released, and the docs gate may
    /// still stop. The rehearsal goes on through the Windows half and reports what a release would stop on.
    func testTheRehearsalReportsWhatAReleaseWouldStopOn() throws {
        try setRelease("public")
        let released = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "merge/windows-port-into-main"])
        XCTAssertEqual(released.status, 0, released.text)
        XCTAssertEqual(released.verbs, Self.rehearsal)
        XCTAssertTrue(released.out.contains("리허설: 태그 v\(Self.releaseVersion) 이 이미 있습니다"))

        let docs = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "feat/x", "FAKE_RC_DOCS": "2"])
        XCTAssertEqual(docs.status, 1, docs.text)
        XCTAssertEqual(docs.verbs, Self.rehearsal, "the Windows half still runs")
        XCTAssertTrue(docs.err.contains("실제 릴리스는 멈췄을 것입니다: [1/10] 문서 게이트가 멈췄습니다"), docs.err)
        assertNothingPublic(docs)
    }

    func testTheRehearsalNeedsThePushedCommitOfABranch() throws {
        let moved = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "feat/x", "FAKE_REMOTE_HEAD": String(repeating: "9", count: 40)])
        assertStopped(moved, before: "team_release.py start", says: ["origin/feat/x 와 다릅니다", "남은 것: 리허설이라"])
        let detached = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "HEAD"])
        assertStopped(detached, before: "git status", says: ["리허설은 브랜치에서"])
        let extra = try release(["--rehearse", notes.path, "more"])
        assertStopped(extra, before: "gh auth status", says: ["인자가 너무 많습니다"])
    }

    func testAReleaseRunsFromMainOnly() throws {
        let run = try release(nil, ["FAKE_BRANCH": "feat/x"])
        assertStopped(run, before: "git status", says: ["main 브랜치에서 실행하세요"])
    }

    // MARK: - failures before anything is public

    func testEveryPreCheckStopsBeforeTheWindowsRunsStart() throws {
        for (key, code, phrase) in [("SELFTEST", "1", "자체 시험이 실패했습니다"), ("NOTES_CHECK", "1", "팀 양식에 맞지 않습니다"),
                                    ("NOTES_CHECK", "9", "예상하지 못한 코드 9"), ("DOCS", "2", "문서 게이트가 멈췄습니다"),
                                    ("DOCS", "1", "문서 게이트를 실행하지 못했습니다"), ("DOCS", "9", "코드 9")] {
            let run = try release(nil, ["FAKE_RC_" + key: code])
            assertStopped(run, before: "team_release.py start", says: [phrase, "남은 것: 없음"])
        }
        // A failing `security` is a message, not a silent `set -e` exit.
        let security = try release(nil, ["FAKE_LEAF": ""])
        assertStopped(security, before: "python3 unittest", says: ["서명 신원 'PokeTokenBar Local' 이 없습니다"])
    }

    func testAStartFailureStopsBeforeTheMacGate() throws {
        for (code, phrase) in [("3", "--new failed"), ("1", "다시 실행하면 이미 시작된 실행을 재사용"), ("2", "인자를 거부"),
                               ("9", "예상하지 못한 코드 9")] {
            let run = try release(nil, ["FAKE_RC_START": code])
            assertStopped(run, before: "test-gate.sh", says: [phrase, "남은 것: Windows 실행이 시작됐을 수 있습니다"])
        }
        let silent = try release(nil, ["FAKE_START_OUT": ""])
        assertStopped(silent, before: "test-gate.sh", says: ["실행 번호를 알려 주지 않았습니다"])
    }

    /// D5: the Mac gate fails, the Windows runs finish by themselves, and the next attempt reuses them.
    func testAMacFailureLeavesOnlyTheWindowsRunsAndTheReRunReusesThem() throws {
        let gate = try release(nil, ["FAKE_RC_GATE": "1"])
        assertStopped(gate, before: "build-app.sh", says: ["테스트 게이트가 실패했습니다", "actions/runs/4101", "재사용합니다",
                                                            "/Applications 는 그대로"])
        assertNothingPublic(gate)
        let again = try release()
        XCTAssertEqual(again.status, 0, again.text)
        XCTAssertEqual(again.verbs, Self.fullRelease, "the re-run asks start again; start reuses this commit's runs")

        for (key, before, phrase) in [("CFPREFSD", "build-app.sh", "cfprefsd 를 회복하지 못했습니다"),
                                      ("BUILD", "codesign", "빌드가 실패했습니다"),
                                      ("DITTO", "lipo", "zip 을 만들지 못했습니다"),
                                      ("LIPO", "team_release.py collect", "universal")] {
            try setRelease("none")
            let run = try release(nil, ["FAKE_RC_" + key: "1"])
            assertStopped(run, before: before, says: [phrase])
            assertNothingPublic(run)
        }
    }

    /// A failed, timed-out or mismatched Windows result stops after the Mac build and before anything is public; the
    /// re-run finds the failed run and stops before the Mac gate until a new run is asked for on purpose.
    func testAWindowsFailureStopsBeforePublishingAndTheReRunNeedsANewRunOnPurpose() throws {
        let failed = try release(nil, ["FAKE_RC_COLLECT": "4"])
        assertStopped(failed, before: "team_notes.py fill", says: ["통과하지 못했습니다", "--new failed", "/Applications 의 새 빌드",
                                                                   "공개한 것은 없습니다"])
        assertNothingPublic(failed)
        XCTAssertTrue(failed.verbs.contains("lipo"), "the Mac half ran meanwhile")

        let rerun = try release(nil, ["FAKE_RC_START": "3"])
        assertStopped(rerun, before: "test-gate.sh", says: ["--new failed"])
        let fixed = try release()
        XCTAssertEqual(fixed.status, 0, fixed.text)

        for (scenario, phrase) in [(["FAKE_RC_COLLECT": "9"], "예상하지 못한 코드 9"), (["FAKE_RC_COLLECT": "2"], "인자를 거부"),
                                   (["FAKE_COLLECT_OUT": ""], "알려 주지 않았습니다"),
                                   (["FAKE_COLLECT_OUT": "INSTALLER=/x.exe"], "알려 주지 않았습니다")] {
            try setRelease("none")
            let run = try release(nil, scenario)
            assertStopped(run, before: "team_notes.py fill", says: [phrase])
        }
    }

    func testUnfilledNotesStopBeforePublishing() throws {
        for (code, phrase) in [("1", "노트를 채우지 못했습니다"), ("9", "예상하지 못한 코드 9")] {
            let run = try release(nil, ["FAKE_RC_FILL": code])
            assertStopped(run, before: "team_release.py publish", says: [phrase, "공개한 것은 없습니다"])
        }
    }

    // MARK: - publish's exit codes

    func testPublishExit5LeavesNothingPublicAndTheReRunPublishes() throws {
        let run = try release(nil, ["FAKE_RC_PUBLISH": "5"])
        assertStopped(run, before: "gh api GET", says: ["공개 전에 멈췄습니다", "v\(Self.releaseVersion) 릴리스가 없습니다(방금 읽음)"])
        XCTAssertFalse(run.verbs.contains("team_release.py smoke"))
        let again = try release()
        XCTAssertEqual(again.status, 0, again.text)
        XCTAssertEqual(again.verbs, Self.fullRelease)
    }

    func testPublishExit5WithADraftLeftStopsTheReRunAtTheExistenceCheck() throws {
        let run = try release(nil, ["FAKE_RC_PUBLISH": "5", "FAKE_LEAVES": "draft"])
        assertStopped(run, before: "gh api GET", says: ["draft 가 있습니다(방금 읽음, 공개 아님)"])
        let again = try release()
        assertStopped(again, before: "python3 unittest", says: ["draft 릴리스 v\(Self.releaseVersion) 이 있습니다(공개 아님)", "남은 것: 없음"])
    }

    /// 6 and 7: the release is (or may be) public. The tap is never touched, and the re-run stops at the tag.
    func testPublishExit6And7NeverReachTheTap() throws {
        let six = try release(nil, ["FAKE_RC_PUBLISH": "6"])
        assertStopped(six, before: "gh api GET", says: ["확인이 실패했습니다", "다시 실행하지 말고",
                                                        "digest 가 sha256:", "일 때만 탭을"])
        XCTAssertFalse(six.verbs.contains("team_release.py smoke"))
        let rerun = try release()
        assertStopped(rerun, before: "python3 unittest", says: ["태그 v\(Self.releaseVersion) 이 이미 있습니다"])
        XCTAssertFalse(rerun.verbs.contains("gh api PUT"))

        try setRelease("none")
        let seven = try release(nil, ["FAKE_RC_PUBLISH": "7", "FAKE_LEAVES": "public"])
        assertStopped(seven, before: "gh api GET", says: ["이미 공개돼 있었습니다", "이 실행의 zip 으로 탭을 고치지 마세요"])
        XCTAssertFalse(seven.err.contains("일 때만 탭을"), "no tap values for someone else's release")
    }

    func testAnUnknownPublishExitIsNeverTakenForSuccess() throws {
        for (code, phrase) in [("1", "예상하지 못한 코드 1"), ("9", "예상하지 못한 코드 9"), ("2", "만든 것은 없습니다")] {
            try setRelease("none")
            let run = try release(nil, ["FAKE_RC_PUBLISH": code, "FAKE_LEAVES": "none"])
            assertStopped(run, before: "gh api GET", says: [phrase])
            XCTAssertFalse(run.verbs.contains("team_release.py smoke"))
        }
    }

    // MARK: - after publishing

    func testATapFailureAfterPublishingGivesTheValuesAndTheReRunStops() throws {
        let put = try release(nil, ["FAKE_RC_TAP_PUT": "1"])
        let zip = try Data(contentsOf: repo.appendingPathComponent("build/PokeTokenBar.zip"))
        let zipSHA = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        assertStopped(put, before: "team_release.py smoke", says: ["Homebrew 탭을 갱신하지 못했습니다", "version 을 \(Self.releaseVersion)",
                                                                  "sha256 을 \(zipSHA)", "smoke --version \(Self.releaseVersion)"])
        let rerun = try release()
        assertStopped(rerun, before: "python3 unittest", says: ["태그 v\(Self.releaseVersion) 이 이미 있습니다"])

        try setRelease("none")
        let get = try release(nil, ["FAKE_RC_TAP_GET": "1"])
        assertStopped(get, before: "gh api PUT", says: ["Homebrew 탭을 갱신하지 못했습니다"])
    }

    func testASmokeFailureSaysTheReleaseIsDone() throws {
        let run = try release(nil, ["FAKE_RC_SMOKE": "1"])
        XCTAssertEqual(run.status, 1, run.text)
        XCTAssertEqual(run.verbs, Self.fullRelease)
        XCTAssertTrue(run.err.contains("공개와 탭 갱신은 끝났습니다. smoke 실행만 시작하지 못했습니다"), run.err)
    }

    // MARK: - interruptions

    /// Ctrl-C reaches the script and the step running; TERM sent to the script alone waits for the step to end
    /// (bash runs the trap then). Either way the message says what is left.
    func testAnInterruptionAtAnyStepSaysWhatIsLeft() throws {
        let cases: [(at: String, signal: String, status: Int32, says: [String], never: String)] = [
            ("view", "INT", 130, ["INT 신호를 받았습니다([0/10]", "남은 것: 없음"], "security"),
            ("docs", "INT", 130, ["INT 신호를 받았습니다([1/10]", "남은 것: 없음"], "team_release.py start"),
            ("start", "INT", 130, ["[2/10]", "Windows 실행이 시작됐을 수 있습니다"], "test-gate.sh"),
            ("gate", "INT", 130, ["[3/10]", "actions/runs/4101", "/Applications 는 그대로", "cfprefsd-guard.sh"], "build-app.sh"),
            ("build", "TERM", 143, ["TERM 신호를", "[4/10]", "/Applications 가 새 빌드로 바뀌었을 수 있습니다"], "codesign"),
            ("collect", "HUP", 129, ["HUP 신호를", "[5/10]", "공개한 것은 없습니다"], "team_notes.py fill"),
            ("fill", "TERM", 143, ["[6/10]", "/Applications 의 새 빌드", "공개한 것은 없습니다"], "team_release.py publish"),
            ("publish", "INT", 130, ["[7/10]", "마지막 명령의 코드 5", "v\(Self.releaseVersion) 릴리스가 없습니다(방금 읽음)"], "gh api GET"),
            ("publish", "TERM", 143, ["[7/10]", "마지막 명령의 코드 0", "publish 가 확인까지 마쳤습니다. 탭은 갱신하지 않았습니다",
                                      "smoke --version \(Self.releaseVersion)"], "gh api GET"),
            ("tap", "INT", 130, ["[9/10]", "공개된 v\(Self.releaseVersion)", "탭은 갱신되지 않았을 수 있습니다", "version \(Self.releaseVersion), sha256 "],
             "team_release.py smoke"),
            ("smoke", "INT", 130, ["[10/10]", "공개된 v\(Self.releaseVersion) 과 갱신된 탭", "smoke 만 남았습니다"], "none"),
        ]
        for c in cases {
            try setRelease("none")
            let run = try release(nil, ["FAKE_INTERRUPT": c.at, "FAKE_SIGNAL": c.signal])
            XCTAssertEqual(run.status, c.status, "\(c.at) \(c.signal): \(run.text)")
            XCTAssertFalse(run.verbs.contains(c.never), "\(c.at) \(c.signal) stops before \(c.never): \(run.verbs)")
            for phrase in c.says {
                XCTAssertTrue(run.err.contains(phrase), "\(c.at) \(c.signal): message lacks '\(phrase)':\n\(run.err)")
            }
        }
    }

    func testAReRunAfterAnInterruptionGoesOnOrStopsAtTheExistingRelease() throws {
        let cleaned = try release(nil, ["FAKE_INTERRUPT": "publish", "FAKE_SIGNAL": "INT"])
        XCTAssertEqual(cleaned.status, 130, cleaned.text)
        let again = try release()
        XCTAssertEqual(again.status, 0, again.text)

        try setRelease("none")
        let published = try release(nil, ["FAKE_INTERRUPT": "publish", "FAKE_SIGNAL": "TERM"])
        XCTAssertEqual(published.status, 143, published.text)
        let rerun = try release()
        assertStopped(rerun, before: "python3 unittest", says: ["태그 v\(Self.releaseVersion) 이 이미 있습니다"])
        XCTAssertFalse(rerun.verbs.contains("gh api PUT"))

        let rehearsal = try release(["--rehearse", notes.path], ["FAKE_BRANCH": "feat/x", "FAKE_INTERRUPT": "collect"])
        XCTAssertEqual(rehearsal.status, 130, rehearsal.text)
        XCTAssertTrue(rehearsal.err.contains("남은 것: 리허설이라 빌드, 공개, 탭은 하지 않았습니다"), rehearsal.err)
    }

    // MARK: - the fake

    /// One fake for every outside command. It logs `name args…` to $FAKE_STATE/calls.log and acts as FAKE_* say:
    /// FAKE_RC_<KEY> exit codes; FAKE_INTERRUPT=<step> sends FAKE_SIGNAL there (INT to the whole process group, as
    /// Ctrl-C does; another signal to the script alone); $FAKE_STATE/release is the release on GitHub (none, draft or
    /// public; publishing makes the tag); FAKE_LEAVES is what publish leaves there.
    static let fake = #"""
    #!/bin/bash
    name=${FAKE_NAME:-${0##*/}}
    printf '%s\n' "$name $*" >> "$FAKE_STATE/calls.log"
    rc_of() { local v="FAKE_RC_$1"; echo "${!v:-0}"; }
    finish() { exit "$(rc_of "$1")"; }
    interrupt_if() {
      [[ "${FAKE_INTERRUPT:-}" == "$1" ]] || return 0
      if [[ "${FAKE_SIGNAL:-INT}" == INT ]]; then
        kill -INT 0
      else
        kill -"$FAKE_SIGNAL" "$(ps -o pgid= -p $$ | tr -d ' ')"
      fi
      sleep 1
    }
    arg_after() { local want=$1; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
    release() { cat "$FAKE_STATE/release" 2>/dev/null || echo none; }

    case "$name" in
      gh)
        case "$1 $2" in
          "auth status") finish AUTH ;;
          "release view")
            interrupt_if view
            case "$(release)" in
              none) echo "release not found" >&2; exit 1 ;;
              draft) echo true ;;
              public) echo false ;;
              *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
            esac ;;
          "api -X")
            interrupt_if tap
            for a in "$@"; do case "$a" in content=*) printf '%s' "${a#content=}" > "$FAKE_STATE/put-content" ;; esac; done
            finish TAP_PUT ;;
          "api repos/likelion-campus/homebrew-tap/contents/Casks/poke-token-bar-team.rb")
            case "$*" in
              *.sha*) echo "blob0123" ;;
              *.content*) printf 'cask "poke-token-bar-team" do\n  version "2.5.634"\n  sha256 "%064d"\nend\n' 0 | base64 ;;
            esac
            finish TAP_GET ;;
          *) echo "fake gh: unexpected call: $*" >&2; exit 97 ;;
        esac ;;
      git)
        case "$1" in
          rev-parse)
            case "$2" in
              --abbrev-ref) echo "${FAKE_BRANCH:-main}" ;;
              HEAD) echo "$FAKE_HEAD" ;;
              --verify) echo "${FAKE_REMOTE_HEAD:-$FAKE_HEAD}" ;;
              *) exit 97 ;;
            esac ;;
          status) printf '%s' "${FAKE_DIRTY:-}" ;;
          remote) echo "${FAKE_ORIGIN:-https://github.com/likelion-campus/PokeTokenBar.git}" ;;
          fetch) finish FETCH ;;
          show-ref) [[ "$(release)" == public ]]; exit $? ;;
          *) echo "fake git: unexpected call: $*" >&2; exit 97 ;;
        esac ;;
      security) [[ -z "$FAKE_LEAF" ]] && exit 1; echo "  1) $FAKE_LEAF \"PokeTokenBar Local\""; echo "     1 valid identities found" ;;
      codesign)
        for a in "$@"; do case "$a" in --extract-certificates=*) cp "$FAKE_CERT" "${a#--extract-certificates=}0" ;; esac; done
        finish CODESIGN ;;
      ditto) for last in "$@"; do :; done; mkdir -p "$(dirname "$last")"; printf 'zip %s\n' "$FAKE_HEAD" > "$last"; finish DITTO ;;
      lipo) finish LIPO ;;
      test-gate.sh) interrupt_if gate; finish GATE ;;
      cfprefsd-guard.sh) finish CFPREFSD ;;
      build-app.sh) interrupt_if build; finish BUILD ;;
      python3)
        if [[ "$1" == "-m" ]]; then
          [[ "$(rc_of SELFTEST)" == 0 ]] || echo "FAIL: test_team_release (fake)"
          finish SELFTEST
        fi
        tool=${1##*/}; sub=$2
        case "$tool $sub" in
          "team_notes.py check") finish NOTES_CHECK ;;
          "team_docs_check.py "*)
            interrupt_if docs
            [[ "$(rc_of DOCS)" != 2 ]] || echo "STOP: windows paths have feat commits but no new windows asset was added (1): feat(windows): x" >&2
            finish DOCS ;;
          "team_release.py start")
            interrupt_if start
            printf '%s\n' "${FAKE_START_OUT-WINDOWS_APP_RUN=4101
    WINDOWS_TESTS_RUN=4202}"
            finish START ;;
          "team_release.py collect")
            interrupt_if collect
            v=$(arg_after --version "$@"); out=$(arg_after --out "$@")
            mkdir -p "$out/windows-release"
            installer="$PWD/$out/windows-release/PokeTokenBar-Setup-$v-win-x64.exe"
            printf 'setup %s\n' "$v" > "$installer"
            printf '%s\n' "${FAKE_COLLECT_OUT-INSTALLER=$installer
    SHA256=$(printf '%064d' 7)}"
            finish COLLECT ;;
          "team_notes.py fill")
            interrupt_if fill
            out=$(arg_after --out "$@")
            [[ "$(rc_of FILL)" != 0 ]] || printf 'filled %s\n' "$(arg_after --sha256 "$@")" > "$out"
            finish FILL ;;
          "team_release.py publish")
            if [[ "${FAKE_INTERRUPT:-}" == publish ]]; then
              trap 'echo "fake publish: interrupted, its own draft removed" >&2; echo none > "$FAKE_STATE/release"; exit 5' INT TERM
              interrupt_if publish
            fi
            rc=$(rc_of PUBLISH)
            if [[ -n "${FAKE_LEAVES:-}" ]]; then echo "$FAKE_LEAVES" > "$FAKE_STATE/release"
            elif [[ "$rc" == 0 || "$rc" == 6 ]]; then echo public > "$FAKE_STATE/release"; fi
            exit "$rc" ;;
          "team_release.py smoke")
            interrupt_if smoke
            echo "https://github.com/likelion-campus/PokeTokenBar/actions/runs/4303"
            finish SMOKE ;;
          *) echo "fake python3: unexpected call: $*" >&2; exit 97 ;;
        esac ;;
      *) echo "fake: unknown tool $name" >&2; exit 97 ;;
    esac
    exit 0
    """#
}
