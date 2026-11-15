import XCTest
@testable import PokeTokenBar

/// The parity scan's parts on synthetic input, on both systems (stage 7, D9): the extractor, the loader and each rule.
/// The scan over the real Mac sources is `PopoverParityScanTests` (Mac-side).
final class PopoverParityTests: XCTestCase {
    typealias X = PopoverParityExtractor

    private func code(_ text: String) -> String { String(decoding: X.lex(text).code, as: UTF8.self) }

    // MARK: lexer

    func testTheLexerDropsCommentsAndBlanksStringsButKeepsInterpolations() {
        let text = "let a = \"l.hidden\" // l.comment\n/* l.block */ Text(\"\\(l.shown) x\")\nlet r = #\"raw \\(l.notInterpolated)\"#\n"
        let lexed = X.lex(text)
        let c = String(decoding: lexed.code, as: UTF8.self)
        XCTAssertEqual(lexed.code.count, text.utf8.count, "same length, so offsets line up")
        XCTAssertFalse(c.contains("hidden"))
        XCTAssertFalse(c.contains("comment"))
        XCTAssertFalse(c.contains("block"))
        XCTAssertTrue(c.contains("l.shown"), "code inside \\( ) stays code")
        XCTAssertFalse(c.contains("notInterpolated"), "a raw string's \\( is text")
        XCTAssertEqual(lexed.literals.map(\.body), ["l.hidden", "\\(l.shown) x", "raw \\(l.notInterpolated)"])
        XCTAssertEqual(c.filter { $0 == "\n" }.count, 3, "newlines stay")
    }

    func testTheLexerHandlesMultilineAndNestedStrings() {
        let text = "let m = \"\"\"\n  a \"quote\" \\(f(\"in\")) b\n  \"\"\"\nlet after = 1\n"
        let lexed = X.lex(text)
        let c = String(decoding: lexed.code, as: UTF8.self)
        XCTAssertTrue(c.contains("f("), "nested call in the interpolation")
        XCTAssertTrue(c.contains("let after = 1"), "the multi-line literal ended at its closing quotes")
        XCTAssertTrue(lexed.literals.contains { $0.body == "in" })
    }

    // MARK: declarations

    func testDeclarationsListTypesFunctionsAndComputedVars() {
        let text = """
        func freeFunction() {}
        struct A: View {
            @State private var stored = false
            var observed = 1 { didSet { x() } }
            let constant = 2
            var onClose: () -> Void
            private var l: L { companion.l }
            var body: some View { inner }
            static func helper(_ a: Int) -> String { "" }
            private func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
                func nested() {}
                return c()
            }
            enum Mode { case a, b }
            init(x: Int) {}
        }
        extension A {
            var extra: Int { 1 }
        }
        private extension View {
            func helpIfPresent() -> some View { self }
        }
        protocol P {
            func requirement()
            var value: Int { get }
        }
        """
        let names = X.declarations(in: X.lex(text).code).filter { $0.kind != .extensionBody }.map(\.name)
        XCTAssertEqual(names, ["freeFunction", "A", "A.l", "A.body", "A.helper", "A.row", "A.Mode", "A.extra",
                               "View.helpIfPresent", "P", "P.requirement", "P.value"])
    }

    func testTheEnclosingSymbolIsTheInnermostBody() {
        let text = "struct A {\n    var body: some View { Text(l.x) }\n    func f() { g(l.y) }\n}\n"
        let lexed = X.lex(text)
        let d = X.declarations(in: lexed.code)
        let refs = X.stringReferences(lexed.code, known: ["x", "y"])
        XCTAssertEqual(refs.map { X.enclosing(d, offset: $0.1, file: "F.swift") }, ["F.swift#A.body", "F.swift#A.f"])
    }

    // MARK: references

    func testLMembersComeFromStructAndExtensionsOfL() {
        let members = X.lMembers(in: ["struct L {\n    let lang: AppLanguage\n    var home: String { t(\"홈\") }\n    func plan(_ p: String) -> String { p }\n    static func helper() {}\n    struct Inner { var notAMember: Int { 1 } }\n}\n",
                                      "extension L {\n    var winOnly: String { \"w\" }\n}\nextension LocalReader { var notL: Int { 1 } }\n"])
        XCTAssertEqual(members, ["home", "plan", "winOnly"])
    }

    func testStringReferencesFindEveryReceiverForm() {
        let text = "Text(l.home); Text(store.l.plan(x)); L(.ko).home; L(language).winOnly; \"\\(l.home)\"; x.lunch; l.unknown; self.l"
        let refs = X.stringReferences(X.lex(text).code, known: ["home", "plan", "winOnly"]).map(\.0)
        XCTAssertEqual(refs, ["home", "plan", "home", "winOnly", "home"])
    }

    func testMemberReferencesFollowTheReceiversDeclaredInTheFile() {
        let text = """
        struct V: View {
            @Environment(UsageStore.self) private var store
            @Environment(TeamFeedStore.self) private var feed: TeamFeedStore?
            let companion: CompanionStore
            let species: CompanionStore.DexSpecies
            func f(_ team: TeamSettings) {}
            var body: some View {
                Toggle("", isOn: $store.showTokensInMenu)
                Button { Task { await store.refresh() } } label: {}
                Text(companion.l.home + companion.displayName)
                if let feed, feed.unreadCount > 0 {}
                Text(species.name); team.isReady; other.x
            }
        }
        """
        let refs = Set(X.memberReferences(X.lex(text).code).map(\.0))
        XCTAssertEqual(refs, ["UsageStore.showTokensInMenu", "UsageStore.refresh", "CompanionStore.displayName",
                              "TeamFeedStore.unreadCount", "TeamSettings.isReady"])
    }

    func testSFSymbolsAndUILiterals() {
        let text = """
        Image(systemName: on ? "eye" : "eye.slash"); Label("x", systemImage: "checkmark")
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        Text("Finder"); Button("·") {}; Text("\\(n)px"); SecureField(on ? "••••" : "sk-ant-sid…", text: $t); .help("GitHub")
        print("not shown"); Text(verbatim)
        """
        let lexed = X.lex(text)
        XCTAssertEqual(Set(X.sfSymbols(lexed).map(\.0)), ["eye", "eye.slash", "checkmark", "chevron.down"])
        XCTAssertEqual(Set(X.uiLiterals(lexed).map(\.0)), ["x", "Finder", "\\(n)px", "sk-ant-sid…", "GitHub"])
    }

    func testDefaultsKeysAreResolved() {
        let text = """
        final class Store {
            static let fooKey = "foo"
            var a: Bool { didSet { defaults.set(a, forKey: "a") } }
            func load(d: UserDefaults) {
                _ = d.object(forKey: Self.fooKey)
                let key = Helper.key(for: id)
                defaults.set(1, forKey: key)
                UserDefaults.standard.removeObject(forKey: "b")
                cache.object(forKey: "notADefault")
                UserDefaults.standard.register(defaults: ["Delay": 600, "Other": true])
            }
        }
        """
        XCTAssertEqual(X.defaultsKeys(X.lex(text), file: "S.swift"),
                       ["\"a\"", "Store.fooKey", "Helper.key(for:id)", "\"b\"", "\"Delay\"", "\"Other\""])
    }

    // MARK: loader

    private let entries = """
    # comment
    [entries]
    P1 | 1 | pending T5 | UI/A.swift | Banner | with a pipe
    G10 | - | n/a: no menu bar | UI/A.swift | Menu bar
    A7 | 1 | elsewhere Platform/X.swift: wiring | UI/A.swift | Wiring
    P30 | 1 | done Popover/S.swift | UI/A.swift | State

    [code]
    UI/A.swift | P1
    UI/A.swift#A.banner | P1
    """

    func testTheLoaderReadsEntriesAndRows() throws {
        let inv = try PopoverParity.parse(inventory: entries, strings: "home | P1\n\"Finder\" | P1 | replace: Mac\nold | P1 | replaced: winNew\n",
                                         members: "UsageStore.x | P1 | n/a: no\n", settings: "\"k\" | G10\n", sfSymbols: "eye | P1\r\n",
                                         twins: "UI/A.swift#N | Popover/S.swift#S | PopoverTab=Tab, A=B\n")
        XCTAssertEqual(inv.entries.map(\.id), ["P1", "G10", "A7", "P30"])
        XCTAssertEqual(inv.entry("P1")?.status, .pending(task: 5))
        XCTAssertEqual(inv.entry("P1")?.function, "Banner | with a pipe")
        XCTAssertEqual(inv.entry("G10")?.tier, PopoverParity.Tier.none)
        XCTAssertEqual(inv.entry("A7")?.status, .elsewhere(path: "Platform/X.swift", note: "wiring"))
        XCTAssertEqual(inv.entry("P30")?.status, .done(path: "Popover/S.swift"))
        XCTAssertEqual(inv.code.map(\.name), ["UI/A.swift", "UI/A.swift#A.banner"])
        XCTAssertEqual(inv.strings.map(\.status), [nil, .replace(why: "Mac"), .replaced(by: "winNew")])
        XCTAssertEqual(inv.members.first?.status, .notApplicable(reason: "no"))
        XCTAssertEqual(inv.sfSymbols.map(\.name), ["eye"], "CR tolerated")
        XCTAssertEqual(inv.twins.first?.renames, ["PopoverTab": "Tab", "A": "B"])
    }

    func testTheLoaderRejectsMalformedRows() {
        for bad in ["[entries]\nP1 | 4 | pending T5 | f | x\n", "[entries]\nP1 | 1 | later | f | x\n", "P1 | 1\n", "[code]\nonlyname\n"] {
            XCTAssertThrowsError(try PopoverParity.parse(inventory: bad, strings: "", members: "", settings: "", sfSymbols: "", twins: ""), bad)
        }
        XCTAssertThrowsError(try PopoverParity.parse(inventory: "", strings: "x | P1 | maybe\n", members: "", settings: "", sfSymbols: "", twins: ""))
    }

    /// The real data files load on both systems (Task 3's glyph table reads `sfSymbols` on Windows).
    func testTheRealInventoryLoads() throws {
        let inv = try PopoverParity.load()
        XCTAssertGreaterThan(inv.entries.count, 100)
        XCTAssertGreaterThan(inv.code.count, 500)
        XCTAssertGreaterThan(inv.strings.count, 300)
        XCTAssertTrue(inv.sfSymbols.contains { $0.name == "gearshape" })
        XCTAssertEqual(Set(inv.entries.map(\.id)).count, inv.entries.count)
        print(PopoverParity.summary(inv, missing: 0, stale: 0))
    }

    // MARK: rules

    func testCoverageNamesMissingStaleAndDuplicateRows() {
        let rows = [PopoverParity.Row(name: "a", entry: "P1"), .init(name: "gone", entry: "P1"), .init(name: "a", entry: "P2")]
        let f = PopoverParityRules.coverage(file: "strings.txt", extracted: ["a": ["F#x"], "new": ["F#y"]], rows: rows)
        XCTAssertEqual(f.count, 3)
        XCTAssertTrue(f[0].hasPrefix("strings.txt: `a` has 2 rows"))
        XCTAssertTrue(f[1].hasPrefix("strings.txt: `new` (in F#y) has no row: add `new | <entry id>`"))
        XCTAssertTrue(f[2].hasPrefix("strings.txt: the row `gone` names nothing"))
        XCTAssertEqual(PopoverParityRules.coverage(file: "s", extracted: ["a": []], rows: [.init(name: "a", entry: "P1")]), [])
    }

    func testConsistencyChecksTiersStatusesPathsAndEntries() throws {
        var inv = try PopoverParity.parse(inventory: entries, strings: "x | P9\n", members: "M.y | P1 | replace: nope\n",
                                         settings: "", sfSymbols: "", twins: "")
        inv.entries.append(.init(id: "P1", tier: .one, status: .pending(task: 5), macFiles: ["UI/A.swift"], function: "dup"))
        inv.entries.append(.init(id: "X1", tier: .none, status: .pending(task: 5), macFiles: ["UI/Gone.swift"], function: ""))
        inv.entries.append(.init(id: "X2", tier: .two, status: .notApplicable(reason: "r"), macFiles: [], function: ""))
        inv.entries.append(.init(id: "X3", tier: .two, status: .pending(task: 1), macFiles: [], function: ""))
        let f = PopoverParityRules.consistency(inv, macFiles: ["UI/A.swift"]) { $0 != "Popover/S.swift" }
        let expected = ["the entry P1 is defined 2 times", "X1 has tier - but is not n/a", "X1 names the Mac file UI/Gone.swift",
                        "X2 is n/a but has tier 2", "X3 is pending T1", "P30 points at Popover/S.swift, which does not exist",
                        "`x` points at the entry P9", "`M.y` uses replace:"]
        for e in expected { XCTAssertTrue(f.contains { $0.contains(e) }, "missing finding: \(e)\n" + f.joined(separator: "\n")) }
        XCTAssertEqual(f.count, expected.count, f.joined(separator: "\n"))
    }

    func testDoneEntriesMustBeReferencedOnWindows() throws {
        let inv = try PopoverParity.parse(
            inventory: entries,
            strings: "home | P30\nplan | P30\n\"Finder\" | P30 | replace: Mac\nold | P30 | replaced: winNew\nold2 | P30 | replaced: winMissing\nlater | P1\nnope | P30 | n/a: r\n",
            members: "UsageStore.refresh | P30\nUsageStore.other | P30\nUsageStore.skip | P30 | n/a: r\n",
            settings: "", sfSymbols: "", twins: "")
        let windows = "let a = l.home; store.refresh(); Text(l.winNew)"
        let f = PopoverParityRules.doneEntries(inv, windowsSource: windows, lMembers: ["home", "plan", "winNew", "winMissing"])
        XCTAssertEqual(f.count, 4, f.joined(separator: "\n"))
        XCTAssertTrue(f.contains { $0.contains("never shows `plan`") })
        XCTAssertTrue(f.contains { $0.contains("`\"Finder\"` still says replace:") })
        XCTAssertTrue(f.contains { $0.contains("replaced by `winMissing`, which the Windows popover never shows") })
        XCTAssertTrue(f.contains { $0.contains("never uses `UsageStore.other`") })
        XCTAssertTrue(PopoverParityRules.containsWord("a.refresh()", "refresh"))
        XCTAssertFalse(PopoverParityRules.containsWord("a.refreshNow()", "refresh"))
    }

    func testTwinBodiesCompareWithoutCommentsSpacingAndRenamedTypes() throws {
        let mac = "@MainActor final class Nav {\n    // Korean comment\n    var tab: PopoverTab = .home\n    func reset() { tab = .home }\n}\n"
        let twin = "final class State {\n    var tab:   Tab = .home   /* note */\n    func reset() {\n        tab = .home\n    }\n}\n"
        let inv = try PopoverParity.parse(inventory: "", strings: "", members: "", settings: "", sfSymbols: "",
                                         twins: "M.swift#Nav | S.swift#State | PopoverTab=Tab\n")
        XCTAssertEqual(PopoverParityRules.twins(inv) { $0 == "M.swift" ? mac : twin }, [])
        let changed = mac.replacingOccurrences(of: "func reset() { tab = .home }", with: "func reset() { tab = .bag }")
        let f = PopoverParityRules.twins(inv) { $0 == "M.swift" ? changed : twin }
        XCTAssertEqual(f.count, 1)
        XCTAssertTrue(f[0].contains("S.swift#State no longer matches M.swift#Nav"))
        XCTAssertEqual(PopoverParityRules.normalized("a PopoverTab PopoverTabs", renames: ["PopoverTab": "Tab"]), "a Tab PopoverTabs")
        let literal = PopoverParityRules.body(ofType: "Nav", in: "final class Nav { let s = \"a  b\" }")
        XCTAssertEqual(literal.map { PopoverParityRules.normalized($0, renames: [:]) }, "let s = \"a b\"",
                       "literals are kept (white space inside them collapses like the rest)")
    }

    /// Twins of functions and computed vars (overloads together), renames that read a value, and pinned Mac bodies.
    func testMemberTwinsOverloadsAndPins() throws {
        let mac = """
        struct V: View {
            private func f(_ x: Int) -> String { /* note */ "a\\(x)" }
            private func f(y: Int) -> String { "b" }
            var body: some View { Text("x") }
        }
        extension PaceTier {
            var color: Color { switch self { case .a: return .green } }
            var percentColor: Color { self == .b ? .primary : color }
        }
        """
        let shared = """
        enum S {
            static func f(_ x: Int) -> String { "a\\(x)" }
            static func f(y: Int) -> String { "b" }
            static func paceColor(_ tier: PaceTier) -> Role { switch tier { case .a: return .systemGreen } }
            static func percentColor(_ tier: PaceTier) -> Role { tier == .b ? .primary : paceColor(tier) }
        }
        """
        XCTAssertEqual(PopoverParityRules.body(of: "V.f", in: mac).map { PopoverParityRules.normalized($0, renames: [:]) },
                       "\"a\\(x)\" ¦ \"b\"", "both overloads, in source order")
        XCTAssertNil(PopoverParityRules.body(of: "V.missing", in: mac))
        XCTAssertEqual(PopoverParityRules.pin(""), "cbf29ce484222325", "FNV-1a 64 offset basis")
        XCTAssertEqual(PopoverParityRules.pin("a"), "af63dc4c8601ec8c")
        let bodyPin = PopoverParityRules.pin(PopoverParityRules.normalized(try XCTUnwrap(PopoverParityRules.body(of: "V.body", in: mac)), renames: [:]))
        let rows = """
        M.swift#V.f | S.swift#S.f
        M.swift#PaceTier.color | S.swift#S.paceColor | self=tier, green=systemGreen
        M.swift#PaceTier.percentColor | S.swift#S.percentColor | self=tier, color=paceColor(tier)
        M.swift#V.body | S.swift#S | pin \(bodyPin)

        """
        let inv = try PopoverParity.parse(inventory: "", strings: "", members: "", settings: "", sfSymbols: "", twins: rows)
        XCTAssertEqual(inv.twins.last?.pin, bodyPin)
        XCTAssertEqual(PopoverParityRules.twins(inv) { $0 == "M.swift" ? mac : shared }, [])

        let changed = mac.replacingOccurrences(of: "Text(\"x\")", with: "Text(\"y\")").replacingOccurrences(of: "\"b\"", with: "\"c\"")
        let f = PopoverParityRules.twins(inv) { $0 == "M.swift" ? changed : shared }
        XCTAssertEqual(f.count, 2, f.joined(separator: "\n"))
        XCTAssertTrue(f.contains { $0.contains("S.swift#S.f no longer matches M.swift#V.f") })
        let newPin = PopoverParityRules.pin(PopoverParityRules.normalized(try XCTUnwrap(PopoverParityRules.body(of: "V.body", in: changed)), renames: [:]))
        XCTAssertTrue(f.contains { $0.contains("M.swift#V.body changed since its twin S.swift#S was written (pin \(bodyPin), now \(newPin))") })
        XCTAssertEqual(PopoverParityRules.twins(inv) { $0 == "M.swift" ? mac : "enum T {}" }.count, 4, "a missing twin is named")
        XCTAssertThrowsError(try PopoverParity.parse(inventory: "", strings: "", members: "", settings: "", sfSymbols: "",
                                                     twins: "M.swift#V.body | S.swift#S | pin 12z\n"), "a pin is 16 hex digits")
    }
}
