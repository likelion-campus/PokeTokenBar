import XCTest

/// Stage 7, D9: the Windows popover is a second copy of the Mac's, so nothing may reach the Mac popover without a row in
/// `Tests/PopoverParity/`. This scan extracts the Mac popover's files, symbols, strings, model members, settings and SF
/// Symbols (`PopoverParityExtractor`) and fails, naming the row to add or delete, when the inventory does not match.
/// It also checks the entries, the shipped entries' Windows references and the twins (`PopoverParityRules`), and prints
/// the `PARITY:` counts. Mac-side like the other source scans: the release gate runs it, and upstream-sync merges must
/// pass it.
final class PopoverParityScanTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let sources = root.appendingPathComponent("Sources/PokeTokenBar")

    /// Every Swift file of the Mac popover: `UI/`, the team section, the app delegate and its outside-click monitor.
    static func popoverFiles() throws -> [String] {
        let ui = try FileManager.default.contentsOfDirectory(atPath: sources.appendingPathComponent("UI").path)
            .filter { $0.hasSuffix(".swift") }.sorted().map { "UI/" + $0 }
        return ui + ["Team/UI/TeamSettingsSection.swift", "PokeTokenBarApp.swift", "OutsideClickMonitor.swift"]
    }

    static let storeFiles = ["Core/UsageStore.swift", "Core/CompanionStore.swift", "Team/TeamSettings.swift", "Core/UpdateChecker.swift"]

    /// Where the Windows popover lives: what a shipped entry's strings and members must be found in.
    static let windowsPopoverRoots = ["Popover", "Platform/Windows/Popover"]
    static let windowsPopoverFiles = ["Platform/TrayMenuModel.swift", "Platform/WindowsPopoverStrings.swift"]

    /// A file relative to `Sources/PokeTokenBar`, or to the repository for `Tests/…` (a twin's verbatim Mac copy).
    static func read(_ relative: String) -> String? {
        let url = relative.hasPrefix("Tests/") ? root.appendingPathComponent(relative) : sources.appendingPathComponent(relative)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Every source file that declares `struct L` or an `extension L`.
    static func lSources() -> [String] {
        SharedSources.allSwiftFiles(root: sources).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("struct L ") || text.contains("extension L ") || text.contains("extension L{") else { return nil }
            return text
        }
    }

    static func windowsSource() -> String {
        var files = windowsPopoverFiles.compactMap(read)
        for r in windowsPopoverRoots {
            files += SharedSources.allSwiftFiles(root: sources.appendingPathComponent(r)).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return files.joined(separator: "\n")
    }

    struct Scan {
        var popover: [(String, String)]
        var lSources: [String]
        var stores: [(String, String)]
    }

    static func liveScan() throws -> Scan {
        let popover = try popoverFiles().map { ($0, try XCTUnwrap(read($0), $0)) }
        return Scan(popover: popover, lSources: lSources(), stores: try storeFiles.map { ($0, try XCTUnwrap(read($0), $0)) })
    }

    /// Rules 1 and 2 over every data file.
    static func coverage(_ scan: Scan, _ inventory: PopoverParity.Inventory) -> [String] {
        let x = PopoverParityExtractor.extract(popover: scan.popover, lSources: scan.lSources, stores: scan.stores)
        var code: [String: Set<String>] = [:]
        for f in x.files { code[f] = [f] }
        for s in x.symbols { code[s] = [s] }
        return PopoverParityRules.coverage(file: "inventory.txt [code]", extracted: code, rows: inventory.code)
            + PopoverParityRules.coverage(file: "strings.txt", extracted: x.strings, rows: inventory.strings)
            + PopoverParityRules.coverage(file: "members.txt", extracted: x.members, rows: inventory.members)
            + PopoverParityRules.coverage(file: "settings.txt", extracted: x.settings, rows: inventory.settings)
            + PopoverParityRules.coverage(file: "sf-symbols.txt", extracted: x.sfSymbols, rows: inventory.sfSymbols)
    }

    func testTheInventoryCoversTheMacPopover() throws {
        let inventory = try PopoverParity.load()
        let findings = Self.coverage(try Self.liveScan(), inventory)
        let stale = findings.filter { $0.contains("names nothing") }.count
        print(PopoverParity.summary(inventory, missing: findings.count - stale, stale: stale))
        XCTAssertEqual(findings, [], "\n" + findings.joined(separator: "\n"))
    }

    func testTheInventoryIsWellFormed() throws {
        let inventory = try PopoverParity.load()
        let findings = PopoverParityRules.consistency(inventory, macFiles: Set(try Self.popoverFiles())) { path in
            FileManager.default.fileExists(atPath: Self.sources.appendingPathComponent(path).path)
        }
        XCTAssertEqual(findings, [], "\n" + findings.joined(separator: "\n"))
    }

    func testShippedEntriesAreOnWindows() throws {
        let inventory = try PopoverParity.load()
        let findings = PopoverParityRules.doneEntries(inventory, windowsSource: Self.windowsSource(),
                                                     lMembers: PopoverParityExtractor.lMembers(in: Self.lSources()))
        XCTAssertEqual(findings, [], "\n" + findings.joined(separator: "\n"))
    }

    func testTwinsMatchTheirOriginals() throws {
        let inventory = try PopoverParity.load()
        XCTAssertFalse(inventory.twins.isEmpty)
        let findings = PopoverParityRules.twins(inventory, read: Self.read)
        XCTAssertEqual(findings, [], "\n" + findings.joined(separator: "\n"))
    }

    // MARK: - the scan's teeth, on the real sources edited in memory

    /// A new view, a new string, a new setting, a new model member and a new SF Symbol in the Mac popover each fail the
    /// scan with a message that names them; the untouched sources pass (the test above).
    func testTheScanNamesWhatTheMacGains() throws {
        var scan = try Self.liveScan()
        let settings = try XCTUnwrap(scan.popover.firstIndex { $0.0 == "UI/SettingsView.swift" })
        scan.popover[settings].1 += """

            struct ParityProbeSection: View {
                @Environment(UsageStore.self) private var store
                var body: some View {
                    Toggle(l.parityProbeLabel, isOn: .constant(store.parityProbeMember))
                    Image(systemName: "parity.probe")
                }
            }
            """
        scan.lSources.append("extension L {\n    var parityProbeLabel: String { \"probe\" }\n}\n")
        let usage = try XCTUnwrap(scan.stores.firstIndex { $0.0 == "Core/UsageStore.swift" })
        scan.stores[usage].1 += "\nextension UsageStore {\n    func parityProbe() { defaults.set(true, forKey: \"parityProbeSetting\") }\n}\n"
        let findings = Self.coverage(scan, try PopoverParity.load())
        print("PARITY-TEETH new:\n" + findings.joined(separator: "\n"))
        let expected = ["inventory.txt [code]: `UI/SettingsView.swift#ParityProbeSection` (",
                        "inventory.txt [code]: `UI/SettingsView.swift#ParityProbeSection.body` (",
                        "strings.txt: `parityProbeLabel` (in UI/SettingsView.swift#ParityProbeSection.body) has no row",
                        "members.txt: `UsageStore.parityProbeMember` (in UI/SettingsView.swift#ParityProbeSection.body) has no row",
                        "settings.txt: `\"parityProbeSetting\"` (in Core/UsageStore.swift) has no row",
                        "sf-symbols.txt: `parity.probe` (in UI/SettingsView.swift#ParityProbeSection.body) has no row"]
        XCTAssertEqual(findings.count, expected.count, findings.joined(separator: "\n"))
        for prefix in expected {
            XCTAssertTrue(findings.contains { $0.hasPrefix(prefix) }, "no finding starts with \(prefix)")
        }
    }

    /// A row whose Mac symbol is gone (renamed here) is stale, and the new name is missing.
    func testTheScanNamesAStaleRow() throws {
        var scan = try Self.liveScan()
        let popover = try XCTUnwrap(scan.popover.firstIndex { $0.0 == "UI/PopoverView.swift" })
        XCTAssertTrue(scan.popover[popover].1.contains("private func statusColor("))
        scan.popover[popover].1 = scan.popover[popover].1.replacingOccurrences(of: "private func statusColor(", with: "private func statusColour(")
        let findings = Self.coverage(scan, try PopoverParity.load())
        print("PARITY-TEETH stale:\n" + findings.joined(separator: "\n"))
        XCTAssertEqual(findings.count, 2, findings.joined(separator: "\n"))
        XCTAssertTrue(findings.contains { $0.hasPrefix("inventory.txt [code]: the row `UI/PopoverView.swift#PopoverView.statusColor` names nothing") })
        XCTAssertTrue(findings.contains { $0.hasPrefix("inventory.txt [code]: `UI/PopoverView.swift#PopoverView.statusColour` (") })
    }

    /// A Mac change to a twinned type fails until the twin has it too.
    func testTheScanNamesAChangedTwin() throws {
        let inventory = try PopoverParity.load()
        let findings = PopoverParityRules.twins(inventory) { path in
            guard let text = Self.read(path) else { return nil }
            return path == "UI/PopoverView.swift" ? text.replacingOccurrences(of: "        tab = .home\n    }", with: "        tab = .shop\n    }") : text
        }
        print("PARITY-TEETH twin:\n" + findings.joined(separator: "\n"))
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings.first?.hasPrefix("twins.txt: Popover/PopoverState.swift#PopoverState no longer matches UI/PopoverView.swift#PopoverNavigation") == true)
    }

    /// A Mac change to a view body rebuilt as values (pinned) or to a private helper copied into the Mac test fails until
    /// the twin has it too; the finding names the new pin.
    func testTheScanNamesAChangedViewBodyAndAChangedPrivateHelper() throws {
        let inventory = try PopoverParity.load()
        let findings = PopoverParityRules.twins(inventory) { path in
            guard let text = Self.read(path) else { return nil }
            guard path == "UI/PopoverView.swift" else { return text }
            return text.replacingOccurrences(of: "Text(name).font(.callout)", with: "Text(name).font(.body)")
                .replacingOccurrences(of: "return store.limitDisplayMode == .remaining ? l.percentRemaining(text) : text",
                                      with: "return text")
        }
        print("PARITY-TEETH view body and helper:\n" + findings.joined(separator: "\n"))
        XCTAssertEqual(findings.count, 2, findings.joined(separator: "\n"))
        XCTAssertTrue(findings.contains { $0.hasPrefix("twins.txt: UI/PopoverView.swift#PopoverView.quotaRow changed since its twin Popover/LimitsModel.swift#LimitsBuilder.quotaRow was written (pin ") })
        XCTAssertTrue(findings.contains { $0.hasPrefix("twins.txt: Tests/PokeTokenBarTests/PopoverTwinEquivalenceTests+Mac.swift#MacPopoverOracle.limitPercentText no longer matches UI/PopoverView.swift#PopoverView.limitPercentText") })
    }
}
