import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PokeTokenBar

/// The credentials-file path of Claude's official limits (`Core/ClaudeOAuthLimitsProvider.swift`), on both OSes.
/// Every test uses `forConfigRoot(tempDir)`, so no real `~/.claude` file and no Keychain is read, and a
/// `URLProtocol` stub stands in for the endpoint.
final class ClaudeOAuthFileCredentialTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-oauth-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileOAuthStubProtocol.reset()
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(FileOAuthStubProtocol.self)
        FileOAuthStubProtocol.reset()
        AppEnv.allowLiveFetchForTesting = false
        try? FileManager.default.removeItem(at: root)
    }

    private var credentialsFile: URL { ClaudeAccountRoots.credentialsFileURL(for: root) }

    private func writeCredentials(token: String, expiresIn: TimeInterval = 3600, plan: String = "max") throws {
        let expiresAt = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(expiresAt),"subscriptionType":"\#(plan)"}}"#
        try Data(json.utf8).write(to: credentialsFile)
    }

    private func openGateWithStub() {
        AppEnv.allowLiveFetchForTesting = true
        URLProtocol.registerClass(FileOAuthStubProtocol.self)
    }

    func testFileTokenIsUsedWithoutTheKeychain() async throws {
        try writeCredentials(token: "file-token-1", plan: "team")
        let cache = OAuthAccessTokenCache.forConfigRoot(root)
        let token = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "file-token-1")
        let plan = await cache.planInfo()
        XCTAssertEqual(plan.subscriptionType, "team")
    }

    func testExpiredFileTokenIsNotUsed() async throws {
        try writeCredentials(token: "stale", expiresIn: -3600)
        let cache = OAuthAccessTokenCache.forConfigRoot(root)
        do {
            _ = try await cache.accessToken(allowKeychainPrompt: false)
            XCTFail("an expired file token was handed out")
        } catch LimitsError.keychainInteractionNotAllowed {
            // The automatic path does not go on to a secret store.
        }
    }

    func testAccountOAuthMissingAsksForRelogin() async throws {
        try Data(#"{"mcpOAuth":{"some-server":{}}}"#.utf8).write(to: credentialsFile)
        let cache = OAuthAccessTokenCache.forConfigRoot(root)
        do {
            _ = try await cache.accessToken(allowKeychainPrompt: false)
            XCTFail("a file without account OAuth produced a token")
        } catch LimitsError.credentialMissingAccountOAuth {
        }
    }

    func testNoFileOnTheAutomaticPathIsInteractionNotAllowed() async throws {
        let cache = OAuthAccessTokenCache.forConfigRoot(root)
        do {
            _ = try await cache.accessToken(allowKeychainPrompt: false)
            XCTFail("no file, no token")
        } catch LimitsError.keychainInteractionNotAllowed {
        }
    }

    func testFetchSendsTheFileTokenAndDecodesTheStatus() async throws {
        try writeCredentials(token: "file-token-2", plan: "max")
        openGateWithStub()
        FileOAuthStubProtocol.responder = { _, _ in (200, [:], Data(#"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#.utf8)) }
        let status = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
        XCTAssertEqual(FileOAuthStubProtocol.usageAuthorizations, ["Bearer file-token-2"])
        XCTAssertEqual(status.subscriptionType, "max")
    }

    /// A 401 makes the provider read the file again exactly once. A new token in it is retried; the same token ends.
    func test401RereadsTheFileOnce() async throws {
        try writeCredentials(token: "old-token")
        openGateWithStub()
        let file = credentialsFile
        let rewrite: @Sendable () -> Void = {
            let expiresAt = Int((Date().timeIntervalSince1970 + 3600) * 1000)
            let json = #"{"claudeAiOauth":{"accessToken":"new-token","expiresAt":\#(expiresAt)}}"#
            try? Data(json.utf8).write(to: file)
        }
        FileOAuthStubProtocol.responder = { auth, _ in
            if auth == "Bearer old-token" { rewrite(); return (401, [:], Data()) }
            return (200, [:], Data(#"{"five_hour":{"utilization":5}}"#.utf8))
        }
        _ = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
        XCTAssertEqual(FileOAuthStubProtocol.usageAuthorizations, ["Bearer old-token", "Bearer new-token"])
    }

    func test401WithTheSameTokenInTheFileDoesNotLoop() async throws {
        try writeCredentials(token: "same-token")
        openGateWithStub()
        FileOAuthStubProtocol.responder = { _, _ in (401, [:], Data()) }
        do {
            _ = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
            XCTFail("401 must surface")
        } catch LimitsError.httpStatus(let status) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(FileOAuthStubProtocol.usageAuthorizations.count, 1)
    }

    func test429CarriesRetryAfter() async throws {
        try writeCredentials(token: "file-token-3")
        openGateWithStub()
        FileOAuthStubProtocol.responder = { _, _ in (429, ["Retry-After": "120"], Data()) }
        do {
            _ = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
            XCTFail("429 must surface")
        } catch LimitsError.rateLimited(let after) {
            XCTAssertEqual(after, 120)
        }
    }

    func testGateClosedUnderSwiftTestWithoutTheTestingFlag() async throws {
        if AppEnv.isParityRun { throw XCTSkip("PTB_PARITY=1 opens the gate on purpose") }
        try writeCredentials(token: "file-token-4")
        URLProtocol.registerClass(FileOAuthStubProtocol.self)
        FileOAuthStubProtocol.responder = { _, _ in (200, [:], Data("{}".utf8)) }
        do {
            _ = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
            XCTFail("the closed gate let a live call through")
        } catch LimitsError.liveFetchNotPermitted {
        }
        XCTAssertEqual(FileOAuthStubProtocol.usageAuthorizations, [], "nothing may reach the transport")
    }

    #if os(Windows)
    /// No Keychain on Windows: a user refresh without a usable file ends in the Mac's own "access disabled" error.
    func testUserRefreshWithoutAFileReportsKeychainAccessDisabled() async throws {
        let cache = OAuthAccessTokenCache.forConfigRoot(root)
        do {
            _ = try await cache.accessToken(allowKeychainPrompt: true)
            XCTFail("no file and no secret store produced a token")
        } catch LimitsError.keychainAccessDisabled {
        }
    }

    func testWindowsFactoryBuildsTheRealClaudeProviderAndAnUnavailableAntigravity() async {
        let factory = WindowsLimitsProviders()
        XCTAssertTrue(factory.claudeOAuth(configRoot: nil) is OAuthLimitsProvider)
        XCTAssertTrue(factory.claudeOAuth(configRoot: root) is OAuthLimitsProvider)
        do {
            _ = try await factory.antigravity().fetch(allowKeychainPrompt: false)
            XCTFail("Antigravity is not available on Windows")
        } catch LimitsError.keychainAccessDisabled {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
    #endif
}

/// Stands in for api.anthropic.com. `responder` gets the usage call's Authorization header and the URL.
private final class FileOAuthStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (String, URL) -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedResponder: Responder?
    nonisolated(unsafe) private static var storedAuthorizations: [String] = []

    static var responder: Responder? {
        get { lock.lock(); defer { lock.unlock() }; return storedResponder }
        set { lock.lock(); storedResponder = newValue; lock.unlock() }
    }
    static var usageAuthorizations: [String] { lock.lock(); defer { lock.unlock() }; return storedAuthorizations }
    static func reset() { lock.lock(); storedResponder = nil; storedAuthorizations = []; lock.unlock() }
    private static func record(_ auth: String) { lock.lock(); storedAuthorizations.append(auth); lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var status = 404
        var headers: [String: String] = [:]
        var body = Data()
        if url.path == "/api/oauth/usage", let responder = Self.responder {
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.record(auth)
            (status, headers, body) = responder(auth, url)
        }
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
