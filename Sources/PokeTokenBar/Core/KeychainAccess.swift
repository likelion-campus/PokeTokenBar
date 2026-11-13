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
