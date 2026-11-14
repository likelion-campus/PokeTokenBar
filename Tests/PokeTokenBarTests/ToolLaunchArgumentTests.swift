import XCTest
@testable import PokeTokenBar

/// F19: a tool that resolves to an npm `.cmd` shim is run by cmd.exe, which interprets `& | < > ^ % !`.
/// Rule: a launched tool gets only fixed, code-defined arguments free of those characters. Free-form text (paths,
/// user input) is never passed through a batch shim; a call that needs it resolves the shim's target `.exe` or
/// escapes for `cmd.exe /d /s /c` in the same change.
final class ToolLaunchArgumentTests: XCTestCase {
    func testBatchSafetyRejectsCmdMetacharacters() {
        for bad in ["a&b", "a|b", "a<b", "a>b", "a^b", "100%", "!x", "a\nb", "a\r"] {
            XCTAssertFalse(PlatformCompat.isBatchSafe(bad), bad)
        }
        for good in ["app-server", "--stdio", "list", "--cask", "has space", "quo\"te", "C:\\x\\y", "/a/b", ""] {
            XCTAssertTrue(PlatformCompat.isBatchSafe(good), good)
        }
    }

    /// Reads the argument lists the shared code passes to a launched tool and holds each to the rule.
    func testEveryLaunchedToolArgumentIsBatchSafe() throws {
        let files = try SharedSources.sharedFiles(root: SharedSources.sourcesRoot, listURL: SharedSources.sourcesList)
        let regex = try NSRegularExpression(pattern: #"\barguments:\s*\[(\s*"[^\]]*)\]"#)
        var lists: [[String]] = []
        var assignmentFiles = Set<String>()
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = SharedSources.relativePath(url, root: SharedSources.sourcesRoot)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let elements = text[r].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for element in elements {
                    XCTAssertTrue(element.range(of: #"^"[^"\\]*"$"#, options: .regularExpression) != nil,
                                  "\(rel): launch argument `\(element)` is not a fixed literal. Free-form text must not reach a .cmd shim (F19).")
                }
                lists.append(elements.map { String($0.dropFirst().dropLast()) })
            }
            if text.contains(".arguments =") { assignmentFiles.insert(rel) }
        }
        XCTAssertTrue(lists.contains(["app-server", "--stdio"]), "the Codex argument list was not found: \(lists)")
        for list in lists { for arg in list { XCTAssertTrue(PlatformCompat.isBatchSafe(arg), arg) } }
        // Direct Process launches: the shell lookup (a shell, never a shim) and the JSON-RPC runner (receives the lists above).
        XCTAssertEqual(assignmentFiles, ["Core/BinaryLocator.swift", "Core/ProcessRunner.swift"],
                       "a new Process launch site: check its arguments against the batch-shim rule (F19) and add it here")
    }
}
