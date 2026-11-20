import Foundation

enum KeychainAccessGate {
    /// 프로세스 전역 게이트(메모리) — 기동 시 저장값으로 1회 시드하고, 영속은
    /// UsageStore.disableKeychainAccess(didSet)가 전담한다. UserDefaults.standard 에
    /// 직접 쓰던 이전 구현은 테스트 실행이 실제 사용자 설정을 오염시켰다.
    /// (Bool 단일 플래그 — MainActor 쓰기/actor 읽기의 경합은 무해)
    nonisolated(unsafe) static var isDisabled: Bool =
        UserDefaults.standard.bool(forKey: "disableKeychainAccess")
}

