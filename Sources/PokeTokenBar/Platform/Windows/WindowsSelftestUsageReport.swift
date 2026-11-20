#if os(Windows)
import Foundation
import FoundationNetworking

/// `net.usageReportRedirect`: the usage report's POST to the Apps Script web app comes back as JSON through the real redirect.
/// Apps Script answers a POST with a 302 that is followed with GET (`WinHTTPFetch.nextHop`); loopback tests cannot show that
/// Google's real redirect works on WinHTTP. The probe body `{"v":0}` is answered with `bad_version` before the sheet takes a lock
/// or writes anything. Like `net.clientCertificateOptional`, only "our answer is wrong" fails (`UsageReportProbe.classify`);
/// the network, a proxy or the host being unavailable passes as unverified (the rule is on `classify`). 10 s per request, 15 s for the whole fetch.
extension WindowsSelftest {
    @MainActor static func usageReportRedirectCheck(_ r: Recorder) async {
        let name = "net.usageReportRedirect"
        guard PlatformCompat.isBundledApp else {
            r.add(name, true, "skipped: not packaged (real hosts are refused outside the installed app)")
            return
        }
        let t0 = Date()
        var request = URLRequest(url: UsageReportConfig.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = UsageReportProbe.body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = clientCertificateCheckDeadline
        let outcome: Result<(status: Int, body: Data, finalHost: String?), URLError>
        do {
            let (data, response) = try await WinHTTPFetch.data(for: request, configuration: configuration)
            outcome = .success((status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data, finalHost: response.url?.host))
        } catch let error as URLError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
        }
        let verdict = UsageReportProbe.classify(outcome)
        r.add(name, verdict.ok, verdict.detail + String(format: " (%.1f s)", Date().timeIntervalSince(t0)))
    }
}
#endif
