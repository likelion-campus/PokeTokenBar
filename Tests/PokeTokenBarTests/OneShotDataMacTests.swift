import XCTest
@testable import PokeTokenBar

/// `PlatformCompat.oneShotData` on the Mac is `URLSession.shared.data(for:)`, the call `ProviderStatusChecker` made before
/// the route: a URLProtocol registered for the shared session (custom sessions do not consult `registerClass`) sees the
/// request unchanged, and its answer comes back. The `.invalid` host never resolves, so a missed intercept cannot reach a
/// server. Windows takes WinHTTP instead (`WindowsHTTPFetchTests`).
final class OneShotDataMacTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var seen: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ptb-oneshot.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Stub.seen.append(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 203, httpVersion: "HTTP/1.1", headerFields: ["X-Stub": "1"])
            else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("stubbed".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testTheMacBranchIsTheSharedSessionUnchanged() async throws {
        URLProtocol.registerClass(Stub.self)
        defer { URLProtocol.unregisterClass(Stub.self) }
        Stub.seen = []
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://ptb-oneshot.invalid/api/v2/summary.json")), timeoutInterval: 10)
        request.setValue("PokeTokenBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await PlatformCompat.oneShotData(for: request)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "stubbed")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 203)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Stub"), "1")
        XCTAssertEqual(Stub.seen.count, 1)
        XCTAssertEqual(Stub.seen.first?.value(forHTTPHeaderField: "User-Agent"), "PokeTokenBar")
        XCTAssertEqual(Stub.seen.first?.timeoutInterval, 10)
        XCTAssertEqual(Stub.seen.first?.httpMethod, "GET")
    }
}
