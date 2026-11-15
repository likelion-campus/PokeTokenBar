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

    func testOutcomeTellsNothingForWindowsApartFromACouldNotAsk() async {
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = release(assets: ["PokeTokenBar-2.6.0.zip"])
        let none = await InstallerReleaseFeed.outcome(session: stubbedSession())
        XCTAssertEqual(none, .noInstaller)
        FeedStubProtocol.status = 403
        let failed = await InstallerReleaseFeed.outcome(session: stubbedSession())
        XCTAssertEqual(failed, .failed, "a rate-limit answer is a failed check, retried at once like the Mac")
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = Data("not json".utf8)
        let garbage = await InstallerReleaseFeed.outcome(session: stubbedSession())
        XCTAssertEqual(garbage, .failed)
        FeedStubProtocol.body = release(assets: ["PokeTokenBar-Setup-2.6.0-win-x64.exe"])
        let found = await InstallerReleaseFeed.outcome(session: stubbedSession())
        XCTAssertEqual(found, .release(UpdateChecker.LatestRelease(tag: "v2.6.0", url: "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.6.0")))
    }

    func testAnEmptyAnswerHoldsTheNextRequestForThirtyMinutes() {
        var cooldown = InstallerReleaseFeed.EmptyAnswerCooldown()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(cooldown.mayAsk(now: t0), "nothing asked yet")
        cooldown.noteEmptyAnswer(now: t0)
        XCTAssertFalse(cooldown.mayAsk(now: t0.addingTimeInterval(5)), "a menu open right after is not a request")
        XCTAssertFalse(cooldown.mayAsk(now: t0.addingTimeInterval(1799)))
        XCTAssertTrue(cooldown.mayAsk(now: t0.addingTimeInterval(1800)), "same 30 minutes as UpdateChecker.check")
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

/// JSON text built from ordered keys and raw values, so a test can set a field to any JSON (`true`, `"x"`, `1e10`) or drop it.
struct RawJSONObject {
    private(set) var pairs: [(key: String, raw: String)]
    init(_ pairs: [(String, String)]) { self.pairs = pairs.map { (key: $0.0, raw: $0.1) } }

    /// `raw` is JSON text; nil removes the key.
    func with(_ key: String, _ raw: String?) -> RawJSONObject {
        var copy = self
        if let i = copy.pairs.firstIndex(where: { $0.key == key }) {
            if let raw { copy.pairs[i].raw = raw } else { copy.pairs.remove(at: i) }
        } else if let raw {
            copy.pairs.append((key: key, raw: raw))
        }
        return copy
    }

    var text: String { "{" + pairs.map { "\"\($0.key)\":\($0.raw)" }.joined(separator: ",") + "}" }

    /// A JSON string literal for any text (quotes, backslashes and control characters escaped).
    static func q(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

/// The real `GET /repos/likelion-campus/PokeTokenBar/releases/tags/v2.5.634` answer (read 2026-11-16): every key in GitHub's
/// order, the Mac zip as published. People carry placeholder values and the notes are shortened. The installer asset is
/// added the way GitHub lists an uploaded asset; its size is the CI-built 2.5.634 installer's (33,121,702 bytes, windows-app
/// run 43736993382), its digest is sample data.
enum ReleaseFixture {
    static let version = "2.5.634"
    static let tag = "v2.5.634"
    static let page = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.5.634"
    static let installerName = "PokeTokenBar-Setup-2.5.634-win-x64.exe"
    static let installerURL = "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/PokeTokenBar-Setup-2.5.634-win-x64.exe"
    static let installerSize = 33_121_702
    static let installerHex = "4f2c7e0b9a1d3c5e7f60819a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
    private static func q(_ s: String) -> String { RawJSONObject.q(s) }

    static let person = RawJSONObject([
        ("login", q("example-user")), ("id", "1"), ("node_id", q("U_placeholder")),
        ("avatar_url", q("https://avatars.githubusercontent.com/u/1?v=4")), ("gravatar_id", q("")),
        ("url", q("https://api.github.com/users/example-user")), ("html_url", q("https://github.com/example-user")),
        ("followers_url", q("https://api.github.com/users/example-user/followers")),
        ("following_url", q("https://api.github.com/users/example-user/following{/other_user}")),
        ("gists_url", q("https://api.github.com/users/example-user/gists{/gist_id}")),
        ("starred_url", q("https://api.github.com/users/example-user/starred{/owner}{/repo}")),
        ("subscriptions_url", q("https://api.github.com/users/example-user/subscriptions")),
        ("organizations_url", q("https://api.github.com/users/example-user/orgs")),
        ("repos_url", q("https://api.github.com/users/example-user/repos")),
        ("events_url", q("https://api.github.com/users/example-user/events{/privacy}")),
        ("received_events_url", q("https://api.github.com/users/example-user/received_events")),
        ("type", q("User")), ("user_view_type", q("public")), ("site_admin", "false"),
    ])

    static let zip = RawJSONObject([
        ("url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/assets/747904509")),
        ("id", "747904509"), ("node_id", q("RA_kwDOVbfQ_84slB39")), ("name", q("PokeTokenBar.zip")), ("label", q("")),
        ("uploader", person.text), ("content_type", q("application/zip")), ("state", q("uploaded")), ("size", "8450836"),
        ("digest", q("sha256:f71be18e45df4588e42ec94f6970e33ae395fbf36afa074cde50042fd4121583")), ("download_count", "3"),
        ("created_at", q("2026-11-14T15:28:23Z")), ("updated_at", q("2026-11-14T15:28:24Z")),
        ("browser_download_url", q("https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/PokeTokenBar.zip")),
    ])

    static let installer = RawJSONObject([
        ("url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/assets/747904510")),
        ("id", "747904510"), ("node_id", q("RA_placeholder")), ("name", q(installerName)), ("label", q("")),
        ("uploader", person.text), ("content_type", q("application/x-msdownload")), ("state", q("uploaded")),
        ("size", "\(installerSize)"), ("digest", q("sha256:" + installerHex)), ("download_count", "0"),
        ("created_at", q("2026-11-14T15:28:24Z")), ("updated_at", q("2026-11-14T15:28:25Z")),
        ("browser_download_url", q(installerURL)),
    ])

    static let release = RawJSONObject([
        ("url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/445392566")),
        ("assets_url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/445392566/assets")),
        ("upload_url", q("https://uploads.github.com/repos/likelion-campus/PokeTokenBar/releases/445392566/assets{?name,label}")),
        ("html_url", q(page)), ("id", "445392566"), ("author", person.text), ("node_id", q("RE_kwDOVbfQ_84ajCa2")),
        ("tag_name", q(tag)), ("target_commitish", q("8f050c929cf1a3d5f081761b67c54f25ec0a8854")), ("name", q(tag)),
        ("draft", "false"), ("immutable", "false"), ("prerelease", "false"),
        ("created_at", q("2026-11-14T15:12:38Z")), ("updated_at", q("2026-11-14T15:28:25Z")),
        ("published_at", q("2026-11-14T15:28:25Z")), ("assets", "[]"),
        ("tarball_url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/tarball/v2.5.634")),
        ("zipball_url", q("https://api.github.com/repos/likelion-campus/PokeTokenBar/zipball/v2.5.634")),
        ("body", q("## New\n- Sample notes.\n\n## Install / Upgrade\n- Sample line.")), ("mentions_count", "1"),
    ])

    /// The release with these assets (default: the Mac zip and the installer), optionally with top-level fields changed.
    static func data(release: RawJSONObject = release, assets: [RawJSONObject] = [zip, installer]) -> Data {
        Data(release.with("assets", "[" + assets.map(\.text).joined(separator: ",") + "]").text.utf8)
    }

    /// The release with one installer field set to `raw` (nil drops it).
    static func data(installer key: String, _ raw: String?) -> Data { data(assets: [zip, installer.with(key, raw)]) }

    /// The installer for another version, consistent in name and address, with the release still tagged 2.5.634.
    static func installerNamed(forVersion v: String) -> RawJSONObject {
        let name = "PokeTokenBar-Setup-\(v)-win-x64.exe"
        return installer.with("name", q(name))
            .with("browser_download_url", q("https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)"))
    }
}

final class InstallerReleaseFeedAssetTests: XCTestCase {
    private typealias F = ReleaseFixture
    private func q(_ s: String) -> String { RawJSONObject.q(s) }

    private func rejection(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> InstallerReleaseFeed.Rejection? {
        switch InstallerReleaseFeed.installerCheck(in: data) {
        case .success(let found):
            XCTFail("accepted \(found)", file: file, line: line)
            return nil
        case .failure(let why):
            XCTAssertNil(InstallerReleaseFeed.installer(in: data), "installer(in:) agrees with installerCheck", file: file, line: line)
            return why
        }
    }

    func testTheRealReleaseShapeWithAnInstallerGivesItsVersionNameAddressSizeAndDigest() throws {
        let found = try XCTUnwrap(InstallerReleaseFeed.installer(in: F.data()))
        let url = try XCTUnwrap(URL(string: F.installerURL))
        XCTAssertEqual(found, InstallerReleaseFeed.Installer(version: F.version, name: F.installerName, url: url,
                                                             size: F.installerSize, sha256: F.installerHex))
        XCTAssertEqual(InstallerReleaseFeed.expectedName(version: "2.5.640"), "PokeTokenBar-Setup-2.5.640-win-x64.exe")
        XCTAssertEqual(InstallerReleaseFeed.releaseDownloadPrefix, "https://github.com/likelion-campus/PokeTokenBar/releases/download/")
        // The offer keeps today's meaning on the same answer: the tag and the release page.
        XCTAssertEqual(InstallerReleaseFeed.parse(F.data()), UpdateChecker.LatestRelease(tag: F.tag, url: F.page))
        // The installer listed before the zip is the same installer.
        XCTAssertEqual(InstallerReleaseFeed.installer(in: F.data(assets: [F.installer, F.zip])), found)
        // An asset without a usable name is not an installer: it neither counts nor hides the real one.
        for nameless in [F.zip.with("name", nil), F.zip.with("name", "1"), F.zip.with("name", "null")] {
            let data = F.data(assets: [nameless, F.installer])
            XCTAssertEqual(InstallerReleaseFeed.installer(in: data), found, nameless.text)
            XCTAssertNotNil(InstallerReleaseFeed.parse(data), nameless.text)
        }
    }

    func testTheRealMacOnlyReleaseIsNeitherAnOfferNorAnInstaller() {
        let macOnly = F.data(assets: [F.zip])
        XCTAssertNil(InstallerReleaseFeed.parse(macOnly))
        XCTAssertEqual(rejection(macOnly), .noInstaller)
        XCTAssertEqual(rejection(F.data(assets: [])), .noInstaller)
    }

    func testAnswersThatAreNotAReleaseObjectAreRefused() {
        for text in ["not json", "[]", "\"v2.5.634\"", "", "{\"tag_name\":"] {
            XCTAssertEqual(rejection(Data(text.utf8)), .notJSON, text)
        }
        XCTAssertEqual(rejection(Data(F.release.with("assets", nil).text.utf8)), .noAssets)
        for raw in ["null", "{}", "\"x\"", "[1]", "[\"PokeTokenBar-Setup-2.5.634-win-x64.exe\"]"] {
            XCTAssertEqual(rejection(Data(F.release.with("assets", raw).text.utf8)), .noAssets, raw)
        }
    }

    func testATagThatIsNotVPlusAPlainVersionIsRefused() {
        for tag in ["2.5.634", "V2.5.634", "v02.5.634", " v2.5.634", "v2.5.634 ", "v2.5.634\n", "v2.5", "v2.5.634.1",
                    "v2.5.634-beta.1", "v2.5.634+build", "latest", "", "v", "vv2.5.634", "v٢.٥.٦٣٤"] {
            XCTAssertEqual(rejection(F.data(release: F.release.with("tag_name", q(tag)))), .tag, tag.debugDescription)
        }
        for raw in [nil, "null", "2.5", "[\"v2.5.634\"]"] as [String?] {
            XCTAssertEqual(rejection(F.data(release: F.release.with("tag_name", raw))), .tag, raw ?? "missing")
        }
    }

    func testADraftOrAPrereleaseOrOneThatDoesNotSayIsRefusedButStillOffered() {
        let cases: [(String, String?)] = [("draft", "true"), ("prerelease", "true"), ("draft", nil), ("prerelease", nil),
                                          ("draft", "\"false\""), ("prerelease", "null")]
        for (key, raw) in cases {
            let data = F.data(release: F.release.with(key, raw))
            XCTAssertEqual(rejection(data), .notPublished, "\(key)=\(raw ?? "missing")")
            XCTAssertNotNil(InstallerReleaseFeed.parse(data), "the offer keeps today's meaning: \(key)=\(raw ?? "missing")")
        }
    }

    func testTwoInstallerAssetsAreRefused() {
        XCTAssertEqual(rejection(F.data(assets: [F.zip, F.installer, F.installer])), .severalInstallers, "the same name twice")
        XCTAssertEqual(rejection(F.data(assets: [F.zip, F.installer, F.installerNamed(forVersion: "2.5.633")])), .severalInstallers)
        XCTAssertEqual(rejection(F.data(assets: [F.installerNamed(forVersion: "2.5.633"), F.installer])), .severalInstallers)
    }

    func testAnInstallerNamedForAnotherVersionIsRefused() {
        for v in ["2.5.633", "2.5.635", "2.6.0", "02.5.634", "2.5.634.1", "..", "2.5.634-beta", "%2e%2e"] {
            XCTAssertEqual(rejection(F.data(assets: [F.zip, F.installerNamed(forVersion: v)])), .name, v)
        }
        // A name the offer does not count at all (a path, another case, a space) is no installer.
        for name in ["PokeTokenBar-Setup-../2.5.634-win-x64.exe", "PokeTokenBar-Setup-2.5.634\\..\\x-win-x64.exe",
                     "pokeTokenBar-Setup-2.5.634-win-x64.exe", "PokeTokenBar-Setup-2.5.634-win-x64.exe ",
                     "PokeTokenBar-Setup-2.5.634-win-arm64.exe"] {
            let data = F.data(installer: "name", q(name))
            XCTAssertNil(InstallerReleaseFeed.parse(data), name)
            XCTAssertEqual(rejection(data), .noInstaller, name)
        }
    }

    func testAnAddressOffTheExactDownloadPatternIsRefused() {
        let base = "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/"
        let name = F.installerName
        let addresses: [String] = [
            "https://github.com/chattymin/PokeTokenBar/releases/download/v2.5.634/\(name)",       // another repository
            "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.633/\(name)", // another tag
            "https://objects.githubusercontent.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)", // host
            "https://github.com.evil.test/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "https://evil.test/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "http://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",  // scheme
            "ftp://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "https://github.com@evil.test/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)", // userinfo
            "https://evil.test@github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "https://github.com:443/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)", // port
            "https://github.com:8443/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "https://GitHub.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/\(name)",  // case
            "https://github.com/Likelion-Campus/PokeTokenBar/releases/download/v2.5.634/\(name)",
            "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/../v2.5.633/\(name)", // traversal
            "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634/%2E%2E/\(name)",
            "https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.634//\(name)",
            "\(base)\(name)?redirect=https://evil.test/x.exe",                                   // query, fragment
            "\(base)\(name)#x", "\(base)\(name)/", " \(base)\(name)", "\(base)\(name) ", "\(base)\(name)\n",
            "\(base)PokeTokenBar.zip",                                                            // another asset
            "https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/assets/747904510",  // the API's asset URL
            "", base,
        ]
        for address in addresses {
            XCTAssertEqual(rejection(F.data(installer: "browser_download_url", q(address))), .url, address.debugDescription)
        }
        let raws: [String?] = [nil, "null", "1", "[\"\(base)\(name)\"]", "{\"href\":\"\(base)\(name)\"}"]
        for raw in raws {
            XCTAssertEqual(rejection(F.data(installer: "browser_download_url", raw)), .url, raw ?? "missing")
        }
    }

    func testAnUploadThatIsNotFinishedIsRefused() {
        for raw in ["\"starter\"", "\"open\"", "\"Uploaded\"", "\"uploaded \"", "\"\"", "null", "true", nil] as [String?] {
            XCTAssertEqual(rejection(F.data(installer: "state", raw)), .state, raw ?? "missing")
        }
    }

    func testASizeOutsideOneTo200MiBOrNotAnIntegerIsRefused() throws {
        for raw in ["0", "-1", "-33121702", "1048575", "209715201", "1e10", "33121702.5", "\"33121702\"", "true", "false",
                    "null", "[33121702]", nil] as [String?] {
            XCTAssertEqual(rejection(F.data(installer: "size", raw)), .size, raw ?? "missing")
        }
        for bound in [1_048_576, 209_715_200] {
            let found = try XCTUnwrap(InstallerReleaseFeed.installer(in: F.data(installer: "size", "\(bound)")), "\(bound)")
            XCTAssertEqual(found.size, bound)
        }
    }

    /// Defect protocol (defect log, "기본 상한"): the installer is 33,121,702 bytes and the WinHTTP seam's default cap for API
    /// answers is 32 MiB. The feed must not carry a cap of its own near the real size: one byte over 32 MiB is an installer.
    func testAnInstallerJustOverTheSeamsDefaultCapIsAnInstaller() throws {
        let found = try XCTUnwrap(InstallerReleaseFeed.installer(in: F.data(installer: "size", "\(32 * 1024 * 1024 + 1)")))
        XCTAssertEqual(found.size, 33_554_433)
    }

    func testADigestThatIsNotSHA256AndSixtyFourLowercaseHexIsRefused() {
        let hex = F.installerHex
        let short = String(hex.dropLast()), upper = hex.uppercased(), sha1 = String(hex.prefix(40)), md5 = String(hex.prefix(32))
        let digests: [String] = [
            "", "sha256:", "sha256:\(short)", "sha256:\(hex)0", "sha256:\(upper)", "SHA256:\(hex)", "Sha256:\(hex)",
            "sha512:\(hex)\(hex)", "sha1:\(sha1)", "md5:\(md5)", hex, " sha256:\(hex)", "sha256:\(hex) ", "sha256: \(short)",
            "sha256:\(hex)\n", "sha256:\(short)g", "sha256:\(short)٣", "sha256=\(hex)", "sha256-\(hex)",
        ]
        for digest in digests {
            XCTAssertEqual(rejection(F.data(installer: "digest", q(digest))), .digest, digest.debugDescription)
        }
        for raw in [nil, "null", "0", "[\"sha256:\(hex)\"]"] as [String?] {
            XCTAssertEqual(rejection(F.data(installer: "digest", raw)), .digest, raw ?? "missing")
        }
        XCTAssertEqual(InstallerReleaseFeed.sha256Hex(fromDigest: "sha256:" + hex), hex)
    }

    func testEveryRejectionHasItsOwnFixedText() {
        let all: [InstallerReleaseFeed.Rejection] = [.notJSON, .tag, .notPublished, .noAssets, .noInstaller, .severalInstallers,
                                                    .name, .url, .state, .size, .digest]
        XCTAssertEqual(Set(all.map(\.description)).count, all.count)
        for why in all { XCTAssertFalse(why.description.contains("http"), "\(why): nothing from the JSON is logged") }
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedStubProtocol.self]
        FeedStubProtocol.requests = []
        return URLSession(configuration: config)
    }

    func testFetchAsksOnceAndReturnsTheOfferWithItsInstaller() async throws {
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = F.data()
        let answer = await InstallerReleaseFeed.fetch(session: stubbedSession())
        XCTAssertEqual(FeedStubProtocol.requests.count, 1, "one request for the offer and the installer")
        let req = try XCTUnwrap(FeedStubProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/latest")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(answer.outcome, .release(UpdateChecker.LatestRelease(tag: F.tag, url: F.page)))
        XCTAssertEqual(answer.installer, InstallerReleaseFeed.installer(in: F.data()))
        XCTAssertNotNil(answer.installer)
        XCTAssertNil(answer.rejection)
        let outcome = await InstallerReleaseFeed.outcome(session: stubbedSession())
        XCTAssertEqual(outcome, answer.outcome, "outcome() is fetch().outcome")
    }

    func testFetchKeepsTheOfferAndNamesWhyTheInstallerWasRefused() async {
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = F.data(installer: "digest", nil)
        let answer = await InstallerReleaseFeed.fetch(session: stubbedSession())
        XCTAssertEqual(answer.outcome, .release(UpdateChecker.LatestRelease(tag: F.tag, url: F.page)))
        XCTAssertNil(answer.installer, "no digest is never accepted")
        XCTAssertEqual(answer.rejection, .digest)
    }

    func testFetchHasNoInstallerWithoutAnOffer() async {
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = F.data(assets: [F.zip])
        let macOnly = await InstallerReleaseFeed.fetch(session: stubbedSession())
        XCTAssertEqual(macOnly.outcome, .noInstaller)
        XCTAssertNil(macOnly.installer)
        XCTAssertNil(macOnly.rejection)
        FeedStubProtocol.status = 403
        FeedStubProtocol.body = F.data()
        let limited = await InstallerReleaseFeed.fetch(session: stubbedSession())
        XCTAssertEqual(limited.outcome, .failed)
        XCTAssertNil(limited.installer, "a refused answer offers no installer, however good its body")
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = Data("not json".utf8)
        let garbage = await InstallerReleaseFeed.fetch(session: stubbedSession())
        XCTAssertEqual(garbage.outcome, .failed)
        XCTAssertNil(garbage.installer)
        XCTAssertNil(garbage.rejection)
    }

    /// The CI selftest's loopback feed (Task 6): the request goes to the given feed and the address must use its prefix;
    /// the real GitHub address is then off the pattern.
    func testFetchFromAnotherFeedTakesOnlyItsDownloadPrefix() async throws {
        let feed = try XCTUnwrap(URL(string: "http://127.0.0.1:9/releases/latest"))
        let prefix = "http://127.0.0.1:9/download/"
        FeedStubProtocol.status = 200
        FeedStubProtocol.body = F.data(installer: "browser_download_url", q(prefix + "v2.5.634/" + F.installerName))
        let loopback = await InstallerReleaseFeed.fetch(from: feed, downloadPrefix: prefix, session: stubbedSession())
        XCTAssertEqual(FeedStubProtocol.requests.map { $0.url?.absoluteString }, [feed.absoluteString])
        XCTAssertEqual(loopback.installer?.url.absoluteString, prefix + "v2.5.634/" + F.installerName)
        FeedStubProtocol.body = F.data()
        let real = await InstallerReleaseFeed.fetch(from: feed, downloadPrefix: prefix, session: stubbedSession())
        XCTAssertEqual(real.rejection, .url)
    }
}
