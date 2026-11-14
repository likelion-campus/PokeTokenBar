#if os(Windows)
import Foundation

/// Claude limits through `~/.claude/.credentials.json` (no secret store on Windows); Antigravity stays unavailable
/// because its token file location on Windows is unknown.
struct WindowsLimitsProviders: LimitsProviderFactory {
    func claudeOAuth(configRoot: URL?) -> any ClaudeLimitsProviding {
        guard let configRoot else { return OAuthLimitsProvider() }
        return OAuthLimitsProvider(accessTokenCache: .forConfigRoot(configRoot))
    }

    func antigravity() -> any AntigravityLimitsProviding {
        AppLog.write("Platform: Antigravity limits unavailable on Windows")
        return UnavailableAntigravityLimits()
    }
}
#endif
