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

    // MARK: - the plaza (stage 6 Task 5)

    /// The Windows app builds the plaza controller with the Mac's `PlazaWindowController(...)` arguments (the preferences'
    /// store is the team settings' syncing one, the store the Mac's `PlazaPreferences()` default reads), hands it to the
    /// runtime and the notifier as the Mac does, observes the same values for it, and opens it only through the Mac's guard.
    func testTheWindowsAppBuildsThePlazaLikeTheMac() throws {
        let mac = try Self.read("PokeTokenBarApp.swift")
        let windows = try Self.read("Platform/Windows/WindowsApp.swift")
        let macArgs = try XCTUnwrap(Self.arguments(of: "PlazaWindowController(", in: mac), "PokeTokenBarApp.swift has no PlazaWindowController(")
        let winArgs = try XCTUnwrap(Self.arguments(of: "PlazaWindowController(", in: windows), "WindowsApp.swift has no PlazaWindowController(")
        XCTAssertEqual(Self.labels(of: "PlazaWindowController(", in: windows), Self.labels(of: "PlazaWindowController(", in: mac),
                       "PlazaWindowController( drifted from AppDelegate")
        XCTAssertEqual(winArgs.filter { !$0.hasPrefix("preferences:") }, macArgs.filter { !$0.hasPrefix("preferences:") },
                       "an argument of PlazaWindowController( differs from AppDelegate's; copy it into WindowsApp.makePlaza")
        XCTAssertEqual(macArgs.first, "preferences: PlazaPreferences()")
        XCTAssertEqual(winArgs.first, "preferences: PlazaPreferences(defaults: teamSettingsDefaults)")
        let macNotifier = try XCTUnwrap(Self.arguments(of: "TeamNotifier(", in: mac))
        XCTAssertEqual(Self.arguments(of: "TeamNotifier(", in: windows)?.suffix(2), macNotifier.suffix(2),
                       "isPlazaFrontmost / showInPlaza differ from AppDelegate's")
        XCTAssertTrue(windows.contains("plaza = PlazaWindowController("), "WindowsApp.makePlaza builds the controller")
        for (name, text) in [("mac", mac), ("windows", windows)] {
            // The Mac builds it inline; Windows in makePlaza(), called from startTeam.
            let made = try XCTUnwrap(text.range(of: name == "mac" ? "plaza = PlazaWindowController(" : "        makePlaza()\n"), name)
            let handed = try XCTUnwrap(text.range(of: "teamRuntime.plaza = plaza"), name)
            let notifier = try XCTUnwrap(text.range(of: "teamRuntime.notifier = TeamNotifier("), name)
            XCTAssertLessThan(made.lowerBound, notifier.lowerBound, "\(name): the plaza exists before the notifier reads it")
            XCTAssertLessThan(handed.lowerBound, notifier.lowerBound, "\(name): the runtime gets the plaza before the notifier")
            XCTAssertTrue(text.contains("if CommandLine.arguments.contains(\"--open-plaza\") { openPlaza() }")
                          || text.contains("if arguments.contains(\"--open-plaza\") { openPlaza() }"), "\(name): --open-plaza")
        }
        for function in ["observePlaza", "observePlazaNickname", "observePlazaTeamName", "observePlazaRoster"] {
            let m = try XCTUnwrap(Self.trackedValues(of: function, in: mac), "AppDelegate has no \(function)")
            XCTAssertFalse(m.isEmpty, function)
            XCTAssertEqual(Self.trackedValues(of: function, in: windows), m, "\(function) tracks different values on Windows")
            let call = "\(function)()\n"
            XCTAssertTrue(windows.contains("        " + call), "WindowsApp.launch does not start \(function)")
        }
        let open = try XCTUnwrap(Self.body(of: "openPlaza", in: windows))
        XCTAssertTrue(open.hasPrefix("guard teamSettings.isReady else { return }"), "the Mac's guard comes first: \(open)")
        XCTAssertTrue(open.contains("plaza.show()"))
        XCTAssertTrue(try XCTUnwrap(Self.body(of: "openPlaza", in: mac)).contains("guard teamSettings.isReady else { return }"))
    }

    /// The tray's plaza entry is the Mac status menu's: the same title expression and the same "team ready" condition.
    func testTheTrayPlazaEntryIsTheMacMenus() throws {
        let menu = try Self.read("UI/StatusItemMenu.swift")
        let tray = try Self.read("Platform/TrayMenuModel.swift")
        let mac = try Self.read("PokeTokenBarApp.swift")
        let windows = try Self.read("Platform/Windows/WindowsApp.swift")
        XCTAssertTrue(menu.contains(#"l.plazaOpen + "…" + (plazaUnread > 0 ? " (\(plazaUnread))" : "")"#), "StatusItemMenu's plaza title changed")
        XCTAssertTrue(tray.contains(#"l.plazaOpen + "…" + (unread > 0 ? " (\(unread))" : "")"#), "TrayMenuModel.plazaTitle drifted")
        XCTAssertTrue(mac.contains("plazaAvailable: teamSettings.isReady,"))
        XCTAssertTrue(mac.contains("plazaUnread: teamSettings.isReady ? teamRuntime.feed.unreadCount : 0)"))
        XCTAssertTrue(windows.contains("tray.plazaUnread = { settings.isReady ? feed.unreadCount : nil }"))
    }

    // MARK: - the tray menu's actions (stage 7 Task 4)

    /// The `case` names inside the braces of `declaration` (`enum Action`), comments cut.
    static func cases(of declaration: String, in text: String) -> Set<String>? {
        guard let start = text.range(of: declaration), let open = text[start.upperBound...].range(of: "{") else { return nil }
        var depth = 1
        var i = open.upperBound
        var body = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { break } }
            body.append(c)
            i = text.index(after: i)
        }
        var out = Set<String>()
        for line in body.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if let c = t.range(of: "//") { t = String(t[..<c.lowerBound]) }
            guard t.hasPrefix("case ") else { continue }
            for name in t.dropFirst(5).split(separator: ",") {
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { out.insert(String(n.prefix { $0.isLetter || $0.isNumber || $0 == "_" })) }
            }
        }
        return out
    }

    /// What the Mac status menu does that the tray does not yet, and the tray's own Windows entries. Everything else must be in
    /// both: a new Mac menu action fails here until the tray has it or this list says why not. (The Pokédex came with stage 7
    /// Task 20, the floating pet's entry with Task 22.)
    static let macMenuOnly: Set<String> = []
    static let trayOnly: Set<String> = ["none", "toggleLaunchAtLogin", "openLogFolder", "openRelease"]

    func testTheTrayMenuActionsAreTheMacMenus() throws {
        let menu = try Self.read("UI/StatusItemMenu.swift")
        let tray = try Self.read("Platform/TrayMenuModel.swift")
        let mac = try XCTUnwrap(Self.cases(of: "enum Action", in: menu), "StatusItemMenu has no enum Action")
        let win = try XCTUnwrap(Self.cases(of: "enum Action", in: tray), "TrayMenuModel has no enum Action")
        XCTAssertTrue(mac.isSuperset(of: Self.macMenuOnly), "an allow-listed Mac action is gone: \(Self.macMenuOnly.subtracting(mac))")
        XCTAssertEqual(win.subtracting(Self.trayOnly), mac.subtracting(Self.macMenuOnly),
                       "the tray's actions differ from StatusItemMenu.Action: Mac only \(mac.subtracting(win).subtracting(Self.macMenuOnly)), "
                       + "tray only \(win.subtracting(mac).subtracting(Self.trayOnly))")
        // The two entries Task 4 added, with the Mac's titles and check mark.
        XCTAssertTrue(menu.contains(#"Entry(title: l.settings + "…", keyEquivalent: ",", action: .openSettings)"#), "StatusItemMenu's Settings… changed")
        XCTAssertTrue(tray.contains(#"Item(title: l.settings + "…", enabled: true, checked: false, action: .openSettings)"#), "TrayMenuModel's Settings… drifted")
        // Task 20: the Pokédex entry, the Mac's title, and what it does (the popover on the representative's Pokédex page).
        XCTAssertTrue(menu.contains(#"Entry(title: l.dexTitle, keyEquivalent: "d", action: .openDex)"#), "StatusItemMenu's Pokédex entry changed")
        XCTAssertTrue(tray.contains("Item(title: l.dexTitle, enabled: true, checked: false, action: .openDex)"), "TrayMenuModel's Pokédex entry drifted")
        XCTAssertTrue(try Self.read("PokeTokenBarApp.swift").contains("case .openDex: showPopover { $0.openRepresentativeDex() }"))
        XCTAssertTrue(try Self.read("Platform/Windows/WindowsApp.swift").contains("present(.trayMenu) { $0.openRepresentativeDex() }"),
                      "the tray's Pokédex opens the popover on the Pokédex, as the Mac's")
        XCTAssertTrue(menu.contains("Entry(title: l.backViewLabel, keyEquivalent: \"\", action: .toggleBackView, isChecked: alwaysFacesBack)"),
                      "StatusItemMenu's Back view changed")
        XCTAssertTrue(tray.contains("Item(title: l.backViewLabel, enabled: true, checked: alwaysFacesBack, action: .toggleBackView)"),
                      "TrayMenuModel's Back view drifted")
        // What they do: the Mac's handleStatusMenu and the tray host's perform.
        let mac2 = try Self.read("PokeTokenBarApp.swift")
        let host = try Self.read("Platform/Windows/WinTrayHost.swift")
        XCTAssertTrue(mac2.contains("case .toggleBackView: store.alwaysFacesBack.toggle()"))
        XCTAssertTrue(host.contains("case .toggleBackView:\n            store.alwaysFacesBack.toggle()"), "the tray's Back view does what the Mac's does")
        XCTAssertTrue(mac2.contains("case .openSettings: showPopover { $0.showSettings = true }"))
        // Stage 7 Task 22: the floating pet's entry, its titles and what it does.
        XCTAssertTrue(menu.contains("Entry(title: floatingPetEnabled ? l.floatingPetHideLabel : l.floatingPetEnableLabel,\n                  keyEquivalent: \"\", action: .toggleFloatingPet)"),
                      "StatusItemMenu's floating pet entry changed")
        XCTAssertTrue(tray.contains("Item(title: floatingPetEnabled ? l.floatingPetHideLabel : l.floatingPetEnableLabel, enabled: true, checked: false,\n                             action: .toggleFloatingPet)"),
                      "TrayMenuModel's floating pet entry drifted")
        XCTAssertTrue(mac2.contains("case .toggleFloatingPet: store.floatingPetEnabled.toggle()"))
        XCTAssertTrue(host.contains("case .toggleFloatingPet:  // stage 7 Task 22\n            store.floatingPetEnabled.toggle()"), "the tray's pet entry does what the Mac's does")
        XCTAssertTrue(try Self.read("Platform/Windows/WindowsApp.swift").contains("present(.trayMenu) { $0.showSettings = true }"),
                      "the tray's Settings… opens the popover on Settings, as the Mac's")
    }

    func testTheActionScanSeesANewCase() {
        let text = "enum Action: Equatable {\n    case refresh, openDex // the Pokédex\n    case quit\n}\nstruct Entry { case nope }"
        XCTAssertEqual(Self.cases(of: "enum Action", in: text), ["refresh", "openDex", "quit"])
        XCTAssertEqual(Self.cases(of: "enum Action", in: "enum Action { case a(Int), b }"), ["a", "b"])
        XCTAssertNotEqual(Self.cases(of: "enum Action", in: text.replacingOccurrences(of: "case quit", with: "case quit, openRecap")),
                          Self.cases(of: "enum Action", in: text))
        XCTAssertNil(Self.cases(of: "enum Action", in: "enum Other {}"))
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
