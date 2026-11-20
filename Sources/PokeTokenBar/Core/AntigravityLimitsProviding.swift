import Foundation

/// Antigravity 공식 한도 조회 추상화 — 실 구현 또는 테스트 스텁 주입.
public protocol AntigravityLimitsProviding: Sendable {
    var hasTokenFile: Bool { get }
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus
}

extension AntigravityLimitsProviding {
    public var hasTokenFile: Bool { false }
}

