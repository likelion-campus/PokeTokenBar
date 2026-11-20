import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokeTokenBar

/// The verdict of the selftest's `net.usageReportRedirect`: JSON back from the sheet passes, the network or host being
/// unavailable is unverified, and any other answer (such as an HTML page from a POST that stayed a POST) fails.
final class UsageReportProbeTests: XCTestCase {
    private func ok(_ status: Int, _ body: String) -> Result<(status: Int, body: Data), URLError> {
        .success((status: status, body: Data(body.utf8)))
    }

    func testJSONPasses() {
        let v = UsageReportProbe.classify(ok(200, #"{"ok":false,"error":"bad_version"}"#))
        XCTAssertTrue(v.ok); XCTAssertFalse(v.detail.hasPrefix("unverified"), v.detail)
    }

    func testHTMLFails() {
        let v = UsageReportProbe.classify(ok(200, "<!DOCTYPE html><html>Moved Temporarily</html>"))
        XCTAssertFalse(v.ok, v.detail)
    }

    func testJSONWithoutBoolOkFails() {
        XCTAssertFalse(UsageReportProbe.classify(ok(200, #"{"error":"x"}"#)).ok)
        XCTAssertFalse(UsageReportProbe.classify(ok(200, #"{"ok":"yes"}"#)).ok)
        XCTAssertFalse(UsageReportProbe.classify(ok(200, "[1]")).ok)
    }

    func testUnreachableIsUnverified() {
        for code in UsageReportProbe.unreachableCodes {
            let v = UsageReportProbe.classify(.failure(URLError(code)))
            XCTAssertTrue(v.ok, "\(code.rawValue)"); XCTAssertTrue(v.detail.hasPrefix("unverified"), v.detail)
        }
        XCTAssertFalse(UsageReportProbe.classify(.failure(URLError(.badServerResponse))).ok)
    }

    func testServerErrorIsUnverified() {
        let v = UsageReportProbe.classify(ok(503, "<html>down</html>"))
        XCTAssertTrue(v.ok); XCTAssertTrue(v.detail.hasPrefix("unverified"), v.detail)
    }
}
