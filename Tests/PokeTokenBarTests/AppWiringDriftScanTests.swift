import XCTest

/// `AppWiring` (the Windows app's companion feed) is a copy of two methods of the Mac's `AppDelegate`, which stays
/// as it is. An upstream change to the Mac copy must reach the Windows one: this compares the arguments of the
/// companion calls in both files.
final class AppWiringDriftScanTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PokeTokenBar")

    /// The arguments (`label: value`, whitespace collapsed) of the first `call` in `text`; nil when there is none.
    static func arguments(of call: String, in text: String) -> [String]? {
        guard let start = text.range(of: call) else { return nil }
        var depth = 1
        var current = ""
        var args: [String] = []
        var i = start.upperBound
        while i < text.endIndex {
            let c = text[i]
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" {
                depth -= 1
                if depth == 0 { args.append(current); break }
            }
            if c == ",", depth == 1 { args.append(current); current = "" } else { current.append(c) }
            i = text.index(after: i)
        }
        return args.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
    }

    func testAppWiringPassesWhatTheMacDelegatePasses() throws {
        let mac = try String(contentsOf: Self.sources.appendingPathComponent("PokeTokenBarApp.swift"), encoding: .utf8)
        let windows = try String(contentsOf: Self.sources.appendingPathComponent("Platform/AppWiring.swift"), encoding: .utf8)
        for call in ["companion.update(", "companion.grantCandies("] {
            let macArgs = try XCTUnwrap(Self.arguments(of: call, in: mac), "PokeTokenBarApp.swift has no \(call)")
            let windowsArgs = try XCTUnwrap(Self.arguments(of: call, in: windows), "AppWiring.swift has no \(call)")
            XCTAssertFalse(macArgs.isEmpty, call)
            XCTAssertEqual(windowsArgs, macArgs, "\(call) drifted from AppDelegate; copy the Mac's arguments into AppWiring")
        }
        let mirror = "companion.alwaysFacesBack = store.alwaysFacesBack"
        XCTAssertTrue(mac.contains(mirror))
        XCTAssertTrue(windows.contains(mirror), "AppWiring.updateCompanion lost the alwaysFacesBack mirror")
    }

    func testTheDriftScanSeesADroppedLabel() {
        let mac = "companion.update(\n    a: store.a,\n    b: store.b(x: 1))"
        XCTAssertEqual(Self.arguments(of: "companion.update(", in: mac), ["a: store.a", "b: store.b(x: 1)"])
        XCTAssertNotEqual(Self.arguments(of: "companion.update(", in: "companion.update(a: store.a)"),
                          Self.arguments(of: "companion.update(", in: mac))
        XCTAssertNil(Self.arguments(of: "companion.update(", in: "companion.other()"))
    }
}
