import XCTest

/// The team fork's release script and install guide: text checks. `TeamReleaseScriptRunTests` (Mac only) runs the
/// script against fakes; these pin its shape on every system.
final class TeamReleaseScriptTests: XCTestCase {

    private func repositoryFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PokeTokenBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relative)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repositoryFile(relative), encoding: .utf8)
    }

    /// Code lines only: comments and blank lines dropped, so a note such as
    /// "never git push" cannot fail or satisfy a check.
    private func codeLines(_ script: String) -> [String] {
        script.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// A code line with its quoted text removed, so a message that names a command (`fail "… run python3
    /// scripts/team_release.py smoke …"`) is not taken for a call of it.
    static func unquoted(_ line: String) -> String {
        var out = "", quote: Character? = nil, escaped = false
        for c in line {
            if let q = quote {
                if escaped { escaped = false } else if c == "\\" && q == "\"" { escaped = true } else if c == q { quote = nil; out.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                out.append(c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private struct Script {
        let text: String
        let code: [String]   // code lines
        let bare: [String]   // the same lines, quoted text removed
    }

    private func script() throws -> Script {
        let text = try read("scripts/team-release.sh")
        let code = codeLines(text)
        return Script(text: text, code: code, bare: code.map(Self.unquoted))
    }

    /// Indices of the lines that run `command` (outside any quoted text).
    private func calls(_ command: String, in s: Script) -> [Int] {
        s.bare.indices.filter { s.bare[$0].contains(command) }
    }

    private func onlyCall(_ command: String, in s: Script, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let found = calls(command, in: s)
        XCTAssertEqual(found.count, 1, "exactly one line must run \(command): \(found.map { s.code[$0] })", file: file, line: line)
        return try XCTUnwrap(found.first, file: file, line: line)
    }

    /// Lines that run gh (not `command -v gh`).
    private func ghCalls(in s: Script) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"(^|[\s;(|&])gh\s"#)
        return s.bare.indices.filter { i in
            let l = s.bare[i]
            return !l.contains("command -v gh") && regex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
    }

    func testTheQuoteStripperKeepsCodeAndDropsMessages() {
        XCTAssertEqual(Self.unquoted(#"fail "run python3 scripts/team_release.py smoke""#), #"fail """#)
        XCTAssertEqual(Self.unquoted(#"X=$(gh api "repos/a" --jq '.sha') || fail "$M""#), #"X=$(gh api "" --jq '') || fail """#)
        XCTAssertEqual(Self.unquoted(#"echo "a \"b\" 'c'" d"#), #"echo "" d"#)
    }

    func testTeamReleaseTargetsForkOnly() throws {
        let s = try script()
        XCTAssertTrue(s.text.contains("export PTB_REQUIRE_STABLE_SIGN=1"))
        XCTAssertFalse(s.text.contains("chattymin/"))
        XCTAssertFalse(s.text.contains("gh-pages"))

        // The script writes no release itself: team_release.py publish is the only writer (D2).
        for verb in ["release create", "release edit", "release delete", "release upload", "delete-asset"] {
            XCTAssertFalse(s.code.contains { $0.contains(verb) }, "the script must not run gh \(verb)")
        }
        // gh calls: auth status, two release views (the version's state; releases/latest), the tap.
        let gh = ghCalls(in: s)
        XCTAssertFalse(gh.isEmpty)
        for i in gh {
            let line = s.code[i]
            if line.contains("gh auth status") { continue }
            if line.contains("gh api") {
                XCTAssertTrue(line.contains("repos/$TAP_REPO/contents/$CASK_PATH"), "gh api outside the cask: \(line)")
                continue
            }
            XCTAssertTrue(line.contains("gh release view") && line.contains("--repo likelion-campus/PokeTokenBar"),
                          "unexpected gh call: \(line)")
        }
        let views = gh.filter { s.code[$0].contains("gh release view") }.map { s.code[$0] }
        XCTAssertEqual(views.count, 2, "two reads: the version's release state and releases/latest: \(views)")
        XCTAssertEqual(views.filter { $0.contains("gh release view \"v$VERSION\"") }.count, 1)
        XCTAssertEqual(views.filter { $0.contains("gh release view --repo") }.count, 1, "no tag: releases/latest")
    }

    /// One writer, called once, pinned to the checked commit and version.
    func testOnlyTheHelperPublishesOnceForTheCheckedCommit() throws {
        let s = try script()
        let publish = s.code[try onlyCall("python3 scripts/team_release.py publish", in: s)]
        for part in ["--sha \"$LOCAL_HEAD\"", "--version \"$VERSION\"", "--zip \"$ZIP\"", "--installer \"$INSTALLER\"",
                     "--notes build/release-notes.md"] {
            XCTAssertTrue(publish.contains(part), "publish needs \(part): \(publish)")
        }
        for command in ["python3 scripts/team_release.py start", "python3 scripts/team_release.py collect"] {
            let line = s.code[try onlyCall(command, in: s)]
            XCTAssertTrue(line.contains("--sha \"$LOCAL_HEAD\"") && line.contains("--version \"$VERSION\""), line)
        }
        let fill = s.code[try onlyCall("python3 scripts/team_notes.py fill", in: s)]
        XCTAssertTrue(fill.contains("--sha256 \"$SHA256\"") && fill.contains("--out build/release-notes.md"), fill)
    }

    /// D3: Windows starts before the Mac gate; everything that can fail runs before publish; the tap and smoke after.
    func testTheStepsRunInTheOrderOfD3() throws {
        let s = try script()
        let start = try onlyCall("python3 scripts/team_release.py start", in: s)
        let gate = try onlyCall("./scripts/test-gate.sh", in: s)
        let lipo = try onlyCall("lipo ", in: s)
        let collect = try onlyCall("python3 scripts/team_release.py collect", in: s)
        let fill = try onlyCall("python3 scripts/team_notes.py fill", in: s)
        let publish = try onlyCall("python3 scripts/team_release.py publish", in: s)
        let tap = try onlyCall("gh api -X PUT", in: s)
        let smoke = try onlyCall("python3 scripts/team_release.py smoke", in: s)
        XCTAssertLessThan(start, gate, "start the Windows runs before the Mac test gate")
        XCTAssertLessThan(lipo, collect)
        XCTAssertLessThan(collect, fill)
        XCTAssertLessThan(fill, publish)
        XCTAssertLessThan(publish, tap, "the tap moves only after the release")
        XCTAssertLessThan(tap, smoke, "smoke after the tap")
    }

    func testTeamReleaseUpdatesOnlyTheTeamTap() throws {
        let s = try script()
        XCTAssertTrue(s.text.contains("TAP_REPO=\"likelion-campus/homebrew-tap\""))
        XCTAssertTrue(s.text.contains("CASK_PATH=\"Casks/poke-token-bar-team.rb\""))
        for line in s.code where line.contains("gh api") {
            XCTAssertTrue(line.contains("repos/$TAP_REPO/contents/$CASK_PATH"), "gh api outside the cask: \(line)")
        }
    }

    func testTeamReleaseNeverPushes() throws {
        let text = try read("scripts/team-release.sh")
        XCTAssertFalse(text.contains("git push"))
        XCTAssertFalse(text.contains("git tag "), "the script must not create a tag; publishing the draft does")
        XCTAssertFalse(text.contains("git commit"))
    }

    /// A failed check must leave /Applications untouched, so every stop sits
    /// above the build line, and the leaf check is cheap enough to run first.
    func testTeamReleaseChecksRunBeforeTheBuild() throws {
        let s = try script()
        let lines = s.code
        let build = try onlyCall("./scripts/build-app.sh", in: s)

        let checks = [
            "git rev-parse --abbrev-ref HEAD",   // main branch
            "git status --porcelain",            // clean tree
            "origin/$BRANCH",                    // same as origin
            "show-ref",                          // tag already exists
            "security find-identity",            // signing identity / leaf
            "TEAM_EXPECTED_LEAF",                // leaf pin
            "create-signing-cert.sh",            // guidance, not execution
            "command -v python3",                // new pre-checks
            "python3 -m unittest discover -s scripts/tests -p 'test_team_*.py'",
            "python3 scripts/team_notes.py check --in \"$NOTES_FILE\"",
            "python3 scripts/team_docs_check.py",
            "python3 scripts/team_release.py start",
            "./scripts/test-gate.sh",            // tests and coverage, as release.sh runs first
        ]
        for check in checks {
            let at = try XCTUnwrap(lines.firstIndex { $0.contains(check) }, "check missing: \(check)")
            XCTAssertLessThan(at, build, "\(check) must run before the build")
        }
        XCTAssertTrue(s.text.contains("[[ \"$BRANCH\" == \"main\" ]]"), "a release runs from main only")

        // The export of the strict-sign flag must also precede the build.
        let export = try XCTUnwrap(lines.firstIndex { $0.contains("export PTB_REQUIRE_STABLE_SIGN=1") })
        XCTAssertLessThan(export, build)

        // The universal check sits between the build and the Windows results.
        let universal = try onlyCall("lipo ", in: s)
        XCTAssertGreaterThan(universal, build)
        XCTAssertLessThan(universal, try onlyCall("python3 scripts/team_release.py collect", in: s))

        // The signing cert script is only mentioned in a message, never invoked.
        XCTAssertEqual(calls("create-signing-cert.sh", in: s), [], "create-signing-cert.sh must only be named in a message")

        // Bash 3.2 safety.
        XCTAssertFalse(s.text.contains("declare -A"))
        XCTAssertFalse(s.text.contains("mapfile"))
        XCTAssertFalse(s.text.contains("readarray"))
        XCTAssertTrue(s.text.contains("set -euo pipefail"))
        XCTAssertTrue(s.text.contains("trap 'rm -rf \"$CERT_DIR\"' EXIT"), "keep the cert folder cleanup")
    }

    /// The release is pinned to the commit that was checked and built.
    func testTeamReleasePinsTheCheckedCommit() throws {
        let s = try script()
        let lines = s.code
        let build = try onlyCall("./scripts/build-app.sh", in: s)
        XCTAssertFalse(s.text.contains("--target main"))

        for check in ["git remote get-url origin", "gh auth status", "export CODESIGN_IDENTITY="] {
            let at = try XCTUnwrap(lines.firstIndex { $0.contains(check) }, "missing: \(check)")
            XCTAssertLessThan(at, build, "\(check) must come before the build")
        }

        // The built app's leaf is confirmed after the build and before the zip.
        let zip = try onlyCall("ditto ", in: s)
        let built = try XCTUnwrap(lines.indices.first { lines[$0].contains("codesign") && $0 > build })
        XCTAssertLessThan(built, zip, "the built-app leaf check must come before the zip")

        // A failed existence check must be told apart from "not found".
        XCTAssertTrue(s.text.contains("release not found"), "view failure must be classified")
    }

    /// `--rehearse` leaves before the publish line, with nothing that writes in between.
    func testTheRehearsalExitsBeforeThePublishLine() throws {
        let s = try script()
        let publish = try onlyCall("python3 scripts/team_release.py publish", in: s)
        let branch = try XCTUnwrap(s.bare.indices.last { $0 < publish && s.bare[$0] == "if [[ \"\" == rehearse ]]; then" },
                                   "the rehearse branch before publish")
        let exit = try XCTUnwrap(s.bare.indices.first { $0 > branch && s.bare[$0] == "exit 0" }, "the rehearse exit 0")
        XCTAssertLessThan(exit, publish, "the rehearse branch's exit 0 comes before the publish line")
        for i in branch...exit {
            let l = s.bare[i]
            XCTAssertFalse(l.contains("team_release.py") || l.contains("gh ") || l.contains("./scripts/"),
                           "the rehearse branch must only print: \(s.code[i])")
        }
        // The test gate and the build sit in the release-only branch.
        let skip = try XCTUnwrap(s.bare.firstIndex { $0.hasPrefix("skipped 3 ") })
        let gate = try onlyCall("./scripts/test-gate.sh", in: s)
        XCTAssertLessThan(skip, gate)
        XCTAssertTrue(s.bare[skip - 1] == "if [[ \"\" == rehearse ]]; then", "skipped 3 opens the rehearse branch")
    }

    func testTeamGuideCreditsAssets() throws {
        let guide = try read("TEAM.md")
        XCTAssertTrue(guide.contains("ArMM1998"))
        XCTAssertTrue(guide.contains("갈무리"))
        XCTAssertTrue(guide.contains("PokéAPI"))
        XCTAssertTrue(guide.contains("brew uninstall --cask poke-token-bar"))
        XCTAssertTrue(guide.contains("brew install --cask likelion-campus/tap/poke-token-bar-team"))
        XCTAssertTrue(guide.contains("scripts/team-probe.swift"))
        XCTAssertTrue(guide.contains("팀 기능 켜기"))
        XCTAssertTrue(guide.contains("광장 열기"))
        XCTAssertTrue(guide.contains("그래도 열기"))
        XCTAssertTrue(guide.contains("xattr -dr com.apple.quarantine /Applications/PokeTokenBar.app"))
        XCTAssertTrue(guide.contains("백업 & 이전"))
        // The Windows section (stage 8 Task 10): the installer, SmartScreen, the hash check and the rollback.
        XCTAssertTrue(guide.contains("PokeTokenBar-Setup-"))
        XCTAssertTrue(guide.contains("추가 정보") && guide.contains("SmartScreen"))
        XCTAssertTrue(guide.contains("Get-FileHash"))
        XCTAssertTrue(guide.contains("업데이트가 잘못됐을 때"))
        XCTAssertTrue(guide.contains("assets/windows/"))
    }

    func testTeamGuideHoldsNoPrivateDetails() throws {
        for file in ["TEAM.md", "scripts/team-release.sh"] {
            let text = try read(file).replacingOccurrences(of: "git@github.com:", with: "")
            XCTAssertFalse(text.contains("@"), "\(file): no email addresses, no $@")
            XCTAssertFalse(text.contains(".local"), "\(file): no host names")
        }
        let guide = try read("TEAM.md")
        // `--zap` may appear only as a warning next to the word 금지.
        for line in guide.components(separatedBy: "\n") where line.contains("--zap") {
            XCTAssertTrue(line.contains("금지") || line.contains("않"), "--zap must be warned against: \(line)")
        }
    }
}
