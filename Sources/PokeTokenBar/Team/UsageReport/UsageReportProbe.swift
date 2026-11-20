import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The probe the Windows selftest (`net.usageReportRedirect`) sends to the real sheet, and its verdict. Apps Script answers a POST
/// with a 302 that must be followed with GET to read the JSON; a loopback test cannot show that the real Google redirect works on
/// WinHTTP, so the selftest posts `body` to `UsageReportConfig.endpoint`. The sheet answers `{"ok":false,"error":"bad_version"}`
/// before it takes any lock or writes anything (`20_store.js` `handleReport`), so the probe never touches the sheet.
enum UsageReportProbe {
    static let body = Data(#"{"v":0}"#.utf8)

    /// The network or the host was not there: no answer to judge. Mirrors `WindowsSelftest.unreachableCodes` (Windows-only).
    static let unreachableCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                                       .dnsLookupFailed, .networkConnectionLost, .cannotLoadFromNetwork]

    /// TLS trust or interception answers (a proxy that inspects TLS, a bad clock) and sign-in demands: not ours to judge.
    static let interceptionCodes: Set<URLError.Code> = [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                                                        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                                                        .clientCertificateRequired, .userAuthenticationRequired]

    static func isGoogleHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "script.google.com" || h.hasSuffix(".googleusercontent.com") || h.hasSuffix(".google.com")
    }

    /// Fails only when the answer shows our redirect handling is wrong (defect-log, "윈도 HTTP 이음매": a user's PC may sit behind
    /// a captive portal or a proxy, so "our answer is wrong" is told apart from "the network or host is unavailable").
    /// Pass: a JSON object with a Bool `ok`, whatever the status. Fail: a 3xx handed back (the redirect was not followed); a
    /// non-JSON 2xx or 4xx (other than 407 and 429) from a Google host; a URLError outside the unverified sets. Unverified pass:
    /// unreachable or TLS-interception URLErrors, 407, 429, any 5xx, and a non-JSON answer from a non-Google or unknown final host.
    static func classify(_ outcome: Result<(status: Int, body: Data, finalHost: String?), URLError>) -> (ok: Bool, detail: String) {
        switch outcome {
        case .failure(let error):
            if unreachableCodes.contains(error.code) {
                return (true, "unverified (network or host not reachable: URLError \(error.code.rawValue))")
            }
            if interceptionCodes.contains(error.code) {
                return (true, "unverified (TLS trust or sign-in in the way: URLError \(error.code.rawValue))")
            }
            return (false, "request failed: URLError \(error.code.rawValue)")
        case .success(let answer):
            if let object = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any], object["ok"] is Bool {
                return (true, "verified: HTTP \(answer.status), JSON answer")
            }
            if (300..<400).contains(answer.status) {
                return (false, "the redirect was not followed: HTTP \(answer.status)")
            }
            if answer.status == 407 || answer.status == 429 || answer.status >= 500 {
                return (true, "unverified (HTTP \(answer.status))")
            }
            guard let host = answer.finalHost, isGoogleHost(host) else {
                return (true, "unverified (non-JSON answer from \(answer.finalHost ?? "an unknown host"): HTTP \(answer.status))")
            }
            return (false, "no JSON answer through the redirect from \(host): HTTP \(answer.status), \(answer.body.count) bytes")
        }
    }
}
