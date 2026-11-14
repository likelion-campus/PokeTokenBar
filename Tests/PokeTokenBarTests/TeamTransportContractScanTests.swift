import XCTest

/// Keeps the transport contract honest: every scenario has a wrapper per transport, and the Windows transport
/// goes through the shared rules instead of re-implementing them.
final class TeamTransportContractScanTests: XCTestCase {
    /// Flipped to `true` by the task that adds the Windows transport and its `WindowsTransportContractTests.swift`.
    static let windowsWrapperRequired = false

    private static let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let windowsTransport = testsRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PokeTokenBar/Platform/Windows/Team/WindowsTeamTransport.swift")

    static func scenarioNames(in contract: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"static func (\w+)<H: TeamTransportHarness>"#)
        return regex.matches(in: contract, range: NSRange(contract.startIndex..., in: contract)).compactMap {
            Range($0.range(at: 1), in: contract).map { String(contract[$0]) }
        }
    }

    static func missingWrappers(names: [String], in wrappers: String) -> [String] {
        names.filter { !wrappers.contains("TeamTransportContract.\($0)(") }
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
    }

    static func sourceViolations(in source: String) -> [String] {
        let text = code(source)
        var out: [String] = []
        for needed in ["TeamLinkReceiver", "admitsInbound", "dialRoom"] where !text.contains(needed) {
            out.append("must use \(needed)")
        }
        for banned in ["FrameDecoder", "TeamTokenBucket"] where text.contains(banned) {
            out.append("must not use \(banned) directly (go through TeamLinkReceiver)")
        }
        return out
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testEveryScenarioHasAWrapperPerTransport() throws {
        let names = Self.scenarioNames(in: try read(Self.testsRoot.appendingPathComponent("TeamTransportContract.swift")))
        XCTAssertGreaterThanOrEqual(names.count, 28)
        XCTAssertEqual(Set(names).count, names.count)
        // The session scenario is wrapped in TeamSessionLoopbackTests, the rest in TeamTransportTests.
        let mac = try read(Self.testsRoot.appendingPathComponent("TeamTransportTests.swift"))
            + (try read(Self.testsRoot.appendingPathComponent("TeamSessionLoopbackTests.swift")))
        XCTAssertEqual(Self.missingWrappers(names: names, in: mac), [], "Mac wrappers")
        if Self.windowsWrapperRequired {
            let windows = try read(Self.testsRoot.appendingPathComponent("WindowsTransportContractTests.swift"))
            XCTAssertEqual(Self.missingWrappers(names: names, in: windows), [], "Windows wrappers")
        }
    }

    func testTheWrapperCheckSeesAMissingWrapper() {
        let contract = "static func one<H: TeamTransportHarness>(_ h: H)\nstatic func two<H: TeamTransportHarness>(_ h: H)"
        let names = Self.scenarioNames(in: contract)
        XCTAssertEqual(names, ["one", "two"])
        XCTAssertEqual(Self.missingWrappers(names: names, in: "try await TeamTransportContract.one(h)"), ["two"])
    }

    func testTheWindowsTransportUsesTheSharedRules() throws {
        guard Self.windowsWrapperRequired else { return }
        XCTAssertEqual(Self.sourceViolations(in: try read(Self.windowsTransport)), [])
    }

    func testTheSourceScanCatchesBypassedRules() {
        let good = "let r = TeamLinkReceiver()\nadmitsInbound(\ndialRoom("
        XCTAssertEqual(Self.sourceViolations(in: good), [])
        XCTAssertEqual(Self.sourceViolations(in: good + "\nvar d = TeamWire.FrameDecoder()").count, 1)
        XCTAssertEqual(Self.sourceViolations(in: good + "\nTeamTokenBucket(").count, 1)
        XCTAssertEqual(Self.sourceViolations(in: "TeamLinkReceiver admitsInbound").count, 1, "dialRoom missing")
        XCTAssertEqual(Self.sourceViolations(in: good + "\n// FrameDecoder in a comment is fine"), [])
    }
}
