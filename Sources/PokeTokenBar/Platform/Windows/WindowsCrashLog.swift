#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// What the Mac's `CrashReporter` does, on Windows: a running marker that survives every abnormal exit (so the NEXT
/// launch says the last session did not end cleanly), a crash record written while dying, and the Swift runtime's
/// stderr in a file. Everything stays in the app's log folder; nothing is sent anywhere.
///
/// The crash record holds the exception code and address, the module and offset, the app version, the OS build, the
/// process and thread ids and the UTC time. No settings, no file contents, no team code, no paths. A minidump
/// (`MiniDumpNormal`, opt-in only) is the one artifact that can hold more: thread contexts and stacks. It stays on
/// this machine and only the newest `keptDumps` are kept.
///
/// Minidumps are OFF by default and written only when the environment variable `PTB_CRASH_DUMPS=1` is set at launch
/// (no UI yet); the decision is read once at install, never in the filter. Existing dump files are never deleted
/// when the variable is off.
///
/// The filter itself lives in `crash.c` (it must not allocate or take locks). It never writes the settings plist.
enum WindowsCrashLog {
    static let markerName = "PokeTokenBar.running"
    static let crashLogName = "PokeTokenBar.crash.log"
    static let stderrName = "PokeTokenBar.stderr.log"
    static let dumpPrefix = "PokeTokenBar-"
    static let keptDumps = 3
    static let stderrKeptBytes = 256 * 1024

    /// `PTB_CRASH_DUMPS=1` in this process's environment right now (install reads it once).
    static var dumpsOptedIn: Bool { ptb_crash_dumps_opted_in() != 0 }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ownedMarkers = Set<String>()

    /// Once, as early as possible at launch (right after the single-instance check).
    static func install(version: String, logsDirectory: URL = PlatformCompat.logsDirectory(),
                        log: @escaping (String) -> Void = { AppLog.write($0) }, installHandlers: Bool = true) {
        prepare(logsDirectory: logsDirectory, dumpsOptedIn: dumpsOptedIn, log: log)
        guard installHandlers else { return }
        version.withCString { ptb_crash_set_version($0) }
        let crash = WinStr.w(WinPath.native(logsDirectory.appendingPathComponent(crashLogName)))
        let dumps = WinStr.w(WinPath.native(logsDirectory))
        let installed = crash.withUnsafeBufferPointer { c in
            dumps.withUnsafeBufferPointer { d in ptb_crash_install(c.baseAddress, d.baseAddress, nil) }
        }
        if installed != 0 { log("crash log: the crash filter was not installed (\(installed))") }
        let stderrPath = WinStr.w(WinPath.native(logsDirectory.appendingPathComponent(stderrName)))
        let redirected = stderrPath.withUnsafeBufferPointer { ptb_crash_redirect_stderr($0.baseAddress) }
        if redirected != 0 { log("crash log: stderr was not redirected (\(redirected))") }
    }

    /// The file part of `install`, without touching the process (the unit tests call this one).
    static func prepare(logsDirectory: URL, dumpsOptedIn: Bool, log: (String) -> Void) {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        drainCrashLog(in: logsDirectory, log: log)
        let marker = logsDirectory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            log("previous session did not end cleanly (crash, kill or power loss). The crash record, if any, follows; "
                + "minidumps (only when PTB_CRASH_DUMPS=1) are in the log folder.")
        }
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        lock.lock(); ownedMarkers.insert(marker.path); lock.unlock()
        // Existing dumps are the user's (an earlier opted-in run): left alone unless dumps are on, then newest three.
        if dumpsOptedIn { pruneDumps(in: logsDirectory) }
        trimStderrLog(in: logsDirectory)
    }

    /// A clean exit: remove the marker(s) THIS process wrote (a helper process that exits through `WindowsApp.exit`
    /// must not clear the running app's marker). With a folder, only that folder's marker.
    static func markClean(logsDirectory: URL? = nil) {
        var markers: [String] = []
        lock.lock()
        if let logsDirectory {
            let path = logsDirectory.appendingPathComponent(markerName).path
            if ownedMarkers.remove(path) != nil { markers = [path] }
        } else {
            markers = Array(ownedMarkers)
            ownedMarkers.removeAll()
        }
        lock.unlock()
        guard !markers.isEmpty else { return }
        for marker in markers { try? FileManager.default.removeItem(atPath: marker) }
        AppLog.writeAndFlush("clean shutdown")
    }

    /// Merges what the last session wrote while dying into the main log, then removes the file.
    private static func drainCrashLog(in directory: URL, log: (String) -> Void) {
        let url = directory.appendingPathComponent(crashLogName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let text = String(decoding: data.prefix(16 * 1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { log("previous session crash record: \(text)") }
        try? FileManager.default.removeItem(at: url)
    }

    /// Keep the newest `keptDumps` of our own dumps (`PokeTokenBar-YYYYMMDD-HHMMSS-<pid>.dmp`) by modification time:
    /// several crashes inside one second share the name's time part, so the name only breaks ties.
    private static func pruneDumps(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let dumps = names.filter { $0.hasPrefix(dumpPrefix) && $0.hasSuffix(".dmp") }.map { name -> (name: String, modified: Date) in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return (name, (attributes?[.modificationDate] as? Date) ?? .distantPast)
        }.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name > $1.name }
        for old in dumps.dropFirst(keptDumps) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name)) }
    }

    /// The runtime appends to this file all session long; keep its newest 256 KB at launch.
    private static func trimStderrLog(in directory: URL) {
        let url = directory.appendingPathComponent(stderrName)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > stderrKeptBytes else { return }
        var kept: Data?
        if let handle = try? FileHandle(forReadingFrom: url) {
            try? handle.seek(toOffset: UInt64(size - stderrKeptBytes))
            kept = try? handle.readToEnd()
            try? handle.close()
        }
        guard let tail = kept else { return }
        try? tail.write(to: url)
    }
}
#endif
