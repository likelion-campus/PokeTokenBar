#if os(Windows)
import Foundation
import FoundationNetworking

/// `net.clientCertificateOptional`: a server that asks for an optional TLS client certificate gets an answer without one, as
/// curl and the Mac's URLSession give it. graphql.pokeapi.co (Cloudflare) sends a CertificateRequest to every client (openssl
/// s_client lists "Acceptable client certificate CA names"); the seam stopped there with ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED
/// (12044), so on Windows the hatch base index never loaded and every new install fell back to 649 PokéAPI REST fetches, which
/// ran on into three idle-gate windows when PokéAPI was slow (run 44143290510). The same request goes once the old way
/// (`clientCertificateAsBefore`) as the control: it must stop at 12044, or the detail says the host no longer asks and the check
/// proves nothing. Two small POSTs to the real host; a runner that cannot reach it passes and says so, as `limits.claude` does,
/// and so does a host that fails both requests the same way (PokéAPI down): only our answer to the certificate request is judged.
extension WindowsSelftest {
    @MainActor static func clientCertificateCheck(_ r: Recorder) async {
        let name = "net.clientCertificateOptional"
        guard PlatformCompat.isBundledApp else {
            r.add(name, true, "skipped: not packaged (real hosts are refused outside the installed app)")
            return
        }
        guard let url = URL(string: "https://graphql.pokeapi.co/v1beta2") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"query":"{ pokemonspecies(limit: 1) { id } }"}"#.utf8)

        func attempt(asBefore: Bool) async -> Result<Int, URLError> {
            do {
                let (_, response) = try await WinHTTPFetch.data(for: request, clientCertificateAsBefore: asBefore)
                return .success((response as? HTTPURLResponse)?.statusCode ?? -1)
            } catch let error as URLError {
                return .failure(error)
            } catch {
                return .failure(URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
            }
        }
        func describe(_ result: Result<Int, URLError>) -> String {
            switch result {
            case .success(let status): return "HTTP \(status)"
            case .failure(let error): return "URLError \(error.code.rawValue) (\(error.localizedDescription))"
            }
        }
        let unreachable: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                               .dnsLookupFailed, .networkConnectionLost]
        let control = await attempt(asBefore: true)
        let fixed = await attempt(asBefore: false)
        let controlNote: String
        switch control {
        case .failure(let error) where error.code == .clientCertificateRequired:
            controlNote = "the old way stopped at the certificate request as before"
        case .success:
            controlNote = "the old way got through too: the host no longer asks for a certificate, so this proves nothing now"
        case .failure:
            controlNote = "the old way did not get an answer"
        }
        let detail = "graphql.pokeapi.co: \(describe(fixed)); control (no answer to the certificate request): \(describe(control)), \(controlNote)"
        switch fixed {
        case .success:
            r.add(name, true, detail)
        case .failure(let error) where unreachable.contains(error.code):
            r.add(name, true, "not reached (network): " + detail)
        case .failure(let error):
            // The host failing both ways the same way (a TLS or server fault of PokeAPI's, not a certificate request) is not ours.
            if case .failure(let old) = control, old.code == error.code, error.code != .clientCertificateRequired {
                r.add(name, true, "host failed both ways: " + detail)
            } else {
                r.add(name, false, detail)
            }
        }
    }
}
#endif
