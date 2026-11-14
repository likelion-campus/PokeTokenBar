import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 공식 한도 % 조회 — Claude Code 자격증명(Keychain)의 OAuth 토큰으로 usage endpoint 호출.
/// 비공식 endpoint 이므로 실패해도 토큰 표시에는 영향 없음 (한도 섹션만 숨김).
struct OAuthLimitsProvider: ClaudeLimitsProviding, Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let accessTokenCache: OAuthAccessTokenCache

    /// `accessTokenCache` defaults to the `~/.claude` login; extra accounts pass
    /// `OAuthAccessTokenCache.forConfigRoot(_:)`.
    init(accessTokenCache: OAuthAccessTokenCache = .shared) {
        self.accessTokenCache = accessTokenCache
    }

    func fetch(allowKeychainPrompt: Bool = false) async throws -> LimitStatus {
        // 사용자 갱신은 캐시를 건너뛴다. 이전 계정의 토큰이 아직 유효하면 401 이 안 나고,
        // 메모리 캐시가 Keychain 의 새 계정을 영원히 가린다(#300). 자동 폴은 false 그대로 —
        // 키체인 다이얼로그를 띄우면 안 된다.
        let token = try await accessTokenCache.accessToken(
            allowKeychainPrompt: allowKeychainPrompt,
            bypassCache: allowKeychainPrompt)
        var activeToken = token
        var status: LimitStatus
        do {
            status = try await fetchStatus(accessToken: token)
        } catch let error as LimitsError {
            guard case .httpStatus(let httpStatus) = error, httpStatus == 401 || httpStatus == 403 else {
                throw error
            }
            await accessTokenCache.invalidate(removePersistentCache: true)
            let refreshed = try await accessTokenCache.accessToken(
                allowKeychainPrompt: allowKeychainPrompt, bypassCache: true)
            guard refreshed != token else { throw error }
            status = try await fetchStatus(accessToken: refreshed)
            activeToken = refreshed
        }
        // 플랜은 usage 응답이 아니라 방금 읽은 자격증명(캐시)에 담겨 있다 — 추가 Keychain 접근 없음.
        let plan = await accessTokenCache.planInfo()
        status.subscriptionType = plan.subscriptionType
        status.rateLimitTier = plan.rateLimitTier
        // 계정 식별(이메일·조직) — 같은 기기에서 두 계정이 하나의 Keychain 항목을 번갈아 덮어쓰면
        // 한도 바가 어느 계정 것인지 소리 없이 뒤바뀐다. 토큰의 실제 주인을 profile endpoint 로
        // 조회해 라벨링한다. best-effort: 실패해도 한도 표시는 그대로 (라벨만 생략).
        if let identity = await OAuthProfileCache.shared.identity(accessToken: activeToken) {
            status.accountEmail = identity.email
            status.accountOrganizationName = identity.organizationName
            // 서버가 정한 현재 플랜 이름 — 이름이 바뀌어도 앱 수정 없이 따라간다.
            status.planDisplayName = identity.planDisplayName
        }
        return status
    }

    private func fetchStatus(accessToken: String) async throws -> LimitStatus {
        guard AppEnv.allowsLiveLimitsFetch else { throw LimitsError.liveFetchNotPermitted }
        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 {
                throw LimitsError.rateLimited(retryAfter: LimitsHTTP.retryAfterSeconds(http))
            }
            throw LimitsError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(LimitStatus.self, from: data)
    }
}

/// profile 조회 캐시 — 토큰이 바뀌지 않는 한 계정 주인도 바뀌지 않으므로 토큰당 1회만 네트워크를 탄다
/// (한도 폴링마다 HTTP 요청이 2배가 되는 것을 방지). 실패는 캐시하지 않는다 — 토큰이 바뀐 직후 조회가
/// 실패했을 때 이전 계정 라벨을 계속 보여주면 라벨링이 없느니만 못하다(잘못된 계정 표시).
actor OAuthProfileCache {
    static let shared = OAuthProfileCache()
    /// Keyed by token: with several accounts polled in turn (additional Claude config folders),
    /// a single-entry cache would refetch every profile on every poll. Bounded because tokens rotate.
    private var identities: [String: AccountIdentity] = [:]
    static let maxEntries = 8
    private let fetchIdentity: @Sendable (String) async -> AccountIdentity?

    init(fetchIdentity: @escaping @Sendable (String) async -> AccountIdentity? = OAuthProfileCache.networkIdentity) {
        self.fetchIdentity = fetchIdentity
    }

    func identity(accessToken: String) async -> AccountIdentity? {
        if let cached = identities[accessToken] { return cached }
        guard let identity = await fetchIdentity(accessToken) else { return nil }
        if identities.count >= Self.maxEntries { identities.removeAll() }
        identities[accessToken] = identity
        return identity
    }

    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    static func networkIdentity(accessToken: String) async -> AccountIdentity? {
        guard AppEnv.allowsLiveLimitsFetch else { return nil }
        var request = URLRequest(url: profileURL, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return OAuthProfileData.identity(from: data)
    }
}

/// profile 응답 파싱 — 순수 함수로 분리해 픽스처로 테스트한다.
enum OAuthProfileData {
    /// `{"account":{"email":...},"organization":{"name":...,"plan_display_name":...}}` → AccountIdentity.
    /// email 이 없거나 비면 응답 전체를 버린다(부분 라벨은 오인 소지) — organization 은 선택.
    /// plan_display_name 은 서버가 정하는 현재 플랜 이름이라, 없으면 표시 단계가 티어로 조립한다.
    static func identity(from data: Data) -> AccountIdentity? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["account"] as? [String: Any],
            let email = account["email"] as? String, !email.isEmpty
        else {
            return nil
        }
        let organization = json["organization"] as? [String: Any]
        let orgName = nonEmpty(organization?["name"] as? String)
        return AccountIdentity(email: email, organizationName: orgName,
                               planDisplayName: nonEmpty(organization?["plan_display_name"] as? String))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

actor OAuthAccessTokenCache {
    static let shared = OAuthAccessTokenCache()
    private var cachedCredential: OAuthCredentialData.Credential?
    private let credentialsFileURL: URL
    private let keychainServices: [String]
    /// The `~/.claude` login. Only it keeps the `CLAUDE_CONFIG_DIR` guard of
    /// `credentialsFileIsAccountOAuthMissing`, which is about the hard-coded default file.
    private let isDefaultRoot: Bool

    init(credentialsFileURL: URL? = nil,
         keychainServices: [String] = [OAuthCredentialData.claudeKeychainService]) {
        self.credentialsFileURL = credentialsFileURL ?? Self.defaultCredentialsFileURL
        self.keychainServices = keychainServices
        self.isDefaultRoot = keychainServices == [OAuthCredentialData.claudeKeychainService]
    }

    /// Token cache for an additional Claude config folder (a `CLAUDE_CONFIG_DIR` login).
    static func forConfigRoot(_ root: URL) -> OAuthAccessTokenCache {
        OAuthAccessTokenCache(
            credentialsFileURL: ClaudeAccountRoots.credentialsFileURL(for: root),
            keychainServices: ClaudeAccountRoots.keychainServices(for: root))
    }

    static var defaultCredentialsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    func accessToken(allowKeychainPrompt: Bool, bypassCache: Bool = false) throws -> String {
        // 파일 크리덴셜(~/.claude/.credentials.json) — 키체인 무관, 프롬프트 없음.
        // 캐시 히트보다 파일을 먼저 본다. `/login` 으로 같은 팀의 다른 메일로 갈아타면 파일이
        // 새 *유효* 토큰으로 덮이는데, 만료만 보고 캐시를 돌려주면 공식 5h/주 바가 이전 계정에
        // 붙고 컴패니언 EXP 만 로컬 jsonl 로 계속 오른다(#227).
        if let credential = try Self.readClaudeCredentialsFile(url: credentialsFileURL) {
            cachedCredential = credential
            return credential.accessToken
        }

        if !bypassCache, let cachedCredential, !cachedCredential.isExpired {
            return cachedCredential.accessToken
        }

        // 자동(타이머) 경로는 Claude Keychain 을 일절 읽지 않는다. no-UI 쿼리(kSecUseAuthenticationUIFail
        // /LAContext)로도 잠긴·미승인 login 키체인의 '암호 입력' 다이얼로그는 억제되지 않는다 —
        // 실측: 캐시 만료 폴 도중 SecItemCopyMatching 이 13초간 블록하며 팝업을 띄웠다(하루 몇 회).
        // → Keychain 읽기는 명시적 사용자 동작(설정/팝오버의 갱신 버튼, allowKeychainPrompt=true)에서만
        // 수행한다. 파일이 유효 토큰을 들고 있으면 매 폴이 그걸 쓴다. 파일이 없거나 oauth 가 빠진
        // 뒤에만 캐시가 버티고, 그것도 만료되면 한도는 stale 표시 후 사용자가 갱신한다.
        // 그 사용자 갱신은 `bypassCache: true` 로 들어온다(#300) — 옛 토큰이 아직 유효해도
        // 여기서 캐시를 돌려주면 계정 전환이 버튼으로도 안 끝난다.
        // 자동 경로는 여기서 끝난다(키체인 미열람). 파일이 있는데 계정 OAuth 만 없으면 재로그인이
        // 답이므로 그때만 안내를 바꾼다 — 판정은 이 분기 안에서 해야 사용자 경로가 파일을 두 번 읽지 않는다.
        guard allowKeychainPrompt else {
            throw Self.credentialsFileIsAccountOAuthMissing(extraRootFile: isDefaultRoot ? nil : credentialsFileURL)
                ? LimitsError.credentialMissingAccountOAuth
                : LimitsError.keychainInteractionNotAllowed
        }

        // 사용자 동작 경로: 무프롬프트로 먼저 시도(과거 '항상 허용'했다면 조용히 성공), 안 되면 프롬프트를
        // 동반해 읽어 최초 1회 '항상 허용'을 유도한다.
        if let credential = Self.readClaudeKeychainSilently(services: keychainServices) {
            cachedCredential = credential
            return credential.accessToken
        }
        let credential = try Self.firstUsableCredential(services: keychainServices) {
            try Self.readClaudeKeychain(service: $0, allowKeychainPrompt: true)
        }
        cachedCredential = credential
        return credential.accessToken
    }

    /// An additional folder's login can sit under several service names
    /// (`ClaudeAccountRoots.keychainServices`). The first live credential wins, an expired one is the
    /// fallback, and any other failure moves on to the next name. A cancelled or failed password
    /// prompt stops right there, so it never opens the next one (#280).
    nonisolated static func firstUsableCredential(
        services: [String],
        read: (String) throws -> OAuthCredentialData.Credential) throws -> OAuthCredentialData.Credential
    {
        var expired: OAuthCredentialData.Credential?
        var failure: Error?
        for service in services {
            do {
                let credential = try read(service)
                if !credential.isExpired { return credential }
                if expired == nil { expired = credential }
            } catch LimitsError.keychainUnavailable(let status)
                where status == errSecUserCanceled || status == errSecAuthFailed
            {
                throw LimitsError.keychainUnavailable(status)
            } catch LimitsError.keychainAccessDisabled {
                throw LimitsError.keychainAccessDisabled
            } catch {
                // A missing item is the least telling failure: keep any other one instead.
                if failure == nil || failure as? LimitsError == .keychainUnavailable(errSecItemNotFound) {
                    failure = error
                }
            }
        }
        if let expired { return expired }
        throw failure ?? LimitsError.keychainUnavailable(errSecItemNotFound)
    }

    /// 마지막으로 사용한 자격증명의 플랜 정보. accessToken() 이 모든 경로에서 cachedCredential 을
    /// 반환 토큰과 일치시키므로, fetch 가 토큰 취득 직후 호출하면 동일 자격증명 기준이다.
    func planInfo() -> (subscriptionType: String?, rateLimitTier: String?) {
        (cachedCredential?.subscriptionType, cachedCredential?.rateLimitTier)
    }

    func invalidate(removePersistentCache: Bool = false) {
        // 앱 자체 키체인 캐시는 코드서명이 바뀔 때마다(재빌드·실사용자 매 업그레이드) 항목 ACL 이
        // 안 맞아 write/삭제 시 접근 허용 프롬프트를 유발했다(no-UI 로도 억제 안 됨) → 제거.
        // 토큰은 Claude 키체인 무UI 읽기/.credentials.json 로 조용히 재취득한다. 인메모리만 비운다.
        cachedCredential = nil
    }

    // (구) 앱 자체 키체인 OAuth 캐시(read/write/delete)는 제거됨 — 코드서명 변경마다 항목 ACL
    // 불일치로 접근 허용 프롬프트를 유발했다. 토큰은 인메모리 + Claude 키체인 무UI 읽기 +
    // .credentials.json 로 충분히 조용히 취득된다.

    /// 자격증명 파일이 존재하지만 계정 OAuth 가 없는 상태인지(만료는 여기 해당 없음 — 그건 재취득 대상).
    ///
    /// 설정 위치를 옮긴 사용자(`CLAUDE_CONFIG_DIR`)는 판정에서 제외한다. 이 경로는 기본 위치를 하드코딩하는데,
    /// 옮긴 뒤 남은 옛 파일이 `mcpOAuth` 만 담고 있으면 실제로는 로그인된 사용자에게 매 폴링마다 재로그인
    /// 배너를 띄우게 된다. 옮긴 자격증명이 어디 있는지는 확인된 바 없으므로 추측하지 않고 판정을 접는다
    /// (한도는 키체인 경로로 계속 동작한다).
    /// `extraRootFile` is set for an additional config folder: that file is the one Claude Code writes
    /// for that login, so the environment guard below does not apply.
    private nonisolated static func credentialsFileIsAccountOAuthMissing(extraRootFile: URL?) -> Bool {
        let url: URL
        if let extraRootFile {
            url = extraRootFile
        } else {
            // 프로세스 환경만 본다 — 셸 조회(`shellAwareClaudeConfigDir`)를 부르면 이 자동 폴링 경로가
            // 안내 문구 하나를 고르려고 로그인 셸 spawn(수백 ms~수 초)을 유발하고, 그 동안 토큰 캐시 actor 가
            // 막힌다. 값이 필요한 쪽(사용량 스캔)이 이미 셸 조회를 하므로 여기서 감당할 이유가 없다.
            guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.isEmpty ?? true else { return false }
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        return OAuthCredentialData.isAccountOAuthMissing(data)
    }

    private nonisolated static func readClaudeCredentialsFile(url: URL) throws -> OAuthCredentialData.Credential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let credential = OAuthCredentialData.credential(from: data), !credential.isExpired else {
            return nil
        }
        return credential
    }
}
