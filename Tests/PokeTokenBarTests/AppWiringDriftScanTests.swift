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

    // MARK: - the tray's text and its observed values

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    /// The `_ = ...` lines (comments cut) of the `withObservationTracking` block inside `function`.
    static func trackedValues(of function: String, in text: String) -> [String]? {
        guard let start = text.range(of: "func \(function)(") else { return nil }
        let body = text[start.upperBound...]
        guard let end = body.range(of: "} onChange") else { return nil }
        return body[..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
            var t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("_ = ") else { return nil }
            if let c = t.range(of: "//") { t = String(t[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return t
        }
    }

    /// The text of `function`'s braces, whitespace collapsed.
    static func body(of function: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(function)("), let open = text[start.upperBound...].range(of: "{") else { return nil }
        var depth = 1
        var i = open.upperBound
        var out = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { break } }
            out.append(c)
            i = text.index(after: i)
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheTraySummaryIsTheMacMenusSummary() throws {
        let mac = try Self.read("UI/StatusItemMenu.swift")
        let tray = try Self.read("Platform/TrayMenuModel.swift")
        let macBody = try XCTUnwrap(Self.body(of: "summary", in: mac))
        XCTAssertEqual(try XCTUnwrap(Self.body(of: "summary", in: tray)), macBody,
                       "StatusItemMenu.summary changed: copy it into TrayMenuModel.summary")
    }

    func testTheWindowsAppObservesWhatTheMacMenuBarTextReads() throws {
        let mac = try Self.read("PokeTokenBarApp.swift")
        let windows = try Self.read("Platform/Windows/WindowsApp.swift")
        let content = try Self.read("UI/MenuBarContent.swift")
        // The Windows app inlines MenuBarContent.lines (it lives in UI/): the expression must stay the same.
        let lines = try XCTUnwrap(Self.body(of: "lines", in: content))
        XCTAssertTrue(lines.contains("store.menuLines(growthText: store.showGrowthInMenu ? companion.menuGrowthText : nil)"))
        let expression = "store.menuLines(growthText: store.showGrowthInMenu ? companion.menuGrowthText : nil)"
        XCTAssertTrue(windows.contains("_ = \(expression)"), "MenuBarContent.lines changed: update WindowsApp.observeStore")
        let macTracked = try XCTUnwrap(Self.trackedValues(of: "observeStore", in: mac)).filter { !$0.contains("MenuBarContent.lines") }
        let winTracked = try XCTUnwrap(Self.trackedValues(of: "observeStore", in: windows)).filter { !$0.contains("menuLines(") }
        XCTAssertFalse(macTracked.isEmpty)
        XCTAssertEqual(winTracked, macTracked, "AppDelegate.observeStore tracks different values than the Windows app")
    }

    func testTheTrayIconObservesTheMacMenuSpriteKeys() throws {
        let mac = try Self.read("PokeTokenBarApp.swift")
        let tray = try Self.read("Platform/Windows/WinTrayHost.swift")
        let macTracked = try XCTUnwrap(Self.trackedValues(of: "observeCompanionSprite", in: mac))
        let winTracked = try XCTUnwrap(Self.trackedValues(of: "observeCompanionSprite", in: tray))
        XCTAssertFalse(winTracked.isEmpty)
        // The animation setting (`store.animationQuality`) is the only Mac key the static icon leaves out.
        XCTAssertEqual(winTracked, macTracked.filter { $0 != "_ = store.animationQuality" },
                       "AppDelegate.observeCompanionSprite tracks different keys than the tray icon")
    }

    // MARK: - the team runtime

    /// The labels of the first `call`'s arguments, in order (`settings`, `companion`, ...).
    static func labels(of call: String, in text: String) -> [String]? {
        arguments(of: call, in: text)?.map { $0.components(separatedBy: ":").first ?? $0 }
    }

    /// The Windows app builds the team runtime the way `AppDelegate` does: the same `TeamRuntime` and `TeamNotifier`
    /// arguments (the transport and the poster are the platform's), the same settings and companion, the notifier set
    /// before `teamRuntime.start()`. A new argument or a new step on the Mac fails here until Windows has it too.
    func testTheWindowsAppBuildsTheTeamRuntimeLikeTheMac() throws {
        let mac = try Self.read("PokeTokenBarApp.swift")
        let windows = try Self.read("Platform/Windows/WindowsApp.swift")
        for call in ["TeamRuntime(", "TeamNotifier("] {
            let macLabels = try XCTUnwrap(Self.labels(of: call, in: mac), "PokeTokenBarApp.swift has no \(call)")
            XCTAssertEqual(Self.labels(of: call, in: windows), macLabels, "\(call) drifted from AppDelegate")
        }
        let macRuntime = try XCTUnwrap(Self.arguments(of: "TeamRuntime(", in: mac))
        let winRuntime = try XCTUnwrap(Self.arguments(of: "TeamRuntime(", in: windows))
        XCTAssertEqual(Array(winRuntime.prefix(2)), Array(macRuntime.prefix(2)), "the settings and the companion")
        XCTAssertEqual(Self.arguments(of: "TeamNotifier(", in: windows)?.first, Self.arguments(of: "TeamNotifier(", in: mac)?.first)
        for (name, text) in [("mac", mac), ("windows", windows)] {
            let notifier = try XCTUnwrap(text.range(of: "teamRuntime.notifier = TeamNotifier("), name)
            let start = try XCTUnwrap(text.range(of: "teamRuntime.start()"), name)
            XCTAssertLessThan(notifier.lowerBound, start.lowerBound, "\(name): the notifier is set before the runtime starts")
        }
    }

    func testTheLabelScanSeesANewArgument() {
        XCTAssertEqual(Self.labels(of: "TeamRuntime(", in: "TeamRuntime(settings: s, companion: c, transport: T())"),
                       ["settings", "companion", "transport"])
        XCTAssertNotEqual(Self.labels(of: "TeamRuntime(", in: "TeamRuntime(settings: s, companion: c, transport: T(), feed: f)"),
                          Self.labels(of: "TeamRuntime(", in: "TeamRuntime(settings: s, companion: c, transport: T())"))
    }

    func testTheTrackedValueScanSeesADroppedKey() {
        let a = "func observeStore() {\n withObservationTracking {\n _ = a // x\n _ = b\n } onChange: {}"
        XCTAssertEqual(Self.trackedValues(of: "observeStore", in: a), ["_ = a", "_ = b"])
        XCTAssertNotEqual(Self.trackedValues(of: "observeStore", in: a.replacingOccurrences(of: " _ = b\n", with: "")),
                          Self.trackedValues(of: "observeStore", in: a))
    }
}
