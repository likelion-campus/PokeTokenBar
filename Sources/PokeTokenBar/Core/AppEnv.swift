import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 실행 환경 판별 — 한 곳에서만 정의해 중복 게이트의 drift(일부만 조건이 어긋나는 것)를 막는다.
enum AppEnv {
    /// 정식 `.app` 번들로 실행 중인가. 알림 전송·키체인 읽기·스프라이트 프리패치·프로덕션 로그 기록 등
    /// "실앱 전용" 부수효과의 단일 게이트 — `swift test`/로우 바이너리(dev 실행)에선 false.
    /// bundleIdentifier(Info.plist)와 경로 접미사를 함께 확인(둘 다 실앱에서만 참).
    static var isBundledApp: Bool {
        PlatformCompat.isBundledApp
    }

    /// The service label launchd gives this process when it starts as a LaunchAgent.
    static var xpcServiceName: String? {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
    }

    /// `PTB_PARITY=1` — a QA/parity run where live endpoints are allowed (the same flag the parity
    /// smoke tests already use). Only ever opens a gate that `isBundledApp` keeps closed.
    static var isParityRun: Bool {
        ProcessInfo.processInfo.environment["PTB_PARITY"] == "1"
    }

    /// Lets a test drive a provider's real network code against a stubbed transport (URLProtocol, an
    /// injected URLSession). Set it in the test and reset it in `defer`.
    nonisolated(unsafe) static var allowLiveFetchForTesting = false

    /// Whether a limits provider may send the user's credentials to a live endpoint. Closed under
    /// `swift test` and for a raw `swift build` binary: a test that does not inject a stub would
    /// otherwise call Anthropic, Google or Cursor with the real login found on the machine
    /// (`~/.claude/.credentials.json`, the Antigravity token file, Cursor's `state.vscdb`).
    /// Put the check at the network boundary, not before the credential read, so the Keychain path
    /// tests keep observing real reads. `LiveCredentialCallGateTests` requires it in every provider.
    static var allowsLiveLimitsFetch: Bool {
        !liveFetchForbidden && (isBundledApp || isParityRun || allowLiveFetchForTesting)
    }

    /// Closes the gate above whatever opens it: a run that must never use a person's credentials or send anything for them (the
    /// Windows `--selftest` on a person's PC). Set once at launch, before any provider exists.
    nonisolated(unsafe) static var liveFetchForbidden = false

    private static let exemptLock = NSLock()
    nonisolated(unsafe) private static var exemptHosts = Set<String>()

    /// The one request choke point (`PlatformCompat.oneShotData`/`oneShotDownload`): while `liveFetchForbidden` is set, only loopback, the
    /// reserved test names and the hosts of an `exempting` block may be reached. nil = allowed.
    static func fetchBlock(for url: URL?) -> URLError? {
        guard liveFetchForbidden else { return nil }
        let host = (url?.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if isLoopbackOrTestHost(host) { return nil }
        exemptLock.lock(); let exempt = exemptHosts.contains(host); exemptLock.unlock()
        if exempt { return nil }
        return URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "a person's selftest sends no request to \(host.isEmpty ? "?" : host)"])
    }

    static func isLoopbackOrTestHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "invalid" || host.hasSuffix(".invalid") || host == "test" || host.hasSuffix(".test") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func changeExemptions(_ change: (inout Set<String>) -> Void) {
        exemptLock.lock(); defer { exemptLock.unlock() }
        change(&exemptHosts)
    }

    /// The selftest's few requests a person is told about (TEAM.md): their hosts are reachable for the duration of `body` only.
    static func exempting<T>(hosts: [String], _ body: () async throws -> T) async rethrows -> T {
        let names = Set(hosts.map { $0.lowercased() })
        changeExemptions { $0.formUnion(names) }
        defer { changeExemptions { $0.subtract(names) } }
        return try await body()
    }

    /// Whether a store may read and write its file. Always true for an injected path, which is how
    /// tests check persistence against a temporary file. A store that fell back to its default
    /// (user) path persists only in the app bundle, so `swift test` never reads or rewrites the
    /// user's real files there. Keep this rule here instead of copying it into each store.
    static func persistsToUserLocation(injectedFileURL: URL?,
                                       isBundledApp: Bool = AppEnv.isBundledApp) -> Bool {
        injectedFileURL != nil || isBundledApp
    }
}
