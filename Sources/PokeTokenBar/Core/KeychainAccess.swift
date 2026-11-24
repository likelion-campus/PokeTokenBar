import Foundation

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

/// 모든 Keychain 조회의 단일 통로.
///
/// `allowKeychainPrompt: false` 는 "프롬프트를 띄우지 않는다"가 아니라 **"Keychain 을 아예
/// 조회하지 않는다"** 는 계약이다 — no-UI 쿼리로도 잠긴·미승인 login 키체인의 암호 다이얼로그는
/// 억제되지 않기 때문이다(`OAuthLimitsProvider` 의 실측: 13초 블록 + 팝업).
///
/// 그 계약을 규약이 아니라 가드로 만들려면 조회 횟수를 셀 수 있어야 한다. 프로바이더가
/// `SecItemCopyMatching` 을 각자 직접 부르면 "자동 경로는 0회" 를 행동으로 검증할 방법이 없고,
/// 실제로 그 틈으로 자동 폴링이 키체인을 읽는 구현이 스위트 초록인 채 들어왔다(#210).
enum KeychainReader {
    nonisolated(unsafe) private(set) static var queryCount = 0
    /// 테스트가 Keychain 항목을 주입한다. 설정돼 있으면 `SecItemCopyMatching` 을 부르지 않는다.
    /// tearDown 에서 반드시 nil 로 되돌린다 — 남으면 다른 테스트가 실제 키체인을 못 본다.
    nonisolated(unsafe) static var copyMatchingForTesting: (([String: Any], inout CFTypeRef?) -> OSStatus)?

    static func resetQueryCountForTesting() { queryCount = 0 }

    static func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        queryCount += 1
        if let copyMatchingForTesting {
            return copyMatchingForTesting(query, &result)
        }
        return SecItemCopyMatching(query as CFDictionary, &result)
    }
}

/// Claude Code 가 로그인을 쓰고 읽는 도구(`/usr/bin/security`)로 자동 경로가 읽을 때의 안전 장치와 시험 이음매.
/// 항목의 복호화 ACL 은 만든 도구(`/usr/bin/security`)를 신뢰하므로 이 도구는 다이얼로그 없이 읽는다 —
/// 이 앱이 `SecItemCopyMatching` 을 부르면 self-signed 라 암호 다이얼로그가 뜨던 것과 다르다.
enum KeychainToolReader {
    /// 프로세스를 대신하는 시험 이음매. nil 을 돌려주면 시간 초과. tearDown 에서 nil 로 되돌린다.
    nonisolated(unsafe) static var runForTesting: (([String]) async -> (status: Int32, stdout: Data)?)?
    /// 기본 키체인이 열려 있는지의 시험 값. nil 이면 실제로 묻는다.
    nonisolated(unsafe) static var keychainUnlockedForTesting: Bool?
    /// 시간 초과 뒤 앱을 다시 켤 때까지 도구 읽기를 끈다. tearDown 에서 false 로.
    nonisolated(unsafe) static var isSuspended = false
    static let timeout: TimeInterval = 3
    /// `run` 호출 수(시험 이음매 포함) — "프로세스를 시작하지 않았다" 를 세는 가드용.
    nonisolated(unsafe) private(set) static var runCount = 0

    /// 기본 키체인이 잠겼으면 `security` 가 잠금 해제 다이얼로그를 띄운다. 이 두 호출은 프롬프트하지 않는다.
    /// 오류는 모두 "열려 있지 않음".
    static func isDefaultKeychainUnlocked() -> Bool {
        if let keychainUnlockedForTesting { return keychainUnlockedForTesting }
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }

    /// nil 은 시간 초과(또는 실행 실패).
    static func run(arguments: [String]) async -> (status: Int32, stdout: Data)? {
        runCount += 1
        if let runForTesting { return await runForTesting(arguments) }
        return try? await ProcessRunner.runCapturingStdout(
            binary: "/usr/bin/security", arguments: arguments, timeout: timeout)
    }
}

enum KeychainNoUIQuery {
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Some legacy Keychain ACL states can still prompt unless the old UI-fail
        // policy is present. Resolve it dynamically to avoid deprecated API usage.
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    static func uiFailPolicyForTesting() -> String {
        uiFailPolicy
    }

    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
#endif
