import XCTest
@testable import PokeTokenBar

/// 자동 경로가 Claude Code 와 같은 방법(`/usr/bin/security`)으로 로그인을 읽는다는 계약.
/// 앱 자신의 `SecItemCopyMatching` 은 여전히 0회여야 한다(`KeychainAutoPathTests`).
/// 가드마다(접근 끔·잠김·꺼짐·번들 아님) 그 가드만 빼면 실패하는 테스트가 있다.
///
/// 안전: 모든 시험은 존재할 수 없는 UUID 서비스 이름만 쓴다 — 가드가 깨져도 실제 `Claude Code-credentials`
/// 항목을 읽지 않는다. 토큰 값은 단언 메시지에 찍지 않는다(`==` 를 `XCTAssertTrue` 안에서 비교).
final class KeychainToolReadTests: XCTestCase {
    private var savedGate = false
    private var calls: [[String]] = []
    private let service = "PTB-NoSuchService-\(UUID().uuidString)"
    private let fakePath = "/tmp/ptb-test-default.keychain-db"

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
        KeychainReader.copyMatchingForTesting = nil
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
        XCTAssertTrue(token == "fake-tool-token", "token mismatch")
        XCTAssertEqual(KeychainReader.queryCount, 0)
        XCTAssertTrue(calls == [["find-generic-password", "-s", service, "-a", NSUserName(), "-w", fakePath]],
                      "unexpected tool arguments")
        let plan = await c.planInfo()
        XCTAssertEqual(plan.subscriptionType, "max")
    }

    func testFallsBackToAnyAccountWhenTheNamedOneIsMissing() async throws {
        let live = json()
        install { args in args.contains("-a") ? (44, Data()) : (0, live) }
        let token = try await cache().accessToken(allowKeychainPrompt: false)
        XCTAssertTrue(token == "fake-tool-token", "token mismatch")
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[1].contains("-a"))
        XCTAssertEqual(calls[1].last, fakePath)
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

    func testAnUnexpectedExitSuspendsLikeATimeout() async {
        for status: Int32 in [51, 128] {
            KeychainToolReader.isSuspended = false
            calls = []
            install { _ in (status, Data()) }
            let first = await OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool(services: [service])
            XCTAssertNil(first)
            XCTAssertTrue(KeychainToolReader.isSuspended, "exit \(status) must suspend")
            XCTAssertEqual(calls.count, 1)
            _ = try? await cache().accessToken(allowKeychainPrompt: false)
            XCTAssertEqual(calls.count, 1, "exit \(status): no second process")
        }
    }

    func testExitFortyFourDoesNotSuspend() async {
        install { _ in (44, Data()) }
        _ = await OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool(services: [service])
        XCTAssertFalse(KeychainToolReader.isSuspended)
        XCTAssertEqual(calls.count, 2)
    }

    func testAManualRefreshClearsTheSuspension() async {
        KeychainToolReader.isSuspended = true
        KeychainReader.copyMatchingForTesting = { _, _ in errSecItemNotFound }
        _ = try? await cache().accessToken(allowKeychainPrompt: true)
        XCTAssertFalse(KeychainToolReader.isSuspended)
    }

    func testExpiredCredentialIsNotReturned() async {
        install { _ in (0, self.json(expired: true)) }
        await assertThrowsInteractionNotAllowed()
        XCTAssertEqual(calls.count, 1, "expired: no no-account retry")
    }

    func testALiveCachedToolCredentialSuppressesTheNextToolRead() async throws {
        let live = json()
        install { _ in (0, live) }
        let c = cache()
        _ = try await c.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(calls.count, 1)
        _ = try await c.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(calls.count, 1, "the cache answers; no second process")
    }

    func testSecondServiceWinsWhenTheFirstIsMissing() async throws {
        let live = json(token: "second-token")
        let first = "svc-one-\(UUID().uuidString)"
        install { args in args.contains(first) ? (44, Data()) : (0, live) }
        let token = try await cache(services: [first, service]).accessToken(allowKeychainPrompt: false)
        XCTAssertTrue(token == "second-token", "token mismatch")
        XCTAssertEqual(calls.count, 3)
    }

    func testNotBundledWithoutSeamStartsNoProcess() async {
        let before = KeychainToolReader.runCount
        let result = await OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool(services: [service])
        XCTAssertNil(result)
        XCTAssertEqual(KeychainToolReader.runCount, before)
    }

    func testCredentialDescriptionsNeverContainTheToken() {
        let secret = "sk-secret-\(UUID().uuidString)"
        guard let credential = OAuthCredentialData.credential(from: json(token: secret)) else {
            return XCTFail("fixture did not parse")
        }
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)"] {
            XCTAssertFalse(text.contains(secret), "a credential description leaked the token")
        }
    }

    func testRealSecurityToolAcceptsTheArgumentForm() async throws {
        KeychainToolReader.keychainUnlockedForTesting = nil
        let path = try XCTUnwrap(KeychainToolReader.unlockedDefaultKeychainPath(), "default keychain locked")
        let start = Date()
        let result = try await ProcessRunner.runCapturingStdout(
            binary: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-a", NSUserName(), "-w", path],
            timeout: KeychainToolReader.timeout)
        XCTAssertEqual(result.status, 44)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), KeychainToolReader.timeout)
    }

    func testRunnerTimesOutAndLeavesNoProcess() async throws {
        let start = Date()
        do {
            _ = try await ProcessRunner.runCapturingStdout(binary: "/bin/sleep", arguments: ["5"], timeout: 0.2)
            XCTFail("should time out")
        } catch RunnerError.timeout {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunnerCapturesStdoutExactly() async throws {
        let result = try await ProcessRunner.runCapturingStdout(
            binary: "/bin/echo", arguments: ["hello"], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello\n")
    }

    func testRunnerReadsOutputLargerThanThePipeBuffer() async throws {
        let result = try await ProcessRunner.runCapturingStdout(
            binary: "/usr/bin/head", arguments: ["-c", "300000", "/dev/zero"], timeout: 5)
        XCTAssertEqual(result.stdout.count, 300_000)
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
