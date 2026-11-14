import XCTest
@testable import PokeTokenBar

/// Source scan for the batch-shim rule (F19, see `ToolLaunchArgumentTests`). Mac-only because `SharedSources` is.
final class ToolLaunchArgumentScanTests: XCTestCase {
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
            // A launch site creates a Process and sets its arguments; `self.arguments = arguments` alone is not one.
            if text.contains("Process()"), text.contains(".arguments =") { assignmentFiles.insert(rel) }
        }
        XCTAssertTrue(lists.contains(["app-server", "--stdio"]), "the Codex argument list was not found: \(lists)")
        for list in lists { for arg in list { XCTAssertTrue(PlatformCompat.isBatchSafe(arg), arg) } }
        // Direct Process launches: the shell lookup (a shell, never a shim), the JSON-RPC runner (receives the lists above),
        // the Windows selftest, which starts copies of its own executable (never a shim) with flags it builds itself, and
        // the updater's brew calls (fixed literals; they run only where `brew` is found, which is never on Windows).
        XCTAssertEqual(assignmentFiles, ["Core/BinaryLocator.swift", "Core/ProcessRunner.swift", "Core/UpdateChecker.swift",
                                         "Platform/Windows/WindowsSelftest.swift"],
                       "a new Process launch site: check its arguments against the batch-shim rule (F19) and add it here")
    }
}
