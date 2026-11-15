import XCTest
@testable import PokeTokenBar

/// The pure checks between the feed and the installer start (stage 8, D8 steps 2–4). Shared: both systems run them.
final class UpdateDownloadCheckTests: XCTestCase {
    private typealias Check = UpdateDownloadCheck
    /// 1 MiB, the smallest installer the feed accepts.
    private static let body = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private static let bodyHex = UpdateDownloadCheck.sha256Hex(body)

    /// The installer for `body`, made the only way one can be: a release answer through `installerCheck`.
    private func installer(version: String = "2.5.634") throws -> InstallerReleaseFeed.Installer {
        try XCTUnwrap(InstallerReleaseFeed.installer(in: ReleaseFixture.installerData(version: version, size: Self.body.count,
                                                                                      sha256: Self.bodyHex)))
    }

    private func url(_ s: String) -> URL? { URL(string: s) }

    private let finalURL = "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r&sig=abc"

    // MARK: before the download

    func testAnInstalledOlderCopyMayDownloadANewerInstaller() throws {
        let good = try installer()
        XCTAssertNil(Check.refusal(installing: good, currentVersion: "2.5.633"))
        XCTAssertNil(Check.refusal(installing: good, currentVersion: "2.4.999"))
        XCTAssertNil(Check.refusal(installing: try installer(version: "2.5.1000"), currentVersion: "2.5.999"), "numeric, not text")
    }

    func testWithoutAPlainVersionFileTheAppIsNotAnInstalledCopy() throws {
        let good = try installer()
        for current in [nil, "", "garbage", "2.5", "2.5.633.1", "v2.5.633-beta"] as [String?] {
            XCTAssertEqual(Check.refusal(installing: good, currentVersion: current), .notPackaged, current ?? "nil")
        }
    }

    func testTheSameOrAnOlderInstallerIsNotInstalled() throws {
        let good = try installer()
        for current in ["2.5.634", "v2.5.634", "2.5.635", "2.6.0", "3.0.0", "2.5.1000"] {
            XCTAssertEqual(Check.refusal(installing: good, currentVersion: current), .notNewer, current)
        }
    }

    // MARK: after the download

    func testACompleteDownloadFromGitHubPasses() throws {
        let good = try installer()
        for final in [finalURL, "https://objects.githubusercontent.com/x/y?z=1", "https://github.com/x",
                      "https://release-assets.githubusercontent.com:443/x"] {
            XCTAssertNil(Check.refusal(status: 200, finalURL: url(final), body: Self.body, for: good), final)
        }
    }

    func testAnAnswerOtherThan200IsRefusedFirst() throws {
        let good = try installer()
        for code in [0, 204, 206, 301, 302, 304, 403, 404, 500] {
            XCTAssertEqual(Check.refusal(status: code, finalURL: url("http://evil.test/"), body: Data(), for: good),
                           .status(code), "\(code)")
        }
    }

    func testAFinalAddressThatIsNotHTTPSIsInsecureUnlessTheLoopbackAllowsHTTP() throws {
        let good = try installer()
        for final in ["http://release-assets.githubusercontent.com/x", "ftp://github.com/x", "file:///C:/x.exe",
                      "HTTP://github.com/x"] {
            XCTAssertEqual(Check.refusal(status: 200, finalURL: url(final), body: Self.body, for: good), .insecure, final)
        }
        let loopback: (String) -> Bool = { $0 == "127.0.0.1" }
        XCTAssertNil(Check.refusal(status: 200, finalURL: url("http://127.0.0.1:50321/download/x.exe"), body: Self.body,
                                   for: good, allowedHost: loopback, allowHTTP: true))
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url("ftp://127.0.0.1/x"), body: Self.body, for: good,
                                     allowedHost: loopback, allowHTTP: true), .insecure, "allowHTTP allows HTTP only")
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url("http://evil.test/x"), body: Self.body, for: good,
                                     allowHTTP: true), .finalHost("evil.test"), "allowHTTP does not widen the hosts")
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url("http://127.0.0.1:50321/x"), body: Self.body, for: good),
                       .insecure, "without allowHTTP the loopback is refused")
    }

    func testAFinalHostOffTheListIsRefused() throws {
        let good = try installer()
        let cases: [(String, String)] = [
            ("https://githubusercontent.com.evil.test/x", "githubusercontent.com.evil.test"),
            ("https://evilgithubusercontent.com/x", "evilgithubusercontent.com"),
            ("https://api.github.com/repos/x", "api.github.com"),
            ("https://140.82.112.3/x", "140.82.112.3"),
            ("https://github.com@evil.test/x", "evil.test"),
            ("https://github.com.evil.test/x", "github.com.evil.test"),
        ]
        for (final, host) in cases {
            XCTAssertEqual(Check.refusal(status: 200, finalURL: url(final), body: Self.body, for: good), .finalHost(host), final)
        }
        XCTAssertEqual(Check.refusal(status: 200, finalURL: nil, body: Self.body, for: good), .finalHost(""))
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url("https://github.com:8443/x"), body: Self.body, for: good),
                       .finalHost("github.com:8443"), "HTTPS on another port")
    }

    func testOnlyGitHubAndItsAssetHostsAreAllowedFinalHosts() {
        for host in ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"] {
            XCTAssertTrue(Check.isAllowedFinalHost(host), host)
        }
        for host in ["githubusercontent.com.evil.test", "evilgithubusercontent.com", "api.github.com", "githubusercontent.com",
                     "github.com.evil.test", "evil-github.com", "gist.github.com", "github.co", "140.82.112.3", "127.0.0.1",
                     "::1", "[::1]", "", "github.com.", "release-assets.githubusercontent.com.evil.test"] {
            XCTAssertFalse(Check.isAllowedFinalHost(host), host)
        }
    }

    func testABodyOfAnotherLengthIsRefused() throws {
        let good = try installer()
        for cut in [Data(), Self.body.dropLast(), Self.body + Data([0])] {
            XCTAssertEqual(Check.refusal(status: 200, finalURL: url(finalURL), body: Data(cut), for: good),
                           .length(expected: Self.body.count, got: cut.count))
        }
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url("https://evil.test/x"), body: Data(), for: good),
                       .finalHost("evil.test"), "the host is checked before the length")
    }

    func testOneChangedByteIsRefusedByTheDigest() throws {
        let good = try installer()
        for index in [0, Self.body.count / 2, Self.body.count - 1] {
            var tampered = Self.body
            tampered[index] ^= 0x01
            XCTAssertEqual(Check.refusal(status: 200, finalURL: url(finalURL), body: tampered, for: good), .digest, "\(index)")
        }
        XCTAssertEqual(Check.refusal(status: 200, finalURL: url(finalURL), body: Data(Self.body.dropLast()), for: good),
                       .length(expected: Self.body.count, got: Self.body.count - 1), "the length is checked before the digest")
    }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(Check.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Check.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Check.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testEveryRefusalHasItsOwnTextWithoutAnAddress() {
        let all: [Check.Refusal] = [.notPackaged, .notNewer, .status(404), .insecure, .finalHost("evil.test"), .finalHost(""),
                                    .length(expected: 2, got: 1), .digest]
        XCTAssertEqual(Set(all.map(\.description)).count, all.count)
        for refusal in all { XCTAssertFalse(refusal.description.contains("/"), "\(refusal): no path or query in the log") }
        XCTAssertTrue(Check.Refusal.finalHost("evil.test").description.contains("evil.test"))
        XCTAssertTrue(Check.Refusal.length(expected: 2, got: 1).description.contains("2"))
    }
}
