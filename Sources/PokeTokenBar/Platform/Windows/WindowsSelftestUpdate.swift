#if os(Windows)
import Crypto
import Foundation
import WinSDK

/// The in-app update's CI-only flags (stage 8 Task 6). Both need `CI=true` and an installed copy, run the app on its own
/// settings (`WinDefaultsSync.selftestSuiteName` leaves them out) and log the release page instead of opening it:
/// - `--selftest-update-from http://127.0.0.1:<port>/releases/latest`: the update feed is that loopback answer (the CI step
///   `in-app-update`, `scripts/windows/update-feed-server.ps1`) and the download may come only from 127.0.0.1 over HTTP;
/// - `--selftest-update-live`: the real feed (the post-release smoke, Task 9).
/// After the launch check the app applies the offer exactly as the tray item does (`UpdateChecker.applyUpdate`).
enum WindowsSelftestUpdate {
    static let fromFlag = "--selftest-update-from"
    static let liveFlag = "--selftest-update-live"
    static let flags: Set<String> = [fromFlag, liveFlag]

    /// Before the app is built (the launch check must already use the loopback feed). A flag it cannot accept ends the
    /// process with exit 2 and one log line.
    @MainActor static func prepare(_ arguments: [String]) {
        guard arguments.contains(where: flags.contains) else { return }
        let environment = ProcessInfo.processInfo.environment
        let packaged = WindowsInstall.isPackagedLayout
        if let i = arguments.firstIndex(of: fromFlag) {
            let value = i + 1 < arguments.count ? arguments[i + 1] : ""
            guard let feed = LoopbackFeed(feed: value, environment: environment, packaged: packaged) else {
                AppLog.writeAndFlush("selftest-update: refused \(fromFlag) '\(value)': it needs CI=true, an installed copy and "
                                     + "http://127.0.0.1:<port>/... (CI=\(environment["CI"] ?? "unset"), installed=\(packaged))")
                WindowsApp.exit(2, .helper)
            }
            WindowsUpdates.useLoopbackFeed(feed)
        } else {
            guard environment["CI"] == "true", packaged else {
                AppLog.writeAndFlush("selftest-update: refused \(liveFlag): it needs CI=true and an installed copy")
                WindowsApp.exit(2, .helper)
            }
            AppLog.write("selftest-update: the live feed")
        }
        PlatformShell.current = PageRecordingShell()
    }

    /// After the launch: waits for the launch check's offer and applies it. With nothing offered (the feed's version is not
    /// newer), the install path is asked for that version on its own, so its refusal is in the log too.
    @MainActor static func start(_ arguments: [String]) {
        guard arguments.contains(where: flags.contains) else { return }
        Task { @MainActor in
            guard let checker = WindowsUpdates.checker else { return }
            AppLog.write("selftest-update: installed v\(WindowsInstall.version ?? "unknown"); waiting for the launch check")
            // The launch check answered: an offer, or at least a checked installer (an older one is not offered).
            _ = await WindowsSelftest.waitUntil(timeout: 60, poll: 0.25) { checker.available != nil || WindowsUpdates.lastCheckedVersion != nil }
            if checker.available == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if let offer = checker.available {
                AppLog.write("selftest-update: offered v\(offer.version); applying it as the tray item does")
                checker.applyUpdate()
                return
            }
            guard let version = WindowsUpdates.lastCheckedVersion else {
                AppLog.write("selftest-update: nothing offered and no installer checked in 60 s")
                return
            }
            AppLog.write("selftest-update: nothing offered (the feed's v\(version) is not newer); asking the install path anyway")
            let installed = await WindowsUpdates.install(version: version)
            AppLog.write("selftest-update: install(v\(version)) without an offer returned \(installed)")
        }
    }

    /// The Windows shell, except that a page is logged, never opened (no browser on the runner).
    @MainActor struct PageRecordingShell: PlatformShellService {
        private let real = WindowsShell()
        func open(_ url: URL) {
            if WindowsUpdates.keepsReleasePageClosed(url) { return }
            AppLog.write("selftest-update: the release page would open: \(url.absoluteString)")
        }
        func terminate() { real.terminate() }
        func installUpdate(version: String) async -> Bool { await real.installUpdate(version: version) }
    }
}

extension WindowsSelftest {
    /// The checks' names, in the order they report.
    static let updateCheckNames = ["update.installsCheckedBytes", "update.offMain", "update.refusesTampered", "update.refusesWrongSize",
                                   "update.refusesOffPatternURL", "update.passesOver32MiB", "update.setupRunningRefused",
                                   "update.markerReport", "update.hashMs"]

    /// Stage 8 Task 6 in the shipped binary: the installer through the real WinHTTP seam against the in-process loopback server
    /// (`/big/<n>` sends n bytes of "a"; `/redirect-to/<port>` sends a 302 to localhost), with a scratch Updates folder and
    /// settings suite and an injected launch (no process is started, the app does not leave). CI only: the loopback feed
    /// exists only with CI=true.
    @MainActor static func updateInstallerChecks(_ r: Recorder) async {
        let environment = ProcessInfo.processInfo.environment
        guard let server = LoopbackServer.start(),
              let feed = LoopbackFeed(feed: "http://127.0.0.1:\(server.port)/releases/latest", environment: environment,
                                      packaged: WindowsInstall.isPackagedLayout) else {
            for name in updateCheckNames {
                r.add(name, !onCI, onCI ? "no loopback server or feed (CI=\(environment["CI"] ?? "unset"), installed=\(WindowsInstall.isPackagedLayout))"
                                         : "skipped (CI not set)")
            }
            return
        }
        let tag = UUID().uuidString.prefix(8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-update-selftest-\(tag)", isDirectory: true)
        let suite = "ptb.selftest.update.\(tag)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            for name in updateCheckNames { r.add(name, false, "no scratch settings suite") }
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let base = "http://127.0.0.1:\(server.port)"
        let n = 1 << 20  // the feed's smallest installer
        func hex(_ data: Data) -> String { UpdateDownloadCheck.sha256Hex(data) }
        let a = { (count: Int) in Data(repeating: 0x61, count: count) }
        /// An installer the feed accepts (through `installerCheck`), whose download is `<prefix>v99.0.1/<name>`.
        func installer(size: Int, sha256: String, prefix: String, url: String? = nil) -> Result<InstallerReleaseFeed.Installer, InstallerReleaseFeed.Rejection> {
            let name = InstallerReleaseFeed.expectedName(version: "99.0.1")
            let asset: [String: Any] = ["name": name, "browser_download_url": url ?? (prefix + "v99.0.1/" + name), "state": "uploaded",
                                        "size": size, "digest": "sha256:" + sha256]
            let json: [String: Any] = ["tag_name": "v99.0.1", "html_url": "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v99.0.1",
                                       "draft": false, "prerelease": false, "assets": [asset]]
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return .failure(.notJSON) }
            return InstallerReleaseFeed.installerCheck(in: data, downloadPrefix: prefix)
        }
        struct Run { var failure: WindowsUpdateInstaller.Failure?; var launches: [(URL, [String], URL)]; var exits: Int; var left: Int }
        func run(_ made: Result<InstallerReleaseFeed.Installer, InstallerReleaseFeed.Rejection>, setupRunning: Bool = false) async -> Run? {
            guard case .success(let i) = made else { return nil }
            var launches: [(URL, [String], URL)] = []
            var exits = 0
            let failure = await WindowsUpdateInstaller.install(i, currentVersion: "2.5.0", defaults: defaults, folder: folder, logs: folder,
                                                               loopback: feed, setupRunning: { setupRunning },
                                                               launch: { launches.append(($0, $1, $2)); return true },
                                                               flush: {}, onLaunched: { exits += 1 })
            let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
            return Run(failure: failure, launches: launches, exits: exits, left: left)
        }
        func show(_ run: Run?) -> String {
            guard let run else { return "the feed refused the test installer" }
            return "failure=\(run.failure.map { "\($0)" } ?? "none") launches=\(run.launches.count) exits=\(run.exits) left_in_updates=\(run.left)"
        }

        // The good path: exactly the served bytes on disk, Setup's path, arguments and working folder, the marker.
        let good = await run(installer(size: n, sha256: hex(a(n)), prefix: base + "/big/\(n)/"))
        let launch = good?.launches.first
        let onDisk = launch.flatMap { try? Data(contentsOf: $0.0) }
        let marker = WindowsUpdateInstaller.readPending(defaults)
        let logFile = WindowsUpdateInstaller.installerLog(version: "99.0.1", logs: folder)
        r.add("update.installsCheckedBytes",
              good?.failure == nil && good?.launches.count == 1 && good?.exits == 1 && onDisk.map(hex) == hex(a(n))
                && launch?.0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
                && launch?.1 == WindowsUpdateInstaller.arguments(logFile: logFile) && launch?.2 == folder && marker?.version == "99.0.1",
              show(good) + "; file \(onDisk?.count ?? -1) bytes at \(launch.map { WinPath.native($0.0) } ?? "-"); args \(launch?.1 ?? []); "
                + "working folder \(launch.map { WinPath.native($0.2) } ?? "-"); marker \(marker?.version ?? "none")")
        defaults.removeObject(forKey: WindowsUpdateInstaller.pendingKey)
        let threads = WindowsUpdateInstaller.lastWorkThreads
        r.add("update.offMain", threads.count == 2 && !threads.contains(WindowsApp.mainThreadID),
              "the checks and the file work ran on threads \(threads) (main \(WindowsApp.mainThreadID))")
        _ = WinUpdateFile.removeContents(WinPath.native(folder))

        var tamperedBytes = a(n)
        tamperedBytes[n / 2] = 0x62
        let tampered = await run(installer(size: n, sha256: hex(tamperedBytes), prefix: base + "/big/\(n)/"))
        r.add("update.refusesTampered", tampered?.failure == .check(.digest) && tampered?.launches.isEmpty == true && tampered?.left == 0
                && WindowsUpdateInstaller.readPending(defaults) == nil,
              "one byte in the middle differs from the digest: " + show(tampered))

        let short = await run(installer(size: n, sha256: hex(a(n)), prefix: base + "/big/\(n - 1)/"))
        let long = await run(installer(size: n, sha256: hex(a(n)), prefix: base + "/big/\(n + 1)/"))
        r.add("update.refusesWrongSize", short?.failure == .check(.length(expected: n, got: n - 1)) && short?.left == 0
                && long?.failure == .download(URLError.Code.dataLengthExceedsMaximum.rawValue) && long?.left == 0
                && short?.launches.isEmpty == true && long?.launches.isEmpty == true,
              "one byte short: " + show(short) + "; one byte over the cap (the size): " + show(long))

        let offPattern = installer(size: n, sha256: hex(a(n)), prefix: feed.downloadPrefix, url: base + "/big/\(n)/v99.0.1/x.exe")
        let elsewhere = await run(installer(size: n, sha256: hex(a(n)), prefix: base + "/redirect-to/\(server.port)/"))
        var offPatternRejection: InstallerReleaseFeed.Rejection?
        if case .failure(let why) = offPattern { offPatternRejection = why }
        r.add("update.refusesOffPatternURL", offPatternRejection == .url && elsewhere?.failure == .check(.finalHost("localhost"))
                && elsewhere?.launches.isEmpty == true && elsewhere?.left == 0,
              "an address off the release pattern: \(offPatternRejection.map { "\($0)" } ?? "accepted"); a redirect to localhost: " + show(elsewhere))

        // The defect class "a default cap sized for API answers": one byte over the seam's 32 MiB default, through the seam.
        let big = (32 << 20) + 1
        let bigDigest = await Task.detached { UpdateDownloadCheck.sha256Hex(Data(repeating: 0x61, count: big)) }.value
        let over = await run(installer(size: big, sha256: bigDigest, prefix: base + "/big/\(big)/"))
        let bigFile = over?.launches.first.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.0.path)[.size] as? Int }
        r.add("update.passesOver32MiB", over?.failure == nil && bigFile == big && WinHTTPFetch.defaultMaxBodyBytes < big,
              "\(big) bytes (the seam's default cap is \(WinHTTPFetch.defaultMaxBodyBytes)): " + show(over) + "; on disk \(bigFile ?? -1)")
        defaults.removeObject(forKey: WindowsUpdateInstaller.pendingKey)
        _ = WinUpdateFile.removeContents(WinPath.native(folder))

        let acceptedBefore = server.accepted
        let blocked = await run(installer(size: n, sha256: hex(a(n)), prefix: base + "/big/\(n)/"), setupRunning: true)
        r.add("update.setupRunningRefused", blocked?.failure == .setupRunning && blocked?.launches.isEmpty == true
                && server.accepted == acceptedBefore && blocked?.failure?.opensReleasePage == false,
              "with Local\\PokeTokenBar-Setup held: " + show(blocked) + "; connections \(acceptedBefore) -> \(server.accepted)")

        await markerReportCheck(r, defaults: defaults, folder: folder)
        await hashTimeCheck(r)
    }

    /// `reportAtLaunch`: a marker for another version (one balloon, marker gone, the version held back, downloads removed),
    /// one for this version (done, no balloon), none (nothing).
    @MainActor private static func markerReportCheck(_ r: Recorder, defaults: UserDefaults, folder: URL) async {
        let l = L(.ko)
        var balloons: [String] = []
        let leftover = folder.appendingPathComponent("99.0.2-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: leftover.appendingPathComponent("PokeTokenBar-Setup-99.0.2-win-x64.exe"))
        WindowsUpdateInstaller.savePending(.init(version: "99.0.2", at: Date()), defaults)
        let failed = WindowsUpdateInstaller.reportAtLaunch(defaults: defaults, currentVersion: "2.5.0", l: l, balloon: { balloons.append($0) },
                                                           folder: folder, logs: folder, setupRunning: { false }, flush: {})
        let left = await failed.cleanup.value
        let heldBack = defaults.string(forKey: WindowsUpdateInstaller.failedKey)
        let afterFailure = WindowsUpdateInstaller.readPending(defaults)
        WindowsUpdateInstaller.savePending(.init(version: "2.5.0", at: Date()), defaults)
        let done = WindowsUpdateInstaller.reportAtLaunch(defaults: defaults, currentVersion: "2.5.0", l: l, balloon: { balloons.append($0) },
                                                         folder: folder, logs: folder, setupRunning: { false }, flush: {})
        _ = await done.cleanup.value
        let none = WindowsUpdateInstaller.reportAtLaunch(defaults: defaults, currentVersion: "2.5.0", l: l, balloon: { balloons.append($0) },
                                                         folder: folder, logs: folder, setupRunning: { false }, flush: {})
        _ = await none.cleanup.value
        defaults.removeObject(forKey: WindowsUpdateInstaller.failedKey)
        r.add("update.markerReport", failed.report == .failed("99.0.2") && done.report == .done("2.5.0") && none.report == .none
                && balloons == [l.updateInstallFailed] && afterFailure == nil && heldBack == "99.0.2" && left == 0,
              "reports \(failed.report), \(done.report), \(none.report); balloons \(balloons.count) (\(balloons.first ?? "-")); "
                + "marker after the failure: \(afterFailure?.version ?? "gone"); held back: \(heldBack ?? "none"); downloads left: \(left)")
    }

    /// SHA-256 of 32 MiB off the main actor, as the install's checks run it; the time in the detail.
    @MainActor private static func hashTimeCheck(_ r: Recorder) async {
        let (ms, thread) = await Task.detached { () -> (Double, DWORD) in
            let data = Data(repeating: 0x61, count: 32 << 20)
            let t0 = Date()
            _ = UpdateDownloadCheck.sha256Hex(data)
            return (Date().timeIntervalSince(t0) * 1000, GetCurrentThreadId())
        }.value
        r.add("update.hashMs", thread != WindowsApp.mainThreadID,
              String(format: "SHA-256 of 32 MiB took %.0f ms on thread %u (main %u)", ms, thread, WindowsApp.mainThreadID))
    }
}
#endif
