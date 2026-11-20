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

    /// Pass: the body is a JSON object with a Bool `ok`. Unverified pass: unreachable, or HTTP status 500 and up. Fail: anything
    /// else, which is what a POST that stayed a POST on the redirect gets (an HTML page).
    static func classify(_ outcome: Result<(status: Int, body: Data), URLError>) -> (ok: Bool, detail: String) {
        switch outcome {
        case .failure(let error):
            if unreachableCodes.contains(error.code) {
                return (true, "unverified (network or host not reachable: URLError \(error.code.rawValue))")
            }
            return (false, "request failed: URLError \(error.code.rawValue)")
        case .success(let answer):
            if let object = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any], object["ok"] is Bool {
                return (true, "verified: HTTP \(answer.status), JSON answer")
            }
            if answer.status >= 500 {
                return (true, "unverified (host error: HTTP \(answer.status))")
            }
            return (false, "no JSON answer through the redirect: HTTP \(answer.status), \(answer.body.count) bytes")
        }
    }
}
