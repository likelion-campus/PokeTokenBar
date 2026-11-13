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
}
