import XCTest

/// Mechanical guard: a `UsageStore` built without its own `providers:` argument registers the real
/// providers, and its poll timer or any setter that starts a refresh then reads the developer's
/// `~/.claude`, `~/.codex`, ... logs (and the Keychain, the network, `codex`) and saves what it found
/// into the test's defaults. So every `UsageStore(` / `UsageStore.init(` call in `Tests/` must pass
/// `providers:` as one of its own top-level arguments (not inside a nested call or a string), and the
/// value must not be `UsageStore.defaultProviders()`. A registry check reads
/// `UsageStore.defaultProviders().map(\.id)` and builds no store. Not covered: a bare `.init(` whose type
/// is only inferred.
final class UsageStoreHermeticityScanTests: XCTestCase {
    /// Every `UsageStore(` or `UsageStore.init(` call in `text` whose own argument list lacks `providers:`
    /// or passes the real default providers, as "line N".
    static func bareStores(in text: String) -> [String] {
        let chars = Array(text)
        var found: [String] = []
        var i = 0
        func matches(_ s: String, at k: Int) -> Bool {
            k + s.count <= chars.count && String(chars[k..<k + s.count]) == s
        }
        while i < chars.count {
            let needle: String
            if matches("UsageStore.init(", at: i) { needle = "UsageStore.init(" }
            else if matches("UsageStore(", at: i) { needle = "UsageStore(" }
            else { i += 1; continue }
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" { i += 1; continue }
            let line = chars[..<i].filter { $0 == "\n" }.count + 1
            var k = i + needle.count
            var depth = 1
            var inString = false
            var argStart = k
            var providersArg: String?
            func closeArg(_ end: Int) {
                let arg = String(chars[argStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if arg.hasPrefix("providers:") { providersArg = arg }
            }
            while k < chars.count, depth > 0 {
                let c = chars[k]
                if inString {
                    if c == "\\" { k += 1 } else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if matches("//", at: k) { while k < chars.count, chars[k] != "\n" { k += 1 } }
                else if c == "(" || c == "[" || c == "{" { depth += 1 }
                else if c == ")" || c == "]" || c == "}" {
                    depth -= 1
                    if depth == 0 { closeArg(k) }
                } else if c == ",", depth == 1 { closeArg(k); argStart = k + 1 }
                k += 1
            }
            if providersArg == nil || providersArg!.contains("defaultProviders") { found.append("line \(line)") }
            i += needle.count
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
        XCTAssertEqual(offenders, [], "pass a stubbed providers: list (makeHermeticUsageStore); a registry check reads UsageStore.defaultProviders().map(\\.id) without building a store")
    }

    func testTheScanFlagsABareStoreAndAcceptsInjectedProviders() {
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(autoRefresh: false, defaults: d)"), ["line 1"])
        XCTAssertEqual(Self.bareStores(in: "x\nlet a = UsageStore(\n  defaults: foo(1))"), ["line 2"])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore.init(autoRefresh: false)"), ["line 1"])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(providers: [p], autoRefresh: false)"), [])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore.init(providers: [])"), [])
        XCTAssertEqual(Self.bareStores(in: "let a = UsageStore(\n  autoRefresh: false,\n  providers: [])"), [])
        XCTAssertEqual(Self.bareStores(in: "let a = FakeUsageStore(autoRefresh: false)"), [])
    }

    func testTheScanFlagsDefaultProvidersAndANestedOrQuotedProvidersLabel() {
        XCTAssertEqual(Self.bareStores(in: "UsageStore(providers: UsageStore.defaultProviders(), autoRefresh: false)"), ["line 1"])
        XCTAssertEqual(Self.bareStores(in: "UsageStore(autoRefresh: f(providers: []))"), ["line 1"])
        XCTAssertEqual(Self.bareStores(in: "UsageStore(autoRefresh: false, defaults: d(\"providers: x\"))"), ["line 1"])
    }
}
