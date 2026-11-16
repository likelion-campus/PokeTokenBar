#if os(Windows)
import Crypto
import Foundation
import FoundationNetworking
import WinSDK

/// What the update download window shows (`WinUpdateProgressWindow`); nil in tests and the CI checks.
@MainActor protocol WindowsUpdateProgress: AnyObject, Sendable {
    /// The download started; `cancel` ends it (the window's Cancel button and its close box).
    func began(version: String, total: Int, cancel: @escaping @MainActor () -> Void)
    func received(_ bytes: Int, of total: Int)
    /// The bytes are in: the checks run.
    func checking()
    /// Setup is about to start; nothing can be cancelled any more.
    func starting()
    func close()
}

/// The CI selftest's loopback release feed (`--selftest-update-from`): the one way the download may be plain HTTP, and then
/// only from 127.0.0.1. It exists only with `CI=true` in an installed copy (a version file next to the exe).
struct LoopbackFeed: Equatable, Sendable {
    static let host = "127.0.0.1"
    let feed: URL
    let port: Int
    /// Where the loopback feed's installer address must start (`InstallerReleaseFeed.installerCheck`).
    var downloadPrefix: String { "http://\(Self.host):\(port)/releases/download/" }

    /// nil unless `CI` is exactly `true`, the app is an installed copy and `feed` is `http://127.0.0.1:<port>/…` without
    /// user info.
    init?(feed text: String, environment: [String: String], packaged: Bool) {
        guard environment["CI"] == "true", packaged, let url = URL(string: text), url.scheme == "http", url.host == Self.host,
              let port = url.port, url.user == nil, url.password == nil else { return nil }
        feed = url
        self.port = port
    }

    /// The final download host it allows instead of GitHub's: 127.0.0.1 only.
    func allows(_ host: String) -> Bool { host == Self.host }
}

/// The in-app update on Windows (stage 8, D8 steps 3-8): download the checked installer, check it, write exactly those bytes,
/// check the file again, start Setup and leave; at the next start, say what happened. Every step before the start leaves the
/// running app running and removes what it wrote.
///
/// The trust chain, each link checked before the next: the feed answer from api.github.com over TLS gave the `Installer`
/// (`InstallerReleaseFeed.installerCheck`: name, address, state, size, digest), for exactly the version being installed
/// (`WindowsUpdates.installer(for:)`); the installed copy is older (`UpdateDownloadCheck.refusal(installing:)`); the download
/// goes through WinHTTP with the installer's own size as the cap and a 15-minute deadline (`PlatformCompat.oneShotDownload`);
/// the answer is a 200 that ended on HTTPS at a GitHub download host with exactly `size` bytes whose SHA-256 is the digest
/// (`UpdateDownloadCheck.refusal(status:…)`, off the main actor); those bytes go into a new file in a new folder of this
/// attempt (`CREATE_NEW`), which is opened again read-only with read sharing only and hashed from disk; with that handle still
/// open, `CreateProcessW` starts that exact path. This protects against other users and accidents (a stale or half-written
/// file, a link left where the folder goes). A process of the same user is out of scope (plan D9): it could swap a folder
/// between the write and the reopen or change the file through a mapping, which it can already do to the installed app.
@MainActor enum WindowsUpdateInstaller {
    static let pendingKey = "windows.pendingUpdate"
    /// The version whose in-app install did not finish: "Update" for it opens the release page instead (no second silent try).
    static let failedKey = "windows.failedUpdateVersion"
    /// Created by every PokeTokenBar Setup at its start (installer/PokeTokenBar.iss, `InitializeSetup`).
    static let setupMutex = "Local\\PokeTokenBar-Setup"
    /// The whole download (D8 step 3); 33 MB take 15 minutes at about 37 KB/s.
    nonisolated static let downloadDeadline: TimeInterval = 15 * 60
    /// Silence on the connection that ends the download.
    nonisolated static let downloadSilence: TimeInterval = 30

    /// Why nothing was started. One fixed text per case for the log: never a body byte, a path or a query.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// A rule of the shared checks (`UpdateDownloadCheck`): not an installed copy, not newer, the answer's status, scheme,
        /// final host, length or digest.
        case check(UpdateDownloadCheck.Refusal)
        /// The transfer failed (network, timeout, the cap): the URLError code.
        case download(Int)
        case cancelled
        /// Writing or re-reading the file: the step and the Win32 code (112: the disk is full).
        case write(String)
        /// The file on disk is not the bytes that passed the checks.
        case writtenCopy
        case setupRunning
        case launch

        var description: String {
            switch self {
            case .check(let refusal): return refusal.description
            case .download(let code): return "the download failed (URLError \(code))"
            case .cancelled: return "cancelled by the user"
            case .write(let step): return "the installer could not be saved: \(step)"
            case .writtenCopy: return "the saved installer is not the checked download"
            case .setupRunning: return "another PokeTokenBar Setup is running"
            case .launch: return "Setup could not be started"
            }
        }

        /// Whether "Update" then opens the release page (`UpdateChecker.applyUpdate`): not after the user's cancel, and not
        /// while another Setup runs (a second installer from the page could not run either).
        var opensReleasePage: Bool { self != .cancelled && self != .setupRunning }

        /// The balloon for the user in the app's language; nil after their own cancel.
        func message(_ l: L) -> String? {
            switch self {
            case .cancelled: return nil
            case .setupRunning: return l.updateSetupRunning
            default: return l.updateInstallFailed
            }
        }
    }

    struct Pending: Equatable {
        let version: String
        let at: Date
    }

    enum LaunchReport: Equatable { case none, done(String), failed(String), setupRunning(String) }

    // MARK: places and arguments

    /// `%LOCALAPPDATA%\PokeTokenBar\Updates`, next to the logs folder.
    static func updatesFolder() -> URL {
        PlatformCompat.logsDirectory().deletingLastPathComponent().appendingPathComponent("Updates", isDirectory: true)
    }

    /// Setup's own log for this version, in the app's logs folder.
    static func installerLog(version: String, logs: URL = PlatformCompat.logsDirectory()) -> URL {
        logs.appendingPathComponent("update-\(version).log")
    }

    /// Setup's switches for an in-app update (D8 step 6, Task 5's surface), in that order: shows its progress window, no
    /// question, no reboot, the per-user install, the previous app started again when it does not finish, its log.
    static func arguments(logFile: URL) -> [String] {
        ["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/PTBRELAUNCHONFAIL=1", "/LOG=\"\(WinPath.native(logFile))\""]
    }

    // MARK: the pending marker

    static func readPending(_ defaults: UserDefaults) -> Pending? {
        guard let entry = defaults.dictionary(forKey: pendingKey), let version = entry["version"] as? String else { return nil }
        let at = (entry["at"] as? Double) ?? (entry["at"] as? NSNumber)?.doubleValue ?? 0
        return Pending(version: version, at: Date(timeIntervalSince1970: at))
    }

    static func savePending(_ pending: Pending, _ defaults: UserDefaults) {
        defaults.set(["version": pending.version, "at": pending.at.timeIntervalSince1970] as [String: Any], forKey: pendingKey)
    }

    // MARK: the install

    /// The download: the request, the cap in bytes, the deadline in seconds, the progress callback.
    typealias Download = @Sendable (URLRequest, Int, TimeInterval, (@Sendable (Int) -> Void)?) async throws -> (Data, URLResponse)
    /// Starts Setup: its path, its arguments, its working folder.
    typealias Launch = @MainActor (URL, [String], URL) -> Bool

    /// What a download gave, as values that may cross to the checks' thread.
    private struct Fetched: @unchecked Sendable {  // Data, Int and URL
        let body: Data
        let status: Int
        let finalURL: URL?
    }

    /// The threads the checks and the file work ran on, last install (the selftest's `update.offMain`).
    private(set) static var lastWorkThreads: [DWORD] = []

    /// nil = Setup started and `onLaunched` ran (which leaves the app by default); otherwise why nothing was started, with
    /// nothing left behind. `fetch`, `launch`, `flush`, `onLaunched` and `loopback` are replaced only by the tests and the CI
    /// selftest (`WindowsSeamScanTests` pins the call sites).
    static func install(_ installer: InstallerReleaseFeed.Installer, currentVersion: String?, defaults: UserDefaults,
                        folder: URL = updatesFolder(), logs: URL = PlatformCompat.logsDirectory(),
                        loopback: LoopbackFeed? = nil, progress: (any WindowsUpdateProgress)? = nil,
                        setupRunning: @MainActor () -> Bool = { WinProcess.mutexExists(setupMutex) },
                        fetch: @escaping Download = { try await PlatformCompat.oneShotDownload(for: $0, maxBytes: $1, deadline: $2, progress: $3) },
                        launch: Launch = { WinProcess.launchDetached($0, $1, workingDirectory: $2) },
                        flush: @MainActor () -> Void = { WinDefaultsSync.flushNow() },
                        onLaunched: @MainActor () -> Void = { WindowsApp.exit(0, .update) }) async -> Failure? {
        lastWorkThreads = []
        if let refusal = UpdateDownloadCheck.refusal(installing: installer, currentVersion: currentVersion) { return .check(refusal) }
        if setupRunning() { return .setupRunning }

        // A folder of this attempt's own under Updates (older attempts' leftovers removed first, links removed as links).
        let place: URL
        do {
            place = try await Task.detached { try WinUpdateFile.freshFolder(in: folder, name: installer.version) }.value
        } catch {
            return .write("\(error)")
        }
        func fail(_ failure: Failure) -> Failure {
            WinUpdateFile.removeTree(WinPath.native(place))
            progress?.close()
            return failure
        }

        let onBytes: (@Sendable (Int) -> Void)? = progress.map { window in
            let relay = ProgressRelay(total: installer.size) { bytes in
                DispatchQueue.main.async { MainActor.assumeIsolated { window.received(bytes, of: installer.size) } }
            }
            return { @Sendable bytes in relay.received(bytes) }
        }
        // The cap is this installer's own size: one byte more ends the transfer (defect log, "기본 상한은…"). Off the main
        // actor from the request to the answer's values.
        let download = Task.detached { () throws -> Fetched in
            let request = downloadRequest(installer)
            let (body, response) = try await fetch(request, installer.size, downloadDeadline, onBytes)
            return Fetched(body: body, status: (response as? HTTPURLResponse)?.statusCode ?? 0, finalURL: response.url)
        }
        let cancelled = CancelRequest()
        progress?.began(version: installer.version, total: installer.size) { cancelled.on = true; download.cancel() }
        let fetched: Fetched
        do {
            fetched = try await download.value
        } catch {
            if cancelled.on || download.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return fail(.cancelled) }
            return fail(.download((error as? URLError)?.code.rawValue ?? -1))
        }
        // A cancel after the last byte (the task had finished, so nothing threw) still counts, here and right before the start.
        if cancelled.on { return fail(.cancelled) }

        progress?.checking()
        let (rule, checkThread) = await Task.detached { () -> (UpdateDownloadCheck.Refusal?, DWORD) in
            let rule: UpdateDownloadCheck.Refusal?
            if let loopback {
                rule = UpdateDownloadCheck.refusal(status: fetched.status, finalURL: fetched.finalURL, body: fetched.body, for: installer,
                                                   allowedHost: loopback.allows, allowHTTP: true)
            } else {
                rule = UpdateDownloadCheck.refusal(status: fetched.status, finalURL: fetched.finalURL, body: fetched.body, for: installer)
            }
            return (rule, GetCurrentThreadId())
        }.value
        lastWorkThreads.append(checkThread)
        if let rule { return fail(.check(rule)) }

        // Exactly the bytes that passed, then the file read back from disk and hashed (against accidents and other users; a
        // same-user process is out of scope, D9).
        let file = place.appendingPathComponent(installer.name)
        let held: WinUpdateFile.Held
        do {
            let (opened, writeThread) = try await Task.detached { () throws -> (WinUpdateFile.Held, DWORD) in
                (try WinUpdateFile.writeAndHold(fetched.body, to: file, sha256: installer.sha256), GetCurrentThreadId())
            }.value
            held = opened
            lastWorkThreads.append(writeThread)
        } catch let failure as WinUpdateFile.Failure {
            return fail(failure.isDigest ? .writtenCopy : .write(failure.description))
        } catch {
            return fail(.write("\(error)"))
        }

        progress?.starting()
        if cancelled.on { held.close(); return fail(.cancelled) }
        // Again right before the start: a Setup the user started meanwhile must not be raced (it would stop ours, exit 1,
        // after this app has left, and a cancelled wizard would leave no app running).
        if setupRunning() { held.close(); return fail(.setupRunning) }
        let started = launch(held.url, arguments(logFile: installerLog(version: installer.version, logs: logs)), logs)
        held.close()
        guard started else { return fail(.launch) }
        savePending(Pending(version: installer.version, at: Date()), defaults)
        flush()
        AppLog.write("update: Setup for v\(installer.version) started; the app leaves for it")
        onLaunched()
        return nil
    }

    /// The download request: the asset address, a 30 s silence limit, GitHub's binary Accept.
    nonisolated static func downloadRequest(_ installer: InstallerReleaseFeed.Installer) -> URLRequest {
        var request = URLRequest(url: installer.url, timeoutInterval: downloadSilence)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: the next start

    /// Once at launch, after the tray exists: a marker means an update ran. The version file now names its version: done.
    /// Otherwise Setup did not finish and put the previous app back: one balloon, and that version is not installed in-app
    /// again (`failedKey`). The marker goes either way; the downloads under Updates are removed (retried while Setup's loader,
    /// which runs from the file, is still ending), also with no marker (an attempt that ended before Setup).
    /// While a PokeTokenBar Setup still runs, nothing is decided and the marker stays: `.setupRunning`, and the caller asks
    /// again once it ended (`afterSetup`). That covers the app Setup starts itself ([Run], or the relaunch after a failure:
    /// Setup holds its mutex until it exits) and an app started by hand before Setup finished. An installed version at or
    /// above the marker's counts as done (a later release installed by hand after an update that never restarted the app).
    @discardableResult
    static func reportAtLaunch(defaults: UserDefaults, currentVersion: String?, l: L, balloon: (String) -> Void,
                               folder: URL = updatesFolder(), logs: URL = PlatformCompat.logsDirectory(),
                               setupRunning: @MainActor () -> Bool = { WinProcess.mutexExists(setupMutex) },
                               flush: @MainActor () -> Void = { WinDefaultsSync.flushNow() }) -> (report: LaunchReport, cleanup: Task<Int, Never>) {
        var report = LaunchReport.none
        if let pending = readPending(defaults), setupRunning() {
            AppLog.write("update: a PokeTokenBar Setup is still running; the update to v\(pending.version) is reported when it ends")
            report = .setupRunning(pending.version)
            return (report, Task { 0 })  // its download is still Setup's own file
        }
        if let pending = readPending(defaults) {
            defaults.removeObject(forKey: pendingKey)
            let current = currentVersion.flatMap(UpdateChecker.normalizedReleaseVersion)
            if let current, !UpdateChecker.isNewer(pending.version, than: current) {
                AppLog.write("update: update to v\(pending.version) done" + (current == pending.version ? "" : " (this is v\(current))"))
                report = .done(pending.version)
            } else {
                defaults.set(pending.version, forKey: failedKey)
                AppLog.write("update: the update to v\(pending.version) did not install; this is v\(current ?? "unknown"); "
                             + "Setup's log: \(WinPath.native(installerLog(version: pending.version, logs: logs))); told the user")
                balloon(l.updateInstallFailed)
                report = .failed(pending.version)
            }
            flush()
        }
        return (report, removeDownloads(in: folder))
    }

    /// `then` on the main actor once no PokeTokenBar Setup exists (its mutex is gone: Setup creates it unowned and holds it
    /// until it exits, so only its existence tells), at most `limit` seconds later. It looks once a `poll` while it waits:
    /// only after an update, for the seconds Setup takes to end.
    @discardableResult
    static func afterSetup(name: String = setupMutex, poll: TimeInterval = 1, limit: TimeInterval = 600,
                           then: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task.detached {
            let end = Date().addingTimeInterval(limit)
            while WinProcess.mutexExists(name), Date() < end { try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000)) }
            await then()
        }
    }

    /// Empties Updates on a background task: up to `attempts` passes `pause` seconds apart while something is still in use,
    /// then the count left (logged once). Nothing waits when the folder is empty or absent.
    static func removeDownloads(in folder: URL, attempts: Int = 10, pause: TimeInterval = 1) -> Task<Int, Never> {
        let path = WinPath.native(folder)
        return Task.detached {
            var left = 0
            for attempt in 1...max(1, attempts) {
                left = WinUpdateFile.emptyFolder(path)
                if left == 0 { break }
                if attempt < attempts { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            }
            if left > 0 { AppLog.write("update: \(left) item(s) under Updates still in use; they go at the next start") }
            return left
        }
    }
}

/// The user's Cancel, as the install reads it after the download (a finished task's own cancellation is not relied on).
@MainActor final class CancelRequest { var on = false }

/// Hands the download's progress to the window, only when the shown permille changes (at most 1001 hops for any size).
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = -1
    private let total: Int
    private let deliver: @Sendable (Int) -> Void

    init(total: Int, deliver: @escaping @Sendable (Int) -> Void) {
        self.total = total
        self.deliver = deliver
    }

    func received(_ bytes: Int) {
        let step = total > 0 ? min(1000, bytes * 1000 / total) : 0
        lock.lock()
        let changed = step != shown
        if changed { shown = step }
        lock.unlock()
        if changed { deliver(bytes) }
    }
}

/// The update's files on disk, without the main actor. Nothing here follows a link: a junction or symbolic link in the way is
/// removed as a link, and the downloaded file is opened with `FILE_FLAG_OPEN_REPARSE_POINT`.
enum WinUpdateFile {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let code: DWORD
        var description: String { code == 0 ? step : "\(step) failed (Win32 error \(code))" }
        var isDigest: Bool { step == Self.digestStep }
        static let digestStep = "the file read back has another SHA-256"
    }

    /// The file Setup starts from, open for reading with read sharing only: until `close`, opening it to write, rename or
    /// delete it fails (the image loader's read-and-execute open shares reading, so `CreateProcessW` still opens it). That
    /// keeps accidents and other users out; a same-user process is out of scope (D9).
    final class Held: @unchecked Sendable {
        let url: URL
        private var handle: UnsafeMutableRawPointer?
        init(url: URL, handle: UnsafeMutableRawPointer) { self.url = url; self.handle = handle }
        func close() { if let h = handle { _ = CloseHandle(h); handle = nil } }
        deinit { close() }
    }

    private static let directory: DWORD = 0x10, reparse: DWORD = 0x400, readOnly: DWORD = 0x1

    /// The attributes of the path itself (a link's own, not its target's); nil when nothing is there.
    static func attributes(_ path: String) -> DWORD? {
        let a = GetFileAttributesW(WinStr.w(path))
        return a == DWORD.max ? nil : a
    }

    /// `folder` as a plain folder (a link or a file in its place is removed first), emptied, and a new folder `<name>-<8 hex>`
    /// made in it (`CreateDirectoryW` fails on anything already there).
    static func freshFolder(in folder: URL, name: String) throws -> URL {
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = WinPath.native(folder)
        if let a = attributes(root), a & reparse != 0 || a & directory == 0 {
            removeEntry(root, attributes: a)
        }
        if attributes(root) == nil, !CreateDirectoryW(WinStr.w(root), nil) {
            throw Failure(step: "creating the Updates folder", code: GetLastError())
        }
        guard let a = attributes(root), a & directory != 0, a & reparse == 0 else {
            throw Failure(step: "the Updates folder is a link or a file that could not be removed", code: 0)
        }
        _ = removeContents(root)  // an older attempt's file still in use stays; this attempt has its own folder
        let dir = root + "\\" + name + "-" + String(UUID().uuidString.prefix(8)).lowercased()
        guard CreateDirectoryW(WinStr.w(dir), nil) else { throw Failure(step: "creating the download folder", code: GetLastError()) }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    /// Writes `data` into a new file (`CREATE_NEW`, no sharing while it is written), then opens it again read-only with read
    /// sharing only and checks what it opened: no link, one name, `data.count` bytes, and the SHA-256 of the contents read back
    /// equal to `sha256`. Returns that open file. Any failure removes the file. `writeChunk` replaces `WriteFile` in tests.
    static func writeAndHold(_ data: Data, to file: URL, sha256: String,
                             writeChunk: (UnsafeMutableRawPointer, UnsafeRawPointer, DWORD, inout DWORD) -> Bool = { WriteFile($0, $1, $2, &$3, nil) }) throws -> Held {
        let path = WinPath.native(file)
        func remove() { _ = DeleteFileW(WinStr.w(path)) }
        guard let out = CreateFileW(WinStr.w(path), DWORD(0x4000_0000) /* GENERIC_WRITE */, 0, nil, DWORD(1) /* CREATE_NEW */,
                                    DWORD(0x80) /* FILE_ATTRIBUTE_NORMAL */, nil), out != INVALID_HANDLE_VALUE
        else { throw Failure(step: "creating the file", code: GetLastError()) }
        var offset = 0
        var writeError: DWORD = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count, let base = raw.baseAddress {
                var written: DWORD = 0
                let chunk = DWORD(min(raw.count - offset, 1 << 20))
                guard writeChunk(out, base.advanced(by: offset), chunk, &written), written > 0 else {
                    writeError = GetLastError()
                    if writeError == 0 { writeError = DWORD(ERROR_WRITE_FAULT) }
                    return
                }
                offset += Int(written)
            }
        }
        _ = CloseHandle(out)
        guard writeError == 0, offset == data.count else { remove(); throw Failure(step: "writing the file", code: writeError) }

        guard let back = CreateFileW(WinStr.w(path), DWORD(0x8000_0000) /* GENERIC_READ */, DWORD(1) /* FILE_SHARE_READ */, nil,
                                     DWORD(3) /* OPEN_EXISTING */,
                                     DWORD(0x0020_0000 | 0x0800_0000) /* FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN */, nil),
              back != INVALID_HANDLE_VALUE
        else { let code = GetLastError(); remove(); throw Failure(step: "opening the file again", code: code) }
        func refuse(_ failure: Failure) -> Failure { _ = CloseHandle(back); remove(); return failure }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(back, &info) else { throw refuse(Failure(step: "reading the file's information", code: GetLastError())) }
        let size = Int(info.nFileSizeHigh) << 32 | Int(info.nFileSizeLow)
        guard info.dwFileAttributes & reparse == 0, info.nNumberOfLinks == 1, size == data.count else {
            throw refuse(Failure(step: "the file read back is a link, has another name or another size", code: 0))
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            var got: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { ReadFile(back, $0.baseAddress, DWORD($0.count), &got, nil) }
            guard ok else { throw refuse(Failure(step: "reading the file back", code: GetLastError())) }
            if got == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<Int(got)])) }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == sha256 else { throw refuse(Failure(step: Failure.digestStep, code: 0)) }
        return Held(url: file, handle: back)
    }

    /// Removes everything in `path` (links as links, never what they point at); the number of entries that could not go.
    /// An absent folder has none.
    @discardableResult static func removeContents(_ path: String) -> Int {
        var data = WIN32_FIND_DATAW()
        let find = FindFirstFileW(WinStr.w(path + "\\*"), &data)
        guard let find, find != INVALID_HANDLE_VALUE else { return 0 }
        defer { _ = FindClose(find) }
        var left = 0
        repeat {
            let name = withUnsafeBytes(of: data.cFileName) { raw in
                String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
            }
            if name == "." || name == ".." { continue }
            if !removeEntry(path + "\\" + name, attributes: data.dwFileAttributes) { left += 1 }
        } while FindNextFileW(find, &data)
        return left
    }

    /// Empties the Updates folder: when a link or a file stands at `path` itself, only that is removed (never what a link
    /// points at); a plain folder loses its contents. The number of entries that could not go; none when nothing is there.
    @discardableResult static func emptyFolder(_ path: String) -> Int {
        guard let a = attributes(path) else { return 0 }
        if a & reparse != 0 || a & directory == 0 { return removeEntry(path, attributes: a) ? 0 : 1 }
        return removeContents(path)
    }

    /// Removes a folder and what is in it, as `removeContents` does.
    static func removeTree(_ path: String) {
        guard let a = attributes(path) else { return }
        removeEntry(path, attributes: a)
    }

    @discardableResult private static func removeEntry(_ path: String, attributes a: DWORD) -> Bool {
        let wide = WinStr.w(path)
        if a & readOnly != 0 { _ = SetFileAttributesW(wide, DWORD(0x80)) }
        if a & reparse != 0 { return a & directory != 0 ? RemoveDirectoryW(wide) : DeleteFileW(wide) }
        if a & directory != 0 {
            guard removeContents(path) == 0 else { return false }
            return RemoveDirectoryW(wide)
        }
        return DeleteFileW(wide)
    }
}
#endif
