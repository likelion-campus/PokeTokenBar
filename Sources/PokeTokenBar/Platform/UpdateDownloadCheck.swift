import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What a downloaded Windows installer must pass before it is written or started (stage 8, D8 steps 2–4). Pure: no I/O and
/// no clock, so both systems test it. The installer is unsigned. What makes it trusted is that the app is an installed copy
/// older than it, that it came over HTTPS from GitHub's download hosts, and that its SHA-256 equals the digest GitHub's API
/// reported for the uploaded asset (D9). Who published it is not checked (D9).
enum UpdateDownloadCheck {
    enum Refusal: Equatable, CustomStringConvertible {
        /// No version file next to the exe (a bare build), or one that is not x.y.z: not an installed copy.
        case notPackaged
        /// The installer is the installed version or an older one.
        case notNewer
        /// The download did not answer 200 (a partial 206 or an unfollowed 3xx included).
        case status(Int)
        /// The download ended on a scheme other than HTTPS (HTTP only with `allowHTTP`, the CI loopback).
        case insecure
        /// The download ended on a host off the list, on an HTTPS port other than 443 (`host:port`), or nowhere known ("").
        case finalHost(String)
        case length(expected: Int, got: Int)
        case digest

        /// One fixed text per reason for the log: never a body byte, a URL path or a query (the CDN's query is a signature).
        var description: String {
            switch self {
            case .notPackaged: return "not an installed copy (no x.y.z version file)"
            case .notNewer: return "the installer is not newer than the installed version"
            case .status(let code): return "the download answered HTTP \(code)"
            case .insecure: return "the download did not end on HTTPS"
            case .finalHost(let host): return host.isEmpty ? "the download reported no final address"
                : "the download ended at \(host), not a GitHub download host"
            case .length(let expected, let got): return "the download has \(got) bytes, the release lists \(expected)"
            case .digest: return "the download's SHA-256 is not the release's digest"
            }
        }
    }

    static let downloadHost = "github.com"
    /// The asset CDN: `release-assets.githubusercontent.com` today (F5), `objects.githubusercontent.com` before. The leading
    /// dot keeps `evilgithubusercontent.com` out.
    static let assetHostSuffix = ".githubusercontent.com"

    /// `github.com` or a `*.githubusercontent.com` host, exactly as the final URL names it. Anything else is refused,
    /// IP literals and `api.github.com` included.
    static func isAllowedFinalHost(_ host: String) -> Bool {
        host == downloadHost || host.hasSuffix(assetHostSuffix)
    }

    /// 64 lowercase hex digits, the form `InstallerReleaseFeed.Installer.sha256` holds.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Before anything is downloaded: the app must be an installed copy (`currentVersion` is `WindowsInstall.version`), and
    /// the installer strictly newer than it.
    static func refusal(installing installer: InstallerReleaseFeed.Installer, currentVersion: String?) -> Refusal? {
        guard let current = currentVersion.flatMap(UpdateChecker.normalizedReleaseVersion) else { return .notPackaged }
        return UpdateChecker.isNewer(installer.version, than: current) ? nil : .notNewer
    }

    /// After the download, before anything is written: nil only for a 200 that ended on HTTPS (port 443) at an allowed host,
    /// with exactly `installer.size` bytes whose SHA-256 is `installer.sha256`. Checked in that order, so the first failing
    /// rule names the refusal. `allowedHost` and `allowHTTP` are replaced only by the CI selftest's loopback feed.
    static func refusal(status: Int, finalURL: URL?, body: Data, for installer: InstallerReleaseFeed.Installer,
                        allowedHost: (String) -> Bool = isAllowedFinalHost, allowHTTP: Bool = false) -> Refusal? {
        guard status == 200 else { return .status(status) }
        guard let finalURL else { return .finalHost("") }
        let scheme = finalURL.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && allowHTTP) else { return .insecure }
        let host = finalURL.host ?? ""
        guard allowedHost(host) else { return .finalHost(host) }
        if scheme == "https", let port = finalURL.port, port != 443 { return .finalHost("\(host):\(port)") }
        guard body.count == installer.size else { return .length(expected: installer.size, got: body.count) }
        guard sha256Hex(body) == installer.sha256 else { return .digest }
        return nil
    }
}
