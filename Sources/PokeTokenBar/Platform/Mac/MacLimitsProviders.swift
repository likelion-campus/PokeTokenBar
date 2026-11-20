import Foundation

struct MacLimitsProviders: LimitsProviderFactory {
    func claudeOAuth(configRoot: URL?) -> any ClaudeLimitsProviding {
        guard let configRoot else { return OAuthLimitsProvider() }
        return OAuthLimitsProvider(accessTokenCache: .forConfigRoot(configRoot))
    }
    func antigravity() -> any AntigravityLimitsProviding { AntigravityRateLimitsProvider() }
}

struct MacNetworkWatching: NetworkWatching {
    func makeReachabilityMonitor() -> any ReachabilityMonitoring { NetworkReachabilityMonitor() }
}

extension NetworkReachabilityMonitor: ReachabilityMonitoring {}
