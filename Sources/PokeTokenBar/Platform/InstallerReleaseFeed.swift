import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Windows update feed: GitHub's latest release, but only when it carries the Windows installer. The Mac
/// release is the same GitHub release without that asset, so Windows must never offer it. Reads release
/// information only: nothing is downloaded or run here. The offer (`parse`) needs only an installer-named asset; the
/// in-app update needs `Installer`, which only an asset that passes every check of `installerCheck` gives.
enum InstallerReleaseFeed {
    static let assetPrefix = "PokeTokenBar-Setup-"
    static let assetSuffix = "-win-x64.exe"

    /// nil unless an asset named `PokeTokenBar-Setup-<version>-win-x64.exe` exists. `url` is the release page.
    static func parse(_ data: Data) -> UpdateChecker.LatestRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let hasInstaller = assets.contains { asset in
            guard let name = asset["name"] as? String else { return false }
            return isInstallerName(name)
        }
        return hasInstaller ? UpdateChecker.LatestRelease(tag: tag, url: html) : nil
    }

    static func isInstallerName(_ name: String) -> Bool {
        guard name.hasPrefix(assetPrefix), name.hasSuffix(assetSuffix),
              name.count > assetPrefix.count + assetSuffix.count else { return false }
        let version = name.dropFirst(assetPrefix.count).dropLast(assetSuffix.count)
        return !version.contains("/") && !version.contains("\\")
    }

    /// Same endpoint, header and timeout as the Mac's `UpdateChecker.liveLatestRelease`. nil on any transport or
    /// payload failure (the checker treats that as "no check happened": no banner, no cooldown).
    static func latest(repo: String = UpdateChecker.releaseRepo, session: URLSession = .shared) async -> UpdateChecker.LatestRelease? {
        if case .release(let release) = await outcome(repo: repo, session: session) { return release }
        return nil
    }

    enum Outcome: Equatable {
        case release(UpdateChecker.LatestRelease)
        /// GitHub answered (200) but the latest release has no Windows installer: a successful check with nothing to offer.
        case noInstaller
        case failed
    }

    /// Same request as `latest`, but tells "answered, nothing for Windows" apart from "could not ask".
    static func outcome(repo: String = UpdateChecker.releaseRepo, session: URLSession = .shared) async -> Outcome {
        await fetch(repo: repo, session: session).outcome
    }

    /// What one check learned: the offer, and with it the installer the in-app update may download (`installer`) or why
    /// there is none (`rejection`). Both are nil unless the outcome is `.release`; then exactly one is set.
    typealias Answer = (outcome: Outcome, installer: Installer?, rejection: Rejection?)

    /// The one request of a check.
    static func fetch(repo: String = UpdateChecker.releaseRepo, session: URLSession = .shared) async -> Answer {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return (.failed, nil, nil) }
        return await fetch(from: url, session: session)
    }

    /// `fetch` from a given feed address with its download prefix. Besides `fetch(repo:)`, only the CI selftest's loopback
    /// feed calls it.
    static func fetch(from feed: URL, downloadPrefix: String = releaseDownloadPrefix, session: URLSession = .shared) async -> Answer {
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await PlatformCompat.oneShotData(for: req, session: session),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return (.failed, nil, nil) }
        if let release = parse(data) {
            switch installerCheck(in: data, downloadPrefix: downloadPrefix) {
            case .success(let installer): return (.release(release), installer, nil)
            case .failure(let rejection): return (.release(release), nil, rejection)
            }
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["tag_name"] is String {
            return (.noInstaller, nil, nil)
        }
        return (.failed, nil, nil)
    }

    /// The Mac stamps a 30-minute cooldown after every SUCCESSFUL check (`UpdateChecker.check`) and retries failures at
    /// once. Here "answered, no installer" is a successful check that the shared checker cannot see as one (the feed
    /// hands it nil), so this keeps the same 30 minutes: no request while the last answer was "nothing for Windows".
    struct EmptyAnswerCooldown {
        static let interval: TimeInterval = 1800
        private var lastEmpty: Date?
        func mayAsk(now: Date) -> Bool { lastEmpty.map { now.timeIntervalSince($0) >= Self.interval } ?? true }
        mutating func noteEmptyAnswer(now: Date) { lastEmpty = now }
    }

    // MARK: The installer the in-app update may download (stage 8, D8 step 2)

    /// An installer asset that passed every check of `installerCheck`, the only place one is made (the init is fileprivate:
    /// an unchecked `Installer` cannot exist). `version` is the normalized tag; the name and the address follow from it, so
    /// the three cannot disagree. `size` and `sha256` are what the download must match.
    struct Installer: Equatable, Sendable {
        let version: String   // "2.5.640"
        let name: String      // "PokeTokenBar-Setup-2.5.640-win-x64.exe"
        let url: URL          // https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.640/<name>
        let size: Int         // bytes, from the asset
        let sha256: String    // 64 lowercase hex, from the asset's "digest"

        fileprivate init(version: String, name: String, url: URL, size: Int, sha256: String) {
            self.version = version
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256
        }
    }

    /// The installer the last answered check found, which the in-app update may take (Windows keeps one in `WindowsUpdates`).
    struct InstallerCache {
        private var installer: Installer?
        /// Why the last answered check has no installer, for the one log line when "Update" opens the page instead.
        private(set) var lastRejection: Rejection?

        /// `.release`: that release's installer, or none and why. `.noInstaller`: none (an installer removed from a bad release
        /// stops in-app installs, D11). `.failed`: unchanged, as the checker keeps its offer when it could not ask.
        mutating func record(_ answer: Answer) {
            switch answer.outcome {
            case .release:
                installer = answer.installer
                lastRejection = answer.rejection
            case .noInstaller:
                installer = nil
                lastRejection = .noInstaller
            case .failed:
                break
            }
        }

        /// The installer only for the version being installed: the checker can keep an older offer after a later check it
        /// rejected, and Settings can install a skipped release.
        func installer(for version: String) -> Installer? { installer?.version == version ? installer : nil }
    }

    /// Why an offered release has no installer the app may download. A fixed text per reason: nothing from the JSON is
    /// logged. Listed in the order `installerCheck` tries them.
    enum Rejection: Error, Equatable, CustomStringConvertible {
        case notJSON, tag, notPublished, noAssets, noInstaller, severalInstallers, name, url, state, size, digest

        var description: String {
            switch self {
            case .notJSON: return "the release answer is not a JSON object"
            case .tag: return "the release tag is not v plus a plain x.y.z"
            case .notPublished: return "the release is a draft or a prerelease, or does not say"
            case .noAssets: return "the release lists no assets"
            case .noInstaller: return "the release has no Windows installer"
            case .severalInstallers: return "the release has more than one Windows installer"
            case .name: return "the installer is named for another version"
            case .url: return "the installer's address is not the release's download address"
            case .state: return "the installer upload is not finished"
            case .size: return "the installer's size is missing, not an integer, or outside 1 to 200 MiB"
            case .digest: return "the installer's digest is not sha256: plus 64 lowercase hex digits"
            }
        }
    }

    static let releaseDownloadPrefix = "https://github.com/\(UpdateChecker.releaseRepo)/releases/download/"
    /// 1 to 200 MiB (D8). The installer is 33,121,702 bytes (2.5.634, windows-app run 43736993382), just under the seam's
    /// 32 MiB default cap for API answers (`WinHTTPFetch.defaultMaxBodyBytes`): the download names its own cap (D19). The
    /// lower bound also refuses a JSON `true`, which bridges to 1.
    static let installerBytes = (1 << 20)...(200 << 20)

    static func expectedName(version: String) -> String { assetPrefix + version + assetSuffix }

    /// nil unless exactly one installer asset passes every D8-step-2 check. `downloadPrefix` is replaced only by the CI selftest.
    static func installer(in data: Data, downloadPrefix: String = releaseDownloadPrefix) -> Installer? {
        try? installerCheck(in: data, downloadPrefix: downloadPrefix).get()
    }

    /// The release answer is outside input that decides what the app downloads and starts, so every field is read strictly
    /// and anything missing, of another type or off the pattern rejects (never "no digest, so accept"):
    /// - the tag is exactly `v` plus a plain x.y.z (`UpdateChecker.normalizedReleaseVersion`, no leading zero or space);
    /// - `draft` and `prerelease` are both present and false (`releases/latest` never returns either; a JSON that says so is not it);
    /// - exactly one asset has an installer name (`isInstallerName`), and it is exactly `expectedName(version:)`;
    /// - `browser_download_url` is exactly `downloadPrefix` + `v<version>/<name>` (no userinfo, port, query, case or path variant);
    /// - `state` is `uploaded`; `size` is an integer in `installerBytes`; `digest` is `sha256:` plus 64 lowercase hex digits.
    static func installerCheck(in data: Data, downloadPrefix: String = releaseDownloadPrefix) -> Result<Installer, Rejection> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.notJSON) }
        guard let tag = json["tag_name"] as? String, let version = UpdateChecker.normalizedReleaseVersion(tag),
              tag == "v" + version else { return .failure(.tag) }
        guard json["draft"] as? Bool == false, json["prerelease"] as? Bool == false else { return .failure(.notPublished) }
        guard let assets = json["assets"] as? [[String: Any]] else { return .failure(.noAssets) }
        let installers = assets.filter { ($0["name"] as? String).map(isInstallerName) ?? false }
        guard let asset = installers.first else { return .failure(.noInstaller) }
        guard installers.count == 1 else { return .failure(.severalInstallers) }
        let name = expectedName(version: version)
        guard asset["name"] as? String == name else { return .failure(.name) }
        let address = downloadPrefix + "v" + version + "/" + name
        guard asset["browser_download_url"] as? String == address, let url = URL(string: address) else { return .failure(.url) }
        guard asset["state"] as? String == "uploaded" else { return .failure(.state) }
        guard let size = asset["size"] as? Int, installerBytes.contains(size) else { return .failure(.size) }
        guard let digest = asset["digest"] as? String, let sha256 = sha256Hex(fromDigest: digest) else { return .failure(.digest) }
        return .success(Installer(version: version, name: name, url: url, size: size, sha256: sha256))
    }

    /// The hex of a GitHub asset digest: `sha256:` and 64 lowercase hex digits, byte for byte (no space, no upper case,
    /// no other algorithm). nil otherwise.
    static func sha256Hex(fromDigest digest: String) -> String? {
        let bytes = Array(digest.utf8), prefix = Array("sha256:".utf8)
        guard bytes.count == prefix.count + 64, bytes.starts(with: prefix) else { return nil }
        let hex = bytes.dropFirst(prefix.count)
        guard hex.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return String(decoding: hex, as: UTF8.self)
    }
}
