#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// The verdict of the selftest's `net.clientCertificateOptional` (`WindowsSelftest.classify`): only "our answer to the certificate
/// request is wrong" fails; the network or the host being unavailable is reported as unverified. The selftest runs on users' PCs
/// and in the release gate, where graphql.pokeapi.co may be unreachable, slow or down.
final class WindowsClientCertificateCheckTests: XCTestCase {
    private func status(_ code: Int) -> Result<Int, URLError> { .success(code) }
    private func error(_ code: URLError.Code) -> Result<Int, URLError> { .failure(URLError(code)) }

    private func verdict(_ fixed: Result<Int, URLError>, _ control: Result<Int, URLError>) -> (ok: Bool, detail: String) {
        WindowsSelftest.classify(fixed: fixed, control: control)
    }

    func testAnAnswerWhileTheOldWayStopsAtTheCertificateRequestIsVerified() {
        let v = verdict(status(200), error(.clientCertificateRequired))
        XCTAssertTrue(v.ok); XCTAssertTrue(v.detail.hasPrefix("verified:"), v.detail)
        let five = verdict(status(503), error(.clientCertificateRequired))  // the handshake went through; the server is unwell
        XCTAssertTrue(five.ok); XCTAssertTrue(five.detail.hasPrefix("verified:"), five.detail)
    }

    func testStoppingAtTheCertificateRequestFails() {
        for control in [error(.clientCertificateRequired), status(200), error(.timedOut)] {
            XCTAssertFalse(verdict(error(.clientCertificateRequired), control).ok, "\(control)")
        }
    }

    func testAFailureTheControlDidNotHaveFails() {
        // Our resend broke the handshake: the control got as far as the certificate request, ours did not get an answer.
        XCTAssertFalse(verdict(error(.secureConnectionFailed), error(.clientCertificateRequired)).ok)
        XCTAssertFalse(verdict(error(.badServerResponse), status(200)).ok)
    }

    func testNoNetworkATimeoutOrAHostDownIsUnverifiedNotAFailure() {
        for code: URLError.Code in [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed,
                                    .networkConnectionLost] {
            let v = verdict(error(code), error(code))
            XCTAssertTrue(v.ok, "\(code.rawValue)"); XCTAssertTrue(v.detail.hasPrefix("unverified"), v.detail)
            XCTAssertTrue(verdict(error(code), error(.clientCertificateRequired)).ok, "unreachable on ours only: \(code.rawValue)")
        }
        let tls = verdict(error(.secureConnectionFailed), error(.secureConnectionFailed))  // the host's TLS is broken both ways
        XCTAssertTrue(tls.ok); XCTAssertTrue(tls.detail.hasPrefix("unverified (the host failed both ways alike)"), tls.detail)
    }

    func testAHostThatNoLongerAsksOrAControlWithoutAnswerProvesNothingAndPasses() {
        let noAsk = verdict(status(200), status(200))
        XCTAssertTrue(noAsk.ok); XCTAssertTrue(noAsk.detail.hasPrefix("unverified (the host no longer asks"), noAsk.detail)
        let noControl = verdict(status(200), error(.timedOut))
        XCTAssertTrue(noControl.ok); XCTAssertTrue(noControl.detail.hasPrefix("unverified (the control got no answer)"), noControl.detail)
    }
}
#endif
