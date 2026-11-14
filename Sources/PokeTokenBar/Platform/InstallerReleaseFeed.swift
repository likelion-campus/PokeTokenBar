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
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
