import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Windows update feed: GitHub's latest release, but only when it carries the Windows installer. The Mac
/// release is the same GitHub release without that asset, so Windows must never offer it. Reads release
/// information only: nothing is downloaded or run. Until releases carry the installer (stage 8) this is always nil
/// and Windows never shows an update.
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
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .failed }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
        if let release = parse(data) { return .release(release) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["tag_name"] is String { return .noInstaller }
        return .failed
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
}
