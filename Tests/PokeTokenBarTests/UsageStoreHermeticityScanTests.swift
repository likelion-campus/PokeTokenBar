import XCTest

/// Mechanical guard: a `UsageStore` built without `providers:` registers the real providers, and anything
/// that makes it refresh (a setter that starts an un-awaited `Task`, `autoRefresh`) then reads the
/// developer's `~/.claude`, `~/.codex`, ... logs and saves what it found into the test's defaults. When
/// that refresh finishes after the test, the real ledger ends up in someone else's defaults. A test that
/// is about the registry passes `UsageStore.defaultProviders()` explicitly (it never refreshes).
final class UsageStoreHermeticityScanTests: XCTestCase {
    /// Every `UsageStore(` call in `text` that has no `providers:` argument, as "line N".
    static func bareStores(in text: String) -> [String] {
        let needle = "UsageStore("
        var found: [String] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: needle, range: search) {
            search = hit.upperBound..<text.endIndex
            // `class FakeUsageStore(`-style names and `.init(`: only the exact type name counts.
            if hit.lowerBound > text.startIndex {
                let before = text[text.index(before: hit.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var depth = 1
            var end = hit.upperBound
            while end < text.endIndex, depth > 0 {
                if text[end] == "(" { depth += 1 } else if text[end] == ")" { depth -= 1 }
                end = text.index(after: end)
            }
            if !text[hit.upperBound..<end].contains("providers:") {
                let line = text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                found.append("line \(line)")
            }
        }
        return found
    }

    func testNoTestBuildsAUsageStoreOnTheRealProviders() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift"
            && url.lastPathComponent != "UsageStoreHermeticityScanTests.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.bareStores(in: text).map { "\(url.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(offenders, [], "pass providers: (makeHermeticUsageStore, or UsageStore.defaultProviders() for a registry check) so no test reads the real usage logs")
    }

    func testTheScanFlagsABareStoreAndAcceptsInjectedProviders() {
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(autoRefresh: false, defaults: d)"), ["line 1"])
        XCTAssertEqual(Self.bareStores(in: "x\nlet a = UsageStore(\n  defaults: foo(1))"), ["line 2"])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(providers: [p], autoRefresh: false)"), [])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(\n  autoRefresh: false,\n  providers: [])"), [])
        XCTAssertEqual(Self.bareStores(in: "let a = FakeUsageStore(autoRefresh: false)"), [])
    }
}
