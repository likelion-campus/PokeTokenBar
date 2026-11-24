import XCTest

/// `WPARAM` is an unsigned 64-bit value and `LPARAM` a signed one, and another process of the same user can post or send any bits to
/// our windows (`PostMessageW(sink, WM_KEYDOWN, 1 << 63, 0)`). `Int(wParam)` then traps in the hook or the window procedure and ends
/// the app (the #270 wake-trace crash was this; the 2026-11 audit found five more sites). Under `Platform/Windows/**` a message
/// parameter is converted only with `truncatingIfNeeded`/`bitPattern`/`exactly`/`clamping`, or after a mask.
final class WindowsMessageParameterScanTests: XCTestCase {
    /// Integer types that trap on an out-of-range `UInt` (`WPARAM`) or `Int` (`LPARAM`) value.
    private static let wParamTargets: Set<String> = ["Int", "Int64", "Int32", "Int16", "Int8", "UInt32", "UInt16", "UInt8", "DWORD", "UINT", "WORD", "BYTE"]
    private static let lParamTargets: Set<String> = ["UInt", "UInt64", "Int32", "Int16", "Int8", "UInt32", "UInt16", "UInt8", "DWORD", "UINT", "WORD", "BYTE"]
    private static let safeMarkers = ["truncatingIfNeeded", "bitPattern", "exactly", "clamping", "& 0x", "&0x"]
    private static let callRegex = try! NSRegularExpression(pattern: #"\b([A-Za-z0-9]+)\("#)

    /// "File:line `Type(argument)`" for each trapping conversion of a window-message parameter in `text`.
    static func violations(file: String, text: String) -> [String] {
        var out: [String] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.components(separatedBy: "//").first ?? raw
            let chars = Array(line)
            for m in callRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let typeRange = Range(m.range(at: 1), in: line), let open = Range(m.range, in: line)?.upperBound else { continue }
                let type = String(line[typeRange])
                guard wParamTargets.contains(type) || lParamTargets.contains(type) else { continue }
                var depth = 1
                var j = line.distance(from: line.startIndex, to: open)
                let begin = j
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { continue }
                let argument = String(chars[begin..<(j - 1)])
                guard !safeMarkers.contains(where: { argument.contains($0) }) else { continue }
                let words = argument.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
                let wide = words.contains { $0.lowercased() == "wparam" } && wParamTargets.contains(type)
                let signed = words.contains { $0.lowercased() == "lparam" } && lParamTargets.contains(type)
                if wide || signed { out.append("\(file):\(i + 1) `\(type)(\(argument))` traps on a message parameter's high bits; use \(type)(truncatingIfNeeded: …)") }
            }
        }
        return out
    }

    func testNoTrappingConversionOfAWindowMessageParameter() throws {
        let root = SharedSources.sourcesRoot
        var found: [String] = []
        for url in SharedSources.allSwiftFiles(root: root) {
            let rel = SharedSources.relativePath(url, root: root)
            guard rel.hasPrefix("Platform/Windows/") else { continue }
            found += Self.violations(file: rel, text: try String(contentsOf: url, encoding: .utf8))
        }
        XCTAssertEqual(found, [])
    }

    func testTheScanCatchesWhatTraps() {
        for bad in ["let v = Int(wParam)", "f(vk: Int(m.pointee.wParam))", "[2, 4].contains(Int(wParam))", "let n = UInt32(wParam)",
                    "let d = DWORD(wParam)", "let i = Int32(lParam)", "let u = UInt(lParam)", "let q = UInt32(lParam >> 16)"] {
            XCTAssertEqual(Self.violations(file: "X.swift", text: bad).count, 1, bad)
        }
        for fine in ["let v = Int(truncatingIfNeeded: wParam)", "let v = Int(bitPattern: wParam)", "let v = UInt32(wParam & 0xFFFF)",
                     "let p = UnsafeRawPointer(bitPattern: Int(lParam))", "let u = UInt(wParam)", "let w = UInt64(wParam)",
                     "let v = Int(count)  // Int(wParam) in a comment", "let h = HDC(bitPattern: UInt(wParam))",
                     "let s = Int16(truncatingIfNeeded: lParam >> 16)"] {
            XCTAssertEqual(Self.violations(file: "X.swift", text: fine), [], fine)
        }
    }
}
