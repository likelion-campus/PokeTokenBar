#if os(Windows)
import XCTest
import FoundationNetworking
import WinSDK
@testable import PokeTokenBar

/// The in-app update on Windows (stage 8 Task 6): Setup's arguments, the folders, the marker and the launch report, and
/// `install` with an injected download and launch (no network but the loopback server, no Setup started), plus the file work
/// on disk and one body over the seam's default cap through the real WinHTTP seam.
@MainActor
final class WindowsUpdateInstallerTests: XCTestCase {
    private static let body = Data(repeating: 0x61, count: 1 << 20)  // the feed's smallest installer
    /// Where GitHub's download ends today (F5): the asset CDN, with a signed query.
    private static let assetHost = "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sp=r&sig=x"

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func installer(version: String = "2.5.640", body: Data = body,
                           prefix: String = InstallerReleaseFeed.releaseDownloadPrefix) throws -> InstallerReleaseFeed.Installer {
        try XCTUnwrap(InstallerReleaseFeed.installer(in: ReleaseFixture.installerData(version: version, size: body.count,
                                                                                      sha256: UpdateDownloadCheck.sha256Hex(body), prefix: prefix),
                                                     downloadPrefix: prefix))
    }

    /// What the injected download was asked, across its thread.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(url: URL?, maxBytes: Int, deadline: TimeInterval)] = []
        func add(_ url: URL?, _ maxBytes: Int, _ deadline: TimeInterval) { lock.lock(); calls.append((url, maxBytes, deadline)); lock.unlock() }
        var all: [(url: URL?, maxBytes: Int, deadline: TimeInterval)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func answering(_ body: Data, status: Int = 200, final: String = assetHost, asked: Asked) -> WindowsUpdateInstaller.Download {
        { request, maxBytes, deadline, _ in
            asked.add(request.url, maxBytes, deadline)
            guard let url = URL(string: final), let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            else { throw URLError(.badURL) }
            return (body, response)
        }
    }

    struct Outcome {
        var failure: WindowsUpdateInstaller.Failure?
        var launches: [(exe: URL, args: [String], folder: URL)] = []
        var flushes = 0
        var exits = 0
        /// Files left under the Updates folder, relative.
        var files: [String] = []
    }

    private func files(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return (e.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }.map { $0.lastPathComponent }.sorted()
    }

    private func install(_ i: InstallerReleaseFeed.Installer, current: String? = "2.5.634", fetch: @escaping WindowsUpdateInstaller.Download,
                         launchOK: Bool = true, setupRunning: Bool = false, defaults: UserDefaults, updates: URL, logs: URL,
                         loopback: LoopbackFeed? = nil, progress: (any WindowsUpdateProgress)? = nil) async -> Outcome {
        var out = Outcome()
        out.failure = await WindowsUpdateInstaller.install(i, currentVersion: current, defaults: defaults, folder: updates, logs: logs,
                                                           loopback: loopback, progress: progress, setupRunning: { setupRunning }, fetch: fetch,
                                                           launch: { out.launches.append(($0, $1, $2)); return launchOK },
                                                           flush: { out.flushes += 1 }, onLaunched: { out.exits += 1 })
        out.files = files(under: updates)
        return out
    }

    // MARK: arguments, folders, the marker

    func testSetupsArgumentsAreExactAndTheLogPathIsQuoted() async throws {
        let log = URL(fileURLWithPath: "C:/Users/a b/AppData/Local/PokeTokenBar/Logs/update-2.5.640.log")
        let args = WindowsUpdateInstaller.arguments(logFile: log)
        XCTAssertEqual(args, ["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/PTBRELAUNCHONFAIL=1",
                              "/LOG=\"C:\\Users\\a b\\AppData\\Local\\PokeTokenBar\\Logs\\update-2.5.640.log\""])
        let exe = "C:\\Users\\a b\\AppData\\Local\\PokeTokenBar\\Updates\\2.5.640-1a2b3c4d\\PokeTokenBar-Setup-2.5.640-win-x64.exe"
        XCTAssertEqual(WinProcess.commandLine(exe, args),
                       "\"\(exe)\" /SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PTBRELAUNCHONFAIL=1 "
                       + "/LOG=\"C:\\Users\\a b\\AppData\\Local\\PokeTokenBar\\Logs\\update-2.5.640.log\"")
        XCTAssertNil(WinProcess.commandLine("C:\\a\" /evil\\x.exe", args), "a quote would end the program name")
        XCTAssertNil(WinProcess.commandLine(exe, ["/LOG=x\n/evil"]))
        XCTAssertNil(WinProcess.commandLine(exe, ["a\0b"]))
        XCTAssertNil(WinProcess.commandLine("", args))
        XCTAssertEqual(WindowsUpdateInstaller.installerLog(version: "2.5.640").lastPathComponent, "update-2.5.640.log")
        XCTAssertEqual(WindowsUpdateInstaller.installerLog(version: "2.5.640").deletingLastPathComponent(), PlatformCompat.logsDirectory())
    }

    func testTheUpdatesFolderIsNextToTheLogsUnderTheAppsDataFolder() async {
        let updates = WindowsUpdateInstaller.updatesFolder()
        XCTAssertEqual(updates.lastPathComponent, "Updates")
        XCTAssertEqual(updates.deletingLastPathComponent().standardizedFileURL, PlatformCompat.logsDirectory().deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(updates.deletingLastPathComponent().lastPathComponent, "PokeTokenBar")
        XCTAssertFalse(WinPath.native(updates).lowercased().contains("\\programs\\"), "never inside the install folder")
    }

    func testThePendingMarkerRoundTrips() async {
        let defaults = TestDefaults.make(suite: "windows-update-marker")
        XCTAssertNil(WindowsUpdateInstaller.readPending(defaults))
        let at = Date(timeIntervalSince1970: 1_763_300_000.25)
        WindowsUpdateInstaller.savePending(.init(version: "2.5.640", at: at), defaults)
        let back = WindowsUpdateInstaller.readPending(defaults)
        XCTAssertEqual(back?.version, "2.5.640")
        XCTAssertEqual(back?.at.timeIntervalSince1970 ?? 0, at.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(defaults.dictionary(forKey: "windows.pendingUpdate"), "the plan's key")
    }

    // MARK: the next start

    private func report(_ defaults: UserDefaults, current: String?, updates: URL, logs: URL) async -> (WindowsUpdateInstaller.LaunchReport, [String], Int, Int) {
        var balloons: [String] = []
        var flushes = 0
        let r = WindowsUpdateInstaller.reportAtLaunch(defaults: defaults, currentVersion: current, l: L(.ko), balloon: { balloons.append($0) },
                                                      folder: updates, logs: logs, flush: { flushes += 1 })
        let left = await r.cleanup.value
        return (r.report, balloons, flushes, left)
    }

    private func leaveADownload(in updates: URL, version: String) throws {
        let dir = updates.appendingPathComponent("\(version)-0badf00d", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("setup".utf8).write(to: dir.appendingPathComponent(InstallerReleaseFeed.expectedName(version: version)))
    }

    func testAtLaunchASuccessfulUpdateIsLoggedAndCleanedUp() async throws {
        let defaults = TestDefaults.make(suite: "windows-update-report-done")
        let updates = try folder(), logs = try folder()
        try leaveADownload(in: updates, version: "2.5.640")
        WindowsUpdateInstaller.savePending(.init(version: "2.5.640", at: Date()), defaults)
        let (r, balloons, flushes, left) = await report(defaults, current: "2.5.640", updates: updates, logs: logs)
        XCTAssertEqual(r, .done("2.5.640"))
        XCTAssertEqual(balloons, [])
        XCTAssertNil(WindowsUpdateInstaller.readPending(defaults), "the marker is read once")
        XCTAssertNil(defaults.string(forKey: WindowsUpdateInstaller.failedKey))
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(left, 0)
        XCTAssertEqual(files(under: updates), [], "the downloaded installer is gone")
    }

    func testAtLaunchAFailedUpdateShowsOneBalloonClearsTheMarkerAndHoldsTheVersionBack() async throws {
        let defaults = TestDefaults.make(suite: "windows-update-report-failed")
        let updates = try folder(), logs = try folder()
        try leaveADownload(in: updates, version: "2.5.640")
        WindowsUpdateInstaller.savePending(.init(version: "2.5.640", at: Date()), defaults)
        let (r, balloons, flushes, left) = await report(defaults, current: "2.5.634", updates: updates, logs: logs)
        XCTAssertEqual(r, .failed("2.5.640"))
        XCTAssertEqual(balloons, ["업데이트를 설치하지 못했어요. 릴리스 페이지에서 직접 설치해 주세요."])
        XCTAssertNil(WindowsUpdateInstaller.readPending(defaults))
        XCTAssertEqual(defaults.string(forKey: WindowsUpdateInstaller.failedKey), "2.5.640", "no second silent try of this version")
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(left, 0)
        XCTAssertEqual(files(under: updates), [])
        // The next start says nothing again: one balloon per failed update.
        let (again, more, _, _) = await report(defaults, current: "2.5.634", updates: updates, logs: logs)
        XCTAssertEqual(again, .none)
        XCTAssertEqual(more, [])
    }

    func testAtLaunchWithoutAMarkerNothingIsSaidButLeftoversGo() async throws {
        let defaults = TestDefaults.make(suite: "windows-update-report-none")
        let updates = try folder(), logs = try folder()
        try leaveADownload(in: updates, version: "2.5.639")
        let (r, balloons, flushes, left) = await report(defaults, current: "2.5.634", updates: updates, logs: logs)
        XCTAssertEqual(r, .none)
        XCTAssertEqual(balloons, [])
        XCTAssertEqual(flushes, 0)
        XCTAssertEqual(left, 0)
        XCTAssertEqual(files(under: updates), [])
        let missing = updates.appendingPathComponent("absent", isDirectory: true)
        let (_, _, _, none) = await report(defaults, current: "2.5.634", updates: missing, logs: logs)
        XCTAssertEqual(none, 0, "an absent Updates folder has nothing to remove")
    }

    // MARK: install with an injected download and launch

    func testGoodBytesAreWrittenExactlyAndSetupGetsThatPathAndItsArguments() async throws {
        let defaults = TestDefaults.make(suite: "windows-update-good")
        let updates = try folder(), logs = try folder()
        let i = try installer()
        let asked = Asked()
        let out = await install(i, fetch: answering(Self.body, asked: asked), defaults: defaults, updates: updates, logs: logs)
        XCTAssertNil(out.failure)
        XCTAssertEqual(asked.all.count, 1)
        XCTAssertEqual(asked.all.first?.url, i.url)
        XCTAssertEqual(asked.all.first?.maxBytes, i.size, "the cap is the installer's own size, not the seam's default")
        XCTAssertEqual(asked.all.first?.deadline, 900, "15 minutes for the whole download")
        let launch = try XCTUnwrap(out.launches.first)
        XCTAssertEqual(out.launches.count, 1)
        XCTAssertEqual(launch.exe.lastPathComponent, "PokeTokenBar-Setup-2.5.640-win-x64.exe")
        XCTAssertEqual(launch.exe.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL, updates.standardizedFileURL,
                       "a folder of this attempt's own under Updates")
        XCTAssertEqual(try Data(contentsOf: launch.exe), Self.body, "exactly the bytes that passed")
        XCTAssertEqual(launch.args, WindowsUpdateInstaller.arguments(logFile: logs.appendingPathComponent("update-2.5.640.log")))
        XCTAssertEqual(launch.folder, logs, "Setup's working folder: the logs, outside the install folder")
        XCTAssertEqual(WindowsUpdateInstaller.readPending(defaults)?.version, "2.5.640")
        XCTAssertEqual(out.flushes, 1, "the marker is on disk before the app leaves")
        XCTAssertEqual(out.exits, 1)
        XCTAssertEqual(WindowsUpdateInstaller.lastWorkThreads.count, 2)
    }

    private func refused(_ i: InstallerReleaseFeed.Installer, body: Data = body, status: Int = 200, final: String = assetHost,
                         current: String? = "2.5.634", setupRunning: Bool = false, launchOK: Bool = true,
                         fetch: WindowsUpdateInstaller.Download? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> (Outcome, Int) {
        let defaults = TestDefaults.make(suite: "windows-update-refused")
        let updates = try folder(), logs = try folder()
        let asked = Asked()
        let out = await install(i, current: current, fetch: fetch ?? answering(body, status: status, final: final, asked: asked), launchOK: launchOK,
                                setupRunning: setupRunning, defaults: defaults, updates: updates, logs: logs)
        XCTAssertNotNil(out.failure, file: file, line: line)
        XCTAssertEqual(out.files, [], "nothing left behind", file: file, line: line)
        XCTAssertEqual(out.exits, 0, "the app keeps running", file: file, line: line)
        XCTAssertEqual(out.flushes, 0, file: file, line: line)
        XCTAssertNil(WindowsUpdateInstaller.readPending(defaults), "no marker", file: file, line: line)
        if !launchOK { XCTAssertEqual(out.launches.count, 1, file: file, line: line) } else { XCTAssertEqual(out.launches.count, 0, "Setup not started", file: file, line: line) }
        return (out, asked.all.count)
    }

    func testOneTamperedByteIsRefusedByTheDigestAndNothingIsWritten() async throws {
        var tampered = Self.body
        tampered[tampered.count / 2] ^= 0x01
        let (out, _) = try await refused(try installer(), body: tampered)
        XCTAssertEqual(out.failure, .check(.digest))
        XCTAssertEqual(out.failure?.opensReleasePage, true, "the page opens")
        XCTAssertEqual(out.failure?.message(L(.en)), L(.en).updateInstallFailed)
    }

    func testAShortBodyIsRefusedByItsLength() async throws {
        let (out, _) = try await refused(try installer(), body: Self.body.dropLast())
        XCTAssertEqual(out.failure, .check(.length(expected: Self.body.count, got: Self.body.count - 1)))
    }

    func testAFinalPlainHTTPAddressIsInsecure() async throws {
        let (out, _) = try await refused(try installer(), final: "http://release-assets.githubusercontent.com/x")
        XCTAssertEqual(out.failure, .check(.insecure))
    }

    func testAFinalHostOffTheListIsRefused() async throws {
        let (out, _) = try await refused(try installer(), final: "https://evil.test/PokeTokenBar-Setup-2.5.640-win-x64.exe")
        XCTAssertEqual(out.failure, .check(.finalHost("evil.test")))
    }

    func testWithoutAVersionFileNothingIsDownloaded() async throws {
        let (out, fetches) = try await refused(try installer(), current: nil)
        XCTAssertEqual(out.failure, .check(.notPackaged))
        XCTAssertEqual(fetches, 0)
    }

    func testTheSameVersionIsNotInstalledAgain() async throws {
        let (out, fetches) = try await refused(try installer(version: "2.5.634"), current: "2.5.634")
        XCTAssertEqual(out.failure, .check(.notNewer))
        XCTAssertEqual(fetches, 0)
    }

    func testARunningSetupStopsTheUpdateBeforeTheDownloadAndKeepsThePageClosed() async throws {
        let (out, fetches) = try await refused(try installer(), setupRunning: true)
        XCTAssertEqual(out.failure, .setupRunning)
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(out.failure?.opensReleasePage, false)
        XCTAssertEqual(out.failure?.message(L(.en)), L(.en).updateSetupRunning)
    }

    func testASetupThatDoesNotStartLeavesNoFileAndNoMarker() async throws {
        let (out, _) = try await refused(try installer(), launchOK: false)
        XCTAssertEqual(out.failure, .launch)
    }

    func testATransportFailureIsReportedWithItsCode() async throws {
        let offline: WindowsUpdateInstaller.Download = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        let (out, _) = try await refused(try installer(), fetch: offline)
        XCTAssertEqual(out.failure, .download(URLError.Code.notConnectedToInternet.rawValue))
        XCTAssertEqual(out.failure?.opensReleasePage, true)
    }

    /// The window's Cancel ends a slow download: nothing is left, no balloon, and the page stays closed.
    func testCancelFromTheWindowEndsTheDownload() async throws {
        @MainActor final class Window: WindowsUpdateProgress {
            var events: [String] = []
            func began(version: String, total: Int, cancel: @escaping @MainActor () -> Void) { events.append("began \(version) \(total)"); cancel() }
            func received(_ bytes: Int, of total: Int) {}
            func checking() { events.append("checking") }
            func starting() { events.append("starting") }
            func close() { events.append("close") }
        }
        let slow: WindowsUpdateInstaller.Download = { _, _, _, _ in
            try await Task.sleep(nanoseconds: 20_000_000_000)
            throw URLError(.timedOut)
        }
        let defaults = TestDefaults.make(suite: "windows-update-cancel")
        let updates = try folder(), logs = try folder()
        let window = Window()
        let t0 = Date()
        let out = await install(try installer(), fetch: slow, defaults: defaults, updates: updates, logs: logs, progress: window)
        XCTAssertEqual(out.failure, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
        XCTAssertEqual(window.events, ["began 2.5.640 \(Self.body.count)", "close"])
        XCTAssertEqual(out.files, [])
        XCTAssertEqual(out.launches.count, 0)
        XCTAssertEqual(out.failure?.opensReleasePage, false)
        XCTAssertNil(out.failure?.message(L(.en)))
    }

    func testTheProgressRelayHopsOnlyWhenThePermilleChanges() async {
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let count = Count()
        let relay = ProgressRelay(total: 10_000) { _ in count.lock.lock(); count.n += 1; count.lock.unlock() }
        for bytes in stride(from: 0, through: 10_000, by: 1) { relay.received(bytes) }
        XCTAssertEqual(count.n, 1001)
    }

    // MARK: the files on disk

    func testOlderAttemptsGoAndEachAttemptGetsAFolderOfItsOwn() async throws {
        let updates = try folder()
        try leaveADownload(in: updates, version: "2.5.639")
        try Data("x".utf8).write(to: updates.appendingPathComponent("stray.txt"))
        let one = try WinUpdateFile.freshFolder(in: updates, name: "2.5.640")
        let two = try WinUpdateFile.freshFolder(in: updates, name: "2.5.640")
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates.path), [two.lastPathComponent], "only the newest attempt")
    }

    /// A junction where the Updates folder goes is removed as a link: what it points at stays untouched, and the download
    /// lands in a plain folder.
    func testAJunctionInPlaceOfTheUpdatesFolderIsRemovedNotFollowed() async throws {
        let root = try folder()
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let victim = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: victim)
        let updates = root.appendingPathComponent("Updates", isDirectory: true)
        let mklink = Process()
        mklink.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        mklink.arguments = ["/c", "mklink", "/J", WinPath.native(updates), WinPath.native(target)]
        try mklink.run()
        mklink.waitUntilExit()
        let before = try XCTUnwrap(WinUpdateFile.attributes(WinPath.native(updates)), "mklink /J made nothing")
        XCTAssertNotEqual(before & 0x400, 0, "the fixture is a junction")
        let fresh = try WinUpdateFile.freshFolder(in: updates, name: "2.5.640")
        let after = try XCTUnwrap(WinUpdateFile.attributes(WinPath.native(updates)))
        XCTAssertEqual(after & 0x400, 0, "Updates is a plain folder now")
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8), "the junction's target was not emptied")
        XCTAssertEqual(fresh.deletingLastPathComponent().standardizedFileURL, updates.standardizedFileURL)
    }

    func testAWriteThatFailsHalfwayLeavesNoFile() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("PokeTokenBar-Setup-2.5.640-win-x64.exe")
        let big = Data(repeating: 0x61, count: 3 << 20)
        var chunks = 0
        XCTAssertThrowsError(try WinUpdateFile.writeAndHold(big, to: file, sha256: UpdateDownloadCheck.sha256Hex(big)) { handle, bytes, count, written in
            chunks += 1
            if chunks > 1 { SetLastError(DWORD(ERROR_DISK_FULL)); return false }
            return WriteFile(handle, bytes, count, &written, nil)
        }) { error in
            XCTAssertEqual((error as? WinUpdateFile.Failure)?.code, DWORD(ERROR_DISK_FULL), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the partial file is removed")
    }

    /// What is read back from disk is hashed: a file whose bytes on disk are not the checked ones is refused and removed.
    func testTheFileReadBackFromDiskIsHashed() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("PokeTokenBar-Setup-2.5.640-win-x64.exe")
        let data = Self.body
        XCTAssertThrowsError(try WinUpdateFile.writeAndHold(data, to: file, sha256: UpdateDownloadCheck.sha256Hex(data)) { handle, bytes, count, written in
            var changed = Data(bytes: bytes, count: Int(count))
            changed[0] ^= 0x01
            return changed.withUnsafeBytes { WriteFile(handle, $0.baseAddress, count, &written, nil) }
        }) { error in
            XCTAssertTrue((error as? WinUpdateFile.Failure)?.isDigest == true, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// While held, nobody may write, rename or delete the file Setup will start; it can still be opened for reading.
    func testTheHeldFileCannotBeChangedOrRemovedUntilClosed() async throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("PokeTokenBar-Setup-2.5.640-win-x64.exe")
        let held = try WinUpdateFile.writeAndHold(Self.body, to: file, sha256: UpdateDownloadCheck.sha256Hex(Self.body))
        XCTAssertFalse(DeleteFileW(WinStr.w(WinPath.native(file))), "no delete while held")
        XCTAssertFalse(MoveFileExW(WinStr.w(WinPath.native(file)), WinStr.w(WinPath.native(file) + ".moved"), 0), "no rename while held")
        let writer = CreateFileW(WinStr.w(WinPath.native(file)), DWORD(0x4000_0000), DWORD(0x7), nil, DWORD(3), 0, nil)
        XCTAssertTrue(writer == INVALID_HANDLE_VALUE, "no writer while held")
        if writer != INVALID_HANDLE_VALUE { _ = CloseHandle(writer) }
        XCTAssertEqual(try Data(contentsOf: file), Self.body, "readers still may")
        held.close()
        XCTAssertTrue(DeleteFileW(WinStr.w(WinPath.native(file))))
    }

    // MARK: through the real seam

    /// The defect class "a default cap sized for API answers silently blocks a larger download" (defect log): a body one byte
    /// over the seam's 32 MiB default goes through WinHTTP with the installer's own size as the cap, where the default fails.
    func testABodyOverTheSeamsDefaultCapPassesWithTheInstallersOwnCap() async throws {
        let server = try XCTUnwrap(LoopbackServer.start(), "loopback server did not start")
        let size = WinHTTPFetch.defaultMaxBodyBytes + 1
        let body = Data(repeating: 0x61, count: size)
        let i = try installer(body: body, prefix: "http://127.0.0.1:\(server.port)/big/\(size)/")
        do {
            _ = try await WinHTTPFetch.data(for: URLRequest(url: i.url, timeoutInterval: 30))
            XCTFail("the default cap took \(size) bytes")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum, "the trigger: the API answers' cap refuses the body")
        }
        let feed = try XCTUnwrap(LoopbackFeed(feed: "http://127.0.0.1:\(server.port)/releases/latest", environment: ["CI": "true"], packaged: true))
        let defaults = TestDefaults.make(suite: "windows-update-over-cap")
        let updates = try folder(), logs = try folder()
        var out = Outcome()
        out.failure = await WindowsUpdateInstaller.install(i, currentVersion: "2.5.634", defaults: defaults, folder: updates, logs: logs,
                                                           loopback: feed, setupRunning: { false },
                                                           launch: { out.launches.append(($0, $1, $2)); return true },
                                                           flush: {}, onLaunched: {})
        XCTAssertNil(out.failure)
        let exe = try XCTUnwrap(out.launches.first?.exe)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: exe.path)[.size] as? Int, size)
    }

    func testTheLoopbackFeedNeedsCIAnInstalledCopyAndPlainLoopback() async {
        let ci = ["CI": "true"]
        XCTAssertEqual(LoopbackFeed(feed: "http://127.0.0.1:8123/releases/latest", environment: ci, packaged: true)?.downloadPrefix,
                       "http://127.0.0.1:8123/releases/download/")
        for (text, env, packaged) in [("http://127.0.0.1:8123/x", [:], true), ("http://127.0.0.1:8123/x", ["CI": "1"], true),
                                      ("http://127.0.0.1:8123/x", ci, false), ("https://127.0.0.1:8123/x", ci, true),
                                      ("http://localhost:8123/x", ci, true), ("http://127.0.0.2:8123/x", ci, true),
                                      ("http://127.0.0.1/x", ci, true), ("http://u@127.0.0.1:8123/x", ci, true),
                                      ("http://api.github.com/x", ci, true), ("", ci, true)] as [(String, [String: String], Bool)] {
            XCTAssertNil(LoopbackFeed(feed: text, environment: env, packaged: packaged), "\(text) \(env) packaged=\(packaged)")
        }
        let feed = LoopbackFeed(feed: "http://127.0.0.1:8123/x", environment: ci, packaged: true)
        XCTAssertEqual(feed?.allows("127.0.0.1"), true)
        XCTAssertEqual(feed?.allows("localhost"), false)
        XCTAssertEqual(feed?.allows("github.com"), false, "the loopback does not widen the hosts, it replaces them")
    }

    // MARK: the process

    func testTheSetupMutexIsSeenWhileItExists() async {
        let name = "Local\\PokeTokenBar-Test-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(WinProcess.mutexExists(name))
        let handle = CreateMutexW(nil, false, WinStr.w(name))
        XCTAssertNotNil(handle)
        XCTAssertTrue(WinProcess.mutexExists(name))
        if let handle { _ = CloseHandle(handle) }
        XCTAssertFalse(WinProcess.mutexExists(name))
        XCTAssertEqual(WindowsUpdateInstaller.setupMutex, "Local\\PokeTokenBar-Setup", "installer/PokeTokenBar.iss creates this name")
    }

    /// `launchDetached` passes the exact path (with a space), the arguments as given and the working folder.
    func testLaunchDetachedStartsTheExactPathInTheGivenFolder() async throws {
        let dir = try folder().appendingPathComponent("a b", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("cwd.txt")
        let cmd = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        XCTAssertTrue(WinProcess.launchDetached(cmd, ["/c", "cd", ">", "\"\(WinPath.native(out))\""], workingDirectory: dir))
        var text = ""
        for _ in 0..<50 where text.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            text = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        XCTAssertEqual(text.lowercased(), WinPath.native(dir).lowercased())
        XCTAssertFalse(WinProcess.launchDetached(URL(fileURLWithPath: "C:\\no\\such\\setup.exe"), [], workingDirectory: dir))
    }
}
#endif
