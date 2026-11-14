#if os(Windows) || PTB_SHARED_ONLY
import Foundation

/// The Keychain half of `OAuthAccessTokenCache` where there is no Keychain (the Mac's lives in
/// `Core/OAuthLimitsProvider.swift`). The credentials-file path in `Core/ClaudeOAuthLimitsProvider.swift` runs first
/// on every OS; these only answer for what comes after it.
extension OAuthAccessTokenCache {
    /// Nothing to read silently.
    nonisolated static func readClaudeKeychainSilently(services: [String]) -> OAuthCredentialData.Credential? { nil }

    /// A user refresh that found no usable credentials file ends here.
    nonisolated static func readClaudeKeychain(
        service: String, allowKeychainPrompt: Bool) throws -> OAuthCredentialData.Credential
    {
        throw LimitsError.keychainAccessDisabled
    }
}
#endif
