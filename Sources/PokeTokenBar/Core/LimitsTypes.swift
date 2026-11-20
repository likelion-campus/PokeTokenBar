import Foundation

enum LimitsError: Error, Equatable {
    case keychainAccessDisabled
    /// A live limits call outside the app bundle (`swift test`, a raw binary). See `AppEnv.allowsLiveLimitsFetch`.
    case liveFetchNotPermitted
    case keychainUnavailable(OSStatus)
    case keychainInteractionNotAllowed
    case credentialFormat
    /// 자격증명은 읽혔지만 Claude 계정 OAuth(`claudeAiOauth`)가 없다 — MCP 서버 OAuth 상태만 들어있는 경우.
    /// Claude Code 2.1.x 에서 관측된다. 형식 오류가 아니라 재로그인이 필요한 상태라 따로 구분한다.
    case credentialMissingAccountOAuth
    case httpStatus(Int)
    /// 429 — 서버가 지정한 Retry-After(초, 없으면 nil). 폴링 백오프 판단에 사용.
    case rateLimited(retryAfter: TimeInterval?)

    // ── claude.ai 세션 키 경로 (SessionKeyLimitsProvider)
    /// 세션 키가 저장돼 있지 않다 — 키를 안 쓰는 사용자의 정상 상태다. 체인은 조용히 OAuth 로 내려간다.
    case sessionKeyMissing
    /// 붙여넣은 값이 세션 키 형식이 아니다(설정 화면 검증).
    case sessionKeyMalformed
    /// 세션 키가 만료·무효 — 브라우저에서 다시 복사해야 한다. claude.ai 는 401 뿐 아니라 **403** 으로도
    /// 거절하므로(조직 스코프가 아닌 `/api/organizations` 의 403 이 그 신호다) 양쪽을 여기로 접는다.
    case sessionKeyInvalid
    /// 키는 유효하지만 한도를 볼 수 있는 조직이 없다(전부 403).
    case sessionKeyNoOrganization
}

/// Claude 한도 조회 추상화 — 실 구현(OAuthLimitsProvider) 또는 테스트 스텁 주입.
protocol ClaudeLimitsProviding: Sendable {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus
}

/// OAuth 토큰의 실제 주인(계정 이메일·조직명). usage 응답에는 계정 정보가 없어 profile endpoint 로 조회한다.
struct AccountIdentity: Equatable, Sendable {
    let email: String
    let organizationName: String?
    /// 서버가 알려주는 현재 플랜 이름(`organization.plan_display_name`). 이름 변경을
    /// 코드 수정 없이 따라가기 위한 값 — 저장 로그인(.claude.json)에는 없어서 nil 이다.
    var planDisplayName: String? = nil
}

enum OAuthCredentialData {
    static let claudeKeychainService = "Claude Code-credentials"

    struct Credential {
        let accessToken: String
        let expiresAt: Date?
        let data: Data
        /// 구독 등급(max/pro/free)과 rate limit 티어(default_claude_max_20x 등) — 플랜 표시용.
        let subscriptionType: String?
        let rateLimitTier: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date().addingTimeInterval(60)
        }
    }

    /// JSON 은 멀쩡한데 `claudeAiOauth` 만 없는 상태인지. Claude Code 2.1.x 의 자격증명 항목이
    /// MCP 서버 OAuth(`mcpOAuth`) 상태만 담고 계정 토큰은 안 담는 경우가 있어, 이때는 파싱 실패를
    /// "형식 오류"가 아니라 "재로그인 필요"로 안내해야 한다.
    /// (JSON 자체가 깨진 경우는 여기 해당하지 않는다 — 그건 형식 오류다.)
    ///
    /// `json["claudeAiOauth"] == nil` 로 검사하면 안 된다. 명시적 JSON `null` 은 `NSNull` 로 디코드돼
    /// `!= nil` 이 참이 되므로, 로그아웃 상태(`"claudeAiOauth": null`)를 "값 있음"으로 오판해 재로그인
    /// 안내 대신 "자격증명 없음"을 띄운다. 딕셔너리로 캐스팅되는지로 판단한다.
    static func isAccountOAuthMissing(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["claudeAiOauth"] as? [String: Any]) == nil
    }

    static func credential(from data: Data) -> Credential? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return nil
        }
        return Credential(
            accessToken: token,
            expiresAt: expiresAt(from: oauth["expiresAt"]),
            data: data,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    private static func expiresAt(from raw: Any?) -> Date? {
        let value: Double?
        switch raw {
        case let raw as Double:
            value = raw
        case let raw as Int:
            value = Double(raw)
        case let raw as Int64:
            value = Double(raw)
        case let raw as String:
            value = Double(raw)
        default:
            value = nil
        }
        guard let value, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
