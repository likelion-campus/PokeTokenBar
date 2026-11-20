import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokeTokenBar

/// The verdict of the selftest's `net.usageReportRedirect`: fails only when the answer shows our redirect handling is wrong;
/// the network, a proxy or the host being unavailable is unverified.
final class UsageReportProbeTests: XCTestCase {
    private let html = "<!DOCTYPE html><html>page</html>"
    private let json = #"{"ok":false,"error":"bad_version"}"#
    private let gHost = "script.googleusercontent.com"

    private func answer(_ status: Int, _ body: String, _ host: String?) -> (ok: Bool, detail: String) {
        UsageReportProbe.classify(.success((status: status, body: Data(body.utf8), finalHost: host)))
    }
    private func unverified(_ v: (ok: Bool, detail: String), _ line: UInt = #line) {
        XCTAssertTrue(v.ok, v.detail, line: line); XCTAssertTrue(v.detail.hasPrefix("unverified"), v.detail, line: line)
    }

    func testJSONPasses() {
        let v = answer(200, json, gHost)
        XCTAssertTrue(v.ok); XCTAssertTrue(v.detail.hasPrefix("verified"), v.detail)
    }

    func testJSONOnA500Passes() {
        let v = answer(500, json, gHost)
        XCTAssertTrue(v.ok); XCTAssertTrue(v.detail.hasPrefix("verified"), v.detail)
    }

    func testJSONWithoutBoolOkIsNotJSONAnswer() {
        XCTAssertFalse(answer(200, #"{"error":"x"}"#, gHost).ok)
        XCTAssertFalse(answer(200, #"{"ok":"yes"}"#, gHost).ok)
        XCTAssertFalse(answer(200, "[1]", gHost).ok)
    }

    func testARedirectHandedBackFails() { XCTAssertFalse(answer(302, "", "script.google.com").ok) }

    func testHTMLFromAGoogleHostFails() {
        XCTAssertFalse(answer(405, html, gHost).ok)
        XCTAssertFalse(answer(200, html, gHost).ok)
        XCTAssertFalse(answer(404, html, "script.google.com").ok)
        XCTAssertFalse(answer(200, html, "accounts.google.com").ok)
    }

    func testHTMLFromAnotherOrUnknownHostIsUnverified() {
        unverified(answer(200, html, "portal.example"))
        unverified(answer(200, html, nil))
        unverified(answer(200, html, "notgoogle.com"))
    }

    func testProxyAuthQuotaAndServerErrorsAreUnverified() {
        unverified(answer(407, html, gHost))
        unverified(answer(429, html, gHost))
        unverified(answer(503, html, gHost))
    }

    func testUnreachableIsUnverified() {
        for code in UsageReportProbe.unreachableCodes {
            unverified(UsageReportProbe.classify(.failure(URLError(code))))
        }
    }

    func testTLSInterceptionIsUnverified() {
        for code in UsageReportProbe.interceptionCodes { unverified(UsageReportProbe.classify(.failure(URLError(code)))) }
        unverified(UsageReportProbe.classify(.failure(URLError(.serverCertificateUntrusted))))
    }

    func testOtherURLErrorsFail() {
        XCTAssertFalse(UsageReportProbe.classify(.failure(URLError(.badServerResponse))).ok)
    }
}
