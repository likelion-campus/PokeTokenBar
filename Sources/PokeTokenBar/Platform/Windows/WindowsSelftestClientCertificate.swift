#if os(Windows)
import Foundation
import FoundationNetworking

/// `net.clientCertificateOptional`: a server that asks for an optional TLS client certificate gets an answer without one, as
/// curl and the Mac's URLSession give it. graphql.pokeapi.co (Cloudflare) sends a CertificateRequest to every client (openssl
/// s_client lists "Acceptable client certificate CA names"); the seam stopped there with ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED
/// (12044), so on Windows the hatch base index never loaded and every new install fell back to 649 PokéAPI REST fetches, which
/// ran on into three idle-gate windows when PokéAPI was slow (run 44143290510). The same request goes the old way
/// (`clientCertificateAsBefore`) as the control, at the same time.
///
/// The selftest also runs on users' PCs and in the release gate, where the host may be unreachable or down: only "our answer to
/// the certificate request is wrong" fails (`classify`); "the network or the host is not available now" passes as unverified with
/// the reason. Each request has a 10 s timeout and a 15 s whole-fetch deadline (the session's `timeoutIntervalForResource`, which
/// `WinHTTPFetch` answers the caller on), and the two run at once, so the check gives its answer within about 15 s whatever the host does.
extension WindowsSelftest {
    static let clientCertificateCheckDeadline: TimeInterval = 15

    @MainActor static func clientCertificateCheck(_ r: Recorder) async {
        let name = "net.clientCertificateOptional"
        guard PlatformCompat.isBundledApp else {
            r.add(name, true, "skipped: not packaged (real hosts are refused outside the installed app)")
            return
        }
        let t0 = Date()
        async let controlAnswer = probe(asBefore: true)
        async let fixedAnswer = probe(asBefore: false)
        let (control, fixed) = await (controlAnswer, fixedAnswer)
        let verdict = classify(fixed: fixed, control: control)
        r.add(name, verdict.ok, verdict.detail + String(format: " (%.1f s)", Date().timeIntervalSince(t0)))
    }

    /// One small GraphQL POST to the host, without (`asBefore` false) or stopping at (true) the certificate request.
    static func probe(asBefore: Bool) async -> Result<Int, URLError> {
        guard let url = URL(string: "https://graphql.pokeapi.co/v1beta2") else { return .failure(URLError(.badURL)) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"query":"{ pokemonspecies(limit: 1) { id } }"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = clientCertificateCheckDeadline
        do {
            let (_, response) = try await WinHTTPFetch.data(for: request, configuration: configuration, clientCertificateAsBefore: asBefore)
            return .success((response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch let error as URLError {
            return .failure(error)
        } catch {
            return .failure(URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
        }
    }

    /// The network or the host was not there: no answer to judge.
    static let unreachableCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                                       .dnsLookupFailed, .networkConnectionLost, .cannotLoadFromNetwork]

    /// The verdict over the two outcomes (HTTP status or URLError). Fails only when our answer to the certificate request is wrong:
    /// the request without a certificate stopped at the request itself (-1206), or failed in a way the control did not. Any HTTP
    /// status, 5xx included, means the handshake went through. Unreachable, timed out, or the host failing both ways alike:
    /// unverified. The control getting an answer too means the host no longer asks, so nothing is proven: unverified.
    static func classify(fixed: Result<Int, URLError>, control: Result<Int, URLError>) -> (ok: Bool, detail: String) {
        func describe(_ r: Result<Int, URLError>) -> String {
            switch r {
            case .success(let status): return "HTTP \(status)"
            case .failure(let error): return "URLError \(error.code.rawValue)"
            }
        }
        let both = "graphql.pokeapi.co: \(describe(fixed)); control (no answer to the certificate request): \(describe(control))"
        switch (fixed, control) {
        case (.success, .failure(let old)) where old.code == .clientCertificateRequired:
            return (true, "verified: " + both)
        case (.success, .success):
            return (true, "unverified (the host no longer asks for a certificate): " + both)
        case (.success, .failure):
            return (true, "unverified (the control got no answer): " + both)
        case (.failure(let new), _) where new.code == .clientCertificateRequired:
            return (false, "the request still stops at the certificate request: " + both)
        case (.failure(let new), _) where unreachableCodes.contains(new.code):
            return (true, "unverified (network or host not reachable): " + both)
        case (.failure(let new), .failure(let old)) where new.code == old.code:
            return (true, "unverified (the host failed both ways alike): " + both)
        case (.failure, _):
            return (false, "failed where the control did not: " + both)
        }
    }
}
#endif
