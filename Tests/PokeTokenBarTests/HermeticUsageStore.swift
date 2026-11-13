import Foundation
@testable import PokeTokenBar

/// A `UsageStore` whose first refresh cannot reach the machine: no provider reads a log, nothing asks the
/// Keychain, runs `codex` or opens a socket, and no Claude config folder is discovered. Use it where a
/// test needs a store that refreshes by itself (a setter that starts an un-awaited `Task`) but is not
/// about a refresh. See the late-write entry in `docs/reference/defect-log.md`.
private enum HermeticError: Error { case unavailable }

private struct HermeticClaudeLimits: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus { throw HermeticError.unavailable }
}
private struct HermeticCodexLimits: CodexLimitsProviding {
    func fetch() async throws -> CodexRateLimitStatus? { nil }
}
private struct HermeticAntigravityLimits: AntigravityLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw HermeticError.unavailable }
}
private struct HermeticStatus: ProviderStatusProviding {
    func fetch() async -> [String: ProviderStatus] { [:] }
}

@MainActor
func makeHermeticUsageStore(providers: [any UsageProvider] = [], defaults: UserDefaults) -> UsageStore {
    UsageStore(
        providers: providers,
        claudeLimitsProvider: HermeticClaudeLimits(),
        discoverClaudeConfigDirs: { [] },
        readDefaultIdentity: { nil },
        claudeUsageEntries: { _ in [] },
        codexLimitsProvider: HermeticCodexLimits(),
        antigravityLimitsProvider: HermeticAntigravityLimits(),
        statusProvider: HermeticStatus(),
        autoRefresh: false, defaults: defaults)
}
