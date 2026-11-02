import XCTest

/// Task 14: the team fork's release script and install guide. Text checks only;
/// the script itself is never run by a test.
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

    private func firstIndex(of needle: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.contains(needle) }
    }

    func testTeamReleaseTargetsForkOnly() throws {
        let script = try read("scripts/team-release.sh")
        let lines = codeLines(script)

        XCTAssertTrue(script.contains("export PTB_REQUIRE_STABLE_SIGN=1"))
        XCTAssertFalse(script.contains("chattymin/"))
        XCTAssertFalse(script.contains("homebrew-tap"))

        // Every release command goes to the fork, and there is exactly one.
        let creates = lines.filter { $0.contains("gh release create") }
        XCTAssertEqual(creates.count, 1, "exactly one gh release line expected")
        let create = try XCTUnwrap(creates.first)
        XCTAssertTrue(create.contains("gh release create"))
        XCTAssertTrue(create.contains("--repo likelion-campus/PokeTokenBar"))
        XCTAssertTrue(create.contains("--target "))
        XCTAssertTrue(create.contains("--notes-file"))
        // No other gh call can reach another repository or the Pages / tap steps.
        let ghCalls = lines.filter {
            ($0.hasPrefix("gh ") || $0.contains(" gh ") || $0.contains("$(gh "))
                && !$0.hasPrefix("fail ") && !$0.hasPrefix("echo") && !$0.contains("fail \"")
                && !$0.hasPrefix("command -v")
        }
        for line in ghCalls where !line.contains("gh auth status") {
            XCTAssertTrue(line.contains("gh release create") || line.contains("gh release view"),
                          "unexpected gh call: \(line)")
            XCTAssertTrue(line.contains("--repo likelion-campus/PokeTokenBar"), "gh call without the fork repo: \(line)")
        }
        XCTAssertFalse(script.contains("gh-pages"))
    }

    func testTeamReleaseNeverPushes() throws {
        let script = try read("scripts/team-release.sh")
        XCTAssertFalse(script.contains("git push"))
        XCTAssertFalse(script.contains("git tag "), "the script must not create a tag; gh release create does")
        XCTAssertFalse(script.contains("git commit"))
    }

    /// A failed check must leave /Applications untouched, so every stop sits
    /// above the build line, and the leaf check is cheap enough to run first.
    func testTeamReleaseChecksRunBeforeTheBuild() throws {
        let script = try read("scripts/team-release.sh")
        let lines = codeLines(script)

        let build = try XCTUnwrap(firstIndex(of: "./scripts/build-app.sh", in: lines), "build line missing")
        let create = try XCTUnwrap(firstIndex(of: "gh release create", in: lines))
        XCTAssertLessThan(build, create, "build must come before the release step")

        let checks = [
            "git rev-parse --abbrev-ref HEAD",   // main branch
            "git status --porcelain",            // clean tree
            "origin/main",                       // same as origin
            "show-ref",                          // tag already exists
            "security find-identity",            // signing identity / leaf
            "TEAM_EXPECTED_LEAF",                // leaf pin
            "create-signing-cert.sh",            // guidance, not execution
            "./scripts/test-gate.sh",            // tests and coverage, as release.sh runs first
        ]
        for check in checks {
            let at = try XCTUnwrap(firstIndex(of: check, in: lines), "check missing: \(check)")
            XCTAssertLessThan(at, build, "\(check) must run before the build")
        }

        // The export of the strict-sign flag must also precede the build.
        let export = try XCTUnwrap(firstIndex(of: "export PTB_REQUIRE_STABLE_SIGN=1", in: lines))
        XCTAssertLessThan(export, build)

        // The universal check sits between the build and the release.
        let universal = try XCTUnwrap(firstIndex(of: "lipo", in: lines))
        XCTAssertGreaterThan(universal, build)
        XCTAssertLessThan(universal, create)

        // The signing cert script is only mentioned in a message, never invoked.
        for line in lines where line.contains("create-signing-cert.sh") {
            XCTAssertTrue(line.contains("fail \"") || line.hasPrefix("echo"),
                          "create-signing-cert.sh must only be named in a message: \(line)")
        }

        // Bash 3.2 safety.
        XCTAssertFalse(script.contains("declare -A"))
        XCTAssertFalse(script.contains("mapfile"))
        XCTAssertFalse(script.contains("readarray"))
        XCTAssertTrue(script.contains("set -euo pipefail"))
    }

    /// Fix round 1: the release is pinned to the commit that was checked and built.
    func testTeamReleasePinsTheCheckedCommit() throws {
        let script = try read("scripts/team-release.sh")
        let lines = codeLines(script)
        let build = try XCTUnwrap(firstIndex(of: "./scripts/build-app.sh", in: lines))
        let create = try XCTUnwrap(lines.first { $0.contains("gh release create") })

        XCTAssertFalse(create.contains("--target main"))
        XCTAssertTrue(create.contains("--target \"$LOCAL_HEAD\""))

        for check in ["git remote get-url origin", "gh auth status", "export CODESIGN_IDENTITY="] {
            let at = try XCTUnwrap(firstIndex(of: check, in: lines), "missing: \(check)")
            XCTAssertLessThan(at, build, "\(check) must come before the build")
        }

        // The built app's leaf is confirmed after the build and before the zip.
        let zip = try XCTUnwrap(firstIndex(of: "ditto", in: lines))
        let built = try XCTUnwrap(lines.indices.first { lines[$0].contains("codesign") && $0 > build })
        XCTAssertLessThan(built, zip, "the built-app leaf check must come before the zip")

        // A failed existence check must be told apart from "not found".
        XCTAssertTrue(script.contains("release not found"), "view failure must be classified")
    }

    func testTeamGuideCreditsAssets() throws {
        let guide = try read("TEAM.md")
        XCTAssertTrue(guide.contains("ArMM1998"))
        XCTAssertTrue(guide.contains("갈무리"))
        XCTAssertTrue(guide.contains("PokéAPI"))
        XCTAssertTrue(guide.contains("brew uninstall --cask poke-token-bar"))
        XCTAssertTrue(guide.contains("scripts/team-probe.swift"))
        XCTAssertTrue(guide.contains("팀 기능 켜기"))
        XCTAssertTrue(guide.contains("광장 열기"))
        XCTAssertTrue(guide.contains("그래도 열기"))
        XCTAssertTrue(guide.contains("xattr -dr com.apple.quarantine /Applications/PokeTokenBar.app"))
        XCTAssertTrue(guide.contains("백업 & 이전"))
    }

    func testTeamGuideHoldsNoPrivateDetails() throws {
        for file in ["TEAM.md", "scripts/team-release.sh"] {
            let text = try read(file).replacingOccurrences(of: "git@github.com:", with: "")
            XCTAssertFalse(text.contains("@"), "\(file): no email addresses")
            XCTAssertFalse(text.contains(".local"), "\(file): no host names")
        }
        let guide = try read("TEAM.md")
        // `--zap` may appear only as a warning next to the word 금지.
        for line in guide.components(separatedBy: "\n") where line.contains("--zap") {
            XCTAssertTrue(line.contains("금지") || line.contains("않"), "--zap must be warned against: \(line)")
        }
    }
}
