import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import PokeTokenBar

final class UsageReportWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tools/usage-sheet/fixtures/\(name).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let member = UsageReportBody.Member(
        id: "8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C",
        secret: "dGVzdC1zZWNyZXQtZm9yLWZpeHR1cmVzLW9ubHktMDA",
        nickname: "지아", appVersion: "2.5.640", platform: "mac")

    private func limit(_ account: String, _ plan: String, _ pct: Double) -> UsageReportBody.Limit {
        .init(tool: "claude", account: account, domain: "likelion.net", plan: plan, usedPercent: pct,
              resetsAt: "2026-11-19T09:00:00Z", readAt: "2026-11-16T02:00:00Z", team: "t_ab12cd34ef56")
    }

    private func assertMatches(_ body: UsageReportBody, _ name: String) throws {
        let expected = try XCTUnwrap(try fixture(name)["body"] as? [String: Any])
        let data = try UsageReportBody.encoded(body)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
    }

    func testTheBodyMatchesTheValidBasicFixture() throws {
        let body = UsageReportBody(
            v: UsageReportConfig.version, token: UsageReportConfig.token, member: member,
            days: [
                .init(date: "2026-11-15", team: "t_ab12cd34ef56", teamLabel: "팀 1", tools: [
                    .init(tool: "claude_code", input: 1200, output: 800, cacheWrite: 5000, cacheRead: 90000),
                    .init(tool: "codex", input: 300, output: 200, cacheWrite: 0, cacheRead: 4000)]),
                .init(date: "2026-11-16", team: "t_ab12cd34ef56", teamLabel: "팀 1", tools: [])],
            limits: [limit("e_3f9a1c2b4d5e6f70", "Max", 82.5)])
        try assertMatches(body, "valid-basic")
    }

    func testTheBodyMatchesTheTwoAccountsFixture() throws {
        let body = UsageReportBody(
            v: UsageReportConfig.version, token: UsageReportConfig.token, member: member,
            days: [.init(date: "2026-11-16", team: "t_ab12cd34ef56", teamLabel: "팀 1", tools: [
                .init(tool: "claude_code", input: 10, output: 20, cacheWrite: 30, cacheRead: 40)])],
            limits: [limit("e_3f9a1c2b4d5e6f70", "Max", 82.5), limit("e_77aa88bb99cc00dd", "Pro", 12)])
        try assertMatches(body, "valid-two-accounts")
    }

    func testANilTeamLabelIsLeftOut() throws {
        let day = UsageReportBody.Day(date: "2026-11-16", team: "t_x1", teamLabel: nil, tools: [])
        let body = UsageReportBody(v: 1, token: "t", member: member, days: [day], limits: [])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: UsageReportBody.encoded(body)) as? [String: Any])
        let days = try XCTUnwrap(obj["days"] as? [[String: Any]])
        XCTAssertNil(days[0]["teamLabel"])
        XCTAssertNotNil(days[0]["team"])
    }

    func testTheFingerprintIsStableAndSensitiveToContent() {
        let a = UsageReportBody.Day(date: "2026-11-16", team: "t_x1", teamLabel: nil, tools: [])
        var b = a
        b.team = "t_x2"
        XCTAssertEqual(UsageReportBody.fingerprint(a), UsageReportBody.fingerprint(a))
        XCTAssertNotEqual(UsageReportBody.fingerprint(a), UsageReportBody.fingerprint(b))
        XCTAssertNotNil(UsageReportBody.fingerprint(a).range(of: "^[0-9a-f]{16}$", options: .regularExpression))
    }

    func testTheAccountIDHashesTheLowercasedEmail() {
        XCTAssertEqual(UsageReportIDs.account(email: "Someone@LikeLion.net", memberID: "M", localAccountID: "default"),
                       "e_ad270506b0f3b0f7")
    }

    func testAnUnknownEmailFallsBackToMemberAndLocalID() {
        let id = "8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C"
        let expected = "m_\(id)_default"
        XCTAssertEqual(UsageReportIDs.account(email: nil, memberID: id, localAccountID: "default"), expected)
        XCTAssertEqual(UsageReportIDs.account(email: "", memberID: id, localAccountID: "default"), expected)
        XCTAssertEqual(UsageReportIDs.account(email: "  \n", memberID: id, localAccountID: "default"), expected)
    }

    func testTheDomainIsTheLowercasedPartAfterTheAt() {
        XCTAssertEqual(UsageReportIDs.domain(email: "A@LikeLion.NET"), "likelion.net")
        XCTAssertEqual(UsageReportIDs.domain(email: nil), "")
        XCTAssertEqual(UsageReportIDs.domain(email: "no-at"), "")
    }

    func testTheTeamIDIsStableOneWayAndNotThePSK() throws {
        var rng = SystemRandomNumberGenerator()
        let a = TeamCode.generate(using: &rng)
        var b = TeamCode.generate(using: &rng)
        while b == a { b = TeamCode.generate(using: &rng) }
        for code in [a, b] {
            let id = code.usageTeamID
            XCTAssertNotNil(id.range(of: "^t_[0-9a-f]{16}$", options: .regularExpression))
            XCTAssertNotNil(id.range(of: "^t_[A-Za-z0-9_-]{2,62}$", options: .regularExpression))
            XCTAssertEqual(id, code.usageTeamID)
            let pskHex = code.pskKey.withUnsafeBytes { Data($0) }.prefix(8).map { String(format: "%02x", $0) }.joined()
            XCTAssertNotEqual(String(id.dropFirst(2)), pskHex)
        }
        XCTAssertNotEqual(a.usageTeamID, b.usageTeamID)
    }

    func testTheResponseParser() {
        func parse(_ s: String) -> UsageReportResponse { UsageReportResponse.parse(Data(s.utf8)) }
        XCTAssertEqual(parse(#"{"ok":true,"accepted":{"days":2,"limits":1},"dropped":0}"#),
                       .accepted(days: 2, limits: 1, dropped: 0))
        XCTAssertEqual(parse(#"{"ok":false,"error":"device_mismatch"}"#), .rejected("device_mismatch"))
        XCTAssertEqual(parse(#"{"ok":false}"#), .rejected("unknown"))
        XCTAssertEqual(parse("<html><body>sign in</body></html>"), .notJSON)
        XCTAssertEqual(parse(#"{"ok":true}"#), .notJSON)
    }

    func testIsoUTCDropsFractionsAndUsesZ() {
        XCTAssertEqual(UsageReportIDs.isoUTC(Date(timeIntervalSince1970: 1_795_078_800.4)), "2026-11-19T09:00:00Z")
    }
}
