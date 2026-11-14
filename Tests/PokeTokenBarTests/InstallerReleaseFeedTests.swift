import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokeTokenBar

/// Canned responses only: the session's protocol class answers, nothing reaches the network.
final class FeedStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class InstallerReleaseFeedTests: XCTestCase {
    private func release(tag: String = "v2.6.0", html: String = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.6.0",
                         assets: [String]) -> Data {
        let list = assets.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        return Data("{\"tag_name\":\"\(tag)\",\"html_url\":\"\(html)\",\"assets\":[\(list)]}".utf8)
    }

    func testFeedIgnoresAReleaseWithoutTheWindowsInstaller() {
        XCTAssertNil(InstallerReleaseFeed.parse(release(assets: ["PokeTokenBar-2.6.0.zip", "PokeTokenBar-2.6.0.dmg"])))
        XCTAssertNil(InstallerReleaseFeed.parse(release(assets: [])))
        XCTAssertNil(InstallerReleaseFeed.parse(Data("{\"tag_name\":\"v2.6.0\",\"html_url\":\"https://github.com/x\"}".utf8)), "no assets key")
        XCTAssertNil(InstallerReleaseFeed.parse(Data("not json".utf8)))
    }

    func testFeedTakesTheReleasePageURL() throws {
        let page = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.6.0"
        let found = try XCTUnwrap(InstallerReleaseFeed.parse(release(html: page, assets: ["PokeTokenBar-2.6.0.zip", "PokeTokenBar-Setup-2.6.0-win-x64.exe"])))
        XCTAssertEqual(found, UpdateChecker.LatestRelease(tag: "v2.6.0", url: page))
    }

    func testOnlyTheExactInstallerNameCounts() {
        for name in ["PokeTokenBar-Setup--win-x64.exe", "PokeTokenBar-Setup-2.6.0-win-arm64.exe", "PokeTokenBar-Setup-2.6.0-win-x64.exe.sig",
                     "Other-Setup-2.6.0-win-x64.exe", "PokeTokenBar-Setup-2.6/0-win-x64.exe", "PokeTokenBar-Setup-win-x64.exe"] {
            XCTAssertFalse(InstallerReleaseFeed.isInstallerName(name), name)
        }
        XCTAssertTrue(InstallerReleaseFeed.isInstallerName("PokeTokenBar-Setup-2.6.0-win-x64.exe"))
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedStubProtocol.self]
        FeedStubProtocol.requests = []
        return URLSession(configuration: config)
    }

    func testLatestAsksTheTeamForkAndOnlyReadsTheAnswer() async throws {
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = release(assets: ["PokeTokenBar-Setup-2.6.0-win-x64.exe"])
        let found = await InstallerReleaseFeed.latest(session: stubbedSession())
        XCTAssertEqual(found?.tag, "v2.6.0")
        XCTAssertEqual(FeedStubProtocol.requests.count, 1)
        let req = try XCTUnwrap(FeedStubProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/latest")
        XCTAssertEqual(req.httpMethod ?? "GET", "GET")
    }

    func testLatestIsNilOnAFailedStatusOrAMacOnlyRelease() async {
        FeedStubProtocol.status = 404
        FeedStubProtocol.body = release(assets: ["PokeTokenBar-Setup-2.6.0-win-x64.exe"])
        let missing = await InstallerReleaseFeed.latest(session: stubbedSession())
        XCTAssertNil(missing, "a non-200 answer is a failed check")
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = release(assets: ["PokeTokenBar-2.6.0.zip"])
        let macOnly = await InstallerReleaseFeed.latest(session: stubbedSession())
        XCTAssertNil(macOnly, "the Mac release is not an update for Windows")
    }

    @MainActor
    func testTheCheckerOffersAWindowsReleaseOnlyThroughTheFeed() async {
        let defaults = TestDefaults.make(suite: "InstallerReleaseFeedTests.\(UUID().uuidString)")
        let data = release(tag: "v2.6.0", assets: ["PokeTokenBar-Setup-2.6.0-win-x64.exe"])
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: defaults) { InstallerReleaseFeed.parse(data) }
        await checker.check()
        XCTAssertEqual(checker.available?.version, "2.6.0")
        let macData = release(tag: "v2.6.0", assets: ["PokeTokenBar-2.6.0.zip"])
        let macChecker = UpdateChecker(currentVersion: "2.5.3", defaults: defaults) { InstallerReleaseFeed.parse(macData) }
        await macChecker.check()
        XCTAssertNil(macChecker.available)
    }
}
