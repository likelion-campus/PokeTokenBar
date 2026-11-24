import XCTest
@testable import PokeTokenBar

/// 자동 경로가 Claude Code 와 같은 방법(`/usr/bin/security`)으로 로그인을 읽는다는 계약.
/// 앱 자신의 `SecItemCopyMatching` 은 여전히 0회여야 한다(`KeychainAutoPathTests`).
/// 가드마다(접근 끔·잠김·시간 초과로 꺼짐·번들 아님) 그 가드만 빼면 실패하는 테스트가 있다.
final class KeychainToolReadTests: XCTestCase {
    private var savedGate = false
    private var calls: [[String]] = []
    private let service = OAuthCredentialData.claudeKeychainService

    override func setUp() {
        super.setUp()
        savedGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        KeychainToolReader.keychainUnlockedForTesting = true
        KeychainToolReader.isSuspended = false
        calls = []
        KeychainReader.resetQueryCountForTesting()
    }

    override func tearDown() {
        KeychainAccessGate.isDisabled = savedGate
        KeychainToolReader.runForTesting = nil
        KeychainToolReader.keychainUnlockedForTesting = nil
        KeychainToolReader.isSuspended = false
        super.tearDown()
    }

    private func json(token: String = "fake-tool-token", expired: Bool = false, plan: String = "max") -> Data {
        let ms = Int((Date().timeIntervalSince1970 + (expired ? -3600 : 3600)) * 1000)
        let text = #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(ms),"subscriptionType":"\#(plan)","rateLimitTier":"tier"}}"#
        return Data((text + "\n").utf8)
    }

    private func cache(services: [String]? = nil) -> OAuthAccessTokenCache {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-no-creds-\(UUID().uuidString).json")
        return OAuthAccessTokenCache(credentialsFileURL: missing, keychainServices: services ?? [service])
    }

    private func install(_ responder: @escaping ([String]) -> (status: Int32, stdout: Data)?) {
        KeychainToolReader.runForTesting = { [unowned self] args in
            self.calls.append(args)
            return responder(args)
        }
    }

    func testAutomaticPathReadsThroughTheTool() async throws {
        let live = json()
        install { _ in (0, live) }
        let c = cache()
        let token = try await c.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "fake-tool-token")
        XCTAssertEqual(KeychainReader.queryCount, 0)
        XCTAssertEqual(calls, [["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]])
        let plan = await c.planInfo()
        XCTAssertEqual(plan.subscriptionType, "max")
    }

    func testFallsBackToAnyAccountWhenTheNamedOneIsMissing() async throws {
        let live = json()
        install { args in args.contains("-a") ? (44, Data()) : (0, live) }
        let token = try await cache().accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "fake-tool-token")
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[1].contains("-a"))
    }

    func testGateOffNeverRunsTheTool() async {
        KeychainAccessGate.isDisabled = true
        install { _ in (0, self.json()) }
        await assertThrowsInteractionNotAllowed()
        XCTAssertTrue(calls.isEmpty)
    }

    func testLockedKeychainNeverRunsTheTool() async {
        KeychainToolReader.keychainUnlockedForTesting = false
        install { _ in (0, self.json()) }
        await assertThrowsInteractionNotAllowed()
        XCTAssertTrue(calls.isEmpty)
    }

    func testTimeoutSuspendsFurtherToolReads() async {
        install { _ in nil }
        let c = cache()
        let first = await OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool(services: [service])
        XCTAssertNil(first)
        XCTAssertTrue(KeychainToolReader.isSuspended)
        XCTAssertEqual(calls.count, 1)
        do { _ = try await c.accessToken(allowKeychainPrompt: false); XCTFail("should throw") } catch {}
        XCTAssertEqual(calls.count, 1, "suspended: no second process")
    }

    func testExpiredCredentialIsNotReturned() async {
        install { _ in (0, self.json(expired: true)) }
        await assertThrowsInteractionNotAllowed()
    }

    func testSecondServiceWinsWhenTheFirstIsMissing() async throws {
        let live = json(token: "second-token")
        install { args in args.contains("svc-one") ? (44, Data()) : (0, live) }
        let token = try await cache(services: ["svc-one", "svc-two"]).accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "second-token")
        XCTAssertEqual(calls.count, 3)
    }

    func testNotBundledWithoutSeamStartsNoProcess() async {
        let before = KeychainToolReader.runCount
        let result = await OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool(services: [service])
        XCTAssertNil(result)
        XCTAssertEqual(KeychainToolReader.runCount, before)
    }

    func testRealSecurityToolAcceptsTheArgumentForm() async throws {
        KeychainToolReader.keychainUnlockedForTesting = nil
        try XCTSkipUnless(KeychainToolReader.isDefaultKeychainUnlocked(), "default keychain locked")
        let missing = "PTB-NoSuchService-\(UUID().uuidString)"
        let start = Date()
        let result = try await ProcessRunner.runCapturingStdout(
            binary: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", missing, "-a", NSUserName(), "-w"],
            timeout: KeychainToolReader.timeout)
        XCTAssertEqual(result.status, 44)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), KeychainToolReader.timeout)
    }

    private func assertThrowsInteractionNotAllowed(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await cache().accessToken(allowKeychainPrompt: false)
            XCTFail("should throw", file: file, line: line)
        } catch let error as LimitsError {
            XCTAssertEqual(error, .keychainInteractionNotAllowed, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
