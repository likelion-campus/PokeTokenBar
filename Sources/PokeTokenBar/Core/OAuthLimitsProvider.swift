import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Security

extension OAuthAccessTokenCache {
    /// 무프롬프트 Keychain 읽기 — no-UI 쿼리라 권한이 없으면 프롬프트 대신 errSecInteractionNotAllowed.
    /// '아직 항상 허용 전'(interactionNotAllowed)은 정상 흐름이라 조용히 nil. 그 외(형식 오류·접근 불가)는
    /// 진단을 위해 로그를 남기고 nil — 자동 경로가 왜 토큰을 못 구했는지 추적 가능하게.
    /// An expired token also gives nil: another service name may hold the live one behind a prompt.
    nonisolated static func readClaudeKeychainSilently(services: [String]) -> OAuthCredentialData.Credential? {
        do {
            let credential = try firstUsableCredential(services: services) {
                try readClaudeKeychain(service: $0, allowKeychainPrompt: false)
            }
            return credential.isExpired ? nil : credential
        } catch LimitsError.keychainInteractionNotAllowed {
            return nil
        } catch {
            AppLog.write("silent claude keychain read failed: \(error)")
            return nil
        }
    }

    /// 자동 경로의 유일한 Claude Keychain 읽기: Claude Code 가 쓰는 `/usr/bin/security` 로 읽는다.
    /// 항목 ACL 이 이 도구를 신뢰하므로 다이얼로그가 없다(`SecItemCopyMatching` 은 쓰지 않는다).
    /// 가드(순서): 접근 끔 → 시험 이음매/번들 아님 → 꺼짐(시간 초과·예상 밖 종료 코드) → 기본 키체인 잠김.
    /// 어느 하나라도 걸리면 프로세스 없이 nil. 종료 코드 0·44(항목 없음) 말고는 다이얼로그를 사용자가 거절한 것일 수 있어
    /// 시간 초과처럼 앱을 다시 켤 때까지(또는 사용자 갱신 버튼까지) 끈다.
    /// 로그에는 종료 코드·바이트 수만 — 출력·토큰·계정 이름은 남기지 않는다.
    nonisolated static func readClaudeKeychainViaSecurityTool(
        services: [String]) async -> OAuthCredentialData.Credential?
    {
        let logKey = "claude-keychain-tool"
        if KeychainAccessGate.isDisabled { return nil }
        if KeychainToolReader.runForTesting == nil, !AppEnv.isBundledApp { return nil }
        if KeychainToolReader.isSuspended {
            AppLog.writeIfChanged(logKey, "claude keychain tool read: skipped, suspended")
            return nil
        }
        guard let keychainPath = KeychainToolReader.unlockedDefaultKeychainPath() else {
            AppLog.writeIfChanged(logKey, "claude keychain tool read: skipped, default keychain locked or unavailable")
            return nil
        }

        for service in services {
            let withAccount = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w", keychainPath]
            let anyAccount = ["find-generic-password", "-s", service, "-w", keychainPath]
            for arguments in [withAccount, anyAccount] {
                switch await KeychainToolReader.run(arguments: arguments) {
                case .timedOut:
                    KeychainToolReader.isSuspended = true
                    AppLog.write("claude keychain tool read timed out; automatic keychain reads off until restart")
                    return nil
                case .failed:
                    AppLog.writeIfChanged(logKey, "claude keychain tool read: could not run the tool (launch failed or cancelled)")
                    return nil
                case .finished(let status, let stdout):
                    if status == 44 { continue }
                    if status != 0 {
                        KeychainToolReader.isSuspended = true
                        AppLog.write("claude keychain tool read: exit \(status); automatic keychain reads off until restart")
                        return nil
                    }
                    guard let credential = OAuthCredentialData.credential(from: stdout) else {
                        AppLog.writeIfChanged(logKey, "claude keychain tool read: unparsable (\(stdout.count) bytes)")
                        break
                    }
                    if credential.isExpired {
                        AppLog.writeIfChanged(logKey, "claude keychain tool read: credential expired")
                        break
                    }
                    return credential
                }
                // 읽혔지만 쓸 수 없는 출력(만료·형식 오류): -a 없는 재시도로 다른 항목을 찾지 않고 다음 서비스로 간다 —
                // 흔한 만료 경우에 프로세스 하나를 아끼는 선택이다.
                break
            }
        }
        return nil
    }

    /// 사용자 갱신 버튼이 자동 도구 읽기의 꺼짐을 푼다(그 경로는 프롬프트가 허용된 사용자 동작).
    nonisolated static func resumeKeychainToolReads() { KeychainToolReader.isSuspended = false }

    nonisolated static func readClaudeKeychain(
        service: String, allowKeychainPrompt: Bool) throws -> OAuthCredentialData.Credential
    {
        if KeychainAccessGate.isDisabled {
            throw LimitsError.keychainAccessDisabled
        }
        // 두 단계로 나눈다: ① 계정 목록을 **속성만** 받아 열거 ② 계정별로 데이터를 하나씩 읽기.
        // 한 번에 `kSecMatchLimitAll` + `kSecReturnData` 로 받을 수 없다 — macOS 는 그 조합을
        // errSecParam(-50) 으로 거절하며, 항목 존재 여부·ACL 승인과 무관하게 실패한다(실측).
        // 그래서 이 조합은 "여러 항목 중 고르기"를 아예 불가능하게 만들었다.
        var accounts: [String] = []
        var enumerateStatus = errSecSuccess
        do {
            var item: CFTypeRef?
            let query = OAuthCredentialData.claudeKeychainAccountsQuery(
                service: service, allowKeychainPrompt: allowKeychainPrompt)
            enumerateStatus = KeychainReader.copyMatching(query, &item)
            if enumerateStatus == errSecInteractionNotAllowed {
                throw LimitsError.keychainInteractionNotAllowed
            }
            if enumerateStatus == errSecItemNotFound {
                throw LimitsError.keychainUnavailable(enumerateStatus)
            }
            if enumerateStatus == errSecSuccess {
                accounts = OAuthCredentialData.prioritizedAccountNames(from: item)
            }
        }

        // 계정 속성을 못 얻으면(구 키체인·속성 미반환) 스코프 없는 단건 읽기로 폴백한다 —
        // 항목이 하나뿐인 흔한 경우는 이 경로로 그대로 동작한다.
        let candidates: [String?] = accounts.isEmpty ? [nil] : accounts.map { $0 }

        var sawAccountOAuthMissing = false
        var lastStatus = enumerateStatus
        for account in candidates {
            var item: CFTypeRef?
            let query = OAuthCredentialData.claudeKeychainDataQuery(
                account: account, service: service, allowKeychainPrompt: allowKeychainPrompt)
            let status = KeychainReader.copyMatching(query, &item)
            if status == errSecInteractionNotAllowed {
                throw LimitsError.keychainInteractionNotAllowed
            }
            // 사용자가 시스템 다이얼로그에서 '취소'를 눌렀거나 인증에 실패한 경우,
            // 다음 계정으로 계속 넘어가며 프롬프트 폭탄(Prompt Bombing)을 띄우지 않고 즉시 중단한다(#280).
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw LimitsError.keychainUnavailable(status)
            }
            lastStatus = status
            guard status == errSecSuccess, let data = item as? Data else { continue }
            // 여러 항목(예: acct="unknown" MCP 전용 + acct="<user>" 계정 토큰) 중
            // 유효한 claudeAiOauth 계정 토큰이 있는 자격증명을 먼저 찾는다.
            if let credential = OAuthCredentialData.credential(from: data) {
                return credential
            }
            if OAuthCredentialData.isAccountOAuthMissing(data) { sawAccountOAuthMissing = true }
        }

        // 읽어낸 데이터가 하나도 없으면 자격증명 문제가 아니라 키체인 접근 문제다.
        guard lastStatus == errSecSuccess || sawAccountOAuthMissing else {
            throw LimitsError.keychainUnavailable(lastStatus)
        }
        // 항목은 있는데 계정 OAuth 만 없는 상태(MCP OAuth 전용)는 재로그인 안내 대상이라 구분한다.
        throw sawAccountOAuthMissing
            ? LimitsError.credentialMissingAccountOAuth
            : LimitsError.credentialFormat
    }
}

extension OAuthCredentialData {
    /// 계정 열거용 쿼리 — **데이터를 요청하지 않는다.**
    ///
    /// `kSecMatchLimitAll` 은 `kSecReturnData` 와 함께 쓸 수 없다. macOS 는 그 조합을
    /// errSecParam(-50) 으로 거절하는데, 이건 항목이 없어서가 아니라 파라미터가 무효라서라
    /// ACL 승인이나 항목 존재 여부로는 우회되지 않는다. 속성만 받아 계정 이름을 얻고,
    /// 데이터는 `claudeKeychainDataQuery` 로 계정별 단건 조회한다.
    /// 가드: `testAllItemsQueryNeverAsksForDataAndIsAcceptedBySecurityFramework`.
    static func claudeKeychainAccountsQuery(
        service: String = claudeKeychainService, allowKeychainPrompt: Bool) -> [String: Any]
    {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if !allowKeychainPrompt { KeychainNoUIQuery.apply(to: &query) }
        return query
    }

    /// 자격증명 데이터 단건 조회 — `kSecMatchLimitOne` 고정.
    /// `account` 가 nil 이면 서비스 전체에서 한 건(계정 속성을 못 얻은 폴백 경로).
    static func claudeKeychainDataQuery(
        account: String?, service: String = claudeKeychainService, allowKeychainPrompt: Bool) -> [String: Any]
    {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !allowKeychainPrompt { KeychainNoUIQuery.apply(to: &query) }
        return query
    }

    /// 속성 조회 결과에서 `acct` 목록을 뽑는다(순서 유지, 중복 제거, 공백 트림).
    static func accountNames(from item: Any?) -> [String] {
        let rows: [[String: Any]]
        if let array = item as? [[String: Any]] { rows = array }
        else if let one = item as? [String: Any] { rows = [one] }
        else { return [] }
        var seen = Set<String>()
        return rows.compactMap {
            ($0[kSecAttrAccount as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 속성 조회 결과에서 `acct` 목록을 뽑고, 사용자 계정 토큰을 담고 있을 확률이 높은 순서로 정렬한다.
    ///
    /// 왜 필요한가: Claude Code 는 사용자 계정 OAuth 를 주로 현재 Mac 로그인 사용자명(`NSUserName()`)으로 저장하고,
    /// MCP OAuth 등은 `acct="unknown"` 등으로 별도 저장한다. 키체인이 반환한 순서 그대로 조회하면
    /// MCP 전용 항목(`unknown`)을 먼저 열람하느라 불필요한 시스템 암호 프롬프트가 발생하고,
    /// 이어서 실제 계정 항목을 열람할 때 두 번째 암호 프롬프트를 또 띄우게 된다(#280).
    ///
    /// 우선순위:
    /// 1. 현재 Mac 로그인 사용자명과 일치하는 계정 (대소문자 무시, 단 'unknown' 제외)
    /// 2. 유효한 이메일 주소 형식(`user@domain.tld`) 계정
    /// 3. "unknown"이 아닌 일반 계정
    /// 4. "unknown", "none" 등 MCP/플레이스홀더 계정
    /// 같은 우선순위 내에서는 기존 열거 순서를 보존(stable)한다.
    static func prioritizedAccountNames(
        from item: Any?,
        currentUserName: String = NSUserName()
    ) -> [String] {
        let names = accountNames(from: item)
        guard names.count > 1 else { return names }
        let trimmedUser = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.enumerated().sorted { first, second in
            let p1 = priority(for: first.element, currentUser: trimmedUser)
            let p2 = priority(for: second.element, currentUser: trimmedUser)
            if p1 != p2 {
                return p1 < p2
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    private static func priority(for account: String, currentUser: String) -> Int {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 4 }
        let lower = trimmed.lowercased()

        // 1. unknown, none 등 명백한 플레이스홀더는 시스템 유저명이 'unknown'이어도 항상 최하위 고정
        if lower == "unknown" || lower == "none" {
            return 3
        }

        // 2. Mac 현재 로그인 유저명 (단, 유저명이 unknown인 환경은 예외)
        let lowerUser = currentUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !lowerUser.isEmpty && lowerUser != "unknown" && lower == lowerUser {
            return 0
        }

        // 3. 실제 이메일 형식 (도메인 온점 포함, 선/후행 @ 제외)
        if lower.contains("@") && lower.contains(".") && !lower.hasPrefix("@") && !lower.hasSuffix("@") {
            return 1
        }

        return 2
    }
}
