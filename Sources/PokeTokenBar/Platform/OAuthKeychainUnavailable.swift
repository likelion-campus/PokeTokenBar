#if os(Windows) || PTB_SHARED_ONLY
import Foundation

/// The Keychain half of `OAuthAccessTokenCache` where there is no Keychain (the Mac's lives in
/// `Core/OAuthLimitsProvider.swift`). The credentials-file path in `Core/ClaudeOAuthLimitsProvider.swift` runs first
/// on every OS; these only answer for what comes after it.
extension OAuthAccessTokenCache {
    /// Nothing to read silently.
    nonisolated static func readClaudeKeychainSilently(services: [String]) -> OAuthCredentialData.Credential? { nil }

    /// No `security` tool either.
    nonisolated static func readClaudeKeychainViaSecurityTool(
        services: [String]) async -> OAuthCredentialData.Credential? { nil }

    /// A user refresh that found no usable credentials file ends here. The answer is the Mac's "no item in the Keychain":
    /// `UsageStore.friendlyLimitError` turns it into "No Claude credential found. Sign in to Claude Code…". It used to throw
    /// `keychainAccessDisabled`, which the store words as "Couldn't fetch Claude limits. Please try again shortly." (advice
    /// that never helps when Claude Code is not signed in on this PC; stage 7 Task 6, defect-log "P14").
    nonisolated static func readClaudeKeychain(
        service: String, allowKeychainPrompt: Bool) throws -> OAuthCredentialData.Credential
    {
        throw LimitsError.keychainUnavailable(errSecItemNotFound)
    }
}
#endif
