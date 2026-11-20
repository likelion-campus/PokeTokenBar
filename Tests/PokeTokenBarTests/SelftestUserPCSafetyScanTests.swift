import XCTest

/// The selftest runs on a person's PC too (`PokeTokenBar.exe --selftest`, TEAM.md tells users to), so it must not drive their input or
/// change a setting that outlives it. Every call in a `WindowsSelftest*.swift` file that does one of those things must sit in a function
/// that tests `onCI` (so it is a no-op off the runner), or be allow-listed with a reason in `selftest-user-pc-allow.txt`
/// (`File.swift:function | reason`). A helper that sends input (`tap`, `type`) tests `onCI` itself, so no caller can forget to.
final class SelftestUserPCSafetyScanTests: XCTestCase {
    /// What the scan looks for: pattern and why it matters.
    static let sensitive: [(pattern: String, why: String)] = [
        ("SetCursorPos(", "moves the user's pointer"),
        ("SendInput(", "types or clicks into whatever has the foreground"),
        ("keybd_event(", "types into whatever has the foreground"),
        ("mouse_event(", "clicks"),
        ("SetClipboardData(", "writes the user's clipboard"),
        ("WinTextClipboard.write(", "writes the user's clipboard"),
        ("EmptyClipboard(", "clears the user's clipboard"),
        ("ActivateKeyboardLayout(", "changes the user's keyboard layout"),
        ("LoadKeyboardLayout", "adds a keyboard layout to the user's list"),
        ("SetForegroundWindow(", "takes the foreground away from the user's window"),
        ("BringWindowToTop(", "raises a window over the user's"),
        ("WinRegistry.setBytes(", "writes the registry"),
        ("WinRegistry.setString(", "writes the registry"),
        ("WinRegistry.deleteValue(", "deletes a registry value"),
        ("WinRegistry.deleteTree(", "deletes a registry tree"),
        ("SystemParametersInfoW(", "reads or SETS a system-wide setting"),
    ]

    struct Span { var name: String; var start: Int; var end: Int }

    static func stripComment(_ line: String) -> String { line.components(separatedBy: "//").first ?? line }

    static func spans(of lines: [String]) -> [Span] {
        let decl = try! NSRegularExpression(pattern: #"^\s*(?:@\w+\s+|private\s+|fileprivate\s+|static\s+|nonisolated(?:\(unsafe\))?\s+|final\s+|mutating\s+|public\s+|internal\s+)*func\s+(\w+)"#)
        var out: [Span] = []
        for (i, line) in lines.enumerated() {
            guard let m = decl.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) else { continue }
            let indent = line.prefix { $0 == " " }.count
            var end = i
            let code = stripComment(line).trimmingCharacters(in: .whitespaces)
            if !(code.hasSuffix("}") && code.contains("{")) {
                end = lines.count - 1
                for j in (i + 1)..<max(i + 1, lines.count) {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("}"), l.prefix(while: { $0 == " " }).count == indent { end = j; break }
                }
            }
            out.append(Span(name: String(line[r]), start: i, end: end))
        }
        return out
    }

    /// Violations in one file's text: "File:line `pattern` in `function`: why".
    static func violations(file: String, text: String, allow: Set<String>) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let all = spans(of: lines)
        var out: [String] = []
        for (i, raw) in lines.enumerated() {
            let code = stripComment(raw)
            for (pattern, why) in sensitive where code.contains(pattern) {
                if pattern == "SystemParametersInfoW(", raw.contains("SPI_GET") || code.contains("0x0042") && false { continue }
                if pattern.hasPrefix("WinRegistry."), code.contains("PokeTokenBarSelftest") { continue }  // our own key
                let enclosing = all.filter { $0.start <= i && i <= $0.end }
                let guarded = enclosing.contains { span in lines[span.start...span.end].contains { stripComment($0).contains("onCI") } }
                let name = enclosing.last?.name ?? "(file scope)"
                if guarded || allow.contains("\(file):\(name)") { continue }
                out.append("\(file):\(i + 1) `\(pattern)` in \(name): \(why)")
                break
            }
        }
        return out
    }

    static func allowList(_ url: URL) throws -> Set<String> {
        Set(try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            let parts = t.components(separatedBy: "|")
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }  // an entry needs its reason
            return parts[0].trimmingCharacters(in: .whitespaces)
        })
    }

    func testNoSelftestCallThatTouchesTheUsersPCRunsOffCI() throws {
        let root = SharedSources.sourcesRoot
        let allow = try Self.allowList(SharedSources.testsRoot.appendingPathComponent("selftest-user-pc-allow.txt"))
        var found: [String] = []
        for url in SharedSources.allSwiftFiles(root: root) {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/"), url.lastPathComponent.hasPrefix("WindowsSelftest") || url.lastPathComponent == "WinUIDump.swift" else { continue }
            found += Self.violations(file: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8), allow: allow)
        }
        XCTAssertEqual(found, [], "a selftest call that drives the user's input or changes a system-wide setting must test onCI in its function, or be allow-listed with a reason (Tests/PokeTokenBarTests/selftest-user-pc-allow.txt)")
    }

    func testTheScanCatchesWhatIsNotGuarded() {
        let ungated = """
        enum X {
            static func nudge() {
                _ = SetCursorPos(1, 2)
            }
        }
        """
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: ungated, allow: []).count, 1)
        let gated = ungated.replacingOccurrences(of: "_ = SetCursorPos(1, 2)", with: "guard WindowsSelftest.onCI else { return }\n        _ = SetCursorPos(1, 2)")
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: gated, allow: []), [])
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: ungated, allow: ["WindowsSelftestX.swift:nudge"]), [])
        let comment = ungated.replacingOccurrences(of: "_ = SetCursorPos(1, 2)", with: "// SetCursorPos(1, 2) was here (onCI)")
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: comment, allow: []), [])
        let ownKey = "func clean() {\n    WinRegistry.deleteTree(#\"Software\\PokeTokenBarSelftest\"#)\n}\n"
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: ownKey, allow: []), [])
        let realKey = "func clean() {\n    WinRegistry.deleteValue(runKey, name)\n}\n"
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: realKey, allow: []).count, 1)
        let read = "func get() {\n    _ = SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)\n}\n"
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: read, allow: []), [])
        let set = "func put() {\n    _ = SystemParametersInfoW(0x0043, 0, &hc, 0)\n}\n"
        XCTAssertEqual(Self.violations(file: "WindowsSelftestX.swift", text: set, allow: []).count, 1)
    }
}
